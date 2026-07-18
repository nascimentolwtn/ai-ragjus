"""
AI-RAGJus Web GUI - conversation memory (M3 per-chat, M4 global).

Best-effort helpers layered on top of `db.py`. Extraction talks directly to
Ollama's non-streaming /api/generate endpoint (no shell subprocess needed
here - this module never touches the vector store or document ingestion,
only the GUI-owned chat_history.db). Any failure here must never break the
main chat flow (mirrors the napkin rule for perguntar_ollama/gerar_embedding
resilience), so every network call is wrapped and swallowed.
"""
import logging
import re

import requests

import db
from config_utils import resolve_context_window

logger = logging.getLogger(__name__)

EXTRACTION_TIMEOUT = 30
SESSION_MEMORY_CHAR_CAP = 1500
GLOBAL_MEMORY_CHAR_CAP = 800
AUTO_GLOBAL_MEMORY_CAP = 30

# --- Context compaction (backlog items 8+10) --------------------------------
CHECKPOINT_PREFIX = "\U0001F4CB Resumo de contexto no turno {turn}: "  # 📋
COMPACT_TRANSCRIPT_MAX_MESSAGES = 20
COMPACT_TRANSCRIPT_CHAR_CAP = 4000
COMPACT_KEEP_RECENT_FACTS = 3  # checkpoint + this many trailing facts survive pruning

_CHECKPOINT_PROMPT = (
    "Você é um assistente que consolida o estado de uma conversa jurídica para "
    "reduzir o contexto reenviado ao modelo nos próximos turnos. Com base no "
    "histórico de mensagens e nos fatos já memorizados abaixo, produza um "
    "resumo objetivo, em português, em no máximo 5 linhas, cobrindo: fatos "
    "relevantes estabelecidos, temas discutidos e decisões/conclusões já "
    "alcançadas. Responda SOMENTE com o resumo, sem introduções nem "
    "despedidas.\n\n"
    "Histórico da conversa:\n{transcript}\n\n"
    "Fatos já memorizados nesta conversa:\n{existing_facts}"
)

_SESSION_FACT_PROMPT = (
    "Extraia até 3 fatos objetivos e curtos desta interação, um por linha. "
    "Responda SOMENTE com os fatos ou com a palavra NENHUM se não houver "
    "fato relevante para lembrar em futuras perguntas desta mesma conversa.\n\n"
    "Pergunta do usuário:\n{query}\n\nResposta do assistente:\n{answer}"
)

_GLOBAL_FACT_PROMPT = (
    "Extraia até 2 preferências ou fatos de LONGO PRAZO sobre o usuário ou seu "
    "domínio de atuação (ex: área do direito em que atua, tipo de cliente, "
    "preferências recorrentes). Responda SOMENTE com os fatos, um por linha, "
    "no formato 'chave_curta: valor descritivo', usando uma chave específica "
    "(nunca a palavra literal 'chave' ou 'valor'). "
    "Exemplo de resposta válida:\n"
    "area_atuacao: direito trabalhista\n"
    "Responda 'NENHUM' se não houver fato de longo prazo nesta interação.\n\n"
    "Pergunta do usuário:\n{query}\n\nResposta do assistente:\n{answer}"
)

# Placeholder keys/values the small model sometimes echoes back literally
# from the prompt template instead of producing real content.
_PLACEHOLDER_TOKENS = {"chave", "valor", "key", "value", "chave_curta", "exemplo"}


def _num_ctx(config):
    """Match the num_ctx the main RAG path sends (src/ai.sh::perguntar_ollama).

    Ollama reloads a resident model whenever a request's num_ctx differs from
    what it was loaded with. Omitting it here made these background calls hit
    the GPU inference model at Ollama's 4096 default, forcing a reload on every
    turn (and another reload back to the real value on the next real
    question). Keeping the value identical avoids the churn.

    Resolves CONTEXT_WINDOW="auto" via resolve_context_window() - same
    MODEL_CONTEXT_MAP/detect_model_context() logic the Bash CLI uses - so the
    background extraction calls agree with the main RAG path's num_ctx instead
    of falling back to a smaller hardcoded default.
    """
    return resolve_context_window(config.get("MODELO_IA"), config.get("CONTEXT_WINDOW", "auto"))


_THINK_BLOCK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def _strip_think(text):
    """Drop <think>...</think> reasoning some models (e.g. lfm2.5, deepseek-r1,
    qwq) emit before their real answer - mirrors src/ai.sh's TAG_PENSAMENTO_*
    handling for the CLI/streaming path. Extraction calls here are
    non-streaming, so the whole block lands in one response; left unstripped,
    _parse_facts() treats each line of the model's internal monologue as a
    candidate fact and persists it, poisoning session/global memory (global
    facts get re-injected into every future session's prompt).
    """
    text = _THINK_BLOCK_RE.sub("", text or "")
    # Truncated response (opening tag, no closing one yet): nothing after it
    # is trustworthy, so drop from <think> onward.
    text = re.split(r"<think>", text, maxsplit=1, flags=re.IGNORECASE)[0]
    return text.strip()


def _call_ollama(prompt, ollama_url, model, num_ctx=16384):
    try:
        resp = requests.post(
            f"{ollama_url}/api/generate",
            json={
                "model": model,
                "prompt": prompt,
                "stream": False,
                "options": {"temperature": 0, "num_ctx": num_ctx},
            },
            timeout=EXTRACTION_TIMEOUT,
        )
        resp.raise_for_status()
        return _strip_think(resp.json().get("response", ""))
    except (requests.RequestException, ValueError) as exc:
        logger.warning("memory extraction call failed: %s", exc)
        return ""


def _parse_facts(raw_text):
    facts = []
    for line in (raw_text or "").splitlines():
        line = line.strip().lstrip("-*•").strip()
        if not line or line.upper().startswith("NENHUM"):
            continue
        facts.append(line)
    return facts


def extract_facts(query, answer, config):
    """Extract short session-scoped facts from one chat turn. Best-effort."""
    ollama_url = config.get("OLLAMA_URL", "http://localhost:11434")
    model = config.get("MODELO_IA", "qwen2.5:1.5b")
    prompt = _SESSION_FACT_PROMPT.format(query=query, answer=answer)
    raw = _call_ollama(prompt, ollama_url, model, _num_ctx(config))
    return _parse_facts(raw)


def extract_global_facts(query, answer, config):
    """Extract long-term/global facts from one chat turn. Best-effort."""
    ollama_url = config.get("OLLAMA_URL", "http://localhost:11434")
    model = config.get("MODELO_IA", "qwen2.5:1.5b")
    prompt = _GLOBAL_FACT_PROMPT.format(query=query, answer=answer)
    raw = _call_ollama(prompt, ollama_url, model, _num_ctx(config))
    return _parse_facts(raw)


def cap_text(lines, char_cap):
    """Join lines, keeping only as many (oldest-dropped-first) as fit the cap.

    Public (not `_`-prefixed): also used by context_tracker.calculate_usage()
    so its per-session token estimate stays aligned with what
    build_memory_context() actually injects into the prompt.
    """
    kept = []
    total = 0
    for line in reversed(lines):
        total += len(line) + 1
        if total > char_cap and kept:
            break
        kept.append(line)
    kept.reverse()
    return "\n".join(kept)


def build_memory_context(session_id):
    """Build the RAG_MEMORY_CONTEXT block: global facts (capped) + session
    facts (capped). Returns "" if nothing is stored (M3/M4 tables may not
    have data yet, or the feature may be unused for this session).
    """
    blocks = []

    try:
        global_entries = db.list_global_memory().get("enabled", [])
        if global_entries:
            lines = [f"- {e['key']}: {e['value']}" for e in global_entries]
            global_text = cap_text(lines, GLOBAL_MEMORY_CHAR_CAP)
            if global_text:
                blocks.append("Fatos gerais sobre o usuário/domínio:\n" + global_text)
    except Exception as exc:  # pragma: no cover - defensive, memory is best-effort
        logger.warning("failed to load global memory: %s", exc)

    try:
        session_facts = db.get_session_memory(session_id)
        if session_facts:
            lines = [f["content"] for f in session_facts]
            session_text = cap_text(lines, SESSION_MEMORY_CHAR_CAP)
            if session_text:
                blocks.append("Fatos desta conversa:\n" + session_text)
    except Exception as exc:  # pragma: no cover
        logger.warning("failed to load session memory: %s", exc)

    return "\n\n".join(blocks)


def record_turn_memory(session_id, query, answer, config, auto_global=True):
    """Runs after a turn completes: extracts + persists session facts, and
    (if enabled) extracts + upserts global facts. Meant to be called from a
    background thread so it never delays the SSE response.
    """
    try:
        for fact in extract_facts(query, answer, config):
            db.add_session_memory(session_id, fact)
        db.prune_session_memory(session_id, keep=10)
    except Exception as exc:  # pragma: no cover
        logger.warning("session memory extraction failed: %s", exc)

    if not auto_global:
        return

    try:
        for fact in extract_global_facts(query, answer, config):
            key, _, value = fact.partition(":")
            key = key.strip().lower().replace(" ", "_")[:60]
            value = (value.strip() or fact)[:500]
            if not key or not value:
                continue
            if key in _PLACEHOLDER_TOKENS or value.lower() in _PLACEHOLDER_TOKENS:
                continue
            if db.count_auto_global_memory() >= AUTO_GLOBAL_MEMORY_CAP:
                db.evict_oldest_auto_global_memory()
            db.upsert_global_memory(key, value, source="auto")
    except Exception as exc:  # pragma: no cover
        logger.warning("global memory extraction failed: %s", exc)


def _build_compact_transcript(session_id):
    """Recent turns of a session's chat transcript, capped to a char budget,
    used as the source material for the checkpoint summary."""
    messages = db.get_messages(session_id)
    recent = messages[-COMPACT_TRANSCRIPT_MAX_MESSAGES:]
    lines = []
    for m in recent:
        role = "Advogado" if m["role"] == "user" else "Assistente"
        content = (m.get("content") or "").strip()
        if content:
            lines.append(f"{role}: {content}")
    text = "\n".join(lines)
    if len(text) > COMPACT_TRANSCRIPT_CHAR_CAP:
        text = text[-COMPACT_TRANSCRIPT_CHAR_CAP:]
    return text


def generate_checkpoint_summary(session_id, config):
    """Ask the model to consolidate this session's transcript + memorized
    facts into one short checkpoint summary. Best-effort - returns "" on any
    failure so the caller can fall back to a generic placeholder line rather
    than skip compaction entirely.
    """
    transcript = _build_compact_transcript(session_id)
    if not transcript:
        return ""

    try:
        existing = db.get_session_memory(session_id)
        existing_facts = "\n".join(f["content"] for f in existing) or "(nenhum)"
    except Exception:  # pragma: no cover - defensive
        existing_facts = "(nenhum)"

    ollama_url = config.get("OLLAMA_URL", "http://localhost:11434")
    model = config.get("MODELO_IA", "qwen2.5:1.5b")
    prompt = _CHECKPOINT_PROMPT.format(transcript=transcript, existing_facts=existing_facts)
    raw = _call_ollama(prompt, ollama_url, model, _num_ctx(config))
    return raw.strip()


def compact_session(session_id, config, turn_number=None, reason="manual"):
    """Backlog items 8 (auto-trigger at 80% context usage) and 10 (manual
    "Compact now" button): consolidate this session's facts/topics/decisions
    into a single checkpoint message, persist it into session_memory, and
    truncate the working context by pruning older individual facts that are
    now folded into the checkpoint - so the NEXT turn's RAG_MEMORY_CONTEXT
    (see build_memory_context) injects one short summary instead of every
    fact accumulated so far.

    Returns a dict describing the checkpoint (content/turn/reason), or None
    if the session has no messages yet (nothing to compact).
    """
    if turn_number is None:
        turn_number = db.count_user_messages(session_id)
    if turn_number <= 0:
        return None

    summary = generate_checkpoint_summary(session_id, config)
    if not summary:
        summary = "Sem fatos ou decisões relevantes identificados para consolidar até este ponto."

    checkpoint_text = CHECKPOINT_PREFIX.format(turn=turn_number) + summary
    db.add_session_memory(session_id, checkpoint_text)
    db.prune_session_memory(session_id, keep=COMPACT_KEEP_RECENT_FACTS)

    return {"content": checkpoint_text, "turn": turn_number, "reason": reason}
