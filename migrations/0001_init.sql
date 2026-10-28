-- Initial schema: users, roles, and the many-to-many between them.
-- Applied once at startup and recorded in schema_migrations.

CREATE TABLE users (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  username    text        NOT NULL UNIQUE,
  pass_hash   text        NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roles (
  id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name  text NOT NULL UNIQUE
);

CREATE TABLE user_roles (
  user_id  bigint NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id  bigint NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);
