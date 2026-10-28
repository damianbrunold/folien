-- Presentations ("decks"). The content is one JSON document (see
-- src/app-model.sld); title, design and status live in columns so the
-- lists need not read it. revision counts saves: a save names the
-- revision it was based on and fails if another save came first.

CREATE TABLE presentations (
  id          text        PRIMARY KEY,
  owner_id    bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title       text        NOT NULL,
  design      text        NOT NULL,
  status      text        NOT NULL DEFAULT 'active'
                          CHECK (status IN ('active', 'archived', 'trashed')),
  doc         jsonb       NOT NULL,
  revision    integer     NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  -- When the deck was archived or moved to the trash.
  status_at   timestamptz
);

CREATE INDEX presentations_owner_status ON presentations (owner_id, status, updated_at DESC);
