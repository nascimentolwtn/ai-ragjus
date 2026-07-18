"""
AI-RAGJus Web GUI - context window (num_ctx) resolution.

Mirrors src/config.sh's MODELO_CONTEXT_MAP + src/ai.sh::detect_model_context()
on the Bash/CLI side. CONTEXT_WINDOW="auto" in config.conf is resolved there
once at startup (carregar_configuracoes()); this module gives the Flask GUI
the exact same resolution so both surfaces send Ollama the same num_ctx for
a given MODELO_IA instead of the GUI silently falling back to a smaller
hardcoded default and triggering needless model reloads / prompt truncation
(see fix_gpu_model_reload.md).
"""

# Keep this in sync with MODELO_CONTEXT_MAP in src/config.sh.
MODEL_CONTEXT_MAP = {
    "lfm2.5:8b": 125000,
    "lfm2.5:1.5b": 125000,
    "qwen2.5:1.5b": 32768,
    "llama2": 4096,
}

# Conservative fallback for models absent from MODEL_CONTEXT_MAP - mirrors
# detect_model_context()'s "echo 8192" fallback branch.
DEFAULT_CONTEXT_WINDOW = 8192


def resolve_context_window(modelo_ia, context_window_config):
    """Resolve num_ctx exactly like src/ai.sh::detect_model_context().

    - context_window_config not "auto" (already numeric, or a numeric
      string): parsed and returned as int, no lookup.
    - context_window_config == "auto" (or missing/None, config.conf's own
      default): looked up in MODEL_CONTEXT_MAP by modelo_ia.
    - Model missing from the map (or modelo_ia missing/None): falls back to
      DEFAULT_CONTEXT_WINDOW, same as the Bash side.
    """
    config_value = "auto" if context_window_config is None else str(context_window_config).strip()

    if config_value.lower() != "auto":
        try:
            return int(config_value)
        except (TypeError, ValueError):
            return DEFAULT_CONTEXT_WINDOW

    return MODEL_CONTEXT_MAP.get(modelo_ia, DEFAULT_CONTEXT_WINDOW)
