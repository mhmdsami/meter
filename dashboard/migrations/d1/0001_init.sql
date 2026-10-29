CREATE TABLE IF NOT EXISTS usage_rows (
    host TEXT NOT NULL,
    day TEXT NOT NULL,
    provider TEXT NOT NULL,
    project TEXT NOT NULL DEFAULT '',
    model TEXT NOT NULL DEFAULT '',
    spent REAL NOT NULL DEFAULT 0,
    tokens INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'estimated',
    updated_at TEXT NOT NULL,
    PRIMARY KEY (host, day, provider, project, model)
);

CREATE INDEX IF NOT EXISTS usage_rows_day ON usage_rows (day);
