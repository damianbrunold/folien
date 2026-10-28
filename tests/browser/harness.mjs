// A static server for the browser tests: the app's static/ under /static,
// and pages and fixtures given by the test under their own paths. The API
// is stubbed in the page (fixture fetch-stub.js), so no database or scm
// server is needed.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { extname, join, normalize } from "node:path";

export const root = new URL("../..", import.meta.url).pathname;

const TYPES = {
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".css": "text/css",
  ".woff2": "font/woff2",
  ".svg": "image/svg+xml",
  ".html": "text/html; charset=utf-8",
  ".json": "application/json",
};

// The designs as the server serves them.
export function designsJson() {
  return execFileSync("scm", [join(root, "tests/js/designs-json.scm")], { encoding: "utf8" });
}

// A stand-in for the asset API of one deck (POST, list, file), keeping
// uploads in memory: enough for the editor's upload code to run for real.
export function assetApi(deckPath) {
  const store = new Map(); // sha -> {mime, body, name, width, height}
  const sniff = (b) =>
    b[0] === 0x89 && b[1] === 0x50 ? "image/png"
    : b[0] === 0xff && b[1] === 0xd8 ? "image/jpeg"
    : b[0] === 0x1a && b[1] === 0x45 ? "video/webm"
    : String(b.subarray(4, 8)) === "ftyp" ? "video/mp4"
    : String(b.subarray(0, 4)) === "<svg" ? "image/svg+xml"
    : null;
  const handler = async (req, res, path, url) => {
    if (path === deckPath + "/assets" && req.method === "POST") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      const body = Buffer.concat(chunks);
      const mime = sniff(body);
      if (!mime) {
        res.writeHead(415).end("{}");
        return true;
      }
      const sha = createHash("sha256").update(body).digest("hex");
      const a = {
        sha, mime, size: body.length, name: url.searchParams.get("name"),
        width: Number(url.searchParams.get("w")) || null,
        height: Number(url.searchParams.get("h")) || null,
      };
      store.set(sha, Object.assign({ body }, a));
      res.writeHead(201, { "Content-Type": "application/json" }).end(JSON.stringify(a));
      return true;
    }
    if (path === deckPath + "/assets" && req.method === "GET") {
      const list = [...store.values()].map(({ body, ...a }) => a).reverse();
      res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify(list));
      return true;
    }
    if (path.startsWith(deckPath + "/assets/")) {
      const a = store.get(path.slice(deckPath.length + 8));
      if (!a) res.writeHead(404).end();
      else res.writeHead(200, { "Content-Type": a.mime }).end(a.body);
      return true;
    }
    return false;
  };
  return { store, handler };
}

// A stand-in for the event stream of a deck (GET: server-sent events,
// POST: a message to every listener), as (app remote) does it.
export function eventRelay(eventsPath) {
  const listeners = new Set();
  const handler = async (req, res, path) => {
    if (path !== eventsPath) return false;
    if (req.method === "GET") {
      res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
      res.write("retry: 1000\n\n");
      listeners.add(res);
      req.on("close", () => listeners.delete(res));
      return true;
    }
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const msg = JSON.parse(Buffer.concat(chunks).toString("utf8"));
    for (const l of listeners) l.write("data: " + JSON.stringify(msg) + "\n\n");
    res.writeHead(202, { "Content-Type": "application/json" }).end(JSON.stringify({ listeners: listeners.size }));
    return true;
  };
  return { listeners, handler, close: () => listeners.forEach((l) => l.end()) };
}

// Several API stand-ins in turn.
export function apis(...handlers) {
  return async (req, res, path, url) => {
    for (const h of handlers) if (await h(req, res, path, url)) return true;
    return false;
  };
}

// files: {"/path": "content"}; api: (req, res, path, url) -> true if it
// answered. Returns {url, close}.
export async function serve(files, api) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url, "http://x");
    const path = decodeURIComponent(url.pathname);
    if (api && (await api(req, res, path, url))) return;
    if (files[path] !== undefined) {
      res.writeHead(200, { "Content-Type": TYPES[extname(path)] || "text/html; charset=utf-8" });
      res.end(files[path]);
      return;
    }
    if (path.startsWith("/static/")) {
      const file = normalize(join(root, path));
      if (!file.startsWith(join(root, "static"))) {
        res.writeHead(403).end();
        return;
      }
      try {
        const body = await readFile(file);
        res.writeHead(200, { "Content-Type": TYPES[extname(file)] || "application/octet-stream" });
        res.end(body);
      } catch (e) {
        res.writeHead(404).end();
      }
      return;
    }
    res.writeHead(404).end();
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((r) => server.close(r)),
  };
}

// The editor page as src/app-views.sld renders it, with the API stubbed:
// GET returns the deck, PUT is recorded in window.__puts and answered
// with window.__putStatus (default 200).
export function editorFiles(deck, designs) {
  return {
    "/fetch-stub.js": `
      const deck = ${JSON.stringify(deck)};
      const designs = ${designs};
      let revision = deck.revision;
      window.__puts = [];
      const realFetch = window.fetch.bind(window);
      window.__putStatus = 200;
      const resp = (status, body) => ({ ok: status < 300, status, json: async () => body });
      window.fetch = async (url, opts = {}) => {
        if (opts.method === "PUT") {
          const body = JSON.parse(opts.body);
          window.__puts.push(body);
          if (window.__putStatus !== 200) return resp(window.__putStatus, { error: "conflict", revision });
          revision += 1;
          return resp(200, { revision });
        }
        if (url === "/api/designs") return resp(200, designs);
        if (url === "/api/decks/d1") return resp(200, Object.assign({}, deck, { revision }));
        return realFetch(url, opts);
      };`,
    "/edit.html": `<!doctype html><html lang="de"><head><meta charset="utf-8">
      <link rel="stylesheet" href="/static/css/app.css">
      <link rel="stylesheet" href="/static/css/slides.css">
      <link rel="stylesheet" href="/static/css/editor.css">
      <script type="module" src="/fetch-stub.js"></script>
      <script type="module" src="/static/js/editor.js"></script></head>
      <body class="editor-body"><div id="editor" class="editor" ${DATA}></div></body></html>`,
    "/present.html": appPage("present", "present.css"),
    "/presenter.html": appPage("presenter", "present.css"),
    "/remote.html": appPage("remote", "present.css"),
  };
}

// The data attributes src/app-views.sld gives the application pages.
const DATA = `data-deck-url="/api/decks/d1" data-designs-url="/api/designs"
  data-events-url="/api/decks/d1/events" data-view-url="/view.html"
  data-present-url="/present.html" data-presenter-url="/presenter.html"
  data-remote-url="/remote.html" data-home-url="/"`;

function appPage(name, css) {
  return `<!doctype html><html lang="de"><head><meta charset="utf-8">
    <link rel="stylesheet" href="/static/css/app.css">
    <link rel="stylesheet" href="/static/css/slides.css">
    <link rel="stylesheet" href="/static/css/${css}">
    <script type="module" src="/fetch-stub.js"></script>
    <script type="module" src="/static/js/${name}.js"></script></head>
    <body class="${name}-body"><div id="${name}" class="${name}" ${DATA}></div></body></html>`;
}
