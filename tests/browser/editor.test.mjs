// Browser tests of the editor in headless Firefox (WebDriver BiDi), with
// the API stubbed. Run:
//   node --experimental-websocket --test tests/browser/
// Screenshots go to $FOLIEN_SHOTS if set.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { launchFirefox, Keys } from "./bidi.mjs";
import { serve, editorFiles, designsJson } from "./harness.mjs";
import * as ops from "../../static/js/doc-ops.js";

const designsText = designsJson();
const designs = JSON.parse(designsText);
const folien = designs.find((d) => d.id === "folien");

function fixtureDeck() {
  const s1 = ops.newSlide(folien, "title");
  s1.elements[0].text = { paragraphs: [{ runs: [{ text: "Hallo" }] }] };
  const s2 = ops.newSlide(folien, "title-content");
  s2.elements[0].text = { paragraphs: [{ runs: [{ text: "Zweite" }] }] };
  s2.elements[1].text = {
    paragraphs: [
      { list: "bullet", runs: [{ text: "eins" }] },
      { list: "bullet", runs: [{ text: "zwei" }] },
    ],
  };
  return {
    id: "d1",
    title: "Testdeck",
    design: "folien",
    status: "active",
    revision: 1,
    doc: { format: 1, slides: [s1, s2] },
  };
}

let browser;
let server;
const deck = fixtureDeck();

async function shot(name) {
  if (!process.env.FOLIEN_SHOTS) return;
  writeFileSync(process.env.FOLIEN_SHOTS + "/" + name + ".png", await browser.screenshot());
}

// The centre of an element of the canvas on screen.
function centerOf(id) {
  return browser.eval(`(() => {
    const r = document.querySelector('.ed-frame .el[data-id="${id}"]').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height };
  })()`);
}

// Puts the caret at the end of the text being edited. (In headless
// Firefox, caret keys do not move the caret in a contenteditable, so the
// tests place it with the Selection API.)
function caretToEnd() {
  return browser.eval(`(() => {
    const e = document.querySelector('.text-inner.editing');
    const s = document.getSelection();
    s.selectAllChildren(e.lastElementChild);
    s.collapseToEnd();
  })()`);
}

// Saves now (Ctrl+S) and returns the document of the last save.
async function saved() {
  await browser.keys("s", [Keys.ctrl]);
  await browser.waitFor("document.querySelector('.ed-status').textContent === 'Gespeichert'");
  return browser.eval("window.__puts[window.__puts.length - 1].doc");
}

before(async () => {
  server = await serve(editorFiles(deck, designsText));
  browser = await launchFirefox();
  await browser.open(server.url + "/edit.html");
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 2");
});

after(async () => {
  if (browser) {
    if (browser.logs.length) console.log(browser.logs.join("\n"));
    await browser.close();
  }
  if (server) await server.close();
});

test("the editor loads the deck", async () => {
  assert.equal(await browser.eval("document.querySelector('.ed-title').value"), "Testdeck");
  assert.equal(await browser.eval("document.querySelectorAll('.ed-frame .el[data-id]').length"), 2);
  await shot("01-loaded");
});

const slide0 = () => deck.doc.slides[0];
const titleId = () => slide0().elements[0].id;
const subtitleId = () => slide0().elements[1].id;
const runsOf = (doc, si, ei) => doc.slides[si].elements[ei].text.paragraphs;

test("typing into a placeholder", async () => {
  const c = await centerOf(titleId());
  await browser.click(c.x, c.y, 2);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  await caretToEnd();
  await browser.keys(" Welt");
  await browser.keys(Keys.escape);
  const doc = await saved();
  assert.equal(runsOf(doc, 0, 0)[0].runs[0].text, "Hallo Welt");
  await shot("02-typed");
});

test("bold, new paragraphs and undo", async () => {
  const c = await centerOf(subtitleId());
  await browser.click(c.x, c.y, 2);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  await browser.keys("Eins");
  await browser.keys(Keys.enter);
  await browser.keys("Zwei");
  await browser.keys("a", [Keys.ctrl]); // select all in the box
  await browser.keys("b", [Keys.ctrl]);
  await browser.keys(Keys.escape);
  let doc = await saved();
  const paras = runsOf(doc, 0, 1);
  assert.deepEqual(paras.map((p) => p.runs.map((r) => [r.text, !!r.b])), [[["Eins", true]], [["Zwei", true]]]);
  await shot("03-bold");
  // Undo the bold (one step), then the typing.
  await browser.keys("z", [Keys.ctrl]);
  doc = await saved();
  assert.deepEqual(runsOf(doc, 0, 1).map((p) => p.runs[0].b), [undefined, undefined]);
  await browser.keys("z", [Keys.ctrl]);
  doc = await saved();
  assert.equal(runsOf(doc, 0, 1)[0].runs[0].text, "");
  await browser.keys("y", [Keys.ctrl]);
  doc = await saved();
  assert.equal(runsOf(doc, 0, 1).length, 2);
});

test("insert, move, resize and delete a shape", async () => {
  await browser.eval(`(() => {
    const s = document.querySelector('select[aria-label="Form einfügen"]');
    s.value = "ellipse";
    s.dispatchEvent(new Event("change"));
  })()`);
  let doc = await saved();
  const shape = doc.slides[0].elements[2];
  assert.equal(shape.shape, "ellipse");
  assert.equal(shape.x, 760);
  const c = await centerOf(shape.id);
  const scale = c.w / shape.w;
  await browser.drag(c.x, c.y, c.x + 100, c.y + 50);
  doc = await saved();
  const moved = doc.slides[0].elements[2];
  // Within snapping distance of the exact move.
  assert.ok(Math.abs(moved.x - (760 + 100 / scale)) <= 10 / scale, "x " + moved.x);
  assert.ok(Math.abs(moved.y - (390 + 50 / scale)) <= 10 / scale, "y " + moved.y);
  // Resize with the bottom-right handle, snapping off (no Alt in BiDi
  // pointer actions, so allow for it).
  const hd = await browser.eval(`(() => {
    const r = document.querySelector('.handle.h-se').getBoundingClientRect();
    return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
  })()`);
  await browser.drag(hd.x, hd.y, hd.x + 60, hd.y + 30);
  doc = await saved();
  const sized = doc.slides[0].elements[2];
  assert.ok(sized.w > 400 && sized.h > 300, JSON.stringify(sized));
  await shot("04-shape");
  await browser.keys(Keys.delete);
  doc = await saved();
  assert.equal(doc.slides[0].elements.length, 2);
});

test("a build effect for an element", async () => {
  await browser.eval(`(() => {
    const s = document.querySelector('select[aria-label="Form einfügen"]');
    s.value = "rect";
    s.dispatchEvent(new Event("change"));
  })()`);
  await browser.eval(`(() => {
    const s = document.querySelector('select[aria-label="Aufbau"]');
    s.value = "fly-left";
    s.dispatchEvent(new Event("change"));
  })()`);
  const doc = await saved();
  const els = doc.slides[0].elements;
  assert.deepEqual(els[els.length - 1].build, { order: 1, effect: "fly-left" });
  assert.equal(await browser.eval("document.querySelectorAll('.build-badge').length"), 1);
  await browser.keys(Keys.delete);
  await saved();
});

test("slides: add, move, delete", async () => {
  await browser.eval(`(() => {
    const s = document.querySelector('select[aria-label="Neue Folie"]');
    s.value = "two-columns";
    s.dispatchEvent(new Event("change"));
  })()`);
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 3");
  let doc = await saved();
  assert.deepEqual(doc.slides.map((s) => s.layout), ["title", "two-columns", "title-content"]);
  await browser.eval(`document.querySelector('button[aria-label="Folie nach unten"]').click()`);
  doc = await saved();
  assert.deepEqual(doc.slides.map((s) => s.layout), ["title", "title-content", "two-columns"]);
  await browser.eval(`document.querySelector('button[aria-label="Folie löschen"]').click()`);
  doc = await saved();
  assert.deepEqual(doc.slides.map((s) => s.layout), ["title", "title-content"]);
});

test("changing the layout keeps the text", async () => {
  await browser.eval("document.querySelectorAll('.ed-thumb')[1].click()");
  await browser.eval(`(() => {
    const s = document.querySelector('select[aria-label="Layout"]');
    s.value = "title-only";
    s.dispatchEvent(new Event("change"));
  })()`);
  const doc = await saved();
  const s = doc.slides[1];
  assert.equal(s.layout, "title-only");
  assert.equal(s.elements[0].text.paragraphs[0].runs[0].text, "Zweite");
  // The body became a free text box with the bullets.
  assert.equal(s.elements[1].placeholder, undefined);
  assert.equal(s.elements[1].text.paragraphs[1].runs[0].text, "zwei");
  await shot("05-layout");
});

test("notes", async () => {
  const r = await browser.eval(`(() => {
    const r = document.querySelector('.ed-notes-body').getBoundingClientRect();
    return { x: r.x + 40, y: r.y + 10 };
  })()`);
  await browser.click(r.x, r.y);
  await browser.keys("Nicht vergessen");
  const doc = await saved();
  assert.equal(doc.slides[1].notes.paragraphs[0].runs[0].text, "Nicht vergessen");
});

test("a new text box", async () => {
  await browser.eval("document.querySelector('.ed-thumb').click()");
  await browser.eval(`document.querySelector('button[aria-label="Textfeld einfügen"]').click()`);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  await browser.keys("Frei");
  await browser.keys(Keys.escape);
  const doc = await saved();
  const el = doc.slides[0].elements[doc.slides[0].elements.length - 1];
  assert.equal(el.placeholder, undefined);
  assert.equal(el.text.paragraphs[0].runs[0].text, "Frei");
  // An empty new text box goes away when editing ends.
  await browser.eval(`document.querySelector('button[aria-label="Textfeld einfügen"]').click()`);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  await browser.keys(Keys.escape);
  const doc2 = await saved();
  assert.equal(doc2.slides[0].elements.length, doc.slides[0].elements.length);
});


test("a conflicting save shows the banner", async () => {
  await browser.eval("window.__putStatus = 409");
  await browser.eval("document.querySelector('.ed-title').focus()");
  await browser.eval(`(() => {
    const t = document.querySelector('.ed-title');
    t.value = "Neuer Titel";
    t.dispatchEvent(new Event("change"));
  })()`);
  await browser.waitFor("!document.querySelector('.ed-banner').hidden", 4000);
  assert.equal(await browser.eval("window.__puts[window.__puts.length - 1].title"), "Neuer Titel");
  await shot("06-conflict");
});
