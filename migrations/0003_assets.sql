-- Uploaded images and videos ("assets"). A file is stored once, named
-- by the SHA-256 of its content (data-dir/assets/<2 hex>/<sha>), however
-- many decks use it; presentation_assets says which decks may. Access to
-- an asset always goes through one of its decks.

CREATE TABLE assets (
  sha256      text        PRIMARY KEY,
  mime        text        NOT NULL,
  size        bigint      NOT NULL,
  width       integer,
  height      integer,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE presentation_assets (
  presentation_id  text        NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  sha256           text        NOT NULL REFERENCES assets(sha256),
  name             text        NOT NULL,
  added_at         timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (presentation_id, sha256)
);
