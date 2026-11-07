PRAGMA foreign_keys = ON;

CREATE TABLE meta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE computer (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    os_user TEXT NOT NULL,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL
);

CREATE TABLE source (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    space TEXT NOT NULL CHECK (space IN ('business', 'private')),
    confidentiality TEXT NOT NULL CHECK (confidentiality IN ('public', 'internal', 'confidential', 'restricted')),
    canonical INTEGER NOT NULL DEFAULT 0,
    origin_json TEXT NOT NULL,
    retention TEXT NOT NULL DEFAULT 'keep',
    status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused', 'retired')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE source_binding (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES source(id),
    computer_id TEXT NOT NULL REFERENCES computer(id),
    binding_key TEXT NOT NULL,
    kind TEXT NOT NULL,
    locator_fingerprint TEXT NOT NULL,
    credential_ref TEXT,
    read INTEGER NOT NULL DEFAULT 1,
    write INTEGER NOT NULL DEFAULT 0,
    derive INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL DEFAULT 'unknown' CHECK (state IN ('reachable', 'unreachable', 'unknown', 'partial', 'access_denied')),
    last_check_at TEXT,
    last_success_at TEXT,
    last_error TEXT,
    observed_read INTEGER,
    observed_write INTEGER,
    access_method TEXT,
    access_checked_at TEXT,
    UNIQUE (source_id, computer_id)
);

CREATE TABLE item (
    id TEXT PRIMARY KEY,
    source_id TEXT NOT NULL REFERENCES source(id),
    external_id TEXT NOT NULL,
    display_path TEXT NOT NULL,
    kind TEXT NOT NULL,
    media_type TEXT,
    register_id TEXT,
    register_ref TEXT,
    canonical INTEGER NOT NULL DEFAULT 0,
    first_seen_at TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    removed_at TEXT,
    UNIQUE (source_id, external_id)
);

CREATE TABLE version (
    id TEXT PRIMARY KEY,
    item_id TEXT NOT NULL REFERENCES item(id),
    content_hash TEXT NOT NULL,
    size INTEGER NOT NULL,
    media_type TEXT,
    seq_no INTEGER NOT NULL,
    first_observed_at TEXT NOT NULL,
    last_observed_at TEXT NOT NULL,
    source_mtime TEXT,
    supersedes_version_id TEXT REFERENCES version(id),
    original_stored INTEGER NOT NULL DEFAULT 0,
    UNIQUE (item_id, content_hash),
    UNIQUE (item_id, seq_no)
);

CREATE TABLE blob (
    hash TEXT PRIMARY KEY,
    rel TEXT NOT NULL,
    size INTEGER NOT NULL,
    media_type TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TABLE extraction (
    id TEXT PRIMARY KEY,
    version_id TEXT NOT NULL REFERENCES version(id),
    extractor TEXT NOT NULL,
    extractor_version TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('full', 'partial', 'failed', 'unsupported', 'pending')),
    reason TEXT,
    text_hash TEXT REFERENCES blob(hash),
    created_at TEXT NOT NULL,
    is_current INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE citation (
    id TEXT PRIMARY KEY,
    extraction_id TEXT NOT NULL REFERENCES extraction(id),
    kind TEXT NOT NULL,
    locator_json TEXT NOT NULL,
    quote TEXT NOT NULL,
    quote_hash TEXT NOT NULL,
    verified_at TEXT,
    verified INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE knowledge (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL CHECK (kind IN ('note', 'summary', 'claim', 'decision', 'topic', 'entity', 'register_entry')),
    title TEXT NOT NULL,
    space TEXT NOT NULL CHECK (space IN ('business', 'private', 'mixed')),
    confidentiality TEXT NOT NULL CHECK (confidentiality IN ('public', 'internal', 'confidential', 'restricted')),
    canonical INTEGER NOT NULL DEFAULT 1,
    created_by TEXT NOT NULL,
    created_at TEXT NOT NULL,
    current_version_id TEXT,
    archived_at TEXT
);

CREATE TABLE knowledge_version (
    id TEXT PRIMARY KEY,
    knowledge_id TEXT NOT NULL REFERENCES knowledge(id),
    version_no INTEGER NOT NULL,
    content_hash TEXT NOT NULL REFERENCES blob(hash),
    author TEXT NOT NULL,
    created_at TEXT NOT NULL,
    lifecycle TEXT NOT NULL CHECK (lifecycle IN ('draft', 'active', 'deprecated', 'retracted')),
    review_state TEXT NOT NULL CHECK (review_state IN ('unverified', 'needs_review', 'confirmed', 'rejected', 'confirmation_stale')),
    basis_json TEXT NOT NULL DEFAULT '[]',
    effective_space TEXT NOT NULL CHECK (effective_space IN ('business', 'private', 'mixed')),
    effective_confidentiality TEXT NOT NULL CHECK (effective_confidentiality IN ('public', 'internal', 'confidential', 'restricted')),
    published_ref TEXT,
    supersedes_version_id TEXT REFERENCES knowledge_version(id),
    UNIQUE (knowledge_id, version_no)
);

CREATE TABLE provenance (
    id TEXT PRIMARY KEY,
    knowledge_version_id TEXT NOT NULL REFERENCES knowledge_version(id),
    relation TEXT NOT NULL CHECK (relation IN ('derived_from', 'supports', 'contradicts', 'cites', 'supersedes')),
    evidence_version_id TEXT REFERENCES version(id),
    evidence_citation_id TEXT REFERENCES citation(id),
    target_knowledge_version_id TEXT REFERENCES knowledge_version(id),
    note TEXT,
    created_at TEXT NOT NULL,
    CHECK ((evidence_version_id IS NOT NULL) + (evidence_citation_id IS NOT NULL) + (target_knowledge_version_id IS NOT NULL) = 1)
);

CREATE TABLE review (
    id TEXT PRIMARY KEY,
    knowledge_version_id TEXT NOT NULL REFERENCES knowledge_version(id),
    reviewer TEXT NOT NULL,
    decision TEXT NOT NULL CHECK (decision IN ('confirmed', 'rejected', 'needs_review')),
    note TEXT,
    decided_at TEXT NOT NULL,
    basis_hash TEXT NOT NULL,
    basis_json TEXT NOT NULL,
    invalidated_by_version_id TEXT,
    invalidated_at TEXT,
    invalidated_reason TEXT
);

CREATE TABLE grant_row (
    id TEXT PRIMARY KEY,
    subject_type TEXT NOT NULL CHECK (subject_type IN ('user', 'role', 'machine')),
    subject_id TEXT NOT NULL,
    scope_type TEXT NOT NULL CHECK (scope_type IN ('store', 'space', 'source', 'knowledge')),
    scope_id TEXT NOT NULL,
    actions TEXT NOT NULL,
    granted_by TEXT NOT NULL,
    granted_at TEXT NOT NULL,
    expires_at TEXT,
    note TEXT
);

CREATE TABLE access_check (
    id TEXT PRIMARY KEY,
    scope_type TEXT NOT NULL,
    scope_id TEXT NOT NULL,
    computer_id TEXT NOT NULL,
    observed_read INTEGER,
    observed_write INTEGER,
    method TEXT NOT NULL,
    checked_at TEXT NOT NULL,
    detail TEXT
);

CREATE TABLE event (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT UNIQUE NOT NULL,
    at TEXT NOT NULL,
    type TEXT NOT NULL,
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    actor TEXT NOT NULL,
    computer_id TEXT NOT NULL,
    payload_json TEXT NOT NULL
);

CREATE TABLE run (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    counts_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE job (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('queued', 'running', 'completed', 'failed', 'cancelled')),
    created_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    error TEXT,
    stats_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL,
    checksum TEXT NOT NULL
);

CREATE INDEX idx_item_source ON item(source_id);
CREATE INDEX idx_version_item ON version(item_id);
CREATE INDEX idx_extraction_version ON extraction(version_id);
CREATE INDEX idx_extraction_text ON extraction(text_hash);
CREATE INDEX idx_event_entity ON event(entity_type, entity_id);
CREATE INDEX idx_knowledge_version ON knowledge_version(knowledge_id);
CREATE INDEX idx_provenance_knv ON provenance(knowledge_version_id);
CREATE INDEX idx_review_knv ON review(knowledge_version_id);
CREATE INDEX idx_grant_scope ON grant_row(scope_type, scope_id);
