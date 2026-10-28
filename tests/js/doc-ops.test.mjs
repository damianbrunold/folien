// Tests for static/js/doc-ops.js. Run: node --test tests/js/

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import * as ops from "../../static/js/doc-ops.js";

// The designs as the server serves them.
const root = new URL("../..", import.meta.url).pathname;
const designs = JSON.parse(
  execFileSync("scm", [root + "tests/js/designs-json.scm"], { encoding: "utf8" }),
);
const zh = designs.find((d) => d.id === "zh");

test("newSlide has one element per placeholder", () => {
  const s = ops.newSlide(zh, "two-columns");
  assert.equal(s.layout, "two-columns");
  assert.deepEqual(s.elements.map((e) => e.placeholder), ["title", "left", "right"]);
  assert.equal(s.elements[0].type, "text");
  assert.equal(ops.newSlide(zh, "image-caption").elements[1].type, "image");
  assert.match(s.id, /^[a-z0-9]{12}$/);
});

test("copySlide gives fresh ids", () => {
  const s = ops.newSlide(zh, "title");
  const c = ops.copySlide(s);
  assert.notEqual(c.id, s.id);
  assert.notEqual(c.elements[0].id, s.elements[0].id);
  assert.deepEqual(c.elements[0].text, s.elements[0].text);
});

test("changeLayout keeps content by role", () => {
  const s = ops.newSlide(zh, "title-content");
  s.elements[0].text = { paragraphs: [{ runs: [{ text: "Titel" }] }] };
  s.elements[1].text = { paragraphs: [{ runs: [{ text: "Inhalt" }] }] };
  s.elements[0].x = 5; // moved title
  ops.changeLayout(zh, s, "two-columns");
  assert.equal(s.layout, "two-columns");
  const title = s.elements.find((e) => e.placeholder === "title");
  assert.equal(title.text.paragraphs[0].runs[0].text, "Titel");
  assert.equal(title.x, undefined); // inherits the new position
  // The body has no role in two-columns: a free element where it was,
  // with the body text style.
  const body = s.elements.find((e) => e.text && e.text.paragraphs[0].runs[0].text === "Inhalt");
  assert.equal(body.placeholder, undefined);
  assert.equal(body.y, 290);
  assert.equal(body.style.size, 42);
  assert.deepEqual(
    s.elements.filter((e) => e.placeholder).map((e) => e.placeholder),
    ["title", "left", "right"],
  );
});

test("changeLayout drops empty placeholders without a role", () => {
  const s = ops.newSlide(zh, "title-content");
  ops.changeLayout(zh, s, "title-only");
  assert.deepEqual(s.elements.map((e) => e.placeholder), ["title"]);
});

test("geometry", () => {
  const r = { x: 0, y: 0, w: 100, h: 50, rot: 90 };
  const b = ops.bounds(r);
  assert.ok(Math.abs(b.w - 50) < 1e-9 && Math.abs(b.h - 100) < 1e-9);
  assert.ok(ops.hits(r, 50, 70, 0));
  assert.ok(!ops.hits(r, 5, 5, 0));
  assert.deepEqual(ops.snapOffset([10, 60], [0, 63], 5), { d: 3, at: 63 });
  assert.equal(ops.snapOffset([10], [100], 5), null);
  const a = [1, 2, 3];
  ops.moveItem(a, 0, 2);
  assert.deepEqual(a, [2, 3, 1]);
});
