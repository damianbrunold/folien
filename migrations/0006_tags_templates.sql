-- Tags (a JSON array of strings) for finding decks, and templates: decks
-- their owner offers as the start of new ones.

ALTER TABLE presentations ADD COLUMN tags jsonb NOT NULL DEFAULT '[]';
ALTER TABLE presentations ADD COLUMN is_template boolean NOT NULL DEFAULT false;
