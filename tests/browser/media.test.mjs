// Browser tests of images and videos in the editor: drop, paste, filling
// an image placeholder, video posters, the media library. The uploads go
// to an in-memory stand-in of the asset API (harness.mjs). The video
// fixture is made with ffmpeg; without it that test is skipped. Run:
//   node --experimental-websocket --test tests/browser/

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launchFirefox } from "./bidi.mjs";
import { serve, editorFiles, designsJson, assetApi } from "./harness.mjs";
import * as ops from "../../static/js/doc-ops.js";

const designsText = designsJson();
const zh = JSON.parse(designsText).find((d) => d.id === "zh");

const s1 = ops.newSlide(zh, "title-only");
const s2 = ops.newSlide(zh, "image-caption");
const deck = {
  id: "d1",
  title: "Medien",
  design: "zh",
  status: "active",
  revision: 1,
  doc: { format: 1, slides: [s1, s2] },
};

function makeVideo() {
  try {
    const dir = mkdtempSync(join(tmpdir(), "folien-video-"));
    const out = join(dir, "clip.webm");
    execFileSync("ffmpeg", [
      "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10",
      "-t", "2", "-c:v", "libvpx", "-b:v", "200k", out,
    ]);
    const bytes = readFileSync(out);
    rmSync(dir, { recursive: true, force: true });
    return bytes;
  } catch (e) {
    return null;
  }
}

let browser;
let server;
const api = assetApi("/api/decks/d1");
const video = makeVideo();

before(async () => {
  const files = editorFiles(deck, designsText);
  if (video) files["/fixtures/clip.webm"] = video;
  server = await serve(files, api.handler);
  browser = await launchFirefox({ port: 9334 });
  await browser.open(server.url + "/edit.html");
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 2");
  // Helpers in the page: files made on a canvas, and drop and paste events.
  await browser.eval(`(() => {
    window.__image = async (type, w, h, alpha) => {
      const c = document.createElement("canvas");
      c.width = w; c.height = h;
      const x = c.getContext("2d");
      x.fillStyle = alpha ? "rgba(255, 0, 0, 0.5)" : "#0070b4";
      x.fillRect(0, 0, w, h);
      const b = await new Promise((r) => c.toBlob(r, type, 0.9));
      return new File([b], "bild." + type.split("/")[1], { type });
    };
    // Drops at a point of the slide given as fractions of its size
    // (default: the centre). Dropping onto an image replaces it.
    window.__drop = (file, fx = 0.5, fy = 0.5) => {
      const dt = new DataTransfer();
      dt.items.add(file);
      const stage = document.querySelector(".ed-stage");
      const r = document.querySelector(".ed-frame").getBoundingClientRect();
      stage.dispatchEvent(new DragEvent("drop", {
        bubbles: true, cancelable: true, dataTransfer: dt,
        clientX: r.x + r.width * fx, clientY: r.y + r.height * fy,
      }));
    };
    window.__paste = (file) => {
      const dt = new DataTransfer();
      dt.items.add(file);
      document.body.dispatchEvent(new ClipboardEvent("paste", {
        bubbles: true, cancelable: true, clipboardData: dt,
      }));
    };
    return true;
  })()`);
});

after(async () => {
  if (browser) {
    if (browser.logs.length) console.log(browser.logs.join("\n"));
    await browser.close();
  }
  if (server) await server.close();
});

// The document of the last save once it has n elements on slide i.
async function docWith(i, n) {
  await browser.waitFor(
    `window.__puts.length && window.__puts[window.__puts.length - 1].doc.slides[${i}].elements.length === ${n}`,
    15000,
  );
  return browser.eval("window.__puts[window.__puts.length - 1].doc");
}

const mimes = () => [...api.store.values()].map((a) => a.mime);

test("dropping a PNG adds an image", async () => {
  await browser.eval(`(async () => window.__drop(await window.__image("image/png", 2400, 1200)))()`);
  const doc = await docWith(0, 2);
  const img = doc.slides[0].elements[1];
  assert.equal(img.type, "image");
  assert.match(img.asset, /^[0-9a-f]{64}$/);
  assert.equal(img.w, 1200); // fitted into 1200 x 700
  assert.equal(img.h, 600);
  assert.ok(api.store.get(img.asset).mime === "image/png");
  // The canvas shows it, loaded from the asset URL.
  await browser.waitFor(`(() => {
    const i = document.querySelector('.ed-frame img');
    return i && i.complete && i.naturalWidth === 2400;
  })()`);
});

// (Pasting goes through the same code after the paste event; Firefox does
// not put files into a synthetic paste event, so the test drops.)
test("a WebP becomes a JPEG (it has no transparency)", async () => {
  await browser.eval(`(async () => window.__drop(await window.__image("image/webp", 300, 200), 0.05, 0.95))()`);
  const doc = await docWith(0, 3);
  const img = doc.slides[0].elements[2];
  assert.equal(api.store.get(img.asset).mime, "image/jpeg");
  assert.equal(api.store.get(img.asset).name, "bild.jpg");
});

test("dropping onto an image replaces it", async () => {
  const before = await browser.eval("window.__puts[window.__puts.length - 1].doc.slides[0].elements[1].asset");
  await browser.eval(`(async () => window.__drop(await window.__image("image/png", 640, 480)))()`);
  await browser.waitFor(
    `window.__puts[window.__puts.length - 1].doc.slides[0].elements[1].asset !== "${before}"`,
    15000,
  );
  const doc = await browser.eval("window.__puts[window.__puts.length - 1].doc");
  assert.equal(doc.slides[0].elements.length, 3);
  assert.equal(doc.slides[0].elements[1].w, 1200); // its place and size stay
});

test("an image fills the empty image placeholder", async () => {
  await browser.eval("document.querySelectorAll('.ed-thumb')[1].click()");
  await browser.eval(`(async () => window.__drop(await window.__image("image/png", 400, 300, true)))()`);
  await browser.waitFor(
    "window.__puts.length && window.__puts[window.__puts.length - 1].doc.slides[1].elements[1].asset",
    15000,
  );
  const doc = await browser.eval("window.__puts[window.__puts.length - 1].doc");
  const els = doc.slides[1].elements;
  assert.equal(els.length, 3); // no new element
  assert.equal(els[1].placeholder, "image");
  assert.equal(els[1].type, "image");
  // with transparency it stays PNG
  assert.equal(api.store.get(els[1].asset).mime, "image/png");
});

test("a video gets a poster frame", { skip: !video && "ffmpeg not available" }, async () => {
  await browser.eval("document.querySelectorAll('.ed-thumb')[0].click()");
  await browser.eval(`(async () => {
    const b = await (await fetch("/fixtures/clip.webm")).blob();
    window.__drop(new File([b], "clip.webm", { type: "video/webm" }), 0.95, 0.95);
  })()`);
  const doc = await docWith(0, 4);
  const v = doc.slides[0].elements[3];
  assert.equal(v.type, "video");
  assert.equal(api.store.get(v.asset).mime, "video/webm");
  assert.equal(api.store.get(v.poster).mime, "image/jpeg");
  assert.equal(api.store.get(v.poster).name, "clip.poster.jpg");
  assert.equal(v.w, 320); // small enough to keep its size
  assert.equal(v.h, 180);
  assert.equal(v.x + v.w, 1920); // dropped near the corner, kept inside the slide
  // the panel offers the video options
  assert.ok(await browser.eval("document.querySelector('.ed-panel').textContent.includes('Endlos wiederholen')"));
});

test("the media library lists the uploads, posters left out", async () => {
  await browser.eval("document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))");
  await browser.waitFor("document.querySelectorAll('.media-tile').length > 0", 5000);
  const tiles = await browser.eval("document.querySelectorAll('.media-tile').length");
  const expected = [...api.store.values()].filter((a) => !a.name.endsWith(".poster.jpg")).length;
  assert.equal(tiles, expected);
  // inserting from the library adds another element
  await browser.eval("document.querySelector('.media-tile img').closest('button').click()");
  const n = video ? 5 : 4;
  const doc = await docWith(0, n);
  assert.match(doc.slides[0].elements[n - 1].asset, /^[0-9a-f]{64}$/);
  if (process.env.FOLIEN_SHOTS) {
    writeFileSync(process.env.FOLIEN_SHOTS + "/07-media.png", await browser.screenshot());
  }
});
