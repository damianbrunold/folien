// The editor by keyboard alone, in headless Firefox (WebDriver BiDi), with
// the API stubbed: focus after editing, from text field to text field,
// lists, alignment and sizes, new and moved slides, the regions (F6), the
// toolbar's arrows, resizing, presenting (F5) and the help (F1).
// Run: node --experimental-websocket --test tests/browser/

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { launchFirefox, Keys } from "./bidi.mjs";
import { serve, editorFiles, designsJson } from "./harness.mjs";
import * as ops from "../../static/js/doc-ops.js";

const designsText = designsJson();
const folien = JSON.parse(designsText).find((d) => d.id === "folien");

function fixtureDeck() {
  const s1 = ops.newSlide(folien, "title");
  s1.elements[0].text = { paragraphs: [{ runs: [{ text: "Hallo" }] }] };
  const s2 = ops.newSlide(folien, "title-content");
  s2.elements[0].text = { paragraphs: [{ runs: [{ text: "Zweite" }] }] };
  s2.elements[1].text = { paragraphs: [{ runs: [{ text: "eins" }] }, { runs: [{ text: "zwei" }] }] };
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

async function saved() {
  await browser.keys("s", [Keys.ctrl]);
  await browser.waitFor("document.querySelector('.ed-status').textContent === 'Gespeichert'");
  return browser.eval("window.__puts[window.__puts.length - 1].doc");
}

const active = () =>
  browser.eval(`(() => {
    const a = document.activeElement;
    return a.className + "|" + (a.getAttribute("aria-label") || a.title || "");
  })()`);

const editingText = () =>
  browser.eval("(document.querySelector('.text-inner.editing') || {}).textContent || null");

before(async () => {
  server = await serve(editorFiles(deck, designsText));
  browser = await launchFirefox({ port: 9338 });
  await browser.open(server.url + "/edit.html");
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 2");
  // window.open is recorded, not followed
  await browser.eval(`(() => {
    window.__opened = [];
    window.open = () => {
      const w = { location: { href: "" } };
      window.__opened.push(w);
      return w;
    };
  })()`);
});

after(async () => {
  if (browser) {
    if (browser.logs.length) console.log(browser.logs.join("\n"));
    await browser.close();
  }
  if (server) await server.close();
});

test("Tab selects, Enter edits, Esc returns to the slide with the element selected", async () => {
  await browser.eval("document.querySelector('.ed-stage').focus()");
  await browser.keys(Keys.tab);
  await browser.keys(Keys.enter);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  assert.equal(await editingText(), "Hallo");
  await browser.keys(Keys.escape);
  await browser.waitFor("!document.querySelector('.text-inner.editing')");
  assert.match(await active(), /ed-stage/);
  assert.equal(await browser.eval("document.querySelectorAll('.sel-box').length"), 1);
  // the arrows now move it
  const doc = await (async () => {
    await browser.keys(Keys.right, [Keys.shift]);
    return saved();
  })();
  assert.equal(doc.slides[0].elements[0].x, ops.bounds(folien.layouts[0].placeholders[0]).x + 10);
});

test("Ctrl+Enter goes from text field to text field, after the last to a new slide", async () => {
  await browser.keys(Keys.escape); // no selection: the arrows change slides
  await browser.keys(Keys.down); // slide 2
  await browser.waitFor("document.querySelectorAll('.ed-thumb.current')[0].dataset.index === '1'");
  await browser.keys(Keys.tab);
  await browser.keys(Keys.enter);
  await browser.waitFor("!!document.querySelector('.text-inner.editing')");
  assert.equal(await editingText(), "Zweite");
  await browser.keys(Keys.enter, [Keys.ctrl]);
  await browser.waitFor("(document.querySelector('.text-inner.editing') || {}).textContent === 'einszwei'");
  await browser.keys(Keys.enter, [Keys.ctrl, Keys.shift]);
  await browser.waitFor("(document.querySelector('.text-inner.editing') || {}).textContent === 'Zweite'");
  await browser.keys(Keys.enter, [Keys.ctrl]);
  await browser.keys(Keys.enter, [Keys.ctrl]); // past the last: a new slide
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 3");
  assert.equal(await browser.eval("document.querySelector('.ed-thumb.current').dataset.index"), "2");
  await browser.keys("Neu");
  await browser.keys(Keys.escape);
  const doc = await saved();
  assert.equal(doc.slides[2].layout, "title-content");
  assert.equal(doc.slides[2].elements[0].text.paragraphs[0].runs[0].text, "Neu");
});

test("lists, alignment and size by keyboard", async () => {
  await browser.keys(Keys.escape); // the new title stays selected after editing: deselect
  await browser.keys(Keys.up); // back to slide 2
  await browser.waitFor("document.querySelector('.ed-thumb.current').dataset.index === '1'");
  await browser.keys(Keys.tab);
  await browser.keys(Keys.tab); // the body
  await browser.keys(Keys.enter);
  await browser.waitFor("(document.querySelector('.text-inner.editing') || {}).textContent === 'einszwei'");
  await browser.keys("a", [Keys.ctrl]);
  await browser.keys("8", [Keys.ctrl, Keys.shift]);
  let doc = await saved();
  assert.deepEqual(doc.slides[1].elements[1].text.paragraphs.map((p) => p.list), ["bullet", "bullet"]);
  await browser.keys("7", [Keys.ctrl, Keys.shift]);
  await browser.keys("e", [Keys.ctrl, Keys.shift]);
  await browser.keys(".", [Keys.ctrl, Keys.shift]);
  doc = await saved();
  const paras = doc.slides[1].elements[1].text.paragraphs;
  assert.deepEqual(paras.map((p) => [p.list, p.align]), [["number", "center"], ["number", "center"]]);
  // the body is 44; the next size of the list is 48
  assert.deepEqual(paras.map((p) => p.runs[0].size), [48, 48]);
  await browser.keys(Keys.escape);
  // on a selected element (not editing) too
  await browser.keys("8", [Keys.ctrl, Keys.shift]);
  doc = await saved();
  assert.deepEqual(doc.slides[1].elements[1].text.paragraphs.map((p) => p.list), ["bullet", "bullet"]);
});

test("Alt+arrows resize, Ctrl+Shift+arrows reorder", async () => {
  const before = (await saved()).slides[1].elements;
  await browser.keys(Keys.right, [Keys.alt]);
  await browser.keys(Keys.down, [Keys.alt, Keys.shift]);
  await browser.keys(Keys.up, [Keys.ctrl, Keys.shift]); // the body was already on top
  await browser.keys(Keys.down, [Keys.ctrl, Keys.shift]); // to the back
  const after = (await saved()).slides[1].elements;
  const body = after[0];
  assert.equal(body.id, before[1].id);
  assert.equal(body.w, 1680 + 1);
  assert.equal(body.h, 680 + 10);
});

test("Ctrl+M adds a slide; Ctrl+arrows move it in the slide list", async () => {
  await browser.keys(Keys.escape);
  await browser.keys("m", [Keys.ctrl]);
  await browser.waitFor("document.querySelectorAll('.ed-thumb').length === 4");
  await browser.keys(Keys.escape);
  const newId = (await saved()).slides[2].id;
  await browser.eval("document.querySelector('.ed-slide-list').focus()");
  await browser.keys(Keys.up, [Keys.ctrl]);
  await browser.keys(Keys.up, [Keys.ctrl]);
  const doc = await saved();
  assert.equal(doc.slides[0].id, newId);
  assert.match(await active(), /ed-slide-list/);
});

test("F6 walks the regions; the toolbar is one Tab stop with arrows inside", async () => {
  await browser.eval("document.querySelector('.ed-stage').focus()");
  await browser.keys(Keys.f6); // notes
  assert.match(await active(), /ed-notes-body/);
  await browser.keys(Keys.f6); // properties
  assert.equal(await browser.eval("document.querySelector('.ed-panel').contains(document.activeElement)"), true);
  await browser.keys(Keys.f6); // title
  assert.match(await active(), /ed-title/);
  await browser.keys(Keys.f6); // toolbar
  assert.equal(await browser.eval("document.querySelector('.ed-toolbar').contains(document.activeElement)"), true);
  assert.equal(await browser.eval("document.querySelectorAll('.ed-toolbar [tabindex=\"0\"]').length"), 1);
  const first = await active();
  await browser.keys(Keys.right);
  const second = await active();
  assert.notEqual(first, second);
  await browser.keys(Keys.home);
  const home = await active();
  assert.match(home, /Rückgängig/);
  await browser.keys(Keys.end);
  assert.notEqual(await active(), home);
  await browser.keys(Keys.home);
  await browser.keys(Keys.f6, [Keys.shift]); // back to the title
  assert.match(await active(), /ed-title/);
  await browser.keys(Keys.f6);
  // the toolbar remembers where it was
  assert.equal(await active(), home);
});

test("F5 and Shift+F5 present; F1 shows the keys", async () => {
  await browser.eval("document.querySelector('.ed-stage').focus()");
  await browser.keys(Keys.f5);
  await browser.keys(Keys.f5, [Keys.shift]);
  await browser.keys(Keys.f5, [Keys.alt]);
  await browser.waitFor("window.__opened.length === 3 && window.__opened[2].location.href !== ''");
  const hrefs = await browser.eval("window.__opened.map((w) => w.location.href)");
  const cur = Number(await browser.eval("document.querySelector('.ed-thumb.current').dataset.index")) + 1;
  assert.deepEqual(hrefs, ["/present.html#1", "/present.html#" + cur, "/presenter.html#" + cur]);

  await browser.keys(Keys.f1);
  await browser.waitFor("!!document.querySelector('dialog.shortcut-help[open]')");
  assert.match(await browser.eval("document.querySelector('dialog.shortcut-help').textContent"), /Strg\+Enter/);
  // keys do not reach the editor behind it
  const n = await browser.eval("document.querySelectorAll('.ed-thumb').length");
  await browser.keys("m", [Keys.ctrl]);
  assert.equal(await browser.eval("document.querySelectorAll('.ed-thumb').length"), n);
  await browser.keys(Keys.escape);
  await browser.waitFor("!document.querySelector('dialog.shortcut-help')");
  assert.match(await active(), /ed-stage/);
});
