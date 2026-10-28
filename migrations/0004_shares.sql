-- Sharing: the owner lets other users see (view) or also change (edit)
-- a deck. Only the owner archives, trashes, deletes or shares it.

CREATE TABLE presentation_shares (
  presentation_id  text        NOT NULL REFERENCES presentations(id) ON DELETE CASCADE,
  user_id          bigint      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role             text        NOT NULL CHECK (role IN ('view', 'edit')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (presentation_id, user_id)
);

CREATE INDEX presentation_shares_user ON presentation_shares (user_id);
