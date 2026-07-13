# RAGSEC — Company Secret Data RAG (Implementation Plan)

## Overview

RAGSEC is a security-hardened variant of AI-RAGJus that repurposes the legal RAG
pipeline for **technical company secrets** (design docs, API specs, SDK internals,
architecture). It keeps the project's core promise — 100% offline / air-gapped,
Bash + Ollama + SQLite, no external calls — while adding four governance layers:
role-based access control (RBAC), document classification, an audit trail, and a
data-loss-prevention (DLP) engine. The existing pipeline (`src/ingest.sh`,
`src/vector.sh`, `src/ai.sh`, `src/ui.sh`, `jus.sh`) is reused; changes are
additive so the cosine-similarity search core stays intact.

## Use Cases

- **Engineer** asks "how does the auth SDK sign tokens?" → answer drawn only from
  `internal` + `public` chunks they are cleared for; `secret` roadmap redacted.
- **Manager** queries delivery status across a team's design docs (`internal`,
  `confidential`) but not board-level `secret` financials.
- **Exec** has full read; queries strategic architecture including `secret`.
- **Auditor** never queries content — only reads the audit log.
- Ingestion now targets `.md`, code snippets, OpenAPI/Swagger, ADRs and Confluence
  exports rather than PDFs of case files. The process-number filter in
  `buscar_trechos_relevantes` is replaced by a **doc-ID / service-name** filter.

## Security Architecture

**Identity.** No network IdP (air-gapped). A local `usuarios` table stores a
username, a salted hash (via `openssl passwd -6`), and a role. Login sets a session
env `RAGSEC_USER` / `RAGSEC_ROLE`; a per-session token file under
`$CACHE_DIR/.session` (mode 600) is validated on each menu action.

**RBAC model.** Four roles map to a clearance level (integer). A query may only
retrieve chunks whose classification level ≤ the user's clearance.

| Role      | Clearance | Sees classifications                    |
|-----------|-----------|-----------------------------------------|
| engineer  | 1         | public, internal                        |
| manager   | 2         | public, internal, confidential          |
| exec      | 3         | public, internal, confidential, secret  |
| auditor   | 0         | none (audit-only)                       |

**Classification schema.** `public < internal < confidential < secret`. Every chunk
inherits its source document's classification, assigned at ingest time via a
sidecar `.class` file, a front-matter `classification:` tag, or an admin override.

## Schema Changes

Extend `inicializar_banco_vetorial()` in `src/vector.sh`. The existing
`document_chunks` table gains a classification column; new tables are added to the
same `rag_store.db`.

```sql
-- Additive column on the existing table
ALTER TABLE document_chunks ADD COLUMN classificacao TEXT NOT NULL DEFAULT 'internal';
CREATE INDEX IF NOT EXISTS idx_classificacao ON document_chunks (classificacao);

CREATE TABLE IF NOT EXISTS usuarios (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT UNIQUE NOT NULL,
    senha_hash    TEXT NOT NULL,
    role          TEXT NOT NULL CHECK (role IN ('engineer','manager','exec','auditor')),
    clearance     INTEGER NOT NULL,
    ativo         INTEGER NOT NULL DEFAULT 1,
    criado_em     TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Document-level classification registry (source of truth per file)
CREATE TABLE IF NOT EXISTS doc_classificacao (
    caminho_arquivo TEXT PRIMARY KEY,
    classificacao   TEXT NOT NULL CHECK (classificacao IN ('public','internal','confidential','secret')),
    nivel           INTEGER NOT NULL,
    classificado_por TEXT,
    classificado_em TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS audit_log (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    ts             TEXT NOT NULL DEFAULT (datetime('now')),
    username       TEXT NOT NULL,
    role           TEXT NOT NULL,
    query_text     TEXT NOT NULL,
    docs_acessados TEXT,          -- JSON array of file paths returned
    max_score      REAL,          -- top cosine similarity / confidence
    dlp_action     TEXT NOT NULL, -- 'allow' | 'redact' | 'block'
    dlp_rule       TEXT           -- id of the rule that fired, if any
);

CREATE TABLE IF NOT EXISTS dlp_rules (
    id       TEXT PRIMARY KEY,
    padrao   TEXT NOT NULL,       -- regex
    acao     TEXT NOT NULL,       -- 'redact' | 'block'
    escopo   TEXT NOT NULL DEFAULT 'all',
    ativo    INTEGER NOT NULL DEFAULT 1
);
```

The vector search (`buscar_trechos_relevantes`) adds a mandatory clearance filter to
its `SELECT`, injected server-side (not user-supplied):
`WHERE classificacao IN (<allowed for $RAGSEC_ROLE>)`, combined with the existing
optional doc-ID `LIKE` filter.

## DLP Engine Design

A new module `src/dlp.sh` runs two passes.

**Pre-retrieval (access):** the clearance filter already excludes over-classified
chunks at the SQL layer — defense in depth, so secrets never enter the prompt
context.

**Post-generation (leak scan):** before the streamed answer is shown, buffer it and
match `dlp_rules`. `block` suppresses the whole answer; `redact` replaces matches
with `[REDACTED]`. Seed rules:

| id            | padrão (regex)                                       | ação   |
|---------------|------------------------------------------------------|--------|
| secret_key    | `AKIA[0-9A-Z]{16}` , `(?i)api[_-]?key\s*[:=]\s*\S+`   | redact |
| priv_key      | `-----BEGIN (RSA\|EC\|OPENSSH) PRIVATE KEY-----`      | block  |
| jwt           | `eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`  | redact |
| conn_string   | `(postgres\|mysql\|mongodb)://[^ ]+:[^ @]+@`         | redact |
| internal_host | `(?i)\b\w+\.internal\.corp\b`                         | redact |
| roadmap_leak  | `(?i)(acquisition\|layoff\|unreleased)`              | block  |

Rules are data (table rows), editable via the admin menu, so no code change is
needed to tune policy. Every fire is written to `audit_log.dlp_action` / `dlp_rule`.

## UI Changes

`src/ui.sh` header rebrands to **RAGSEC** and shows the logged-in user + clearance.
A login gate runs before `menu_principal` in `jus.sh`. New/changed menu items:

- **[Login / Logout]** — establishes the session, sets role env vars.
- **[Admin] User management** (exec only) — add/disable users, set roles.
- **[Admin] Classification manager** — list unclassified files, assign
  public/internal/confidential/secret, bulk re-tag a folder.
- **[Admin] DLP rules** — list/add/toggle regex rules.
- **[Auditor] View audit log** — filter by user/date, export CSV.

Menu options are shown/hidden by role; every admin action re-checks clearance
server-side rather than trusting the menu (menu is a convenience, not the control).

## Audit Logging

Every chat turn writes one `audit_log` row **before** printing the answer, capturing
who, when, the query, the file paths returned, the top similarity as a confidence
proxy, and the DLP verdict. Format is queryable SQL; export is newline-delimited
JSON or CSV for offline review. **Retention:** default 365 days; a
`purgar_auditoria()` helper deletes rows older than a configurable
`AUDIT_RETENTION_DIAS` (added to `config.conf`), run manually or via cron. The log
table is append-only in practice — no UI path updates or deletes individual rows,
and the DB file is chmod 600. Optional integrity: store a running `sha256`
hash-chain column so tampering is detectable.

## Testing

- **Unit (bats):** clearance filter returns no over-classified chunks for each role;
  DLP regexes redact/block on crafted fixtures; login rejects bad passwords.
- **Integration:** ingest a mixed-classification corpus, run identical queries as
  engineer vs exec, assert engineer never sees `secret` text and that an audit row
  exists per query.
- **Negative/security:** SQL-injection attempts in the query (existing code escapes
  with `sed s/'/''/g`; extend to parameterized `.param` binds), path traversal in
  classification input, privilege-escalation attempt via forged session file.
- **Air-gap check:** run under `unshare -n` / no route; confirm zero outbound
  connections beyond `localhost:11434`.

## Deployment

**Migration strategy: monorepo variant, not a hard fork.** Keep one repo; add a
`RAGSEC_MODE` flag in `config.conf`. Governance lives in new modules (`src/auth.sh`,
`src/dlp.sh`, `src/audit.sh`, `src/rbac.sh`) sourced only when the mode is on, so the
legal build stays clean and both variants share the search core and bug fixes. A
branch (`ragsec`) or `git worktree` isolates active development; merge shared fixes
back to `main`. A schema-version row drives idempotent `ALTER TABLE` migrations on
startup so existing `rag_store.db` files upgrade in place. Ship with a hardened
default: DB and session files chmod 600, no default users (first-run creates the
initial `exec`), DLP rules pre-seeded, and the header banner asserting
AIR-GAPPED status.
