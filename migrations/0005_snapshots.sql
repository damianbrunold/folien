-- Named versions of a deck ("Versionen"): a copy of its document, title
-- and design. Restoring one makes it the deck's content again (after
-- keeping the current content as a version too).

CREATE TABLE snapshots (
  id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  presentation_id  text        NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  name             text        NOT NULL,
  title            text        NOT NULL,
  design           text        NOT NULL,
  doc              jsonb       NOT NULL,
  revision         integer     NOT NULL,
  created_by       bigint      REFERENCES users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX snapshots_presentation ON snapshots (presentation_id, created_at DESC);
