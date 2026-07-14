"""Context window monitor (M5) coverage."""
from context_tracker import ContextTracker


def test_estimate_tokens_scales_with_length():
    tracker = ContextTracker(context_window=16384, token_ratio=0.30)
    assert tracker.estimate_tokens("a" * 3) >= 1
    assert tracker.estimate_tokens("a" * 3300) >= 990


def test_output_reserve_reduces_available():
    tracker = ContextTracker(context_window=16384, output_reserve=1024)
    assert tracker.available == 15360


def test_calculate_usage_safe_for_small_session(temp_db):
    sid = temp_db.create_session("s")
    tracker = ContextTracker(context_window=16384, output_reserve=1024)
    usage = tracker.calculate_usage(session_id=sid)
    assert usage["usage_percent"] < 60
    assert usage["status"] == "safe"


def test_calculate_usage_critical_for_small_window():
    tracker = ContextTracker(context_window=5000, output_reserve=1024)
    usage = tracker.calculate_usage(
        session_id=999, prompt_char_estimate={"retrieved_docs": 15000, "query": 200}
    )
    assert usage["usage_percent"] > 85
    assert usage["status"] == "critical"


def test_breakdown_sums_to_total_and_has_no_chat_history_key(temp_db):
    sid = temp_db.create_session("s")
    tracker = ContextTracker()
    usage = tracker.calculate_usage(session_id=sid)
    breakdown = usage["breakdown"]
    assert "system_prompt" in breakdown
    assert "retrieved_docs" in breakdown
    assert "query" in breakdown
    assert "session_memory" in breakdown
    assert "global_memory" in breakdown
    assert "chat_history" not in breakdown
    assert sum(breakdown.values()) == usage["total_tokens"]


def test_calculate_usage_includes_memory_when_present(temp_db):
    sid = temp_db.create_session("s")
    temp_db.add_session_memory(sid, "fato " * 50)
    temp_db.upsert_global_memory("k", "v " * 50)

    tracker = ContextTracker()
    usage = tracker.calculate_usage(session_id=sid)
    assert usage["breakdown"]["session_memory"] > 0
    assert usage["breakdown"]["global_memory"] > 0


def test_calculate_usage_missing_memory_tables_does_not_crash():
    tracker = ContextTracker()
    usage = tracker.calculate_usage(session_id=99999)
    assert usage["status"] in ("safe", "caution", "warning", "critical")


# --- API endpoint ------------------------------------------------------------

def test_context_usage_endpoint(client, temp_db):
    sid = temp_db.create_session("s")
    resp = client.post(f"/api/sessions/{sid}/context-usage", json={"query": 50, "retrieved_docs": 3000})
    assert resp.status_code == 200
    data = resp.get_json()
    assert "usage_percent" in data
    assert "breakdown" in data


def test_context_usage_endpoint_404(client):
    resp = client.post("/api/sessions/9999/context-usage", json={})
    assert resp.status_code == 404
