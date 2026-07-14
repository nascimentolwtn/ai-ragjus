"""M1 (lazy-load pagination) + M2 (rename/delete) coverage."""


def test_list_sessions_pagination_boundaries(temp_db):
    for i in range(75):
        temp_db.create_session(f"Conversa {i}")

    page0 = temp_db.list_sessions(limit=30, offset=0)
    assert len(page0["sessions"]) == 30
    assert page0["has_more"] is True

    page1 = temp_db.list_sessions(limit=30, offset=30)
    assert len(page1["sessions"]) == 30
    assert page1["has_more"] is True

    page2 = temp_db.list_sessions(limit=30, offset=60)
    assert len(page2["sessions"]) == 15
    assert page2["has_more"] is False


def test_list_sessions_ordering_newest_first(temp_db):
    a = temp_db.create_session("Primeira")
    b = temp_db.create_session("Segunda")
    temp_db.add_message(a, "user", "oi")  # bumps `a`'s updated_at

    result = temp_db.list_sessions()
    ids = [s["id"] for s in result["sessions"]]
    assert ids.index(a) < ids.index(b)


def test_api_sessions_param_clamping(client, temp_db):
    for i in range(5):
        temp_db.create_session(f"Conversa {i}")

    resp = client.get("/api/sessions?limit=99999&offset=-5")
    assert resp.status_code == 200
    data = resp.get_json()
    assert len(data["sessions"]) == 5
    assert data["has_more"] is False


def test_rename_session(client, temp_db):
    sid = temp_db.create_session("Título original")
    resp = client.patch(f"/api/sessions/{sid}", json={"title": "Novo título"})
    assert resp.status_code == 200
    assert resp.get_json()["title"] == "Novo título"
    assert temp_db.get_session(sid)["title"] == "Novo título"


def test_rename_session_empty_title_rejected(client, temp_db):
    sid = temp_db.create_session("Título original")
    resp = client.patch(f"/api/sessions/{sid}", json={"title": "   "})
    assert resp.status_code == 400
    assert temp_db.get_session(sid)["title"] == "Título original"


def test_rename_session_truncates_long_title(client, temp_db):
    sid = temp_db.create_session("Título original")
    resp = client.patch(f"/api/sessions/{sid}", json={"title": "x" * 500})
    assert resp.status_code == 200
    assert len(resp.get_json()["title"]) == 120


def test_rename_nonexistent_session_404(client):
    resp = client.patch("/api/sessions/9999", json={"title": "qualquer"})
    assert resp.status_code == 404


def test_delete_session_cascades_messages(client, temp_db):
    sid = temp_db.create_session("Para excluir")
    temp_db.add_message(sid, "user", "pergunta")
    temp_db.add_message(sid, "assistant", "resposta")

    resp = client.delete(f"/api/sessions/{sid}")
    assert resp.status_code == 200
    assert temp_db.get_session(sid) is None
    assert temp_db.get_messages(sid) == []


def test_delete_nonexistent_session_404(client):
    resp = client.delete("/api/sessions/9999")
    assert resp.status_code == 404
