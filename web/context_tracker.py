"""
AI-RAGJus Web GUI - per-turn context window usage estimator (M5).

Each RAG turn is stateless (system prompt + acervo metadata + retrieved
docs + query + memory, never chat history - see src/rag_query.sh), so usage
is computed per-turn, not cumulatively across a session. Token counts are a
char-based estimate (Portuguese legal text: ~3.3 chars/token) until Ollama's
own `prompt_eval_count` arrives via the "stats" SSE event and replaces it
client-side with an exact number.
"""
import db
import memory


class ContextTracker:
    def __init__(self, context_window=16384, token_ratio=0.30, output_reserve=1024):
        """
        Args:
            context_window: model's num_ctx (tokens); mirrors config.conf CONTEXT_WINDOW.
            token_ratio: estimation factor, 1 token ~= 1/token_ratio chars.
            output_reserve: tokens reserved for the model's response.
        """
        self.context_window = context_window
        self.token_ratio = token_ratio
        self.output_reserve = output_reserve
        self.available = max(1, context_window - output_reserve)

    @classmethod
    def from_config(cls, config):
        """Build a tracker straight from the raw config dict (CONTEXT_WINDOW/
        TOKEN_RATIO strings from config.conf). Shared by the context-usage
        endpoint and the auto-compact threshold check in /api/chat (backlog
        item 8) so both agree on the same available-token math.
        """
        try:
            context_window = int(config.get("CONTEXT_WINDOW", 16384))
        except (TypeError, ValueError):
            context_window = 16384
        try:
            token_ratio = float(config.get("TOKEN_RATIO", 0.30))
        except (TypeError, ValueError):
            token_ratio = 0.30
        return cls(context_window=context_window, token_ratio=token_ratio)

    def estimate_tokens(self, text):
        return max(1, int(len(text) * self.token_ratio))

    def calculate_usage(self, session_id, prompt_char_estimate=None):
        """Per-turn usage estimate, scoped to a single session (`session_id`
        is required and every underlying lookup below is filtered by it,
        except global_memory which is intentionally cross-session - see
        below). `prompt_char_estimate` may carry `retrieved_docs` and
        `query` char counts measured client-side for the turn about to be
        sent; falls back to typical defaults otherwise.
        """
        if session_id is None:
            raise ValueError("calculate_usage() requires a session_id")

        estimate = prompt_char_estimate or {}

        # System prompt template + acervo metadata (file list is unbounded
        # but typically small; ~2K chars is a reasonable fixed estimate).
        system_tokens = self.estimate_tokens("x" * 2000) + 550

        doc_chars = estimate.get("retrieved_docs", 10000)
        retrieved_tokens = self.estimate_tokens("x" * doc_chars)

        query_chars = estimate.get("query", 100)
        query_tokens = self.estimate_tokens("x" * query_chars)

        # Both blocks below mirror memory.build_memory_context()'s formatting
        # AND char caps exactly, so the estimate reflects what will actually
        # be injected into THIS session's next prompt - not the raw,
        # unbounded fact store. Session facts are already scoped to
        # `session_id` by db.get_session_memory(); global facts are
        # intentionally cross-session (M4 design: they're re-injected into
        # every session's prompt), but must still be capped here the same
        # way they're capped at injection time, otherwise a large shared
        # global-memory store (accumulated across many other sessions over
        # time) inflates every individual session's usage_percent and can
        # trip the auto-compact threshold on a session that never came
        # close to it.
        session_tokens = 0
        try:
            session_facts = db.get_session_memory(session_id)
            if session_facts:
                lines = [f["content"] for f in session_facts]
                mem_text = memory.cap_text(lines, memory.SESSION_MEMORY_CHAR_CAP)
                session_tokens = self.estimate_tokens(mem_text)
        except (AttributeError, KeyError):
            pass  # M3 table not present / session has no facts yet

        global_tokens = 0
        try:
            global_result = db.list_global_memory()
            global_facts = global_result.get("enabled", [])
            if global_facts:
                lines = [f"- {f['key']}: {f['value']}" for f in global_facts]
                mem_text = memory.cap_text(lines, memory.GLOBAL_MEMORY_CHAR_CAP)
                global_tokens = self.estimate_tokens(mem_text)
        except (AttributeError, KeyError):
            pass  # M4 table not present

        total_tokens = system_tokens + retrieved_tokens + query_tokens + session_tokens + global_tokens
        usage_percent = (total_tokens / self.available) * 100

        if usage_percent < 60:
            status = "safe"
        elif usage_percent < 75:
            status = "caution"
        elif usage_percent < 85:
            status = "warning"
        else:
            status = "critical"

        return {
            "total_tokens": total_tokens,
            "available_tokens": self.available,
            "context_window": self.context_window,
            "output_reserve": self.output_reserve,
            "usage_percent": round(usage_percent, 1),
            "breakdown": {
                "system_prompt": system_tokens,
                "retrieved_docs": retrieved_tokens,
                "query": query_tokens,
                "session_memory": session_tokens,
                "global_memory": global_tokens,
            },
            "status": status,
            "exact_prompt_tokens": None,
        }
