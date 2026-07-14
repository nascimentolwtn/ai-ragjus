"""Shared pytest fixtures for the Flask GUI test suite.

Each test gets a throwaway chat_history.db (both `db` module globals and the
Flask app's underlying storage point at it) so tests never touch the real
web/data/chat_history.db used by a running instance.
"""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import db as db_module  # noqa: E402


@pytest.fixture()
def temp_db(tmp_path, monkeypatch):
    db_path = tmp_path / "chat_history_test.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "DB_DIR", tmp_path)
    db_module.init_db()
    return db_module


@pytest.fixture()
def client(temp_db, monkeypatch):
    import app as app_module

    monkeypatch.setattr(app_module, "db", temp_db)
    app_module.app.config["TESTING"] = True
    with app_module.app.test_client() as c:
        yield c
