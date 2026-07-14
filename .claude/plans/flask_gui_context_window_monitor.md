# Flask GUI Context Window Monitor

**Feature**: Real-time chat screen widget estimating/monitoring LLM context usage  
**Date**: 2026-07-14  
**Motivation**: Default inference model `qwen2.5:1.5b` has limited context (~4K–8K tokens). Memory features (M3/M4 from backlog) add extra context. Need visual warning before hitting ceiling to prevent silent truncation or degraded responses.

---

## Problem Statement

Current architecture:
- **Inference model**: `qwen2.5:1.5b` (small, fast, ~4K–8K token window)
- **Prompt template** (`src/rag_query.sh`): system prompt + chat history + retrieved documents + memory context (M3/M4)
- **No visibility**: User has no way to know context usage. If prompt exceeds model's limit:
  - Ollama silently truncates (oldest tokens dropped first)
  - Responses degrade (loses earlier context)
  - No error raised to user

**Goal**: Display live context-window usage % in chat header. Warn when approaching ceiling (e.g., 75%+). Integrate with memory subsystem to suggest pruning old facts if at risk.

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

- **Percentage bar** (horizontal) or **numeric badge** (e.g., "3.2K / 5K")
- **Color coding**:
  - Green (0–50%): Safe
  - Yellow (50–75%): Caution
  - Orange (75–90%): Warning (log to console, consider compressing memory)
  - Red (90–100%): Critical (disable memory injection; warn user before sending query)
- **Tooltip** (hover): Breakdown of contributors
  ```
  System Prompt: 0.5K tokens
  Chat History: 1.2K tokens
  Retrieved Docs: 1.8K tokens
  Memory (Session): 0.3K tokens
  Memory (Global): 0.2K tokens
  ─────────────────────────
  Total: 4.0K / 8.0K (50%)
  ```

---

## Technical Implementation

### Context Estimation Strategy

**Phase 1: Heuristic (character-based)**
- Rough rule: 1 token ≈ 4 characters (varies by model/content; accuracy ±10–20%)
- Calculate for each component:
  - System prompt: read from `config.conf` or hardcode known template
  - Chat history: sum message lengths from `messages` table for current session
  - Retrieved docs: sum chunk sizes from latest query's search results
  - Session memory: sum fact lengths from `session_memory` table
  - Global memory: sum enabled entry lengths from `global_memory` table
- **Model context window**: Read from config or hardcode `CONTEXT_WINDOW=8192` (tunable per model)

**Phase 2: Actual tokenization (TBD)**
- Integrate tokenizer library (if available for target model)
- Example: `tiktoken` (OpenAI) or port Ollama tokenizer to Python
- More accurate; trades complexity/latency for precision

### Calculation Function

Create new module `web/context_tracker.py`:

```python
class ContextTracker:
    def __init__(self, context_window: int = 8192, token_ratio: float = 0.25):
        """
        Args:
            context_window: model's max tokens (e.g., 8192 for qwen2.5:1.5b)
            token_ratio: estimation factor (1 token ≈ 1/token_ratio chars; default 0.25 = 4 chars/token)
        """
        self.context_window = context_window
        self.token_ratio = token_ratio
        
    def estimate_tokens(self, text: str) -> int:
        """Estimate tokens from text length."""
        return max(1, int(len(text) * self.token_ratio))
    
    def calculate_usage(self, session_id: int) -> dict:
        """
        Returns:
        {
            "total_tokens": 2048,
            "context_window": 8192,
            "usage_percent": 25.0,
            "breakdown": {
                "system_prompt": 512,
                "chat_history": 1024,
                "retrieved_docs": 256,
                "session_memory": 64,
                "global_memory": 32,
            },
            "status": "safe",  # "safe" | "caution" | "warning" | "critical"
        }
        """
        db = DB()
        
        # System prompt (hardcoded template ~ 500–800 tokens)
        system_tokens = 640
        
        # Chat history (messages in current session)
        messages = db.get_messages(session_id, limit=50)  # last N messages
        history_text = "\n".join(f"{'User' if m.role == 'user' else 'Assistant'}: {m.content}" for m in messages)
        history_tokens = self.estimate_tokens(history_text)
        
        # Retrieved docs (placeholder; will be populated during query)
        # For now, estimate from DB or cache latest retrieval
        retrieved_tokens = 256  # default estimate; can be cached per query
        
        # Session memory
        session_facts = db.get_session_memory(session_id)
        session_mem_text = "\n".join(f["content"] for f in session_facts)
        session_tokens = self.estimate_tokens(session_mem_text)
        
        # Global memory (enabled only)
        global_facts = db.list_global_memory(enabled_only=True)
        global_mem_text = "\n".join(f"{f['key']}: {f['value']}" for f in global_facts)
        global_tokens = self.estimate_tokens(global_mem_text)
        
        total_tokens = system_tokens + history_tokens + retrieved_tokens + session_tokens + global_tokens
        usage_percent = (total_tokens / self.context_window) * 100
        
        # Status logic
        if usage_percent < 50:
            status = "safe"
        elif usage_percent < 75:
            status = "caution"
        elif usage_percent < 90:
            status = "warning"
        else:
            status = "critical"
        
        return {
            "total_tokens": total_tokens,
            "context_window": self.context_window,
            "usage_percent": round(usage_percent, 1),
            "breakdown": {
                "system_prompt": system_tokens,
                "chat_history": history_tokens,
                "retrieved_docs": retrieved_tokens,
                "session_memory": session_tokens,
                "global_memory": global_tokens,
            },
            "status": status,
        }
```

### API Endpoint

Add to `web/app.py`:

```python
@app.route('/api/sessions/<int:session_id>/context-usage', methods=['GET'])
def get_context_usage(session_id):
    """Get current context window usage for a session."""
    from context_tracker import ContextTracker
    from config import CONTEXT_WINDOW  # read from config.conf or default 8192
    
    tracker = ContextTracker(context_window=CONTEXT_WINDOW)
    usage = tracker.calculate_usage(session_id)
    return jsonify(usage)
```

Endpoint response:
```json
{
  "total_tokens": 2048,
  "context_window": 8192,
  "usage_percent": 25.0,
  "breakdown": {
    "system_prompt": 512,
    "chat_history": 1024,
    "retrieved_docs": 256,
    "session_memory": 64,
    "global_memory": 32
  },
  "status": "safe"
}
```

### Frontend Integration

#### `web/static/chat.js`

Add to chat view initialization:

```javascript
function initContextMonitor(sessionId) {
  const monitor = document.querySelector('[data-context-monitor]');
  if (!monitor) return;
  
  async function updateContextUsage() {
    try {
      const res = await fetch(`/api/sessions/${sessionId}/context-usage`);
      const data = await res.json();
      
      const percent = data.usage_percent;
      const status = data.status;
      
      // Update bar
      monitor.querySelector('.context-bar').style.width = percent + '%';
      monitor.className = `context-monitor context-${status}`;
      
      // Update text
      monitor.querySelector('.context-text').textContent = 
        `${Math.round(percent)}% (${data.breakdown.total_tokens}/${data.context_window})`;
      
      // Populate tooltip
      const breakdown = data.breakdown;
      const tooltip = `
        System Prompt: ${breakdown.system_prompt} tokens
        Chat History: ${breakdown.chat_history} tokens
        Retrieved Docs: ${breakdown.retrieved_docs} tokens
        Session Memory: ${breakdown.session_memory} tokens
        Global Memory: ${breakdown.global_memory} tokens
        ─────────────────────────────
        Total: ${data.total_tokens} / ${data.context_window} (${percent}%)
      `;
      monitor.title = tooltip;
      
      // Warn if critical
      if (status === 'critical') {
        console.warn('[Context] Critical usage (' + percent + '%). Consider clearing chat history or disabling memory.');
      }
    } catch (e) {
      console.error('Failed to fetch context usage:', e);
    }
  }
  
  // Update after each message
  document.addEventListener('message-sent', updateContextUsage);
  document.addEventListener('response-received', updateContextUsage);
  
  // Initial update
  updateContextUsage();
}

// On page load
DOMContentLoaded(() => {
  const sessionId = getCurrentSessionId();
  if (sessionId) initContextMonitor(sessionId);
});
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

Add to `config.conf`:

```bash
# Context window size for the active inference model (tokens)
# qwen2.5:1.5b: ~8000–8192
# qwen2.5:7b: ~32000
# Adjust if swapping models
CONTEXT_WINDOW=8192

# Token estimation factor: 1 token ≈ (1 / TOKEN_RATIO) characters
# Default 0.25 = 1 token per 4 chars (rough; varies by model/language)
TOKEN_RATIO=0.25
```

Load in `web/app.py` or `web/config.py`:

```python
from config import load_config
config = load_config()
CONTEXT_WINDOW = int(config.get("CONTEXT_WINDOW", 8192))
TOKEN_RATIO = float(config.get("TOKEN_RATIO", 0.25))
```

---

## Testing

### Unit Tests (`web/tests/test_context_tracker.py`)

```python
def test_estimate_tokens():
    tracker = ContextTracker(context_window=8192, token_ratio=0.25)
    text = "a" * 4  # 4 chars = 1 token
    assert tracker.estimate_tokens(text) == 1
    
    text = "a" * 8192  # 8192 chars = 2048 tokens
    assert tracker.estimate_tokens(text) == 2048

def test_calculate_usage_safe():
    tracker = ContextTracker(context_window=8192)
    # Mock DB to return small messages
    usage = tracker.calculate_usage(session_id=1)
    assert usage["usage_percent"] < 50
    assert usage["status"] == "safe"

def test_calculate_usage_critical():
    tracker = ContextTracker(context_window=1000)
    # Mock DB to return large messages
    usage = tracker.calculate_usage(session_id=1)
    assert usage["usage_percent"] > 90
    assert usage["status"] == "critical"

def test_breakdown_components():
    usage = tracker.calculate_usage(session_id=1)
    breakdown = usage["breakdown"]
    assert "system_prompt" in breakdown
    assert "chat_history" in breakdown
    assert "retrieved_docs" in breakdown
    assert "session_memory" in breakdown
    assert "global_memory" in breakdown
    assert sum(breakdown.values()) == usage["total_tokens"]
```

### Integration Tests

- **API endpoint**: GET `/api/sessions/1/context-usage` returns valid JSON with all fields.
- **Memory injection**: After activating session memory (M3) and global memory (M4), verify context usage increases.
- **Status transitions**: Send messages to drive usage from safe → caution → warning → critical; verify UI color changes.

### E2E Tests (Playwright)

- Load chat → monitor shows in header
- Send 20 messages → usage bar fills, color changes at thresholds
- Enable global memory → usage increases
- Hover tooltip shows breakdown
- Critical warning logged to console

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

## Future Enhancements (Phase 2)

1. **Auto-summarization**: If session memory grows large, auto-summarize oldest facts and replace.
2. **Sliding window**: Keep only last N messages in context, discard oldest (trade-off: lose conversation thread).
3. **Model-aware tokenizer**: Use actual tokenizer library for target model (Ollama has one; can expose via `/api/tokenize`).
4. **Per-model profiles**: Store known context windows + token ratios for common models (qwen2.5:1.5b, llama2:13b, etc.) in config.
5. **Archive old chats**: Auto-archive sessions after X days to keep SQLite lean.

---

## Files to Create/Modify

- [ ] `/home/lw_na/git/ai-ragjus/web/context_tracker.py` — **new**
- [ ] `/home/lw_na/git/ai-ragjus/web/app.py` — add `/api/sessions/<id>/context-usage` endpoint
- [ ] `/home/lw_na/git/ai-ragjus/web/templates/chat.html` — add monitor widget to header
- [ ] `/home/lw_na/git/ai-ragjus/web/static/chat.js` — init monitor, update on message events
- [ ] `/home/lw_na/git/ai-ragjus/web/static/style.css` — widget styling + color states
- [ ] `/home/lw_na/git/ai-ragjus/config.conf` — add `CONTEXT_WINDOW`, `TOKEN_RATIO` keys
- [ ] `/home/lw_na/git/ai-ragjus/web/tests/test_context_tracker.py` — **new** unit tests
- [ ] `/home/lw_na/git/ai-ragjus/web/tests/test_routes.py` — add E2E test for endpoint

---

## Sign-Off

Feature is **implementation-ready**. Simple, high-value addition to prevent silent truncation. Recommend shipping after M1/M2, or as prerequisite to M3 to establish baseline before memory injection.

**Open questions:**
1. Display location preference: header badge or footer bar?
2. Should 90%+ usage block message send (Phase 1), or just warn?
3. Reserve for Phase 2: actual tokenizer vs. staying with heuristic?
