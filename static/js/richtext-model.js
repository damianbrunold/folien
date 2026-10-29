// Operations on rich text, the text model of the deck document (see
// src/app-model.sld):
//
//   {paragraphs: [{align?, list?, level?, runs: [{text, b?, i?, u?,
//                                                color?, size?, link?}]}]}
//
// A position is {p, o}: paragraph index and character offset (UTF-16
// code units, as in DOM selections) into the paragraph's text. The
// functions mutate the text they are given and return new positions; the
// editor clones before an edit when it needs the old state. No DOM here,
// so this module is tested with node (tests/js/).

export const MARK_KEYS = ["b", "i", "u", "code", "color", "size", "link"];
const PARA_KEYS = ["align", "list", "level"];

export function clone(x) {
  return JSON.parse(JSON.stringify(x));
}

export function emptyText() {
  return { paragraphs: [{ runs: [{ text: "" }] }] };
}

// The text, with at least one paragraph and one run per paragraph.
export function ensureText(text) {
  if (!text || !Array.isArray(text.paragraphs)) text = emptyText();
  if (text.paragraphs.length === 0) text.paragraphs.push({ runs: [{ text: "" }] });
  for (const p of text.paragraphs) if (!p.runs || p.runs.length === 0) p.runs = [{ text: "" }];
  return text;
}

export function marksOf(run) {
  const m = {};
  for (const k of MARK_KEYS) if (run[k] !== undefined) m[k] = run[k];
  return m;
}

export function sameMarks(a, b) {
  for (const k of MARK_KEYS) if (a[k] !== b[k]) return false;
  return true;
}

export function paraText(p) {
  return p.runs.map((r) => r.text).join("");
}

export function plainText(text) {
  return text.paragraphs.map(paraText).join("\n");
}

export function comparePos(a, b) {
  return a.p !== b.p ? a.p - b.p : a.o - b.o;
}

export function orderRange(a, b) {
  return comparePos(a, b) <= 0 ? [a, b] : [b, a];
}

export function startPos() {
  return { p: 0, o: 0 };
}

export function endPos(text) {
  const p = text.paragraphs.length - 1;
  return { p, o: paraText(text.paragraphs[p]).length };
}

// Merges neighbouring runs with the same marks and drops empty runs; a
// paragraph without text keeps one empty run carrying the marks typing
// should continue with (fallback, else those of its first run).
export function normalizeParagraph(p, fallback) {
  const keep = fallback || (p.runs[0] ? marksOf(p.runs[0]) : {});
  const out = [];
  for (const r of p.runs) {
    if (r.text === "") continue;
    const last = out[out.length - 1];
    if (last && sameMarks(last, r)) last.text += r.text;
    else out.push(Object.assign({}, r));
  }
  p.runs = out.length ? out : [Object.assign({ text: "" }, keep)];
  return p;
}

// The runs of p left and right of offset o, as copies.
export function splitRuns(p, o) {
  const left = [];
  const right = [];
  let pos = 0;
  for (const r of p.runs) {
    const end = pos + r.text.length;
    if (end <= o) left.push(Object.assign({}, r));
    else if (pos >= o) right.push(Object.assign({}, r));
    else {
      left.push(Object.assign({}, r, { text: r.text.slice(0, o - pos) }));
      right.push(Object.assign({}, r, { text: r.text.slice(o - pos) }));
    }
    pos = end;
  }
  return [left, right];
}

// The marks typing at pos continues with: those of the character before
// it, or at the start of a paragraph those of its first run.
export function marksAt(text, pos) {
  const p = text.paragraphs[pos.p];
  let at = 0;
  for (const r of p.runs) {
    const end = at + r.text.length;
    if (pos.o > at && pos.o <= end) return marksOf(r);
    at = end;
  }
  return p.runs[0] ? marksOf(p.runs[0]) : {};
}

// Deletes the text between two positions; returns the position where it
// was (the earlier one). Paragraphs in between go; the first paragraph's
// properties stay.
export function deleteRange(text, a, b) {
  const [s, e] = orderRange(a, b);
  const paras = text.paragraphs;
  const first = paras[s.p];
  const fallback = marksAt(text, s);
  const left = splitRuns(first, s.o)[0];
  const right = splitRuns(paras[e.p], e.o)[1];
  first.runs = left.concat(right);
  paras.splice(s.p + 1, e.p - s.p);
  normalizeParagraph(first, fallback);
  return { p: s.p, o: s.o };
}

// Inserts str (no line breaks between paragraphs; "\n" stays in the run
// as a line break) at pos with marks; returns the position after it.
export function insertText(text, pos, str, marks) {
  const p = text.paragraphs[pos.p];
  const [left, right] = splitRuns(p, pos.o);
  p.runs = left.concat([Object.assign({ text: str }, marks || marksAt(text, pos))], right);
  normalizeParagraph(p);
  return { p: pos.p, o: pos.o + str.length };
}

// Splits the paragraph at pos; the new one keeps the properties (list,
// level, alignment). Returns the start of the new paragraph.
export function splitParagraph(text, pos) {
  const p = text.paragraphs[pos.p];
  const marks = marksAt(text, pos);
  const [left, right] = splitRuns(p, pos.o);
  const q = {};
  for (const k of PARA_KEYS) if (p[k] !== undefined) q[k] = p[k];
  p.runs = left;
  q.runs = right;
  normalizeParagraph(p, marks);
  normalizeParagraph(q, marks);
  text.paragraphs.splice(pos.p + 1, 0, q);
  return { p: pos.p + 1, o: 0 };
}

// A copy of the text between two positions, as rich text.
export function sliceText(text, a, b) {
  const [s, e] = orderRange(a, b);
  const out = [];
  for (let i = s.p; i <= e.p; i++) {
    const p = text.paragraphs[i];
    let runs = p.runs.map((r) => Object.assign({}, r));
    const q = { runs };
    if (i === e.p) q.runs = runs = splitRuns(q, e.o)[0];
    if (i === s.p) q.runs = splitRuns(q, s.o)[1];
    for (const k of PARA_KEYS) if (p[k] !== undefined) q[k] = p[k];
    normalizeParagraph(q, marksOf(p.runs[0] || {}));
    out.push(q);
  }
  return { paragraphs: out };
}

// Inserts a rich-text fragment at pos; returns the position after it. The
// first fragment paragraph joins the paragraph at pos, the last one joins
// what followed pos; paragraphs in between come with their properties.
export function insertFragment(text, pos, frag) {
  const fps = frag.paragraphs;
  if (fps.length === 0) return pos;
  const p = text.paragraphs[pos.p];
  const [left, right] = splitRuns(p, pos.o);
  const copy = (runs) => runs.map((r) => Object.assign({}, r));
  if (fps.length === 1) {
    const ins = copy(fps[0].runs);
    p.runs = left.concat(ins, right);
    normalizeParagraph(p);
    const n = ins.reduce((a, r) => a + r.text.length, 0);
    return { p: pos.p, o: pos.o + n };
  }
  p.runs = left.concat(copy(fps[0].runs));
  normalizeParagraph(p);
  const middle = fps.slice(1, -1).map((q) => Object.assign(clone(q), {}));
  const lastFrag = fps[fps.length - 1];
  const last = {};
  for (const k of PARA_KEYS) if (p[k] !== undefined) last[k] = p[k];
  last.runs = copy(lastFrag.runs).concat(right);
  const lastLen = paraText({ runs: lastFrag.runs }).length;
  normalizeParagraph(last);
  text.paragraphs.splice(pos.p + 1, 0, ...middle, last);
  return { p: pos.p + fps.length - 1, o: lastLen };
}

// Plain text (lines become paragraphs) as a fragment with marks.
export function fragmentFromPlain(str, marks) {
  const lines = str.replace(/\r\n?/g, "\n").split("\n");
  return {
    paragraphs: lines.map((l) => ({ runs: [Object.assign({ text: l }, marks || {})] })),
  };
}

// Calls f(paragraph, from, to) for the part of each paragraph in a range.
function eachInRange(text, a, b, f) {
  const [s, e] = orderRange(a, b);
  for (let i = s.p; i <= e.p; i++) {
    const p = text.paragraphs[i];
    const from = i === s.p ? s.o : 0;
    const to = i === e.p ? e.o : paraText(p).length;
    f(p, from, to, i);
  }
}

// Sets (or with value undefined removes) a mark on the text in a range.
export function setMark(text, a, b, key, value) {
  eachInRange(text, a, b, (p, from, to) => {
    if (from === to) return;
    const [left, rest] = splitRuns(p, from);
    const [mid, right] = splitRuns({ runs: rest }, to - from);
    for (const r of mid) {
      if (value === undefined || value === false) delete r[key];
      else r[key] = value;
    }
    p.runs = left.concat(mid, right);
    normalizeParagraph(p);
  });
}

// True if every character in the range has a truthy key (a collapsed
// range: the marks typing continues with).
export function rangeHasMark(text, a, b, key) {
  if (comparePos(a, b) === 0) return !!marksAt(text, a)[key];
  let all = true;
  let any = false;
  eachInRange(text, a, b, (p, from, to) => {
    let pos = 0;
    for (const r of p.runs) {
      const end = pos + r.text.length;
      if (end > from && pos < to) {
        any = true;
        if (!r[key]) all = false;
      }
      pos = end;
    }
  });
  return any && all;
}

// The value of a mark if the whole range has the same one, else undefined.
export function rangeMarkValue(text, a, b, key) {
  if (comparePos(a, b) === 0) return marksAt(text, a)[key];
  let value;
  let first = true;
  let same = true;
  eachInRange(text, a, b, (p, from, to) => {
    let pos = 0;
    for (const r of p.runs) {
      const end = pos + r.text.length;
      if (end > from && pos < to) {
        if (first) {
          value = r[key];
          first = false;
        } else if (r[key] !== value) same = false;
      }
      pos = end;
    }
  });
  return same ? value : undefined;
}

// Sets paragraph properties (align, list, level) on the paragraphs a
// range touches; undefined removes one.
export function setParagraphProps(text, a, b, props) {
  const [s, e] = orderRange(a, b);
  for (let i = s.p; i <= e.p; i++) {
    const p = text.paragraphs[i];
    for (const k of Object.keys(props)) {
      if (props[k] === undefined) delete p[k];
      else p[k] = props[k];
    }
  }
}

// Changes the list level of the paragraphs in a range by delta (0..8).
export function shiftLevel(text, a, b, delta) {
  const [s, e] = orderRange(a, b);
  for (let i = s.p; i <= e.p; i++) {
    const p = text.paragraphs[i];
    const level = Math.max(0, Math.min(8, (p.level || 0) + delta));
    if (level === 0) delete p.level;
    else p.level = level;
  }
}

// The position one word before or after pos (dir -1 or 1), crossing into
// the neighbouring paragraph at a paragraph boundary.
export function wordBoundary(text, pos, dir) {
  const s = paraText(text.paragraphs[pos.p]);
  if (dir < 0) {
    if (pos.o === 0) return pos.p > 0 ? endPos({ paragraphs: text.paragraphs.slice(0, pos.p) }) : pos;
    let o = pos.o;
    while (o > 0 && /\s/.test(s[o - 1])) o--;
    while (o > 0 && !/\s/.test(s[o - 1])) o--;
    return { p: pos.p, o };
  }
  if (pos.o === s.length) return pos.p < text.paragraphs.length - 1 ? { p: pos.p + 1, o: 0 } : pos;
  let o = pos.o;
  while (o < s.length && /\s/.test(s[o])) o++;
  while (o < s.length && !/\s/.test(s[o])) o++;
  return { p: pos.p, o };
}

// The position one character before or after pos, across paragraphs;
// surrogate pairs count as one character.
export function charStep(text, pos, dir) {
  const s = paraText(text.paragraphs[pos.p]);
  if (dir < 0) {
    if (pos.o === 0) {
      return pos.p > 0 ? { p: pos.p - 1, o: paraText(text.paragraphs[pos.p - 1]).length } : pos;
    }
    const two = pos.o >= 2 && /[\uDC00-\uDFFF]/.test(s[pos.o - 1]) && /[\uD800-\uDBFF]/.test(s[pos.o - 2]);
    return { p: pos.p, o: pos.o - (two ? 2 : 1) };
  }
  if (pos.o === s.length) {
    return pos.p < text.paragraphs.length - 1 ? { p: pos.p + 1, o: 0 } : pos;
  }
  const two = /[\uD800-\uDBFF]/.test(s[pos.o]) && /[\uDC00-\uDFFF]/.test(s[pos.o + 1] || "");
  return { p: pos.p, o: pos.o + (two ? 2 : 1) };
}

// Replaces paragraph i's text by newText, keeping marks where the text is
// unchanged: the changed middle (after the common prefix and suffix) gets
// the marks at its start. Used to take over what the browser typed itself
// (IME composition, spelling corrections). Returns the end of the change.
export function reconcileParagraph(text, i, newText) {
  const old = paraText(text.paragraphs[i]);
  if (old === newText) return null;
  let pre = 0;
  while (pre < old.length && pre < newText.length && old[pre] === newText[pre]) pre++;
  let suf = 0;
  while (
    suf < old.length - pre &&
    suf < newText.length - pre &&
    old[old.length - 1 - suf] === newText[newText.length - 1 - suf]
  ) suf++;
  const marks = marksAt(text, { p: i, o: pre });
  deleteRange(text, { p: i, o: pre }, { p: i, o: old.length - suf });
  const ins = newText.slice(pre, newText.length - suf);
  if (ins) insertText(text, { p: i, o: pre }, ins, marks);
  return { p: i, o: pre + ins.length };
}

// Applies a mark-changing function to the whole text.
export function wholeRange(text) {
  return [startPos(), endPos(text)];
}

// True if a URL is allowed as a link (as validate-doc checks it).
export function safeLink(url) {
  const l = String(url).trim().toLowerCase();
  return (
    l.length <= 2000 &&
    (l.startsWith("https://") ||
      l.startsWith("http://") ||
      l.startsWith("mailto:") ||
      l.startsWith("#slide-"))
  );
}
