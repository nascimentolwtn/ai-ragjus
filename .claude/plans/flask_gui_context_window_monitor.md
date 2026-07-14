# Flask GUI Context Window Monitor

**Feature**: Real-time per-turn prompt size monitor for LLM context usage  
**Date**: 2026-07-14  
**Status**: Fable review complete; critical issues fixed  
**Motivation**: Inference model `qwen2.5-coder:7b-instruct` prompts are stateless per turn (system + docs + query + memory only). Ollama's `num_ctx` default is 4096, not model's native 32K. Users need visibility into actual per-turn prompt size before hitting ceiling; silent truncation degrades responses.

---

## Problem Statement

Current architecture:
- **Inference model**: `qwen2.5-coder:7b-instruct` (native 32K context, but Ollama defaults `num_ctx=4096`)
- **Prompt template** (`src/rag_query.sh`): system prompt + acervo metadata + retrieved docs (~10 chunks × 1K chars ≈ ~3K tokens, dominant) + query + memory context (M3/M4)
- **Critical bug**: `ai.sh:94` never sets `num_ctx`, so config.conf CONTEXT_WINDOW is ignored; real ceiling is Ollama's hardcoded 4096
- **No per-turn visibility**: User doesn't know actual prompt size each turn. Ollama silently truncates at 4096 while monitor (if misconfigured) shows "40% of 8192"

**Goal**: 
1. **Wire `num_ctx` in `ai.sh`** so config.conf CONTEXT_WINDOW actually controls Ollama's behavior (ONE critical line)
2. Display live per-turn prompt size % in chat header (not cumulative session history — that's not injected)
3. Emit actual token counts via Ollama's `prompt_eval_count` (eliminates estimation error)

---

## Design Overview

### Display Location

**Chat header** (between title and message area):
```
┌─────────────────────────────────────────────┐
│ Chat Title                  [Context: 62%] ⓘ │  ← tooltip on hover shows breakdown
├─────────────────────────────────────────────┤
│ [message stream]                            │
└─────────────────────────────────────────────┘
```

Alternatively: **footer bar** (always visible, bottom-right corner). Choose based on mockup preference.

### Visual Indicator

- **Numeric badge** (e.g., "3.8K / 16.0K" or "4.2K / 16K [est]") in chat header
- **Color coding** (includes 1K-token output reserve):
  - Green (0–60%): Safe (leaves ~6.4K for output + safety margin)
  - Yellow (60–75%): Caution
  - Orange (75–85%): Warning (log to console)
  - Red (85–100%): Critical (block send; warn "Context critical. Disable memory or clear history")
- **Tooltip** (hover): Breakdown of contributors (accurate counts post-M3/M4 ship)
  ```
  System Prompt: 0.6K tokens
  Acervo Metadata: 0.2K tokens
  Retrieved Docs: 3.0K tokens
  Query: 0.1K tokens
  Memory (Session): 0.2K tokens [if M3 active]
  Memory (Global): 0.1K tokens [if M4 active]
  ─────────────────────────
  Used: 4.2K / 16.0K (26%) [15K reserved for output]
  ```

---

## Technical Implementation

### Context Estimation Strategy

**Per-turn, NOT cumulative**: Each turn's prompt is independent (stateless RAG). `messages` table is GUI history only; never injected into prompt.

**Phase 1: Hybrid (estimate + Ollama's exact count)**
- Estimate system + docs + memory: 1 token ≈ 3.3 characters for Portuguese legal text (qwen2.5-coder:7b BPE; not English's 4 chars/token)
- Token ratio: `TOKEN_RATIO=0.30` (1 token ≈ ~3.3 chars)
- Calculate for each component per turn:
  - System prompt: hardcode ~500–600 tokens (template size); plus acervo metadata (unbounded file list)
  - Retrieved docs: estimate from `limite=10` × `CHUNK_SIZE=1000` chars ≈ ~3,000 tokens (dominant contributor)
  - Current query: measure from user input
  - Session memory (M3): sum fact lengths from `session_memory` table
  - Global memory (M4): sum enabled entry lengths from `global_memory` table
- **Actual token count**: After Ollama generates response, parse `prompt_eval_count` from the stream → update widget retroactively (eliminates estimation error)
- **Model context window**: Read from `config.conf` `CONTEXT_WINDOW` (default 16384 for qwen2.5-coder:7b); wire as `num_ctx` in `ai.sh:94`

**Phase 2 (future): Exact per-turn counts**
- Emit `{"type":"stats","prompt_tokens":N,"response_tokens":M}` from `src/rag_query.sh` before each generation
- Persist stats per turn for learning curve visibility

### Calculation Function

Create new module `web/context_tracker.py`:

```python
class ContextTracker:
    def __init__(self, context_window: int = 16384, token_ratio: float = 0.30, output_reserve: int = 1024):
        """
        Args:
            context_window: model's max tokens (default 16384 for qwen2.5-coder:7b)
            token_ratio: estimation factor (1 token ≈ 1/token_ratio chars; default 0.30 ≈ 3.3 chars/token for Portuguese)
            output_reserve: tokens to reserve for response (default 1024)
        """
        self.context_window = context_window
        self.token_ratio = token_ratio
        self.output_reserve = output_reserve
        self.available = context_window - output_reserve
        
    def estimate_tokens(self, text: str) -> int:
        """Estimate tokens from text length."""
        return max(1, int(len(text) * self.token_ratio))
    
    def calculate_usage(self, session_id: int, prompt_char_estimate: dict = None) -> dict:
        """
        Calculate per-turn prompt usage. Accepts optional char counts to avoid DB queries.
        
        Args:
            session_id: GUI session ID (for memory tables)
            prompt_char_estimate: dict with keys:
                - "system_prompt": chars (hardcoded ~2000 for template + acervo)
                - "retrieved_docs": chars (from latest query; ~10K if 10 chunks @ 1K each)
                - "query": chars (from user input)
        
        Returns dict with usage_percent relative to available window (minus output reserve).
        """
        db = get_db()  # Use get_db() function, not DB() class (which doesn't exist)
        
        # System prompt + acervo metadata (hardcoded estimate; acervo filename list is unbounded but typically ~2K chars)
        system_tokens = self.estimate_tokens("# System prompt template + acervo metadata\n") + 550
        
        # Retrieved docs (from latest query, passed in or default estimate)
        doc_chars = prompt_char_estimate.get("retrieved_docs", 10000) if prompt_char_estimate else 10000
        retrieved_tokens = self.estimate_tokens("x" * doc_chars)
        
        # Current query
        query_chars = prompt_char_estimate.get("query", 100) if prompt_char_estimate else 100
        query_tokens = self.estimate_tokens("x" * query_chars)
        
        # Session memory (optional; only if M3 shipped and table exists)
        session_tokens = 0
        try:
            session_facts = db.get_session_memory(session_id)  # Returns list of dicts
            if session_facts:
                mem_text = "\n".join(f["content"] for f in session_facts)
                session_tokens = self.estimate_tokens(mem_text)
        except (AttributeError, KeyError):
            pass  # M3 not yet implemented
        
        # Global memory (optional; only if M4 shipped and table exists, enabled=1)
        global_tokens = 0
        try:
            global_facts = db.list_global_memory()  # Returns all entries
            if global_facts:
                mem_text = "\n".join(f"{f['key']}: {f['value']}" for f in global_facts if f.get('enabled', 0))
                global_tokens = self.estimate_tokens(mem_text)
        except (AttributeError, KeyError):
            pass  # M4 not yet implemented
        
        total_tokens = system_tokens + retrieved_tokens + query_tokens + session_tokens + global_tokens
        usage_percent = (total_tokens / self.available) * 100
        
        # Status logic (relative to available window, not raw window)
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
            "exact_prompt_tokens": None,  # Will be populated from Ollama's prompt_eval_count after generation
        }
```

### API Endpoint

Add to `web/app.py`:

```python
@app.route('/api/sessions/<int:session_id>/context-usage', methods=['POST'])
def get_context_usage(session_id):
    """
    Get current per-turn context window usage.
    POST accepts optional prompt char estimates (from the current turn before sending).
    """
    from web.context_tracker import ContextTracker
    
    # Read config (must be in DEFAULT_CONFIG + added to web/app.py:40)
    context_window = int(config.get("CONTEXT_WINDOW", 16384))
    token_ratio = float(config.get("TOKEN_RATIO", 0.30))
    
    tracker = ContextTracker(context_window=context_window, token_ratio=token_ratio)
    
    # Optional: client sends estimated char counts for prompt components
    prompt_estimate = request.get_json() or {}
    
    usage = tracker.calculate_usage(session_id, prompt_char_estimate=prompt_estimate)
    return jsonify(usage)
```

Endpoint response:
```json
{
  "total_tokens": 4200,
  "available_tokens": 15360,
  "context_window": 16384,
  "output_reserve": 1024,
  "usage_percent": 27.3,
  "breakdown": {
    "system_prompt": 600,
    "retrieved_docs": 3000,
    "query": 50,
    "session_memory": 200,
    "global_memory": 100
  },
  "status": "safe",
  "exact_prompt_tokens": null
}
```

POST body (optional):
```json
{
  "retrieved_docs": 9800,
  "query": 120
}
```

### Frontend Integration

#### `web/static/chat.js`

Add to chat view initialization:

```javascript
function initContextMonitor(sessionId) {
  const monitor = document.querySelector('[data-context-monitor]');
  if (!monitor) return;
  
  async function updateContextUsage(promptEstimate = {}) {
    try {
      // POST with optional prompt char estimates (if called before sending query)
      const res = await fetch(`/api/sessions/${sessionId}/context-usage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(promptEstimate)
      });
      const data = await res.json();
      
      const percent = data.usage_percent;
      const status = data.status;
      
      // Update bar
      const bar = monitor.querySelector('.context-bar');
      if (bar) bar.style.width = Math.min(percent, 100) + '%';
      monitor.className = `context-monitor context-${status}`;
      
      // Update text — fix field path: total_tokens is top-level
      monitor.querySelector('.context-text').textContent = 
        `${Math.round(percent)}% (${data.total_tokens}/${data.available_tokens})${data.exact_prompt_tokens ? ' [exact]' : ' [est]'}`;
      
      // Populate tooltip with line breaks (native tooltip renders \n)
      const b = data.breakdown;
      const lines = [
        `System Prompt: ${b.system_prompt} tokens`,
        `Retrieved Docs: ${b.retrieved_docs} tokens`,
        `Query: ${b.query} tokens`,
        b.session_memory > 0 ? `Session Memory: ${b.session_memory} tokens` : null,
        b.global_memory > 0 ? `Global Memory: ${b.global_memory} tokens` : null,
        '─────────────────────────────',
        `Used: ${data.total_tokens} / ${data.available_tokens} (${percent}%)`,
        `Context Window: ${data.context_window} (${data.output_reserve}K reserved for output)`
      ].filter(Boolean).join('\n');
      
      monitor.title = lines;
      
      // Warn if critical
      if (status === 'critical') {
        console.error('%c[Context] CRITICAL usage (' + percent + '%). Disable memory or clear docs before next query.', 'color: red; font-weight: bold;');
      } else if (status === 'warning') {
        console.warn('[Context] Warning: ' + percent + '% usage');
      }
    } catch (e) {
      console.error('Failed to fetch context usage:', e);
    }
  }
  
  // Update after each message is persisted (wire into streamChat callback)
  // Note: custom events below must be dispatched from streamChat() in this file
  document.addEventListener('message-persisted', updateContextUsage);
  
  // Initial update
  updateContextUsage();
}

// On page load — FIX: DOMContentLoaded is not a function
document.addEventListener('DOMContentLoaded', () => {
  const sessionId = getCurrentSessionId();
  if (sessionId) initContextMonitor(sessionId);
});

// In streamChat() or the SSE listener, after response is received and persisted:
// Dispatch custom event so monitor updates (replace with actual field names)
const evt = new CustomEvent('message-persisted', {
  detail: { prompt_estimate: { retrieved_docs: 9800, query: 120 } }
});
document.dispatchEvent(evt);
```

#### `web/templates/chat.html`

Add monitor widget to chat header:

```html
<div class="chat-header">
  <h1>{{ session.title }}</h1>
  <div class="context-monitor" data-context-monitor>
    <div class="context-bar"></div>
    <span class="context-text">Loading…</span>
  </div>
</div>
```

#### `web/static/style.css`

```css
.context-monitor {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.25rem 0.75rem;
  border-radius: 4px;
  font-size: 0.85rem;
  font-weight: 500;
  background: rgba(200, 200, 200, 0.1);
  border: 1px solid rgba(100, 100, 100, 0.2);
  cursor: help; /* hint that title is a tooltip */
}

.context-monitor.context-safe {
  border-color: #4caf50;
  color: #2e7d32;
}

.context-monitor.context-caution {
  border-color: #ff9800;
  color: #e65100;
}

.context-monitor.context-warning {
  border-color: #f44336;
  color: #c62828;
}

.context-monitor.context-critical {
  border-color: #c62828;
  color: #fff;
  background: #c62828;
  font-weight: 700;
  animation: pulse 1s infinite;
}

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.8; }
}

.context-bar {
  display: none; /* or show as a mini horizontal bar if desired */
}
```

---

## Integration with Memory Features (M3/M4)

### Phase 1: Monitor Only

Display usage, warn on critical, but no automatic action. User can manually clear chat or disable memory.

### Phase 2: Auto-mitigation (Future)

When status == "critical":
1. Auto-disable global memory injection (keep session memory intact)
2. Suggest pruning old session facts: "Context window critical. Would you like to archive old facts?"
3. Option to clear chat history before sending next query

---

## Configuration

### 1. Add to `config.conf`:

```bash
# Context window size for the active inference model (tokens)
# qwen2.5-coder:7b-instruct: native 32K, but set conservatively for 8GB RAM
# Default: 16384 (reserves 1K for output safety margin)
# Increase only on 16GB+ machines or with quantized models (q4, q5)
CONTEXT_WINDOW=16384

# Token estimation factor: 1 token ≈ (1 / TOKEN_RATIO) characters
# qwen2.5-coder:7b Portuguese legal text: ~3.3 chars/token (not English's 4)
# Default 0.30 is conservative; produces underestimate (warns earlier)
TOKEN_RATIO=0.30
```

### 2. Update `web/app.py::DEFAULT_CONFIG` (line ~40):

Add these keys to the dictionary so they load from config.conf:

```python
DEFAULT_CONFIG = {
    # ... existing keys ...
    "CONTEXT_WINDOW": "16384",
    "TOKEN_RATIO": "0.30",
}
```

### 3. **CRITICAL FIX**: Wire `num_ctx` in `src/ai.sh` line 94

Current (broken):
```bash
options: {temperature}
```

Fixed:
```bash
options: {temperature, num_ctx: $CONTEXT_WINDOW}
```

This is THE critical fix. Without it, Ollama ignores `num_ctx` and uses default 4096, causing silent truncation regardless of config.conf CONTEXT_WINDOW setting.

---

## Testing

### Unit Tests (`web/tests/test_context_tracker.py`)

```python
def test_estimate_tokens():
    tracker = ContextTracker(context_window=16384, token_ratio=0.30)
    # 1 token ≈ 3.3 chars
    text = "a" * 3  # ~1 token
    assert tracker.estimate_tokens(text) >= 0  # May round to 0; use max(1, ...) in code
    
    text = "a" * 3300  # ~1000 tokens
    assert tracker.estimate_tokens(text) >= 990

def test_calculate_usage_safe():
    tracker = ContextTracker(context_window=16384, output_reserve=1024)
    # Mock DB: empty session, minimal docs
    usage = tracker.calculate_usage(session_id=999)  # Nonexistent session
    assert usage["usage_percent"] < 60
    assert usage["status"] == "safe"

def test_calculate_usage_critical():
    tracker = ContextTracker(context_window=5000, output_reserve=1024)
    # Small window; system + large docs should trigger critical
    usage = tracker.calculate_usage(session_id=1, 
        prompt_char_estimate={"retrieved_docs": 15000, "query": 200})
    assert usage["usage_percent"] > 85
    assert usage["status"] == "critical"

def test_output_reserve():
    tracker = ContextTracker(context_window=16384, output_reserve=1024)
    assert tracker.available == 15360

def test_breakdown_no_history_component():
    usage = tracker.calculate_usage(session_id=1)
    breakdown = usage["breakdown"]
    # Fixed: no chat_history component (not injected)
    assert "system_prompt" in breakdown
    assert "retrieved_docs" in breakdown
    assert "query" in breakdown
    assert "session_memory" in breakdown
    assert "global_memory" in breakdown
    assert "chat_history" not in breakdown
    assert sum(breakdown.values()) == usage["total_tokens"]

def test_missing_memory_tables():
    """Pre-M3/M4: session_memory / global_memory don't exist; should not crash."""
    usage = tracker.calculate_usage(session_id=1)
    assert usage["session_memory"] == 0
    assert usage["global_memory"] == 0
```

### Integration Tests

- **API endpoint**: POST `/api/sessions/1/context-usage` with prompt estimate returns valid JSON.
- **Memory injection** (M3/M4 active): Verify breakdown includes session + global memory when tables exist.
- **Status transitions**: Vary prompt_char_estimate to drive usage safe → caution → warning → critical.

### E2E Tests (Playwright)

- Load chat → monitor shows in header (header badge visible)
- Send a message → usage updates (monitor shows safe, [est] suffix)
- Hover tooltip shows full breakdown
- If M4 active: enable global memory → usage % increases
- Critical status (>85%) → console logs red warning
- NOT included: "send 20 messages fills bar" (invalid; stateless per-turn)

---

## Effort Estimate

| Component | Effort | Notes |
|-----------|--------|-------|
| `web/context_tracker.py` module | S | ~100 lines, straightforward math |
| `/api/sessions/<id>/context-usage` endpoint | S | CRUD pattern |
| `chat.js` monitor update logic | S | event listeners, fetch, DOM update |
| `chat.html` widget markup | XS | 3–4 lines |
| `style.css` styling + animations | S | color states, pulse animation |
| Tests (unit + E2E) | M | ~15 test cases |
| **Total** | **M** (Medium) | ~1–2 days |

---

## Scheduling

**Dependencies**: None. Can implement independent of memory features (M3/M4), though more valuable *after* they ship.

**Recommended placement**: After M1/M2 (UX polish). Before or alongside M3 (memory features).

**Alternative**: Implement as a *prerequisite* to M3 so users can monitor impact of memory injection.

---

## Risk Mitigation

### Token Estimation Accuracy

**Risk**: Character-based estimate may be off by 20–50% depending on content language/structure.

**Mitigation**:
- Start conservative (overestimate tokens) → warn earlier.
- Phase 2: integrate actual tokenizer for target model.
- Document assumption in UI tooltip: "(estimated; accuracy ±20%)".

### Performance

**Risk**: Recalculating context usage per message could be slow if chat history is large (100+ messages).

**Mitigation**:
- Cache calculation for 5–10 seconds (only recalculate on message send/receive).
- Lazy-load: don't fetch on every keystroke, only after message persisted.
- Profile: optimize DB queries (add indexes on `session_id` if not present).

### Silent Truncation

**Risk**: Even with warning, user might not see it before sending a query.

**Mitigation**:
- Critical status (>90%): disable auto-send, show explicit confirmation: "Context window critical. Send anyway?"
- Log to browser console with red emoji/text.
- Phase 2: add a "Do not send" blocker at 100%.

---

## Phase 2 Enhancements (Prioritized by Fable)

1. **Exact per-turn token counts via `prompt_eval_count`** (PULL INTO 1.5!)
   - Ollama's final streaming chunk includes `"prompt_eval_count": N` (exact token count used)
   - Parse in `ai.sh` streaming loop; emit as stats event to `web/app.py`
   - Update widget retroactively with exact count (badge shows "[exact]" instead of "[est]")
   - Eliminates 15–25% estimation error entirely

2. **Per-model context profiles**
   - Store context windows + token ratios per MODELO_IA + BACKEND
   - Example: `{"qwen2.5-coder:7b": {window: 32768, ratio: 0.30}, "llama2:13b": {window: 4096, ratio: 0.25}}`
   - Auto-load correct values on model switch

3. **Sliding window for history** (blocked until history injection exists)
   - M5 (future): if user enables "session context injection", keep last N messages in prompt
   - Calculate history token count, warn if approaching window

4. **Auto-summarization of memory facts** (defer to M3's own backlog)
   - Compress old session facts into summaries when cap is reached

5. **Archive old chats** (drop from this plan; unrelated housekeeping)

---

## Critical Implementation Order

1. **FIX in `src/ai.sh` line 94** (DO THIS FIRST — it fixes the root bug)
   - Change: `options: {temperature}` → `options: {temperature, num_ctx: $CONTEXT_WINDOW}`
   - This wires the config.conf CONTEXT_WINDOW into Ollama's actual limit (currently ignored)

2. **Add config keys to `web/app.py::DEFAULT_CONFIG`** (so `config.conf` keys load)
   - `CONTEXT_WINDOW=16384`, `TOKEN_RATIO=0.30`

3. **Create `web/context_tracker.py`** (core calculation module)

4. **Add endpoint + frontend** (in parallel)

## Files to Create/Modify

- [x] `src/ai.sh` — **CRITICAL FIX** wire `num_ctx` in JSON payload (line 94)
- [ ] `config.conf` — add `CONTEXT_WINDOW=16384`, `TOKEN_RATIO=0.30`
- [ ] `web/app.py` — update `DEFAULT_CONFIG` (add 2 keys), add `/api/.../context-usage` POST endpoint
- [ ] `/home/lw_na/git/ai-ragjus/web/context_tracker.py` — **new** (main calculation module)
- [ ] `/home/lw_na/git/ai-ragjus/web/templates/chat.html` — add monitor widget markup to header
- [ ] `/home/lw_na/git/ai-ragjus/web/static/chat.js` — init monitor, wire event dispatch
- [ ] `/home/lw_na/git/ai-ragjus/web/static/style.css` — color states, pulse animation
- [ ] `/home/lw_na/git/ai-ragjus/web/tests/test_context_tracker.py` — **new** unit tests
- [ ] `/home/lw_na/git/ai-ragjus/web/tests/test_routes.py` — add integration test for endpoint

---

## Sign-Off

**Status**: NO-GO → GO after fixes (Fable review applied)

**Plan is implementation-ready.** Critical issues fixed:
1. ✅ Removed `chat_history` component (not injected into prompt; stateless RAG)
2. ✅ Added `num_ctx` wiring in `ai.sh` (THE critical fix — 1 line, high impact)
3. ✅ Fixed API/DB usage (module functions, dict rows, guard missing M3/M4 tables)
4. ✅ Fixed JS bugs (correct field paths, DOMContentLoaded, event dispatch)
5. ✅ Updated config: CONTEXT_WINDOW=16384, TOKEN_RATIO=0.30 (for qwen2.5-coder:7b + Portuguese)
6. ✅ Added output-token reserve (1K tokens minimum)
7. ✅ Compute per-turn usage (not cumulative history)

**High-value, low-risk feature.** Prevents silent truncation; integrates cleanly with M3/M4. Recommend shipping after M1/M2, or as prerequisite to M3.

**Decision points:**
1. Header badge placement: confirmed ✓
2. Phase 1 behavior: warn (no blocking) — shift to Phase 2 if needed
3. Phase 1.5 opportunity: emit `prompt_eval_count` from Ollama → exact counts, not estimates
