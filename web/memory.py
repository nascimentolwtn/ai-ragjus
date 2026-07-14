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

import requests

import db

logger = logging.getLogger(__name__)

EXTRACTION_TIMEOUT = 30
SESSION_MEMORY_CHAR_CAP = 1500
GLOBAL_MEMORY_CHAR_CAP = 800
AUTO_GLOBAL_MEMORY_CAP = 30

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


def _call_ollama(prompt, ollama_url, model):
    try:
        resp = requests.post(
            f"{ollama_url}/api/generate",
            json={"model": model, "prompt": prompt, "stream": False, "options": {"temperature": 0}},
            timeout=EXTRACTION_TIMEOUT,
        )
        resp.raise_for_status()
        return resp.json().get("response", "")
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
    raw = _call_ollama(prompt, ollama_url, model)
    return _parse_facts(raw)


def extract_global_facts(query, answer, config):
    """Extract long-term/global facts from one chat turn. Best-effort."""
    ollama_url = config.get("OLLAMA_URL", "http://localhost:11434")
    model = config.get("MODELO_IA", "qwen2.5:1.5b")
    prompt = _GLOBAL_FACT_PROMPT.format(query=query, answer=answer)
    raw = _call_ollama(prompt, ollama_url, model)
    return _parse_facts(raw)


def _cap_text(lines, char_cap):
    """Join lines, keeping only as many (oldest-dropped-first) as fit the cap."""
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
            global_text = _cap_text(lines, GLOBAL_MEMORY_CHAR_CAP)
            if global_text:
                blocks.append("Fatos gerais sobre o usuário/domínio:\n" + global_text)
    except Exception as exc:  # pragma: no cover - defensive, memory is best-effort
        logger.warning("failed to load global memory: %s", exc)

    try:
        session_facts = db.get_session_memory(session_id)
        if session_facts:
            lines = [f["content"] for f in session_facts]
            session_text = _cap_text(lines, SESSION_MEMORY_CHAR_CAP)
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
