# folien

A web application for creating, editing and presenting slide decks
("Folien"), written in [dabscm](../dabscm). Five designs: our own
("Folien", and dark as "Folien Dunkel"), one after the corporate design of
the canton of Zurich ("Kanton Zürich"), and a plain one in Roboto Slab for
technical and conference talks ("Slab", "Slab Dunkel"). The interface is
in German.

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
      lines, tables, properties, undo/redo, autosave with conflict detection, notes
- [x] Phase 4 — images and videos: upload, drag and drop, paste, image
      placeholders, poster frames, media library, byte-range streaming
- [x] Phase 5 — presenting: transitions, builds, black/white screen,
      presenter console with notes, next preview, timer and an overview
      to jump to any slide, phone remote
      (WebSocket, falling back to server-sent events)
- [x] Phase 6 — PDF export: slides (960 × 540 pt) or A4 handouts with 2 or 4
      per page, each with or without notes; builds final or step by step
- [x] Phase 7 — zip bundle: export (document, assets, PDFs, offline player),
      import as a new deck; ZIP downloads in the lists and the archive
- [x] Phase 8 — PowerPoint export (.pptx): text, shapes, pictures, videos,
      transitions, builds as animations, notes; also in the bundle
- [x] Phase 9 — sharing (view/edit), versions, templates, tags and search,
      tables, clean-up and backup timers, Debian package; accessibility
      (design contrast WCAG AA, tested; keyboard selection on the editor
      stage with screen-reader announcements; skip link, status regions)
- [x] Footer fields: footer text, slide number and date (today's or a
      fixed text) per deck, placed by the design; not on title slides
      unless wanted, switchable per slide; in the PDF, and in PowerPoint
      as real slide-number and date fields
- [x] Images on the server (dabscm 2.7 `(scm image)`): uploads and imports
      must decode and are measured by the server; thumbnails load
      downscaled copies (`?w=320|640|1280`, cached); PDF and PowerPoint
      embed photos upright (EXIF) and no larger than the slide shows
- [x] Publishing: frozen copies at stable public addresses (`/p/<name>`),
      many per deck; offline export as one HTML file or a folder zip

## Layout

```
bin/server.scm        load the config, run migrations, serve
bin/dev-server.scm    auto-reloading dev supervisor
bin/seed-admin.scm    create the first admin (prompts for a password)
bin/reset-password.scm  set a new password for a user (prompts for it)
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
src/app-images.sld    image checks, thumbnail copies, export copies ((scm image))
src/app-export-pdf.sld  the deck as PDF, natively with (scm pdf)
src/app-export-pptx.sld the deck as PowerPoint file, with (scm ooxml presentation)
src/app-bundle.sld    the deck as zip bundle and back, the offline player
                      (also on its own); app-jsbundle.sld builds its script
src/app-publish.sld   publications: frozen public copies of a deck
src/app-views.sld     HTML rendering
src/app-web.sld       routes, JSON API and middleware: make-app
static/js/render.js   draws slides (viewer, editor, later player and exports)
static/js/editor.js   the editor; richtext-*.js its text editing, doc-ops.js
                      document operations
static/js/present.js  presenting: player.js (transitions, builds), deck-nav.js,
                      presenter.js, remote.js, sync.js (windows in step)
migrations/           NNNN_*.sql, applied in order at startup
static/               CSS, fonts (Inter, JetBrains Mono: SIL OFL; Roboto Slab:
                      Apache 2.0), favicon; js/render.js draws slides (shared
                      by viewer, editor, player), js/viewer.js
tests/                test_pure_*.scm (no database), test_live_web.scm
deploy/               systemd units, health probe, nginx/Apache examples, install script
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

Needs dabscm 2.12.0 or later (2.11.0 works, but embeds screenshots in PDFs slowly).

## PDF export

`GET /decks/<id>/export.pdf?per-page=1|2|4&notes=0|1&builds=final|steps`
(the form on the deck overview, "Übersicht"). The PDF is drawn natively with `(scm pdf)`
from the same document model the browser renders: the design's family
(Inter with the same OpenType features, or Roboto Slab), written as TrueType by `(scm truetype)` and embedded
(subset), kerned; text broken into lines by `(scm text layout)` with the
browser's rules, so line breaks match the screen; real, selectable text
with clickable web links. Images are embedded once each (PNG, JPEG, SVG
rasterized), videos show their poster frame, hidden slides are left out.
`FOLIEN_PDF_OUT=/tmp/x.pdf scm tests/test_pure_export.scm` writes a test
deck to look at.

## PowerPoint export

`GET /decks/<id>/export.pptx` (on the overview; also `exports/folien.pptx`
in a bundle) writes every element as a positioned PowerPoint object with
`(scm ooxml presentation)`: text boxes with the deck's formatting (bullets,
numbering, links), tables, shapes, lines, pictures (fitted or cropped as on the
slide), MP4 videos with their poster (other videos as the poster), the
layouts' decorations, slide backgrounds, transitions, builds as
animations (zoom becomes fade) and notes. Hidden slides are left out. The
text is in the design's family, Inter or Roboto Slab (bold where the web
uses Inter Black): exact where the font is installed, a similar font
otherwise.

## Bundles

`GET /decks/<id>/export.zip` (in the lists' menus and the overview's export section) gives
everything in one file: `manifest.json`, `presentation.json`, `assets/`,
`exports/` (slides, notes, 2 and 4 per page as PDF), `player/index.html`
(the presentation, offline, straight from the file system; its script is
the app's modules turned into one classic script by
`src/app-jsbundle.sld`, since browsers do not load modules from files)
and `LIESMICH.txt`. Bundles are cached per deck version in
`data-dir/bundles` for a day.

## Offline

To present without a network, the overview's export section offers the
offline player on its own, without hidden slides, with the notes (for
its presenter console) or, to pass it on, without them (`?notes=0`):

- `GET /decks/<id>/export.html`: one HTML file with everything in it
  (script, styles, the design's fonts as data URLs, their licences, the
  images and videos as base64 blocks that `static/js/offline.js` turns
  into blob URLs). Copy it anywhere and double-click it.
- `GET /decks/<id>/export-offline.zip`: the player's folder (`index.html`,
  `assets/`, `fonts/`, ...), better for large videos, which make the one
  file big and slow to open.

Both are cached like bundles. R switches the presentation to the
presenter console (`index.html?referent`, also in a bundle's player:
`static/js/presenter-app.js`, shared with the app), whose
"Publikumsfenster öffnen" opens the presentation as a second window of
the same file. Pages from files may have no working BroadcastChannel
(Firefox gives each file its own origin), so the two windows also talk
directly with `postMessage` (`Sync`'s windows option). There is no remote
without the server.

## Publishing

"Veröffentlichen" on the overview (the owner, a deck not in the trash)
makes a frozen copy that anyone with the address may see, present and
download as PDF, without signing in: title, design, and the document
without notes and hidden slides; an automatic footer date is fixed to the
day of publishing. Later changes to the deck do not touch it. Publishing
again makes another copy and leaves the earlier ones alone (a talk given
twice, with changes in between); "Zurückziehen" ends one. Optionally each
has a label ("Anlass").

```
/p/<name>                   the deck's newest publication
/p/<name>/<stamp>           one of them, for good ("2026-10-29", "2026-10-29-2")
/p/<name>/<stamp>/present   presenting it (no remote, no console)
/p/<name>/<stamp>/folien.pdf
```

name is the deck's public token (16 random characters, made at the first
publication, never changed) or a readable name the owner sets ("Name in
der Adresse": lower-case letters, digits, hyphens; unique across decks).
Both work; renaming changes only the readable addresses. Publications are
kept in `publications` (migration 0008) with their own copy of the
document; images and videos are content-addressed files, so a copy only
links the ones it shows (`publication_assets`, the only ones served under
its address) and shares the files with the deck and the other copies.
The nightly clean-up keeps an asset while a publication links it. A
deck in the trash shows none of its publications (restoring it brings
them back); deleting it deletes them.

"Aus ZIP importieren" on the presentations page (`POST /api/import`, the
zip as body) makes a new deck from a bundle. Nothing in an uploaded
archive is trusted: only the two JSON files and the assets the document
refers to are read, by known names; sizes are checked before and while
unpacking; each asset must hash to its name and be an accepted type; the
document must validate; newer bundle versions are refused with a message.

## Presenting

"Präsentieren" opens the deck full-window (F for fullscreen; arrows,
space, Page Up/Down and clickers move on; B and W blank the screen; a
number and Enter jump). The "Referentenansicht" shows the current slide,
what the next click brings, the notes, a timer and the clock; "Übersicht"
(G) shows all slides there to jump to one (click, or arrows and Enter;
the audience only sees the slide jumped to); it opens
the audience window (drag it to the projector and press F there) and
both stay in step over a BroadcastChannel. The "Fernbedienung" (open it
on a phone, signed in as the same user, or by its QR code, see below)
steers through the server, which
relays every message to all windows of the deck (src/app-remote.sld):
over a WebSocket, `GET /api/decks/<id>/socket`, both ways; where that
cannot connect (a proxy without WebSocket support) the browsers fall back
to `GET /api/decks/<id>/events`, a server-sent event stream, and `POST`s
to it. Every open connection holds a server thread (`http-max-threads`);
behind nginx the socket needs the upgrade headers of
`deploy/nginx.conf.example`, and `X-Accel-Buffering: no` turns off
buffering for the event stream.

### The remote by QR code

"Fernbedienung" in the presenter console and on the overview
show a QR code (`GET /decks/<id>/remote-qr.svg?origin=…`, drawn with
dabscm's `(scm qr)`): scanned with a phone's camera it opens the remote
without signing in. The code holds a remote link, a token
(`1.<user>.<deck>.<epoch>.<expiry>.<HMAC>`, src/app-auth.sld) signed
with a key derived from `session-secret` over the user's password stamp.
The remote page moves it into the `folien_remote` cookie (HttpOnly,
SameSite=Lax, as the phone opens the link from outside the browser) and
drops it from the address. It counts as its maker
only for that deck's remote, its JSON, the designs and the event
stream/socket; it ends after 12 hours, when the password changes, when
its maker loses access to the deck, or with "Neuen Code erzeugen"
(`POST /api/decks/<id>/remote-links/renew`, raising the deck's
`remote_epoch`), which ends all codes given out so far. Whoever holds a
code can steer the deck and read its notes: do not show it to the
audience. Without a code, the remote asks to sign in and comes back to
it afterwards (`/login?next=`).

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

## Slab designs

"Slab" and "Slab Dunkel" set Roboto Slab (Regular and Bold, 2.002, from
<https://github.com/googlefonts/robotoslab>; `static/fonts/RobotoSlab-*`
and `(scm fonts roboto-slab)` for the PDF). Roboto Slab has no arrows and
only some superscript digits: the browser draws those in a fallback font,
the PDF as "?". Its ligatures are off on screen, as in the PDF.

## Code

Text can be marked as code (toolbar `</>`, Ctrl+E): it is set in the
design's code font, JetBrains Mono (`static/fonts/JetBrainsMono-*`, SIL
OFL), with the weight of its box (bold in headings) and without its code
ligatures, so `->` stays two characters on screen as in the exports. The
PDF export takes the font from dabscm's `(scm fonts)`, i.e. the
`dabscm-fonts` package (`/usr/share/dabscm/fonts`, or unpacked into
`~/.local/share/dabscm/fonts`); without it, code keeps the text's font
in PDFs. PowerPoint names JetBrains Mono.

Code blocks are text boxes in the code font (`{ }` in the toolbar, the
layout "Titel und Code", or Schrift: Code in the inspector): on the
design's light tint with padding (`pad`, Innenabstand), Tab indents by
two spaces. The exports pad them alike (PowerPoint: text insets).

## Keyboard

Everything can be done without a mouse; `?` or F1 shows the keys of the
page (static/js/shortcuts.js). In the editor: F6 moves between the
toolbar, slide list, slide, notes, properties and title; the toolbar is
one Tab stop with arrows inside; on the slide Tab selects elements,
arrows move them, Alt+arrows resize, Enter edits, Esc returns to the
slide; while typing Ctrl+Enter goes to the next text field (after the
last: a new slide), Ctrl+Shift+8/7 make lists, Ctrl+Shift+L/E/R/J align,
Ctrl+Shift+. and , change the size, Ctrl+K links; Ctrl+M adds a slide,
Ctrl+arrows in the slide list move it; F5, Shift+F5 and Alt+F5 present
(from the start, from here, presenter console), also on the overview;
Esc ends a presentation (its window closes when the editor or the deck
page opened it).
The presentation list: arrows between the cards, `/` searches, `n`
starts a new presentation. Browsers keep some keys for themselves
(Firefox: Ctrl+Shift+J opens its console).

## Maintenance and backups

`bin/maintenance.scm` (nightly, `folien-maintenance.timer`) deletes decks
that have been in the trash longer than `trash-days` (30), removes assets
no deck uses any more (a file is shared by all decks with the same
content and goes with the last of them) and leftovers of broken uploads,
imports and cached bundles; anything younger than an hour (assets) or a
day (files) stays.

`bin/backup.scm` (nightly, `folien-backup.timer`) writes a compressed
`pg_dump` to `data-dir/backups` and keeps `backup-keep` (14) of them. Back
up `data-dir` (`/var/lib/folien`: the dumps and the assets) with your
usual file backup after it. Restore: `gunzip -c <dump> | psql folien`,
then put `data-dir` back.

## Deploy

**Debian package** (preferred): `scm packaging/package-deb.scm` builds
`releases/folien_<version>_all.deb` from the current commit (pure Scheme,
reproducible; bundles the dabscm runtime it was built with, the units
and a default config). `apt install ./folien_<version>_all.deb`, then
follow `/usr/share/doc/folien/README.Debian` (database, config, first
admin with `folien-admin seed-admin <name>`, start the units).

**Without a package**: `sudo deploy/install.sh` installs the checkout to
`/opt/folien` with the config in `/etc/folien/config.scm` (as in
starter-admin).

Either way the app binds loopback only behind a TLS-terminating reverse
proxy (`deploy/nginx.conf.example`, or `deploy/apache2.conf.example` for
Apache). To run it under a path of an existing site
(`https://www.example.com/folien/`), set `url-prefix` and see
`deploy/apache2-subpath.conf.example`.
