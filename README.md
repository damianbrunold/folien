# folien

A web application for creating, editing and presenting slide decks
("Folien"), written in [dabscm](../dabscm). Two designs: our own ("Folien")
and one after the corporate design of the canton of Zurich ("Kanton
Zürich"). The interface is in German.

Built from `dabscm/examples/starter-admin`: PostgreSQL with migrations,
users and roles, signed-cookie sessions, strict CSP (no inline scripts or
styles), server-rendered pages, plain JavaScript in `static/js`.

## Status

Implemented step by step, phase by phase:

- [x] Phase 0 — skeleton: config, users, admin console, sign-in, deploy files
- [x] Phase 1 — deck management: create, rename, duplicate, archive,
      trash, delete; document model with validation; JSON API with
      revision-checked saves
- [x] Phase 2 — renderer (`static/js/render.js`) and read-only viewer
- [ ] Phase 3 — editor
- [ ] Phase 4 — assets (images, videos, paste)
- [ ] Phase 5 — presenting (transitions, builds, presenter console)
- [ ] Phase 6 — PDF export (slides, notes, handouts)
- [ ] Phase 7 — zip bundle export/import
- [ ] Phase 8 — PPTX export
- [ ] Phase 9 — sharing, snapshots, packaging

## Layout

```
bin/server.scm        load the config, run migrations, serve
bin/dev-server.scm    auto-reloading dev supervisor
bin/seed-admin.scm    create the first admin (prompts for a password)
bin/init-config.scm   write a new config file (used by deploy/install.sh)
bin/gen-secret.scm    print a new session secret (for key rotation)
bin/seed-demo.scm     create two demo decks (one per design) for a user
src/app-config.sld    config reading and first-run creation
src/app-site.sld      URL prefix: url, asset, cookie-path
src/app-db.sld        pool, query helpers, transactions, migrations
src/app-users.sld     user / role / user-role queries
src/app-auth.sld      sign-in, sessions, password changes
src/app-designs.sld   the designs: colour and font tokens, layouts
src/app-model.sld     the deck document: creation and validation
src/app-decks.sld     deck queries (owner-scoped, revision-checked saves)
src/app-views.sld     HTML rendering
src/app-web.sld       routes, JSON API and middleware: make-app
migrations/           NNNN_*.sql, applied in order at startup
static/               CSS, fonts (Inter, SIL OFL), favicon; js/render.js draws
                      slides (shared by viewer, editor, player), js/viewer.js
tests/                test_pure_*.scm (no database), test_live_web.scm
deploy/               systemd units, health probe, nginx example, install script
```

## The deck document

A deck's content is one JSON document stored as `jsonb`
(`presentations.doc`), described at the top of `src/app-model.sld`. Slides
use a layout of the deck's design; placeholder elements inherit position
and text style from the layout, and colours and fonts are design tokens
("accent", "heading"), so switching the design restyles the deck. Slide
coordinates are 1920 × 1080.

The editor saves with `PUT /api/decks/<id>` and
`{"revision": n, "design": id, "doc": {...}}`. The server validates the
document and answers `409` when another save came first.

## Setup

1. Create a database and a login role for the app:

   ```sql
   CREATE ROLE folien LOGIN PASSWORD 'choose-a-password';
   CREATE DATABASE folien OWNER folien;
   ```

2. Create `config.scm`, with a fresh `session-secret`, and set
   `db-password` (and the other `db-` settings if needed) in it:

   ```sh
   scm bin/init-config.scm config.scm
   ```

3. Seed the first admin. This also applies the migrations:

   ```sh
   scm bin/seed-admin.scm admin       # prompts for a password
   ```

## Run

```sh
scm bin/server.scm             # http://127.0.0.1:8090
scm bin/dev-server.scm         # same, restarts when src/, migrations/ or the config change
```

## Test

```sh
for t in tests/test_pure_*.scm; do scm "$t" || exit 1; done
```

`tests/test_live_web.scm` runs the full flows against a real database. It
drops the app's tables first, so it only runs against a database whose name
ends in `_test`:

```sh
createdb -O folien folien_test
sed 's/(define db-name "folien")/(define db-name "folien_test")/' \
    config.scm > tests/test-config.scm
FOLIEN_TEST_CONFIG=tests/test-config.scm scm tests/test_live_web.scm
```

## Kanton Zürich design

Colours and type follow the canton's web design system as already applied
in `../dashboards` (`static/design-zh.css`, `docs/design.md` there): Inter
Regular and Black, black on white, accent blue `#0070B4`. The canton's
logo is **not** included; it needs the official file and permission to use
it. The slide layouts should be checked against the canton's official
presentation template.

## Deploy

As in starter-admin: the app binds loopback only behind a TLS-terminating
reverse proxy (`deploy/nginx.conf.example`); `sudo deploy/install.sh`
installs it to `/opt/folien` with the config in `/etc/folien/config.scm`.
