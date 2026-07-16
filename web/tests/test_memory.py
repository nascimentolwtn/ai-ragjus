"""M3 (per-chat memory) + M4 (global memory) coverage."""
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


def test_parse_facts_filters_nenhum_and_blank_lines():
    facts = memory._parse_facts("- fato um\n\nNENHUM\n* fato dois\n")
    assert facts == ["fato um", "fato dois"]


def test_parse_facts_all_nenhum_returns_empty():
    assert memory._parse_facts("NENHUM") == []


def test_extract_facts_parses_ollama_response(monkeypatch):
    monkeypatch.setattr(
        memory.requests, "post",
        lambda *a, **k: _FakeResponse("fato A\nfato B"),
    )
    facts = memory.extract_facts("pergunta", "resposta", {"OLLAMA_URL": "http://x", "MODELO_IA": "m"})
    assert facts == ["fato A", "fato B"]


def test_extract_facts_swallows_network_errors(monkeypatch):
    def raise_err(*a, **k):
        raise memory.requests.RequestException("boom")
    monkeypatch.setattr(memory.requests, "post", raise_err)
    facts = memory.extract_facts("q", "a", {})
    assert facts == []


def test_extract_facts_swallows_timeout(monkeypatch):
    def raise_timeout(*a, **k):
        raise memory.requests.exceptions.Timeout("slow")
    monkeypatch.setattr(memory.requests, "post", raise_timeout)
    assert memory.extract_facts("q", "a", {}) == []


def test_cap_text_keeps_most_recent_within_budget():
    lines = ["a" * 100 for _ in range(20)]
    result = memory.cap_text(lines, char_cap=250)
    assert len(result) <= 250 + 100  # allows the single overflow line that made it fit
    # newest lines are the ones kept (last of the input list)
    assert result.endswith(lines[-1])


def test_build_memory_context_empty_when_no_facts(temp_db):
    assert memory.build_memory_context(999) == ""


def test_build_memory_context_includes_session_and_global(temp_db):
    sid = temp_db.create_session("s")
    temp_db.add_session_memory(sid, "cliente prefere respostas curtas")
    temp_db.upsert_global_memory("area_atuacao", "direito trabalhista")

    ctx = memory.build_memory_context(sid)
    assert "cliente prefere respostas curtas" in ctx
    assert "area_atuacao: direito trabalhista" in ctx


def test_build_memory_context_excludes_disabled_global(temp_db):
    sid = temp_db.create_session("s")
    entry = temp_db.upsert_global_memory("k", "v")
    temp_db.set_global_memory_enabled(entry["id"], False)

    ctx = memory.build_memory_context(sid)
    assert "k: v" not in ctx


def test_prune_session_memory_keeps_cap(temp_db):
    sid = temp_db.create_session("s")
    for i in range(15):
        temp_db.add_session_memory(sid, f"fato {i}")
    temp_db.prune_session_memory(sid, keep=10)
    facts = temp_db.get_session_memory(sid, limit=100)
    assert len(facts) == 10
    # newest facts survive
    assert facts[-1]["content"] == "fato 14"


def test_global_memory_upsert_is_idempotent_on_key(temp_db):
    temp_db.upsert_global_memory("k", "v1")
    temp_db.upsert_global_memory("k", "v2")
    result = temp_db.list_global_memory()
    all_entries = result["enabled"] + result["disabled"]
    assert len(all_entries) == 1
    assert all_entries[0]["value"] == "v2"


def test_global_memory_auto_cap_eviction(temp_db):
    for i in range(35):
        temp_db.upsert_global_memory(f"auto_{i}", "v", source="auto")
    assert temp_db.count_auto_global_memory() == 35
    temp_db.evict_oldest_auto_global_memory()
    assert temp_db.count_auto_global_memory() == 34


def test_record_turn_memory_persists_session_facts(temp_db, monkeypatch):
    sid = temp_db.create_session("s")
    monkeypatch.setattr(memory, "extract_facts", lambda *a, **k: ["fato extraído"])
    monkeypatch.setattr(memory, "extract_global_facts", lambda *a, **k: [])
    memory.record_turn_memory(sid, "q", "a", {}, auto_global=False)
    facts = temp_db.get_session_memory(sid)
    assert len(facts) == 1
    assert facts[0]["content"] == "fato extraído"


def test_record_turn_memory_auto_global_upserts(temp_db, monkeypatch):
    sid = temp_db.create_session("s")
    monkeypatch.setattr(memory, "extract_facts", lambda *a, **k: [])
    monkeypatch.setattr(memory, "extract_global_facts", lambda *a, **k: ["area: trabalhista"])
    memory.record_turn_memory(sid, "q", "a", {}, auto_global=True)
    result = temp_db.list_global_memory()
    entries = result["enabled"] + result["disabled"]
    assert len(entries) == 1
    assert entries[0]["source"] == "auto"
    assert entries[0]["key"] == "area"


def test_record_turn_memory_filters_placeholder_facts(temp_db, monkeypatch):
    """Small models sometimes echo the prompt template literally back
    ("chave: domínio") instead of a real fact; these must be dropped."""
    sid = temp_db.create_session("s")
    monkeypatch.setattr(memory, "extract_facts", lambda *a, **k: [])
    monkeypatch.setattr(
        memory, "extract_global_facts",
        lambda *a, **k: ["chave: domínio", "valor: direito trabalhista", "area_atuacao: penal"],
    )
    memory.record_turn_memory(sid, "q", "a", {}, auto_global=True)
    result = temp_db.list_global_memory()
    entries = result["enabled"] + result["disabled"]
    assert len(entries) == 1
    assert entries[0]["key"] == "area_atuacao"


# --- API routes -------------------------------------------------------------

def test_api_global_memory_crud(client, temp_db):
    resp = client.post("/api/memory/global", json={"key": "k1", "value": "v1"})
    assert resp.status_code == 201
    entry_id = resp.get_json()["entry"]["id"]

    resp = client.get("/api/memory/global")
    assert resp.status_code == 200
    assert len(resp.get_json()["enabled"]) == 1

    resp = client.patch(f"/api/memory/global/{entry_id}", json={"enabled": False})
    assert resp.status_code == 200
    assert temp_db.get_global_memory(entry_id)["enabled"] == 0

    resp = client.delete(f"/api/memory/global/{entry_id}")
    assert resp.status_code == 200
    assert temp_db.get_global_memory(entry_id) is None


def test_api_global_memory_validation(client):
    resp = client.post("/api/memory/global", json={"key": "", "value": "v"})
    assert resp.status_code == 400
    resp = client.post("/api/memory/global", json={"key": "k", "value": ""})
    assert resp.status_code == 400


def test_api_global_memory_404(client):
    resp = client.patch("/api/memory/global/9999", json={"enabled": False})
    assert resp.status_code == 404
    resp = client.delete("/api/memory/global/9999")
    assert resp.status_code == 404


def test_api_session_memory_roundtrip(client, temp_db):
    sid = temp_db.create_session("s")
    temp_db.add_session_memory(sid, "fato 1")

    resp = client.get(f"/api/sessions/{sid}/memory")
    assert resp.status_code == 200
    facts = resp.get_json()["facts"]
    assert len(facts) == 1

    fact_id = facts[0]["id"]
    resp = client.delete(f"/api/sessions/{sid}/memory/{fact_id}")
    assert resp.status_code == 200
    assert temp_db.get_session_memory(sid) == []
