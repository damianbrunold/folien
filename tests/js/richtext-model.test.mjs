// Tests for static/js/richtext-model.js. Run: node --test tests/js/

import { test } from "node:test";
import assert from "node:assert/strict";
import * as rt from "../../static/js/richtext-model.js";

const T = (...paras) => ({
  paragraphs: paras.map((p) => (Array.isArray(p) ? { runs: p } : p)),
});
const R = (text, marks = {}) => Object.assign({ text }, marks);
const P = (p, o) => ({ p, o });

test("insertText continues the marks before the caret", () => {
  const t = T([R("ab"), R("cd", { b: true })]);
  assert.deepEqual(rt.insertText(t, P(0, 4), "e"), P(0, 5));
  assert.deepEqual(t, T([R("ab"), R("cde", { b: true })]));
  rt.insertText(t, P(0, 1), "X");
  assert.deepEqual(t, T([R("aXb"), R("cde", { b: true })]));
  rt.insertText(t, P(0, 0), "Y", { i: true });
  assert.deepEqual(t, T([R("Y", { i: true }), R("aXb"), R("cde", { b: true })]));
});

test("deleteRange within and across paragraphs", () => {
  const t = T([R("hello")], { list: "bullet", runs: [R("big", { b: true }), R("world")] });
  assert.deepEqual(rt.deleteRange(t, P(0, 1), P(0, 3)), P(0, 1));
  assert.deepEqual(t.paragraphs[0].runs, [R("hlo")]);
  rt.deleteRange(t, P(1, 2), P(0, 2)); // reversed range
  assert.deepEqual(t, T([R("hl"), R("g", { b: true }), R("world")]));
});

test("deleting everything keeps an empty run with the marks", () => {
  const t = T([R("x", { b: true, size: 40 })]);
  rt.deleteRange(t, P(0, 0), P(0, 1));
  assert.deepEqual(t, T([R("", { b: true, size: 40 })]));
  rt.insertText(t, P(0, 0), "y");
  assert.deepEqual(t, T([R("y", { b: true, size: 40 })]));
});

test("splitParagraph keeps paragraph properties and marks", () => {
  const t = T({ list: "number", level: 1, runs: [R("ab", { i: true })] });
  assert.deepEqual(rt.splitParagraph(t, P(0, 2)), P(1, 0));
  assert.deepEqual(t, T(
    { list: "number", level: 1, runs: [R("ab", { i: true })] },
    { list: "number", level: 1, runs: [R("", { i: true })] },
  ));
  rt.insertText(t, P(1, 0), "c");
  assert.deepEqual(t.paragraphs[1].runs, [R("c", { i: true })]);
});

test("setMark, rangeHasMark and rangeMarkValue", () => {
  const t = T([R("abcdef")], [R("ghi")]);
  rt.setMark(t, P(0, 2), P(1, 1), "b", true);
  assert.deepEqual(t, T([R("ab"), R("cdef", { b: true })], [R("g", { b: true }), R("hi")]));
  assert.equal(rt.rangeHasMark(t, P(0, 2), P(1, 1), "b"), true);
  assert.equal(rt.rangeHasMark(t, P(0, 1), P(1, 1), "b"), false);
  rt.setMark(t, P(0, 0), P(1, 3), "b", undefined);
  assert.deepEqual(t, T([R("abcdef")], [R("ghi")]));
  rt.setMark(t, P(0, 0), P(0, 3), "size", 40);
  assert.equal(rt.rangeMarkValue(t, P(0, 0), P(0, 3), "size"), 40);
  assert.equal(rt.rangeMarkValue(t, P(0, 0), P(0, 4), "size"), undefined);
});

test("sliceText and insertFragment round trip", () => {
  const t = T([R("one "), R("two", { b: true })], { list: "bullet", runs: [R("three")] }, [R("four")]);
  const frag = rt.sliceText(t, P(0, 4), P(2, 2));
  assert.deepEqual(frag, T([R("two", { b: true })], { list: "bullet", runs: [R("three")] }, [R("fo")]));
  const u = T([R("[]")]);
  assert.deepEqual(rt.insertFragment(u, P(0, 1), frag), P(2, 2));
  assert.deepEqual(u, T(
    [R("["), R("two", { b: true })],
    { list: "bullet", runs: [R("three")] },
    [R("fo]")],
  ));
});

test("plain text becomes paragraphs", () => {
  const t = T([R("ab")]);
  const end = rt.insertFragment(t, P(0, 1), rt.fragmentFromPlain("x\r\ny\nz"));
  assert.deepEqual(end, P(2, 1));
  assert.equal(rt.plainText(t), "ax\ny\nzb");
});

test("list levels", () => {
  const t = T([R("a")], [R("b")]);
  rt.shiftLevel(t, P(0, 0), P(1, 0), 1);
  assert.deepEqual(t.paragraphs.map((p) => p.level), [1, 1]);
  rt.shiftLevel(t, P(1, 0), P(1, 0), -1);
  assert.equal("level" in t.paragraphs[1], false);
  rt.setParagraphProps(t, P(0, 0), P(1, 0), { list: "bullet" });
  assert.deepEqual(t.paragraphs.map((p) => p.list), ["bullet", "bullet"]);
});

test("word and character steps", () => {
  const t = T([R("Hallo  Welt")], [R("😀x")]);
  assert.deepEqual(rt.wordBoundary(t, P(0, 11), -1), P(0, 7));
  assert.deepEqual(rt.wordBoundary(t, P(0, 7), -1), P(0, 0));
  assert.deepEqual(rt.wordBoundary(t, P(0, 0), 1), P(0, 5));
  assert.deepEqual(rt.wordBoundary(t, P(1, 0), -1), P(0, 11));
  assert.deepEqual(rt.charStep(t, P(1, 2), -1), P(1, 0)); // surrogate pair
  assert.deepEqual(rt.charStep(t, P(1, 0), 1), P(1, 2));
  assert.deepEqual(rt.charStep(t, P(1, 0), -1), P(0, 11));
});

test("reconcileParagraph keeps the marks of unchanged text", () => {
  const t = T([R("ab", { b: true }), R("cd")]);
  rt.reconcileParagraph(t, 0, "abXcd");
  assert.deepEqual(t, T([R("abX", { b: true }), R("cd")]));
  rt.reconcileParagraph(t, 0, "abcd");
  assert.deepEqual(t, T([R("ab", { b: true }), R("cd")]));
});

test("safeLink", () => {
  assert.equal(rt.safeLink("https://zh.ch"), true);
  assert.equal(rt.safeLink(" JavaScript:alert(1)"), false);
  assert.equal(rt.safeLink("#slide-abc"), true);
});
