// Browser tests of presenting: the presentation window (keys, builds,
// hidden slides, black screen, end screen), the presenter console keeping
// the presentation in step (BroadcastChannel), and the remote steering
// both through the event stream (a stand-in relay). Run:
//   node --experimental-websocket --test tests/browser/

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { launchFirefox, Keys } from "./bidi.mjs";
import { serve, editorFiles, designsJson, eventRelay, apis } from "./harness.mjs";
import * as ops from "../../static/js/doc-ops.js";

const designsText = designsJson();
const folien = JSON.parse(designsText).find((d) => d.id === "folien");

function text(t) {
  return { paragraphs: [{ runs: [{ text: t }] }] };
}

// 1: a title and a shape that builds; 2: fades in, notes; 3: hidden; 4.
const s1 = ops.newSlide(folien, "title-only");
s1.elements[0].text = text("Eins");
s1.elements.push({
  id: "box", type: "shape", shape: "rect", x: 200, y: 400, w: 400, h: 300,
  style: { fill: "accent" }, build: { order: 1, effect: "fade" },
});
const s2 = ops.newSlide(folien, "title-only");
s2.elements[0].text = text("Zwei");
s2.transition = { type: "fade", duration: 300 };
s2.notes = text("Notiz zu zwei");
const s3 = ops.newSlide(folien, "title-only");
s3.hidden = true;
const s4 = ops.newSlide(folien, "title-only");
s4.elements[0].text = text("Vier");
const deck = {
  id: "d1", title: "Vortrag", design: "folien", status: "active", revision: 1,
  doc: { format: 1, slides: [s1, s2, s3, s4] },
};

let browser;
let server;
const relay = eventRelay("/api/decks/d1/events");

async function shot(tab, name) {
  if (process.env.FOLIEN_SHOTS) writeFileSync(process.env.FOLIEN_SHOTS + "/" + name + ".png", await tab.screenshot());
}

const hashOf = (tab) => tab.eval("location.hash");

before(async () => {
  server = await serve(editorFiles(deck, designsText), apis(relay.handler));
  browser = await launchFirefox({ port: 9336 });
});

after(async () => {
  relay.close();
  if (browser) {
    if (browser.logs.length) console.log(browser.logs.join("\n"));
    await browser.close();
  }
  if (server) await server.close();
});

test("the presentation: builds, hidden slides, black screen, end", async () => {
  const p = browser;
  await p.open(server.url + "/present.html", 1280, 720);
  await p.waitFor("!!document.querySelector('.player-layer .slide')");
  assert.equal(await p.eval("document.querySelector('.present-counter').textContent"), "1 / 3");
  // the shape waits for its build step
  assert.equal(await p.eval("document.querySelector('[data-id=box]').classList.contains('build-pending')"), true);
  await p.keys(Keys.right);
  await p.waitFor("!document.querySelector('[data-id=box]').classList.contains('build-pending')");
  assert.equal(await hashOf(p), "#1.1");
  await p.keys(Keys.right);
  await p.waitFor("location.hash === '#2'");
  // the transition leaves one slide when it is done
  await p.waitFor("document.querySelectorAll('.player-layer').length === 1", 3000);
  await shot(p, "08-present");
  await p.keys("b");
  assert.equal(await p.eval("document.querySelector('.present-blank').classList.contains('black')"), true);
  // moving on clears the black screen and skips the hidden slide
  await p.keys(Keys.right);
  await p.waitFor("location.hash === '#4'");
  assert.equal(await p.eval("document.querySelector('.present-blank').className"), "present-blank");
  assert.equal(await p.eval("document.querySelector('.present-counter').textContent"), "3 / 3");
  await p.keys(Keys.right);
  assert.equal(await p.eval("document.querySelector('.present-end').classList.contains('shown')"), true);
  await p.keys(Keys.left);
  assert.equal(await p.eval("document.querySelector('.present-end').classList.contains('shown')"), false);
  // back from slide 4 lands on slide 2, fully built (it has no builds)
  await p.keys(Keys.left);
  await p.waitFor("location.hash === '#2'");
  await p.keys(Keys.left);
  await p.waitFor("location.hash === '#1.1'");
  // a number and Enter jump
  await p.keys("4");
  await p.keys(Keys.enter);
  await p.waitFor("location.hash === '#4'");
});

test("the presenter console keeps the presentation in step", async () => {
  // (the first test's window would answer too: all windows of a deck
  // share the position)
  await browser.open("about:blank");
  const presenter = await browser.newTab(server.url + "/presenter.html");
  await presenter.waitFor("!!document.querySelector('.p-current .slide')");
  const audience = await browser.newTab(server.url + "/present.html");
  await audience.waitFor("!!document.querySelector('.player-layer .slide')");
  // the new audience window takes over the console's position
  await audience.waitFor("location.hash === '#1'");
  assert.match(await presenter.eval("document.querySelector('.p-label').textContent"), /Folie 1 \/ 3 · Schritt 0\/1/);
  assert.equal(await presenter.eval("document.querySelector('.p-next-label').textContent"), "Als Nächstes: nächster Schritt");
  await presenter.keys(Keys.right);
  await presenter.keys(Keys.right);
  await audience.waitFor("location.hash === '#2'");
  assert.equal(await presenter.eval("document.querySelector('.p-notes').textContent"), "Notiz zu zwei");
  // and the other way round
  await audience.keys(Keys.right);
  await presenter.waitFor("document.querySelector('.p-label').textContent.startsWith('Folie 3 / 3')");
  await shot(presenter, "09-presenter");
  await presenter.keys("b");
  await audience.waitFor("document.querySelector('.present-blank').classList.contains('black')");
  await presenter.keys("b");
  await audience.waitFor("!document.querySelector('.present-blank').classList.contains('black')");
  browser.presenterTab = presenter;
  browser.audienceTab = audience;
});

test("the remote steers both", async () => {
  const { presenterTab: presenter, audienceTab: audience } = browser;
  const remote = await browser.newTab(server.url + "/remote.html");
  // it learns where the presentation is (it said hello)
  await remote.waitFor("document.querySelector('.r-label').textContent === 'Folie 3 / 3'", 5000);
  await remote.eval("document.querySelector('.r-prev').click()");
  await audience.waitFor("location.hash === '#2'", 5000);
  await presenter.waitFor("document.querySelector('.p-label').textContent.startsWith('Folie 2 / 3')", 5000);
  assert.equal(await remote.eval("document.querySelector('.r-notes').textContent"), "Notiz zu zwei");
  await remote.eval("document.querySelector('.r-small').click()");
  await audience.waitFor("document.querySelector('.present-blank').classList.contains('black')", 5000);
  await shot(remote, "10-remote");
});
