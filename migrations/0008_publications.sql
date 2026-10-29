-- Publications: frozen copies of a deck that anyone with the address may
-- see, without signing in (/p/<name>/<stamp>). A deck can have many (say
-- one for each time a talk is given); each keeps its content, however
-- the deck changes later, until the owner withdraws it. The name is the
-- deck's random public token, or the readable slug the owner chose.

ALTER TABLE presentations ADD COLUMN public_token text UNIQUE;
ALTER TABLE presentations ADD COLUMN public_slug text UNIQUE;

CREATE TABLE publications (
  id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  presentation_id  text        NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  -- "2026-10-29", a second one that day "2026-10-29-2"
  stamp            text        NOT NULL,
  label            text        NOT NULL DEFAULT '',
  title            text        NOT NULL,
  design           text        NOT NULL,
  doc              jsonb       NOT NULL,
  revision         integer     NOT NULL,
  created_by       bigint      REFERENCES users(id) ON DELETE SET NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (presentation_id, stamp)
);

-- The assets a publication shows: only these are served under its
-- address. Files are content-addressed, so a publication shares them
-- with its deck and every other publication; this keeps them stored
-- while any publication needs them.
CREATE TABLE publication_assets (
  publication_id  bigint NOT NULL REFERENCES publications(id) ON DELETE CASCADE,
  sha256          text   NOT NULL REFERENCES assets(sha256),
  PRIMARY KEY (publication_id, sha256)
);
