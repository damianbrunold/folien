// A static server for the browser tests: the app's static/ under /static,
// and pages and fixtures given by the test under their own paths. The API
// is stubbed in the page (fixture fetch-stub.js), so no database or scm
// server is needed.

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
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

// files: {"/path": "content"}. Returns {url, close}.
export async function serve(files) {
  const server = createServer(async (req, res) => {
    const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
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
        return resp(200, Object.assign({}, deck, { revision }));
      };`,
    "/edit.html": `<!doctype html><html lang="de"><head><meta charset="utf-8">
      <link rel="stylesheet" href="/static/css/app.css">
      <link rel="stylesheet" href="/static/css/slides.css">
      <link rel="stylesheet" href="/static/css/editor.css">
      <script type="module" src="/fetch-stub.js"></script>
      <script type="module" src="/static/js/editor.js"></script></head>
      <body class="editor-body"><div id="editor" class="editor" data-deck-url="/api/decks/d1"
        data-designs-url="/api/designs" data-view-url="/decks/d1" data-home-url="/"></div></body></html>`,
  };
}
