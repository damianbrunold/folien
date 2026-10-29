// The offline player of a bundle, opened from the file system (file://)
// in headless Firefox: the classic-script build of the presentation
// code runs, the slides draw in Inter, images load from ../assets, the
// keys move on. The player files are written by tests/js/player-files.scm
// exactly as a bundle has them; the one-file player (everything in one
// HTML file) by tests/js/player-html.scm. Run:
//   node --experimental-websocket --test tests/browser/

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { deflateSync } from "node:zlib";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launchFirefox, Keys } from "./bidi.mjs";
import { root, designsJson } from "./harness.mjs";
import * as ops from "../../static/js/doc-ops.js";

// A small RGB PNG of one colour.
function png(w, h, rgb) {
  const crcTable = Array.from({ length: 256 }, (_, n) => {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    return c >>> 0;
  });
  const crc = (buf) => {
    let c = 0xffffffff;
    for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
    return (c ^ 0xffffffff) >>> 0;
  };
  const chunk = (type, data) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc(td));
    return Buffer.concat([len, td, c]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  const rows = [];
  for (let y = 0; y < h; y++) rows.push(Buffer.from([0, ...Array(w).fill(rgb).flat()]));
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(Buffer.concat(rows))),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const zh = JSON.parse(designsJson()).find((d) => d.id === "zh");
let dir;
let browser;

before(async () => {
  dir = mkdtempSync(join(tmpdir(), "folien-offline-"));
  const image = png(40, 20, [0, 112, 180]);
  const sha = createHash("sha256").update(image).digest("hex");
  mkdirSync(join(dir, "assets"));
  writeFileSync(join(dir, "assets", sha + ".png"), image);
  const s1 = ops.newSlide(zh, "image-caption");
  s1.elements[0].text = { paragraphs: [{ runs: [{ text: "Offline" }] }] };
  s1.elements[1].asset = sha;
  s1.elements[2].text = { paragraphs: [{ runs: [{ text: "Ein Bild aus dem Archiv" }] }] };
  const s2 = ops.newSlide(zh, "section");
  s2.elements[0].text = { paragraphs: [{ runs: [{ text: "Zweite Folie" }] }] };
  writeFileSync(join(dir, "deck.json"), JSON.stringify({
    id: "d1", title: "Offline-Test", design: "zh",
    doc: { format: 1, slides: [s1, s2] },
    assets: { [sha]: "../assets/" + sha + ".png" },
  }));
  execFileSync("scm", [join(root, "tests/js/player-files.scm"), join(dir, "deck.json"), dir]);
  writeFileSync(join(dir, "single.json"), JSON.stringify({
    id: "d1", title: "Eine Datei", design: "zh",
    doc: { format: 1, slides: [s1, s2] },
    files: { [sha]: ["image/png", join(dir, "assets", sha + ".png")] },
  }));
  mkdirSync(join(dir, "single"));
  execFileSync("scm", [join(root, "tests/js/player-html.scm"), join(dir, "single.json"),
    join(dir, "single", "folien.html")]);
  browser = await launchFirefox({ port: 9337 });
});

after(async () => {
  if (browser) {
    if (browser.logs.length) console.log(browser.logs.join("\n"));
    await browser.close();
  }
  if (dir) rmSync(dir, { recursive: true, force: true });
});

test("the offline player runs from the file system", async () => {
  await browser.open("file://" + join(dir, "player", "index.html"), 1280, 720);
  await browser.waitFor("!!document.querySelector('.player-layer .slide')", 10000);
  assert.equal(await browser.eval("document.title"), "Offline-Test · Folien");
  assert.equal(await browser.eval("document.querySelector('.present-counter').textContent"), "1 / 2");
  // the image from ../assets
  await browser.waitFor(`(() => {
    const i = document.querySelector('.player-layer img');
    return i && i.complete && i.naturalWidth === 40;
  })()`, 5000);
  // the slides' font
  await browser.waitFor("document.fonts.check('900 40px Inter')", 5000);
  assert.ok(await browser.eval("document.body.textContent.includes('Ein Bild aus dem Archiv')"));
  if (process.env.FOLIEN_SHOTS) {
    writeFileSync(process.env.FOLIEN_SHOTS + "/11-offline.png", await browser.screenshot());
  }
  await browser.keys(Keys.right);
  await browser.waitFor("location.hash === '#2'");
  assert.ok(await browser.eval("document.body.textContent.includes('Zweite Folie')"));
});

test("the one-file player needs nothing beside it", async () => {
  // alone in its folder: no assets, fonts or scripts next to it
  await browser.open("file://" + join(dir, "single", "folien.html"), 1280, 720);
  await browser.waitFor("!!document.querySelector('.player-layer .slide')", 10000);
  assert.equal(await browser.eval("document.title"), "Eine Datei · Folien");
  // the image from its base64 block, as a blob URL
  await browser.waitFor(`(() => {
    const i = document.querySelector('.player-layer img');
    return i && i.complete && i.naturalWidth === 40 && i.src.startsWith('blob:');
  })()`, 5000);
  assert.equal(await browser.eval("document.querySelectorAll('script[type=\"application/x-folien-asset\"]').length"), 0);
  await browser.waitFor("document.fonts.check('900 40px Inter')", 5000);
  await browser.waitFor(`[...document.fonts].some((f) => f.family.includes('Inter') && f.status === 'loaded')`, 5000);
  await browser.keys(Keys.right);
  await browser.waitFor("location.hash === '#2'");
  assert.ok(await browser.eval("document.body.textContent.includes('Zweite Folie')"));
});
