// Tests for static/js/deck-nav.js. Run: node --test tests/js/

import { test } from "node:test";
import assert from "node:assert/strict";
import * as nav from "../../static/js/deck-nav.js";

const el = (order) => (order ? { id: "e" + order, build: { order } } : { id: "x" });
const doc = {
  slides: [
    { elements: [el(0)] },                 // 0: no builds
    { elements: [el(3), el(1), el(3)] },   // 1: two steps (orders 1, 3)
    { hidden: true, elements: [el(1)] },   // 2: hidden
    { elements: [el(2)] },                 // 3: one step
  ],
};
const P = (slide, step) => ({ slide, step });

test("build orders and steps", () => {
  assert.deepEqual(nav.buildOrders(doc.slides[1]), [1, 3]);
  assert.equal(nav.stepCount(doc.slides[1]), 2);
  assert.equal(nav.visibleOrder(doc.slides[1], 0), 0);
  assert.equal(nav.visibleOrder(doc.slides[1], 1), 1);
  assert.equal(nav.visibleOrder(doc.slides[1], 2), 3);
  assert.equal(nav.visibleOrder(doc.slides[1], 9), 3);
});

test("forward through builds, skipping hidden slides", () => {
  const seen = [];
  for (let p = nav.first(doc); p; p = nav.next(doc, p)) seen.push([p.slide, p.step]);
  assert.deepEqual(seen, [[0, 0], [1, 0], [1, 1], [1, 2], [3, 0], [3, 1]]);
});

test("backward lands on fully built slides", () => {
  assert.deepEqual(nav.prev(doc, P(3, 0)), P(1, 2));
  assert.deepEqual(nav.prev(doc, P(1, 1)), P(1, 0));
  assert.equal(nav.prev(doc, P(0, 0)), null);
  assert.deepEqual(nav.last(doc), P(3, 1));
});

test("a hidden slide you jumped to moves on normally", () => {
  assert.deepEqual(nav.next(doc, P(2, 0)), P(2, 1));
  assert.deepEqual(nav.next(doc, P(2, 1)), P(3, 0));
});

test("clamping untrusted positions", () => {
  assert.deepEqual(nav.clampPos(doc, P(1, 7)), P(1, 2));
  assert.equal(nav.clampPos(doc, P(9, 0)), null);
  assert.equal(nav.clampPos(doc, { slide: "1", step: 0 }), null);
  assert.equal(nav.clampPos(doc, null), null);
  assert.equal(nav.slideLabel(doc, P(3, 0)), "3 / 3");
  assert.equal(nav.slideLabel(doc, P(2, 0)), "3 / 3");
});

test("slide numbers count the shown slides", () => {
  assert.equal(nav.slideByNumber(doc, 1), 0);
  assert.equal(nav.slideByNumber(doc, 2), 1);
  assert.equal(nav.slideByNumber(doc, 3), 3); // the hidden one is skipped
  assert.equal(nav.slideByNumber(doc, 4), null);
  assert.equal(nav.slideByNumber(doc, 0), null);
  assert.equal(nav.slideByNumber(doc, NaN), null);
});
