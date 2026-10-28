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
- [x] Phase 3 — editor: slides, layouts, text (own rich-text editor), shapes,
      lines, properties, undo/redo, autosave with conflict detection, notes
- [x] Phase 4 — images and videos: upload, drag and drop, paste, image
      placeholders, poster frames, media library, byte-range streaming
- [x] Phase 5 — presenting: transitions, builds, black/white screen,
      presenter console with notes, next preview and timer, phone remote
- [x] Phase 6 — PDF export: slides (960 × 540 pt) or A4 handouts with 2 or 4
      per page, each with or without notes; builds final or step by step
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
src/app-assets.sld    uploaded images and videos (content-addressed files)
src/app-export-pdf.sld  the deck as PDF, natively with (scm pdf)
src/app-views.sld     HTML rendering
src/app-web.sld       routes, JSON API and middleware: make-app
static/js/render.js   draws slides (viewer, editor, later player and exports)
static/js/editor.js   the editor; richtext-*.js its text editing, doc-ops.js
                      document operations
static/js/present.js  presenting: player.js (transitions, builds), deck-nav.js,
                      presenter.js, remote.js, sync.js (windows in step)
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

## Images and videos

Uploads go to `POST /api/decks/<id>/assets` (the file as the body). The
server takes the type from the file's first bytes (PNG, JPEG, GIF, WebP,
SVG, MP4, WebM) and stores each file once, named by its SHA-256, under
`data-dir/assets`; decks link to the files they use. Bodies over 1 MB are
spooled to disk by the HTTP server, so `max-upload-bytes` (default 1 GB)
needs no memory. Files are served with byte ranges (videos seek) and,
being content-addressed, cached for good; a sandbox CSP keeps an uploaded
SVG from running script. The browser converts images to PNG or JPEG of at
most 3840 px (what the PDF export embeds) and takes a poster frame of
each video. Behind nginx, `client_max_body_size` must allow the uploads
(`deploy/nginx.conf.example`).

Needs dabscm 2.4.0 or later.

## PDF export

`GET /decks/<id>/export.pdf?per-page=1|2|4&notes=0|1&builds=final|steps`
(the form on the deck page). The PDF is drawn natively with `(scm pdf)`
from the same document model the browser renders: Inter with the same
OpenType features, written as TrueType by `(scm truetype)` and embedded
(subset), kerned; text broken into lines by `(scm text layout)` with the
browser's rules, so line breaks match the screen; real, selectable text
with clickable web links. Images are embedded once each (PNG, JPEG, SVG
rasterized), videos show their poster frame, hidden slides are left out.
`FOLIEN_PDF_OUT=/tmp/x.pdf scm tests/test_pure_export.scm` writes a test
deck to look at.

## Presenting

"Präsentieren" opens the deck full-window (F for fullscreen; arrows,
space, Page Up/Down and clickers move on; B and W blank the screen; a
number and Enter jump). The "Referentenansicht" shows the current slide,
what the next click brings, the notes, a timer and the clock; it opens
the audience window (drag it to the projector and press F there) and
both stay in step over a BroadcastChannel. The "Fernbedienung" (open it
on a phone, signed in as the same user) steers through the server:
`GET /api/decks/<id>/events` is a server-sent event stream and `POST` to
it sends a message (src/app-remote.sld). Every open stream holds a server
thread (`http-max-threads`); behind nginx the `X-Accel-Buffering: no`
header turns off buffering for it.

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

The browser code's pure modules (rich-text model, document operations)
have node tests; the editor has browser tests that drive headless Firefox
over WebDriver BiDi, with the API stubbed (no server or database needed):

```sh
node --test tests/js/
node --experimental-websocket --test tests/browser/   # node 20; plain --test from node 22
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
