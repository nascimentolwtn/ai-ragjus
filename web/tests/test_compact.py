"""Backlog item 8 (auto-compact) + item 10 (manual "Compact now" button)."""
import memory


class _FakeResponse:
    def __init__(self, text, status=200):
        self._text = text
        self.status_code = status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError("http error")

    def json(self):
        return {"response": self._text}


# --- db helpers --------------------------------------------------------------

def test_count_user_messages(temp_db):
    sid = temp_db.create_session("s")
    assert temp_db.count_user_messages(sid) == 0
    temp_db.add_message(sid, "user", "pergunta 1")
    temp_db.add_message(sid, "assistant", "resposta 1")
    temp_db.add_message(sid, "user", "pergunta 2")
    assert temp_db.count_user_messages(sid) == 2


def test_auto_compact_settings_defaults(temp_db):
    settings = temp_db.get_auto_compact_settings()
    assert settings == {"enabled": True, "threshold": 80.0}


def test_auto_compact_settings_roundtrip(temp_db):
    temp_db.set_auto_compact_settings(enabled=False, threshold=70)
    settings = temp_db.get_auto_compact_settings()
    assert settings == {"enabled": False, "threshold": 70.0}

    # Partial update: only threshold changes, enabled flag untouched.
    temp_db.set_auto_compact_settings(threshold=65)
    settings = temp_db.get_auto_compact_settings()
    assert settings == {"enabled": False, "threshold": 65.0}


# --- memory.compact_session ---------------------------------------------------

def test_compact_session_no_turns_returns_none(temp_db):
    sid = temp_db.create_session("s")
    assert memory.compact_session(sid, {}, turn_number=0) is None


def test_compact_session_persists_checkpoint_and_prunes(temp_db, monkeypatch):
    sid = temp_db.create_session("s")
    temp_db.add_message(sid, "user", "Qual o prazo prescricional?")
    temp_db.add_message(sid, "assistant", "O prazo é de 5 anos.")
    for i in range(6):
        temp_db.add_session_memory(sid, f"fato antigo {i}")

    monkeypatch.setattr(
        memory.requests, "post",
        lambda *a, **k: _FakeResponse("Prazo prescricional de 5 anos discutido."),
    )

    checkpoint = memory.compact_session(sid, {}, turn_number=1, reason="manual")
    assert checkpoint is not None
    assert checkpoint["turn"] == 1
    assert checkpoint["reason"] == "manual"
    assert checkpoint["content"].startswith("\U0001F4CB Resumo de contexto no turno 1: ")
    assert "Prazo prescricional de 5 anos discutido." in checkpoint["content"]

    facts = temp_db.get_session_memory(sid, limit=100)
    # Truncated to checkpoint + a small trailing buffer, not all 6 old facts + checkpoint.
    assert len(facts) == memory.COMPACT_KEEP_RECENT_FACTS
    assert facts[-1]["content"] == checkpoint["content"]


def test_build_compact_transcript_only_uses_target_session(temp_db):
    """_build_compact_transcript() must source messages from the target
    session only - a different session's transcript must never bleed into
    another session's checkpoint summary."""
    sid_a = temp_db.create_session("A")
    sid_b = temp_db.create_session("B")

    temp_db.add_message(sid_a, "user", "pergunta exclusiva da sessao A")
    temp_db.add_message(sid_a, "assistant", "resposta exclusiva da sessao A")
    temp_db.add_message(sid_b, "user", "pergunta exclusiva da sessao B")
    temp_db.add_message(sid_b, "assistant", "resposta exclusiva da sessao B")

    transcript_a = memory._build_compact_transcript(sid_a)
    transcript_b = memory._build_compact_transcript(sid_b)

    assert "sessao A" in transcript_a
    assert "sessao B" not in transcript_a
    assert "sessao B" in transcript_b
    assert "sessao A" not in transcript_b


def test_compact_session_does_not_touch_other_sessions_memory(temp_db, monkeypatch):
    """Compacting one session must never prune or alter another session's
    session_memory facts."""
    sid_a = temp_db.create_session("A")
    sid_b = temp_db.create_session("B")

    temp_db.add_message(sid_a, "user", "pergunta A")
    temp_db.add_message(sid_a, "assistant", "resposta A")
    for i in range(6):
        temp_db.add_session_memory(sid_a, f"fato A {i}")
    for i in range(6):
        temp_db.add_session_memory(sid_b, f"fato B {i}")

    monkeypatch.setattr(memory.requests, "post", lambda *a, **k: _FakeResponse("resumo A"))

    memory.compact_session(sid_a, {}, turn_number=1, reason="manual")

    facts_b = temp_db.get_session_memory(sid_b, limit=100)
    assert len(facts_b) == 6
    assert all(f["content"].startswith("fato B") for f in facts_b)


def test_compact_session_falls_back_when_ollama_unavailable(temp_db, monkeypatch):
    sid = temp_db.create_session("s")
    temp_db.add_message(sid, "user", "pergunta")
    temp_db.add_message(sid, "assistant", "resposta")

    def raise_err(*a, **k):
        raise memory.requests.RequestException("boom")
    monkeypatch.setattr(memory.requests, "post", raise_err)

    checkpoint = memory.compact_session(sid, {}, turn_number=1)
    assert checkpoint is not None
    assert "Sem fatos ou decisões relevantes" in checkpoint["content"]


# --- API routes ----------------------------------------------------------------

def test_api_compact_endpoint(client, temp_db, monkeypatch):
    sid = temp_db.create_session("s")
    temp_db.add_message(sid, "user", "pergunta")
    temp_db.add_message(sid, "assistant", "resposta")

    monkeypatch.setattr(memory.requests, "post", lambda *a, **k: _FakeResponse("resumo"))

    resp = client.post(f"/api/sessions/{sid}/compact")
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["ok"] is True
    assert data["checkpoint"]["turn"] == 1
    assert data["session_memory_count"] == 1


def test_api_compact_endpoint_404(client):
    resp = client.post("/api/sessions/9999/compact")
    assert resp.status_code == 404


def test_api_compact_endpoint_no_turns_yet(client, temp_db):
    sid = temp_db.create_session("s")
    resp = client.post(f"/api/sessions/{sid}/compact")
    assert resp.status_code == 400


def test_api_auto_compact_settings_get_default(client):
    resp = client.get("/api/settings/auto-compact")
    assert resp.status_code == 200
    assert resp.get_json() == {"enabled": True, "threshold": 80.0}


def test_api_auto_compact_settings_post_updates(client, temp_db):
    resp = client.post("/api/settings/auto-compact", json={"enabled": False, "threshold": 60})
    assert resp.status_code == 200
    data = resp.get_json()
    assert data["ok"] is True
    assert data["enabled"] is False
    assert data["threshold"] == 60.0
    assert temp_db.get_auto_compact_settings() == {"enabled": False, "threshold": 60.0}


def test_api_auto_compact_settings_post_validates_threshold(client):
    resp = client.post("/api/settings/auto-compact", json={"threshold": 5})
    assert resp.status_code == 400
    resp = client.post("/api/settings/auto-compact", json={"threshold": "not-a-number"})
    assert resp.status_code == 400
