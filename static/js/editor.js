// The deck editor: slide list, canvas, properties, notes; undo and redo;
// autosave. Loaded by the editor page (src/app-views.sld, editor-page),
// which provides <div id="editor" data-deck-url data-designs-url
// data-view-url data-home-url>.
//
// State is the deck document (doc) plus the deck's design and title. Every
// change goes through change(), which records an undo step and schedules
// a save; drags record one step when they end, typing one per pause. The
// canvas is the slide renderer's output with an overlay for the selection;
// text is edited in place with RichTextEditor.

import {
  SLIDE_W,
  SLIDE_H,
  designMap,
  findLayout,
  resolveElement,
  renderSlide,
  fitInto,
  cssColor,
  cellStyle,
  todayText,
} from "./render.js";
import * as rt from "./richtext-model.js";
import { RichTextEditor } from "./richtext-editor.js";
import * as ops from "./doc-ops.js";
import * as up from "./upload.js";

const root = document.getElementById("editor");
const urls = root.dataset;

// --- state ----------------------------------------------------------

let deck; // {id, title, design, status, revision}
let doc; // the document
let designs; // Map id -> design
let design; // the deck's design
let cur = 0; // current slide index
let sel = []; // selected element ids (current slide)
let editing = null; // {id, ed, box, cell?} while a text box or table cell is edited
let notesEditor = null;
let scale = 1;
const undoStack = [];
const redoStack = [];
let lastTyping = 0;
// True while the notes are what is being edited (they keep that status
// while a toolbar control has the focus).
let notesActive = false;
document.addEventListener("focusin", (e) => {
  if (ui.notesBody && ui.notesBody.contains(e.target)) notesActive = true;
  else if (!(ui.toolbar && ui.toolbar.contains(e.target))) notesActive = false;
  if (ui.toolbar) updateToolbar();
});

const slide = () => doc.slides[cur];
const layout = () => findLayout(design, slide().layout);
const findEl = (id) => slide().elements.find((e) => e.id === id);
const resolved = (el) => resolveElement(layout(), el);
const selectedEls = () => sel.map(findEl).filter(Boolean);
const assetUrl = (sha) => urls.deckUrl + "/assets/" + sha;
// Thumbnails get downscaled copies of images (videos ignore ?w).
const thumbUrl = (sha, w = 640) => assetUrl(sha) + "?w=" + w;

// --- DOM helpers ----------------------------------------------------

function h(tag, props, ...children) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(props || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else if (k === "on") for (const [ev, f] of Object.entries(v)) e.addEventListener(ev, f);
    else if (k.startsWith("data-") || k.startsWith("aria-") || k === "role") e.setAttribute(k, v);
    else e[k] = v;
  }
  for (const c of children.flat()) {
    if (c === null || c === undefined || c === false) continue;
    e.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return e;
}

// A toolbar button that keeps the focus (and text selection) where it is.
function tb(label, title, action, cls) {
  return h("button", {
    type: "button",
    class: "tb" + (cls ? " " + cls : ""),
    title,
    "aria-label": title,
    text: label,
    on: { mousedown: (e) => e.preventDefault(), click: action },
  });
}

const COLOR_NAMES = [
  ["text", "Text"],
  ["muted", "Grau"],
  ["accent", "Akzent"],
  ["accent2", "Akzent 2"],
  ["accent3", "Akzent 3"],
  ["light", "Hell"],
  ["background", "Hintergrund"],
  ["on-accent", "Auf Akzent"],
];

// A colour chooser: the design's tokens, optionally "none" and a default
// entry, and a custom colour. onChange(value) with a token, "#rrggbb",
// "none" or undefined (default).
function colorField(value, onChange, opts = {}) {
  const select = h("select", { "aria-label": opts.label || "Farbe" });
  if (opts.defaultLabel) select.append(h("option", { value: "", text: opts.defaultLabel }));
  if (opts.none) select.append(h("option", { value: "none", text: "Keine" }));
  for (const [token, name] of COLOR_NAMES) select.append(h("option", { value: token, text: name }));
  select.append(h("option", { value: "custom", text: "Eigene …" }));
  const picker = h("input", { type: "color", "aria-label": "Eigene Farbe" });
  const swatch = h("span", { class: "swatch" });
  const show = (v) => {
    const custom = typeof v === "string" && v.startsWith("#");
    select.value = v === undefined ? (opts.defaultLabel ? "" : "text") : custom ? "custom" : v;
    picker.hidden = !custom;
    if (custom) picker.value = v;
    swatch.style.backgroundColor = v === undefined ? "transparent" : cssColor(design, v);
    swatch.classList.toggle("none", v === "none" || v === undefined);
  };
  show(value);
  select.addEventListener("change", () => {
    if (select.value === "custom") {
      picker.hidden = false;
      onChange(picker.value);
    } else onChange(select.value === "" ? undefined : select.value);
  });
  picker.addEventListener("change", () => onChange(picker.value));
  return h("span", { class: "color-field" }, swatch, select, picker);
}

function numberField(label, value, onChange, opts = {}) {
  const input = h("input", {
    type: "number",
    value: value === undefined ? "" : String(Math.round(value * 100) / 100),
    step: opts.step || 1,
    min: opts.min,
    max: opts.max,
    "aria-label": label,
  });
  input.addEventListener("change", () => {
    const n = parseFloat(input.value);
    if (Number.isFinite(n)) onChange(n);
  });
  return h("label", { class: "field" }, h("span", { text: label }), input);
}

function selectField(label, value, options, onChange) {
  const select = h("select", { "aria-label": label });
  for (const [v, name] of options) select.append(h("option", { value: v, text: name }));
  select.value = value;
  select.addEventListener("change", () => onChange(select.value));
  return h("label", { class: "field" }, h("span", { text: label }), select);
}

// A text input that reports its value when it changes (on blur/Enter).
function textField(label, value, onChange, opts = {}) {
  const input = h("input", {
    type: "text",
    value: value || "",
    maxLength: opts.maxLength,
    placeholder: opts.placeholder,
    "aria-label": opts.ariaLabel || label,
  });
  input.addEventListener("change", () => onChange(input.value));
  return h("label", { class: "field" }, h("span", { text: label }), input);
}

function checkField(label, checked, onChange) {
  return h(
    "label",
    { class: "check" },
    h("input", { type: "checkbox", checked, on: { change: (e) => onChange(e.target.checked) } }),
    " " + label,
  );
}

// --- undo, changes, saving ------------------------------------------

function snapshot() {
  return { doc: JSON.stringify(doc), design: deck.design, cur, sel: sel.slice() };
}

function restore(s) {
  doc = JSON.parse(s.doc);
  deck.design = s.design;
  design = designs.get(deck.design);
  cur = Math.min(s.cur, doc.slides.length - 1);
  sel = s.sel.filter((id) => findEl(id));
}

function pushUndo(s) {
  undoStack.push(s);
  if (undoStack.length > 200) undoStack.shift();
  redoStack.length = 0;
}

// Runs f (which mutates the state) as one undoable step and redraws.
function change(f, opts = {}) {
  if (editing && !opts.keepEditing) stopEditing();
  const before = snapshot();
  f();
  pushUndo(before);
  lastTyping = 0;
  afterChange(opts);
}

function afterChange(opts = {}) {
  markDirty();
  if (opts.structure) renderSlideList();
  else scheduleThumb(cur);
  if (!opts.light) {
    renderCanvas();
    renderPanel();
  }
  updateToolbar();
}

// Text edits: typing makes one undo step per pause of 1.5 s; anything
// else (formatting, paste, cut) a step of its own.
function typingStep(typing) {
  const now = Date.now();
  if (!typing || now - lastTyping > 1500) pushUndo(snapshot());
  lastTyping = typing ? now : 0;
}

function undo() {
  if (editing) stopEditing();
  if (!undoStack.length) return;
  redoStack.push(snapshot());
  restore(undoStack.pop());
  lastTyping = 0;
  markDirty();
  renderAll();
}

function redo() {
  if (editing) stopEditing();
  if (!redoStack.length) return;
  undoStack.push(snapshot());
  restore(redoStack.pop());
  lastTyping = 0;
  markDirty();
  renderAll();
}

const saver = { timer: null, inflight: false, dirty: false, conflict: false };

function markDirty() {
  saver.dirty = true;
  setStatus("unsaved");
  clearTimeout(saver.timer);
  saver.timer = setTimeout(save, 1000);
}

async function save() {
  clearTimeout(saver.timer);
  if (saver.inflight || !saver.dirty || saver.conflict) return;
  saver.inflight = true;
  saver.dirty = false;
  setStatus("saving");
  const body = JSON.stringify({
    revision: deck.revision,
    design: deck.design,
    title: deck.title,
    doc,
  });
  let retry = false;
  try {
    const r = await fetch(urls.deckUrl, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body,
    });
    const j = await r.json().catch(() => ({}));
    if (r.ok) {
      deck.revision = j.revision;
      setStatus(saver.dirty ? "unsaved" : "saved");
    } else {
      saver.dirty = true;
      if (r.status === 409) {
        saver.conflict = true;
        showConflict();
      } else if (r.status === 400) setStatus("error", "Ungültige Daten: " + (j.error || ""));
      else if (r.status === 401) setStatus("error", "Sie sind nicht mehr angemeldet.");
      else if (r.status === 403) setStatus("error", "Die Präsentation ist schreibgeschützt.");
      else {
        setStatus("error", "Fehler beim Speichern (" + r.status + ").");
        retry = true;
      }
    }
  } catch (err) {
    saver.dirty = true;
    setStatus("error", "Keine Verbindung – wird erneut versucht.");
    retry = true;
  } finally {
    saver.inflight = false;
  }
  if (retry) saver.timer = setTimeout(save, 5000);
  else if (saver.dirty && !saver.conflict && statusState === "unsaved") {
    saver.timer = setTimeout(save, 1000);
  }
}

let statusState = "saved";
function setStatus(state, message) {
  statusState = state;
  const texts = {
    saved: "Gespeichert",
    unsaved: "Nicht gespeichert",
    saving: "Speichert …",
    error: message || "Fehler",
  };
  ui.status.textContent = texts[state];
  ui.status.className = "ed-status " + state;
}

function showConflict() {
  setStatus("error", "Konflikt");
  ui.banner.replaceChildren(
    h("span", {
      text:
        "Diese Präsentation wurde inzwischen anderswo gespeichert (anderes Fenster oder Gerät).",
    }),
    h("button", {
      type: "button",
      class: "small",
      text: "Andere Version laden",
      on: { click: () => location.reload() },
    }),
    h("button", {
      type: "button",
      class: "small",
      text: "Meine Version behalten",
      on: {
        click: async () => {
          const r = await fetch(urls.deckUrl);
          if (!r.ok) return;
          deck.revision = (await r.json()).revision;
          saver.conflict = false;
          ui.banner.hidden = true;
          saver.dirty = true;
          save();
        },
      },
    }),
  );
  ui.banner.hidden = false;
}

window.addEventListener("beforeunload", (e) => {
  if (saver.dirty || saver.inflight) {
    save();
    e.preventDefault();
    e.returnValue = "";
  }
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") save();
});

// Opens a presenting window at the current slide, with what is unsaved
// saved first.
async function openPresenting(base) {
  if (editing) stopEditing();
  const w = window.open("about:blank", "_blank");
  await save();
  if (w) w.location.href = base + "#" + (cur + 1);
}

// --- the skeleton ---------------------------------------------------

const ui = {};

function buildSkeleton() {
  ui.title = h("input", {
    class: "ed-title",
    value: deck.title,
    maxLength: 200,
    "aria-label": "Titel der Präsentation",
  });
  ui.title.addEventListener("change", () => {
    const t = ui.title.value.trim();
    if (t.length >= 1 && t.length <= 200) {
      deck.title = t;
      document.title = t + " · Folien";
      markDirty();
    } else ui.title.value = deck.title;
  });
  ui.status = h("span", { class: "ed-status saved", text: "Gespeichert", role: "status" });
  ui.uploadStatus = h("span", { class: "ed-upload", role: "status" });
  ui.banner = h("div", { class: "ed-banner", hidden: true, role: "alert" });

  const top = h(
    "header",
    { class: "ed-top" },
    h("a", { class: "ed-home", href: urls.homeUrl, title: "Zu den Präsentationen", text: "Folien" }),
    ui.title,
    ui.status,
    ui.uploadStatus,
    h("span", { class: "spacer" }),
    h("a", { class: "button small", href: urls.viewUrl, text: "Ansehen" }),
    h("a", { class: "button small", href: urls.viewUrl + "#export", text: "PDF" }),
    h("button", {
      type: "button",
      class: "small",
      text: "Referentenansicht",
      title: "Präsentieren mit Notizen und Vorschau",
      on: { click: () => openPresenting(urls.presenterUrl) },
    }),
    h("button", {
      type: "button",
      class: "small primary-btn",
      text: "Präsentieren",
      title: "Ab der aktuellen Folie präsentieren",
      on: { click: () => openPresenting(urls.presentUrl) },
    }),
  );

  ui.toolbar = h("div", { class: "ed-toolbar", role: "toolbar", "aria-label": "Werkzeuge" });
  ui.slides = h("div", { class: "ed-slide-list", tabIndex: 0, "aria-label": "Folien" });
  ui.slideActions = h("div", { class: "ed-slide-actions" });
  // The stage takes the focus: Tab then walks through the slide's
  // elements, arrows move them, Enter edits; ui.live tells screen readers
  // what is selected.
  ui.stage = h("div", {
    class: "ed-stage",
    tabIndex: 0,
    role: "group",
    "aria-label": "Folie: Tab wählt ein Element, Pfeiltasten verschieben, Enter bearbeitet, Entf löscht",
  });
  ui.live = h("div", { class: "visually-hidden", role: "status", "aria-live": "polite" });
  ui.frame = h("div", { class: "ed-frame" });
  ui.overlay = h("div", { class: "ed-overlay" });
  ui.stage.append(ui.frame, ui.overlay, ui.live);
  ui.notesBody = h("div", { class: "ed-notes-body", "aria-label": "Notizen" });
  ui.panel = h("aside", { class: "ed-panel", "aria-label": "Eigenschaften" });

  root.replaceChildren(
    top,
    ui.banner,
    ui.toolbar,
    h(
      "div",
      { class: "ed-main" },
      h("aside", { class: "ed-slides" }, ui.slideActions, ui.slides),
      h(
        "div",
        { class: "ed-center" },
        ui.stage,
        h("div", { class: "ed-notes" }, h("div", { class: "ed-notes-label", text: "Notizen" }), ui.notesBody),
      ),
      ui.panel,
    ),
  );

  buildToolbar();
  new ResizeObserver(layoutStage).observe(ui.stage);
  wireStage();
  wireSlideList();
}

// --- toolbar --------------------------------------------------------

const SIZES = [16, 20, 24, 28, 32, 36, 40, 44, 48, 56, 64, 72, 80, 96, 112, 128, 160];

function buildToolbar() {
  const t = ui.toolbar;
  const group = (...xs) => h("div", { class: "tb-group" }, ...xs);

  ui.undoBtn = tb("↶", "Rückgängig (Strg+Z)", undo);
  ui.redoBtn = tb("↷", "Wiederholen (Strg+Y)", redo);

  ui.newSlide = h("select", { class: "tb-select", "aria-label": "Neue Folie" });
  ui.newSlide.addEventListener("change", () => {
    if (ui.newSlide.value) addSlide(ui.newSlide.value);
    ui.newSlide.value = "";
  });

  ui.shapeSelect = h(
    "select",
    { class: "tb-select", "aria-label": "Form einfügen" },
    h("option", { value: "", text: "Form …" }),
    ...[
      ["rect", "Rechteck"],
      ["rounded", "Abgerundet"],
      ["ellipse", "Ellipse"],
      ["triangle", "Dreieck"],
      ["arrow", "Pfeil"],
      ["chevron", "Chevron"],
    ].map(([v, n]) => h("option", { value: v, text: n })),
  );
  ui.shapeSelect.addEventListener("change", () => {
    if (ui.shapeSelect.value) insertShape(ui.shapeSelect.value);
    ui.shapeSelect.value = "";
  });

  ui.bold = tb("F", "Fett (Strg+B)", () => fmt().toggleMark("b"), "b");
  ui.italic = tb("K", "Kursiv (Strg+I)", () => fmt().toggleMark("i"), "i");
  ui.underline = tb("U", "Unterstrichen (Strg+U)", () => fmt().toggleMark("u"), "u");
  ui.code = tb("</>", "Code (Strg+E)", () => fmt().toggleMark("code"), "code");
  ui.size = h("select", { class: "tb-select", "aria-label": "Schriftgrösse" });
  ui.size.addEventListener("change", () => fmt().setSize(parseInt(ui.size.value, 10)));
  ui.colorSlot = h("span", { class: "tb-color" });
  ui.alignBtns = [
    ["left", "⯇", "Linksbündig"],
    ["center", "≡", "Zentriert"],
    ["right", "⯈", "Rechtsbündig"],
    ["justify", "☰", "Blocksatz"],
  ].map(([v, l, title]) => {
    const b = tb(l, title, () => fmt().setParagraphProps({ align: v }));
    b.dataset.align = v;
    return b;
  });
  ui.bullets = tb("•", "Aufzählung", () => fmt().toggleList("bullet"));
  ui.numbers = tb("1.", "Nummerierung", () => fmt().toggleList("number"));
  ui.outdent = tb("⇤", "Ebene höher (Umschalt+Tab)", () => fmt().shiftLevel(-1));
  ui.indent = tb("⇥", "Ebene tiefer (Tab)", () => fmt().shiftLevel(1));
  ui.link = tb("🔗", "Link", setLink);

  ui.front = tb("⤒", "In den Vordergrund", () => zOrder("front"));
  ui.back = tb("⤓", "In den Hintergrund", () => zOrder("back"));
  ui.del = tb("🗑", "Löschen (Entf)", deleteSelected);

  t.append(
    group(ui.undoBtn, ui.redoBtn),
    group(ui.newSlide),
    group(
      tb("T", "Textfeld einfügen", insertTextBox),
      tb("{ }", "Codeblock einfügen", insertCodeBlock, "code"),
      tb("🖼", "Bild oder Video einfügen", () => pickFiles(true, (files) => insertMedia(files))),
      ui.shapeSelect,
      tb("╱", "Linie einfügen", insertLine),
      tb("▦", "Tabelle einfügen", insertTable),
    ),
    group(ui.bold, ui.italic, ui.underline, ui.code, ui.size, ui.colorSlot),
    group(...ui.alignBtns),
    group(ui.bullets, ui.numbers, ui.outdent, ui.indent, ui.link),
    group(ui.front, ui.back, ui.del),
  );
}

function fillNewSlideSelect() {
  ui.newSlide.replaceChildren(
    h("option", { value: "", text: "+ Neue Folie …" }),
    ...design.layouts.map((l) => h("option", { value: l.id, text: l.name })),
  );
}

// The target of text formatting: the text being edited, the notes when
// they have the focus, else the whole text of the selected text boxes.
function fmt() {
  if (editing) return editorTarget(editing.ed);
  if (notesEditor && notesActive) {
    return editorTarget(notesEditor, true);
  }
  return elementsTarget(selectedEls().filter((e) => e.type === "text" || e.type === "table"));
}

function editorTarget(ed, notes) {
  return {
    enabled: true,
    notes,
    hasMark: (k) => ed.hasMark(k),
    markValue: (k) => ed.markValue(k),
    paragraphProp: (k) => ed.paragraphProp(k),
    toggleMark: (k) => ed.toggleMark(k),
    setSize: (n) => ed.setMark("size", n),
    setColor: (c) => ed.setMark("color", c),
    setParagraphProps: (p) => ed.setParagraphProps(p),
    toggleList: (kind) =>
      ed.setParagraphProps({ list: ed.paragraphProp("list") === kind ? undefined : kind }),
    shiftLevel: (d) => ed.shiftLevel(d),
    link: () => ed.markValue("link"),
    setLink: (url) => ed.setMark("link", url),
    baseSize: () => (editing ? resolved(findEl(editing.id)).style.size : 16),
  };
}

// Formatting applied to the whole text of text elements.
// The rich texts of an element: a text box's text, a table's cells.
function textsOf(e) {
  if (e.type === "table") {
    return e.table.rows.flatMap((row) => row.map((c, j) => (row[j] = rt.ensureText(c))));
  }
  return [(e.text = rt.ensureText(e.text))];
}

function elementsTarget(els) {
  const texts = () => els.flatMap(textsOf);
  const all = (f) => texts().every((t) => f(t, ...rt.wholeRange(t)));
  return {
    enabled: els.length > 0,
    hasMark: (k) => els.length > 0 && all((t, s, e) => rt.rangeHasMark(t, s, e, k)),
    markValue: (k) => {
      const vs = new Set(texts().map((t) => rt.rangeMarkValue(t, ...rt.wholeRange(t), k)));
      return vs.size === 1 ? [...vs][0] : undefined;
    },
    paragraphProp: (k) => {
      const vs = new Set(texts().flatMap((t) => t.paragraphs.map((p) => p[k])));
      return vs.size === 1 ? [...vs][0] : undefined;
    },
    toggleMark(k) {
      const on = !this.hasMark(k);
      change(() => texts().forEach((t) => rt.setMark(t, ...rt.wholeRange(t), k, on || undefined)));
    },
    setSize: (n) =>
      change(() =>
        els.forEach((e) => {
          e.style = Object.assign({}, e.style, { size: n });
          for (const t of textsOf(e)) rt.setMark(t, ...rt.wholeRange(t), "size", undefined);
        }),
      ),
    setColor: (c) =>
      change(() =>
        els.forEach((e) => {
          e.style = Object.assign({}, e.style);
          if (c === undefined) delete e.style.color;
          else e.style.color = c;
          for (const t of textsOf(e)) rt.setMark(t, ...rt.wholeRange(t), "color", undefined);
        }),
      ),
    setParagraphProps: (p) =>
      change(() => texts().forEach((t) => rt.setParagraphProps(t, ...rt.wholeRange(t), p))),
    toggleList(kind) {
      const on = this.paragraphProp("list") !== kind;
      change(() =>
        texts().forEach((t) => rt.setParagraphProps(t, ...rt.wholeRange(t), { list: on ? kind : undefined })),
      );
    },
    shiftLevel: (d) => change(() => texts().forEach((t) => rt.shiftLevel(t, ...rt.wholeRange(t), d))),
    link: () => undefined,
    setLink: null,
    baseSize: () => (els[0] ? resolved(els[0]).style.size : 40),
  };
}

function setLink() {
  const f = fmt();
  if (!f.setLink) return;
  const current = f.link() || "https://";
  const url = window.prompt("Link (https://…, mailto:… oder #slide-<Folien-ID>; leer = entfernen)", current);
  if (url === null) return;
  if (url.trim() === "") f.setLink(undefined);
  else if (rt.safeLink(url)) f.setLink(url.trim());
  else window.alert("Dieser Link ist nicht erlaubt.");
}

function updateToolbar() {
  if (!ui.toolbar) return;
  ui.undoBtn.disabled = !undoStack.length && !editing;
  ui.redoBtn.disabled = !redoStack.length;
  const f = fmt();
  const textBtns = [
    ui.bold, ui.italic, ui.underline, ui.code, ui.size, ...ui.alignBtns,
    ui.bullets, ui.numbers, ui.outdent, ui.indent,
  ];
  for (const b of textBtns) b.disabled = !f.enabled;
  ui.link.disabled = !f.setLink;
  const pressed = (b, on) => b.setAttribute("aria-pressed", on ? "true" : "false");
  if (f.enabled) {
    pressed(ui.bold, f.hasMark("b"));
    pressed(ui.italic, f.hasMark("i"));
    pressed(ui.underline, f.hasMark("u"));
    pressed(ui.code, f.hasMark("code"));
    const align = f.paragraphProp("align") || "left";
    ui.alignBtns.forEach((b) => pressed(b, b.dataset.align === align));
    pressed(ui.bullets, f.paragraphProp("list") === "bullet");
    pressed(ui.numbers, f.paragraphProp("list") === "number");
    const size = f.markValue("size") || f.baseSize();
    const sizes = SIZES.includes(size) || !size ? SIZES : SIZES.concat([size]).sort((a, b) => a - b);
    ui.size.replaceChildren(...sizes.map((s) => h("option", { value: s, text: String(s) })));
    ui.size.value = String(size);
  } else {
    for (const b of textBtns) if (b.tagName === "BUTTON") pressed(b, false);
  }
  const color = f.enabled ? f.markValue("color") : undefined;
  ui.colorSlot.replaceChildren(
    f.enabled
      ? colorField(color, (c) => fmt().setColor(c), { defaultLabel: "Standardfarbe", label: "Textfarbe" })
      : h("span", { class: "muted", text: "" }),
  );
  ui.front.disabled = ui.back.disabled = ui.del.disabled = sel.length === 0;
}

// --- the stage ------------------------------------------------------

function layoutStage() {
  const W = ui.stage.clientWidth;
  const H = ui.stage.clientHeight;
  const pad = 24;
  scale = Math.max(0.05, Math.min((W - 2 * pad) / SLIDE_W, (H - 2 * pad) / SLIDE_H));
  const w = SLIDE_W * scale;
  const hh = SLIDE_H * scale;
  for (const e of [ui.frame, ui.overlay]) {
    e.style.left = (W - w) / 2 + "px";
    e.style.top = (H - hh) / 2 + "px";
    e.style.width = w + "px";
    e.style.height = hh + "px";
  }
  const s = ui.frame.firstChild;
  if (s) s.style.transform = "scale(" + scale + ")";
  renderOverlay();
}

function renderCanvas() {
  if (editing) {
    renderOverlay();
    return;
  }
  const el = renderSlide(slide(), design, { editing: true, assetUrl, doc, index: cur });
  el.style.transform = "scale(" + scale + ")";
  ui.frame.replaceChildren(el);
  renderOverlay();
}

let guides = [];

function renderOverlay() {
  const o = ui.overlay;
  o.replaceChildren();
  const single = sel.length === 1;
  for (const el of selectedEls()) {
    const r = resolved(el);
    const box = h("div", { class: "sel-box" + (editing && editing.id === el.id ? " editing" : "") });
    box.style.left = r.x * scale + "px";
    box.style.top = r.y * scale + "px";
    box.style.width = Math.max(r.w * scale, 1) + "px";
    box.style.height = Math.max(r.h * scale, 1) + "px";
    if (r.rot) box.style.transform = "rotate(" + r.rot + "deg)";
    if (single && !editing) {
      const dirs = el.type === "line" ? ["nw", "se"] : ["nw", "n", "ne", "e", "se", "s", "sw", "w"];
      for (const d of dirs) {
        const hd = h("div", { class: "handle h-" + d, "data-dir": d });
        hd.addEventListener("pointerdown", (e) => startResize(e, el.id, d));
        box.append(hd);
      }
      if (el.type !== "line") {
        const rot = h("div", { class: "handle h-rot", title: "Drehen" });
        rot.addEventListener("pointerdown", (e) => startRotate(e, el.id));
        box.append(rot);
      }
    }
    o.append(box);
  }
  // The build order of elements that build.
  for (const el of slide().elements) {
    if (!el.build) continue;
    const r = resolved(el);
    const badge = h("div", { class: "build-badge", text: String(el.build.order) });
    badge.style.left = r.x * scale + "px";
    badge.style.top = r.y * scale + "px";
    o.append(badge);
  }
  for (const g of guides) {
    const line = h("div", { class: "guide " + (g.axis === "x" ? "gx" : "gy") });
    if (g.axis === "x") line.style.left = g.at * scale + "px";
    else line.style.top = g.at * scale + "px";
    o.append(line);
  }
}

function toSlide(e) {
  const r = ui.frame.getBoundingClientRect();
  return { x: (e.clientX - r.left) / scale, y: (e.clientY - r.top) / scale };
}

// The topmost element at a slide point.
function hitTest(pt) {
  const els = slide().elements;
  for (let i = els.length - 1; i >= 0; i--) {
    const r = resolved(els[i]);
    const pad = (els[i].type === "line" ? 10 : 2) / scale;
    if (ops.hits(r, pt.x, pt.y, pad)) return els[i].id;
  }
  return null;
}

function wireStage() {
  ui.stage.addEventListener("pointerdown", (e) => {
    if (e.button !== 0 || e.target.closest(".handle")) return;
    if (editing && editing.box.contains(e.target)) {
      // The caret moves in the text, or to another cell of the table.
      const c = editing.cell && cellAt(e);
      if (c && (c[0] !== editing.cell[0] || c[1] !== editing.cell[1])) {
        e.preventDefault();
        startEditing(editing.id, false, e, c);
      }
      return;
    }
    const pt = toSlide(e);
    const id = hitTest(pt);
    if (editing) stopEditing();
    ui.stage.focus({ preventScroll: true });
    if (!id) {
      sel = [];
      selectionChanged();
      return;
    }
    if (e.shiftKey) {
      sel = sel.includes(id) ? sel.filter((x) => x !== id) : sel.concat([id]);
      selectionChanged();
      return;
    }
    if (!sel.includes(id)) {
      sel = [id];
      selectionChanged();
    }
    startMove(e);
  });
  ui.stage.addEventListener("dblclick", (e) => {
    const id = hitTest(toSlide(e));
    const el = id && findEl(id);
    if (el && el.type === "text" && !(editing && editing.id === id)) startEditing(id, false, e);
    else if (el && el.type === "table") startEditing(id, false, e, cellAt(e));
    else if (el && (el.type === "image" || el.type === "video")) {
      pickFiles(false, (files) => insertMedia(files, null, el.id));
    }
  });
  ui.stage.addEventListener("dragover", (e) => {
    if (e.dataTransfer && Array.from(e.dataTransfer.types).includes("Files")) {
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
    }
  });
  ui.stage.addEventListener("drop", (e) => {
    const files = up.mediaFiles(e.dataTransfer && e.dataTransfer.files);
    if (!files.length) return;
    e.preventDefault();
    const pt = toSlide(e);
    // Dropped on an image or video: replace it.
    const id = hitTest(pt);
    const target = id && findEl(id);
    insertMedia(files, pt, target && (target.type === "image" || target.type === "video") ? id : null);
  });
}

function selectionChanged() {
  renderOverlay();
  renderPanel();
  updateToolbar();
  announceSelection();
}

// "Textfeld «Hallo Welt» ausgewählt" for screen readers.
function announceSelection() {
  const els = selectedEls();
  let msg = "Keine Auswahl";
  if (els.length > 1) msg = els.length + " Elemente ausgewählt";
  else if (els.length === 1) {
    const el = els[0];
    const what = el.placeholder && resolved(el).placeholder ? resolved(el).placeholder.label : TYPE_NAMES[el.type];
    const words = el.type === "text" && el.text ? rt.plainText(el.text).slice(0, 60) : el.alt || "";
    msg = what + (words ? " «" + words + "»" : "") + " ausgewählt";
  }
  if (ui.live.textContent !== msg) ui.live.textContent = msg;
}

// Tab on the stage: the next (Shift: previous) element of the slide.
function cycleSelection(dir) {
  const els = slide().elements;
  if (!els.length) return;
  const i = sel.length ? els.findIndex((e) => e.id === sel[sel.length - 1]) : -1;
  const j = i < 0 ? (dir > 0 ? 0 : els.length - 1) : (i + dir + els.length) % els.length;
  sel = [els[j].id];
  selectionChanged();
}

// Snap targets: the slide's edges and centre, and the other elements'.
function snapTargets(exclude) {
  const xs = [0, SLIDE_W / 2, SLIDE_W];
  const ys = [0, SLIDE_H / 2, SLIDE_H];
  for (const el of slide().elements) {
    if (exclude.includes(el.id)) continue;
    const b = ops.bounds(resolved(el));
    xs.push(b.x, b.x + b.w / 2, b.x + b.w);
    ys.push(b.y, b.y + b.h / 2, b.y + b.h);
  }
  return { xs, ys };
}

// Gives placeholders their geometry before it is changed.
function ownGeometry(el) {
  if (el.x === undefined || el.y === undefined || el.w === undefined || el.h === undefined) {
    ops.materialize(layout(), el);
  }
}

function drag(e, onMove) {
  const before = snapshot();
  const start = { x: e.clientX, y: e.clientY };
  let moved = false;
  ui.stage.setPointerCapture(e.pointerId);
  const move = (ev) => {
    if (!moved && Math.hypot(ev.clientX - start.x, ev.clientY - start.y) < 3) return;
    moved = true;
    onMove(ev);
    renderCanvas();
  };
  const up = () => {
    ui.stage.removeEventListener("pointermove", move);
    ui.stage.removeEventListener("pointerup", up);
    ui.stage.removeEventListener("pointercancel", up);
    guides = [];
    if (moved) {
      pushUndo(before);
      lastTyping = 0;
      afterChange();
    } else renderOverlay();
  };
  ui.stage.addEventListener("pointermove", move);
  ui.stage.addEventListener("pointerup", up);
  ui.stage.addEventListener("pointercancel", up);
}

function startMove(e) {
  e.preventDefault();
  const p0 = toSlide(e);
  const orig = selectedEls().map((el) => ({ el, r: resolved(el) }));
  const union = unionBounds(orig.map((o) => o.r));
  const targets = snapTargets(sel);
  drag(e, (ev) => {
    const p = toSlide(ev);
    let dx = p.x - p0.x;
    let dy = p.y - p0.y;
    guides = [];
    if (!ev.altKey) {
      const tol = 8 / scale;
      const sx = ops.snapOffset(
        [union.x + dx, union.x + union.w / 2 + dx, union.x + union.w + dx], targets.xs, tol);
      const sy = ops.snapOffset(
        [union.y + dy, union.y + union.h / 2 + dy, union.y + union.h + dy], targets.ys, tol);
      if (sx) {
        dx += sx.d;
        guides.push({ axis: "x", at: sx.at });
      }
      if (sy) {
        dy += sy.d;
        guides.push({ axis: "y", at: sy.at });
      }
    }
    for (const o of orig) {
      ownGeometry(o.el);
      o.el.x = Math.round(o.r.x + dx);
      o.el.y = Math.round(o.r.y + dy);
    }
  });
}

function unionBounds(rs) {
  const bs = rs.map(ops.bounds);
  const x = Math.min(...bs.map((b) => b.x));
  const y = Math.min(...bs.map((b) => b.y));
  const x2 = Math.max(...bs.map((b) => b.x + b.w));
  const y2 = Math.max(...bs.map((b) => b.y + b.h));
  return { x, y, w: x2 - x, h: y2 - y };
}

function startResize(e, id, dir) {
  e.preventDefault();
  e.stopPropagation();
  const el = findEl(id);
  const r = resolved(el);
  const p0 = toSlide(e);
  const targets = snapTargets([id]);
  const line = el.type === "line";
  const min = line ? 0 : 10;
  drag(e, (ev) => {
    const p = toSlide(ev);
    // The pointer's movement in the element's own (unrotated) axes.
    const a = (-(r.rot || 0) * Math.PI) / 180;
    const mx = p.x - p0.x;
    const my = p.y - p0.y;
    const dx = mx * Math.cos(a) - my * Math.sin(a);
    const dy = mx * Math.sin(a) + my * Math.cos(a);
    let { x, y, w, h: hh } = r;
    if (dir.includes("e")) w = r.w + dx;
    if (dir.includes("w")) w = r.w - dx;
    if (dir.includes("s")) hh = r.h + dy;
    if (dir.includes("n")) hh = r.h - dy;
    guides = [];
    if (!ev.altKey && !r.rot) {
      const tol = 8 / scale;
      const edgeX = dir.includes("e") ? r.x + w : dir.includes("w") ? r.x + r.w - w : null;
      const edgeY = dir.includes("s") ? r.y + hh : dir.includes("n") ? r.y + r.h - hh : null;
      const sx = edgeX !== null && ops.snapOffset([edgeX], targets.xs, tol);
      const sy = edgeY !== null && ops.snapOffset([edgeY], targets.ys, tol);
      if (sx) {
        w += dir.includes("e") ? sx.d : -sx.d;
        guides.push({ axis: "x", at: sx.at });
      }
      if (sy) {
        hh += dir.includes("s") ? sy.d : -sy.d;
        guides.push({ axis: "y", at: sy.at });
      }
    }
    if (ev.shiftKey && dir.length === 2 && r.w > 0 && r.h > 0) {
      const ratio = r.w / r.h;
      if (Math.abs(w / r.w) > Math.abs(hh / r.h)) hh = w / ratio;
      else w = hh * ratio;
    }
    w = Math.max(min, w);
    hh = Math.max(min, hh);
    if (dir.includes("w")) x = r.x + r.w - w;
    if (dir.includes("n")) y = r.y + r.h - hh;
    ownGeometry(el);
    Object.assign(el, { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(hh) });
  });
}

function startRotate(e, id) {
  e.preventDefault();
  e.stopPropagation();
  const el = findEl(id);
  const r = resolved(el);
  const c = { x: r.x + r.w / 2, y: r.y + r.h / 2 };
  drag(e, (ev) => {
    const p = toSlide(ev);
    let deg = (Math.atan2(p.y - c.y, p.x - c.x) * 180) / Math.PI + 90;
    if (ev.shiftKey) deg = Math.round(deg / 15) * 15;
    else {
      const near = Math.round(deg / 90) * 90;
      if (Math.abs(deg - near) < 3) deg = near;
    }
    deg = ((((deg + 180) % 360) + 360) % 360) - 180;
    ownGeometry(el);
    if (deg === 0) delete el.rot;
    else el.rot = Math.round(deg * 10) / 10;
  });
}

// --- text editing ---------------------------------------------------

// The table cell [row, column] under a pointer event, or null.
function cellAt(e) {
  const c = e.target.closest && e.target.closest(".el-table .cell");
  return c ? [Number(c.dataset.r), Number(c.dataset.c)] : null;
}

// Edits a text box, or a cell of a table (default: the first).
function startEditing(id, selectAll, clickEvent, cell) {
  const el = findEl(id);
  if (!el || (el.type !== "text" && el.type !== "table")) return;
  if (editing) stopEditing();
  const table = el.type === "table" ? el.table : null;
  if (table && !(cell && table.rows[cell[0]] && cell[1] < table.rows[0].length)) cell = [0, 0];
  sel = [id];
  renderCanvas();
  const box = ui.frame.querySelector('.el[data-id="' + id + '"]');
  if (!box) return;
  const host = table ? box.querySelector('.cell[data-r="' + cell[0] + '"][data-c="' + cell[1] + '"]') : box;
  const inner = host.querySelector(".text-inner");
  inner.classList.remove("prompt");
  const ed = new RichTextEditor(inner, {
    text: table ? rt.ensureText(table.rows[cell[0]][cell[1]]) : el.text,
    base: table ? cellStyle(resolved(el).style, cell[0] === 0 && !!table.header) : resolved(el).style,
    design,
    beforeChange: typingStep,
    change: (t) => {
      if (table) table.rows[cell[0]][cell[1]] = t;
      else el.text = t;
      afterChange({ light: true });
    },
    // Tab moves between cells; Tab in the last cell adds a row. In a
    // code block Tab indents by two spaces (Shift+Tab does nothing there).
    tab: !table && resolved(el).style.font === "code"
      ? (e) => {
          if (!e.shiftKey) ed.typeText("  ");
          return true;
        }
      : table
      ? (e) => {
          const dir = e.shiftKey ? -1 : 1;
          let next = ops.nextCell(table, cell, dir);
          if (!next && dir === 1) {
            change(() => ops.insertRow(table, table.rows.length));
            next = ops.nextCell(table, cell, dir);
          }
          if (next) startEditing(id, true, null, next);
          return true;
        }
      : null,
    selectionChange: updateToolbar,
    keydown: (e) => {
      if (e.key === "Escape") {
        e.preventDefault();
        stopEditing();
      } else globalKeys(e);
    },
    pasteFiles: (files) => {
      const media = up.mediaFiles(files);
      if (media.length) {
        stopEditing();
        insertMedia(media);
      }
    },
  });
  editing = { id, ed, box, cell };
  box.classList.add("is-editing");
  host.classList.add("is-editing");
  ed.focus(selectAll);
  if (clickEvent) placeCaret(ed, clickEvent.clientX, clickEvent.clientY);
  renderOverlay();
  renderPanel();
  updateToolbar();
}

function placeCaret(ed, x, y) {
  let node;
  let offset;
  if (document.caretPositionFromPoint) {
    const p = document.caretPositionFromPoint(x, y);
    if (p) [node, offset] = [p.offsetNode, p.offset];
  } else if (document.caretRangeFromPoint) {
    const r = document.caretRangeFromPoint(x, y);
    if (r) [node, offset] = [r.startContainer, r.startOffset];
  }
  if (node && ed.el.contains(node)) ed.setSelection(ed.toPos(node, offset));
}

function stopEditing() {
  if (!editing) return;
  const { id, ed } = editing;
  ed.destroy();
  editing = null;
  lastTyping = 0;
  // A free text box left empty goes away.
  const el = findEl(id);
  if (el && el.type === "text" && !el.placeholder && rt.plainText(rt.ensureText(el.text)) === "") {
    slide().elements = slide().elements.filter((e) => e !== el);
    sel = [];
    markDirty();
  }
  renderCanvas();
  scheduleThumb(cur);
  renderPanel();
  updateToolbar();
}

function renderNotesEditor() {
  if (notesEditor) notesEditor.destroy();
  const s = slide();
  notesEditor = new RichTextEditor(ui.notesBody, {
    text: s.notes || rt.emptyText(),
    base: { font: "body", size: 15, color: "text", align: "left" },
    design: notesDesign(),
    beforeChange: typingStep,
    change: (t) => {
      if (rt.plainText(t) === "") delete s.notes;
      else s.notes = t;
      afterChange({ light: true });
    },
    selectionChange: updateToolbar,
    keydown: (e) => {
      if (e.key === "Escape") ui.notesBody.blur();
      else globalKeys(e);
    },
  });
}

// Notes are page text: the page's font and colours, not the slide's.
function notesDesign() {
  return {
    colors: { text: "inherit" },
    fonts: { body: { family: "system-ui, sans-serif", weight: 400 } },
    text: { bullet: "•", lineHeight: 1.45, paraSpacing: 0.4 },
  };
}

// --- slides ---------------------------------------------------------

function wireSlideList() {
  ui.slides.addEventListener("keydown", (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowRight") selectSlide(cur + 1);
    else if (e.key === "ArrowUp" || e.key === "ArrowLeft") selectSlide(cur - 1);
    else if (e.key === "Delete" || e.key === "Backspace") deleteSlide();
    else if ((e.ctrlKey || e.metaKey) && e.key === "d") duplicateSlide();
    else return;
    e.preventDefault();
    e.stopPropagation();
  });
}

let dragFrom = null;

function renderSlideList() {
  for (const f of ui.slides.querySelectorAll(".slide-frame")) {
    const prev = unfits.get(f);
    if (prev) prev();
  }
  ui.slides.replaceChildren();
  doc.slides.forEach((s, i) => {
    const frame = h("div", { class: "slide-frame" });
    const item = h(
      "div",
      {
        class: "ed-thumb" + (i === cur ? " current" : "") + (s.hidden ? " hidden-slide" : ""),
        draggable: true,
        "data-index": i,
      },
      h("span", { class: "num", text: String(i + 1) }),
      frame,
    );
    item.addEventListener("click", () => selectSlide(i));
    item.addEventListener("dragstart", (e) => {
      dragFrom = i;
      e.dataTransfer.effectAllowed = "move";
      e.dataTransfer.setData("text/plain", String(i));
    });
    item.addEventListener("dragover", (e) => {
      if (dragFrom === null) return;
      e.preventDefault();
      const r = item.getBoundingClientRect();
      const after = e.clientY > r.top + r.height / 2;
      item.classList.toggle("drop-before", !after);
      item.classList.toggle("drop-after", after);
    });
    item.addEventListener("dragleave", () => item.classList.remove("drop-before", "drop-after"));
    item.addEventListener("drop", (e) => {
      e.preventDefault();
      item.classList.remove("drop-before", "drop-after");
      if (dragFrom === null) return;
      const r = item.getBoundingClientRect();
      let to = e.clientY > r.top + r.height / 2 ? i + 1 : i;
      const from = dragFrom;
      dragFrom = null;
      if (to > from) to--;
      if (to !== from) moveSlide(from, to);
    });
    item.addEventListener("dragend", () => (dragFrom = null));
    ui.slides.append(item);
    drawThumb(frame, s);
  });
  const currentItem = ui.slides.children[cur];
  if (currentItem) currentItem.scrollIntoView({ block: "nearest" });
  renderSlideActions();
}

// Draws a slide into a thumbnail frame, replacing the previous drawing
// (and its resize observer).
const unfits = new WeakMap();
function drawThumb(frame, s) {
  const prev = unfits.get(frame);
  if (prev) prev();
  unfits.set(frame, fitInto(frame, renderSlide(s, design, { assetUrl: thumbUrl, doc, index: doc.slides.indexOf(s) })));
}

const thumbTimers = new Map();
function scheduleThumb(i) {
  clearTimeout(thumbTimers.get(i));
  thumbTimers.set(
    i,
    setTimeout(() => {
      const item = ui.slides.children[i];
      if (!item || !doc.slides[i]) return;
      const frame = item.querySelector(".slide-frame");
      drawThumb(frame, doc.slides[i]);
      item.classList.toggle("hidden-slide", !!doc.slides[i].hidden);
    }, 250),
  );
}

function renderSlideActions() {
  ui.slideActions.replaceChildren(
    tb("⧉", "Folie duplizieren (Strg+D in der Liste)", duplicateSlide),
    tb("↑", "Folie nach oben", () => cur > 0 && moveSlide(cur, cur - 1)),
    tb("↓", "Folie nach unten", () => cur < doc.slides.length - 1 && moveSlide(cur, cur + 1)),
    tb("🗑", "Folie löschen", deleteSlide),
  );
}

function selectSlide(i) {
  if (i < 0 || i >= doc.slides.length) return;
  if (editing) stopEditing();
  cur = i;
  sel = [];
  Array.from(ui.slides.children).forEach((c, j) => c.classList.toggle("current", j === cur));
  const item = ui.slides.children[cur];
  if (item) item.scrollIntoView({ block: "nearest" });
  renderCanvas();
  renderNotesEditor();
  renderPanel();
  updateToolbar();
}

function addSlide(layoutId) {
  change(
    () => {
      doc.slides.splice(cur + 1, 0, ops.newSlide(design, layoutId));
      cur += 1;
      sel = [];
    },
    { structure: true },
  );
  renderNotesEditor();
}

function duplicateSlide() {
  change(
    () => {
      doc.slides.splice(cur + 1, 0, ops.copySlide(slide()));
      cur += 1;
      sel = [];
    },
    { structure: true },
  );
  renderNotesEditor();
}

function deleteSlide() {
  if (doc.slides.length <= 1) return;
  change(
    () => {
      doc.slides.splice(cur, 1);
      cur = Math.min(cur, doc.slides.length - 1);
      sel = [];
    },
    { structure: true },
  );
  renderNotesEditor();
}

function moveSlide(from, to) {
  change(
    () => {
      ops.moveItem(doc.slides, from, to);
      cur = to;
    },
    { structure: true },
  );
}

// --- elements -------------------------------------------------------

function addElement(el) {
  change(() => {
    slide().elements.push(el);
    sel = [el.id];
  });
}

function insertTextBox() {
  const el = {
    id: ops.newId(),
    type: "text",
    x: 560,
    y: 440,
    w: 800,
    h: 200,
    style: { font: "body", size: 40, color: "text", align: "left", valign: "top" },
    text: rt.emptyText(),
  };
  addElement(el);
  startEditing(el.id, true);
}

// A code block: the code font on the light tint, padded.
function insertCodeBlock() {
  const el = {
    id: ops.newId(),
    type: "text",
    x: 260,
    y: 340,
    w: 1400,
    h: 400,
    style: { font: "code", size: 32, color: "text", align: "left", valign: "top", fill: "light", pad: 36 },
    text: rt.emptyText(),
  };
  addElement(el);
  startEditing(el.id, true);
}

function insertShape(kind) {
  addElement({
    id: ops.newId(),
    type: "shape",
    shape: kind,
    x: 760,
    y: 390,
    w: 400,
    h: 300,
    style: { fill: "accent" },
  });
}

function insertTable() {
  addElement({
    id: ops.newId(),
    type: "table",
    x: 360,
    y: 340,
    w: 1200,
    h: 400,
    style: { font: "body", size: 32, color: "text", align: "left" },
    table: ops.newTable(4, 3),
  });
}

function insertLine() {
  addElement({
    id: ops.newId(),
    type: "line",
    x: 660,
    y: 540,
    w: 600,
    h: 0,
    style: { stroke: "text", strokeWidth: 6 },
  });
}

function deleteSelected() {
  if (!sel.length) return;
  change(() => {
    slide().elements = slide().elements.filter((e) => !sel.includes(e.id));
    sel = [];
  });
}

function duplicateSelected() {
  if (!sel.length) return;
  change(() => {
    const copies = selectedEls().map((el) => {
      const c = ops.copyElement(el);
      ops.materialize(layout(), c, !!c.placeholder);
      delete c.placeholder;
      c.x += 30;
      c.y += 30;
      return c;
    });
    slide().elements.push(...copies);
    sel = copies.map((c) => c.id);
  });
}

function zOrder(where) {
  if (!sel.length) return;
  change(() => {
    const els = slide().elements;
    const picked = els.filter((e) => sel.includes(e.id));
    const rest = els.filter((e) => !sel.includes(e.id));
    slide().elements = where === "front" ? rest.concat(picked) : picked.concat(rest);
  });
}

function nudge(dx, dy) {
  if (!sel.length) return;
  change(() => {
    for (const el of selectedEls()) {
      ownGeometry(el);
      el.x += dx;
      el.y += dy;
    }
  });
}

function alignSelected(kind) {
  const items = selectedEls().map((el) => ({ el, b: ops.bounds(resolved(el)) }));
  if (items.length < 2) return;
  const u = unionBounds(items.map((i) => resolved(i.el)));
  change(() => {
    if (kind === "dist-h" || kind === "dist-v") {
      const hz = kind === "dist-h";
      items.sort((a, b) => (hz ? a.b.x - b.b.x : a.b.y - b.b.y));
      const total = items.reduce((s, i) => s + (hz ? i.b.w : i.b.h), 0);
      const gap = ((hz ? u.w : u.h) - total) / (items.length - 1);
      let at = hz ? u.x : u.y;
      for (const i of items) {
        ownGeometry(i.el);
        if (hz) i.el.x += Math.round(at - i.b.x);
        else i.el.y += Math.round(at - i.b.y);
        at += (hz ? i.b.w : i.b.h) + gap;
      }
      return;
    }
    for (const i of items) {
      ownGeometry(i.el);
      const b = i.b;
      if (kind === "left") i.el.x += Math.round(u.x - b.x);
      if (kind === "center") i.el.x += Math.round(u.x + u.w / 2 - (b.x + b.w / 2));
      if (kind === "right") i.el.x += Math.round(u.x + u.w - (b.x + b.w));
      if (kind === "top") i.el.y += Math.round(u.y - b.y);
      if (kind === "middle") i.el.y += Math.round(u.y + u.h / 2 - (b.y + b.h / 2));
      if (kind === "bottom") i.el.y += Math.round(u.y + u.h - (b.y + b.h));
    }
  });
}

// --- images and videos ----------------------------------------------

let mediaLibrary = null; // the deck's assets, once loaded

function pickFiles(multiple, then) {
  const input = h("input", { type: "file", accept: up.ACCEPT, multiple });
  input.addEventListener("change", () => {
    const files = up.mediaFiles(input.files);
    if (files.length) then(files);
  });
  input.click();
}

function showUpload(text) {
  ui.uploadStatus.textContent = text || "";
}

// Uploads a file (and a video's poster); resolves with
// {asset, poster, width, height, video}.
async function uploadMedia(file, n, total) {
  const label = total > 1 ? " (" + n + "/" + total + ")" : "";
  const progress = (f) => showUpload("Lädt hoch" + label + " … " + Math.round(f * 100) + " %");
  progress(0);
  if (up.isVideo(file)) {
    const poster = await up.videoPoster(file, file.name);
    const posterAsset = await up.upload(urls.deckUrl, poster.blob, poster.name, poster);
    const asset = await up.upload(urls.deckUrl, file, file.name || "video", poster, progress);
    return { asset, poster: posterAsset, width: poster.width, height: poster.height, video: true };
  }
  const img = await up.prepareImage(file);
  const asset = await up.upload(urls.deckUrl, img.blob, img.name, img, progress);
  return { asset, width: img.width, height: img.height, video: false };
}

// The geometry of new media: at most 1200 x 700, keeping the aspect
// ratio, centred on at (a slide point) or the slide, inside the slide.
function mediaBox(width, height, at) {
  const s = Math.min(1, 1200 / width, 700 / height);
  const w = Math.max(20, Math.round(width * s));
  const hh = Math.max(20, Math.round(height * s));
  const cx = at ? at.x : SLIDE_W / 2;
  const cy = at ? at.y : SLIDE_H / 2;
  return {
    x: Math.round(Math.min(Math.max(0, cx - w / 2), SLIDE_W - w)),
    y: Math.round(Math.min(Math.max(0, cy - hh / 2), SLIDE_H - hh)),
    w,
    h: hh,
  };
}

function setMedia(el, m) {
  el.type = m.video ? "video" : "image";
  el.asset = m.asset.sha;
  if (m.poster) el.poster = m.poster.sha;
  else delete el.poster;
  if (!m.video) {
    for (const k of ["autoplay", "loop", "muted"]) delete el[k];
  }
}

// Uploads files and puts them on the current slide: into the element
// target (replacing its media), else into an empty image placeholder of
// the slide, else as new elements (at, a slide point, or centred).
async function insertMedia(files, at, target) {
  if (editing) stopEditing();
  const slideId = slide().id;
  let n = 0;
  for (const file of files) {
    n += 1;
    let m;
    try {
      m = await uploadMedia(file, n, files.length);
    } catch (err) {
      showUpload("");
      window.alert((file.name ? file.name + ": " : "") + err.message);
      continue;
    }
    mediaLibrary = null;
    // The user may have moved on to another slide meanwhile.
    const s = doc.slides.find((x) => x.id === slideId) || slide();
    change(() => {
      let el = target && s.elements.find((x) => x.id === target);
      if (!el) {
        el = s.elements.find((x) => x.placeholder && (x.type === "image" || x.type === "video") && !x.asset);
      }
      if (el) {
        setMedia(el, m);
      } else {
        el = Object.assign({ id: ops.newId() }, mediaBox(m.width, m.height, at));
        setMedia(el, m);
        s.elements.push(el);
      }
      sel = [el.id];
      target = null; // only the first file replaces
    });
  }
  showUpload("");
}

async function insertFromLibrary(asset) {
  const video = asset.mime.startsWith("video/");
  let poster = null;
  let width = asset.width || 800;
  let height = asset.height || 600;
  if (video) {
    try {
      const p = await up.videoPoster(assetUrl(asset.sha), asset.name);
      poster = await up.upload(urls.deckUrl, p.blob, p.name, p);
      width = p.width;
      height = p.height;
    } catch (err) {
      window.alert(err.message);
      return;
    }
  }
  change(() => {
    const el = Object.assign({ id: ops.newId() }, mediaBox(width, height, null));
    setMedia(el, { asset, poster, video });
    slide().elements.push(el);
    sel = [el.id];
  });
}

// The deck's images and videos for the panel (posters left out).
function librarySection() {
  const grid = h("div", { class: "media-grid" });
  const fill = (assets) => {
    const shown = assets.filter((a) => !a.name.endsWith(".poster.jpg"));
    if (!shown.length) {
      grid.replaceChildren(h("p", { class: "muted small", text: "Noch keine Bilder oder Videos." }));
      return;
    }
    grid.replaceChildren(
      ...shown.map((a) =>
        h(
          "button",
          {
            type: "button",
            class: "media-tile",
            title: a.name,
            "aria-label": a.name + " einfügen",
            on: { click: () => insertFromLibrary(a) },
          },
          a.mime.startsWith("video/")
            ? h("span", { class: "media-video", text: "▶" })
            : h("img", { src: thumbUrl(a.sha, 320), alt: "", loading: "lazy" }),
        ),
      ),
    );
  };
  if (mediaLibrary) fill(mediaLibrary);
  else {
    grid.append(h("p", { class: "muted small", text: "Lädt …" }));
    up.listAssets(urls.deckUrl)
      .then((list) => {
        mediaLibrary = list;
        fill(list);
      })
      .catch(() => grid.replaceChildren(h("p", { class: "muted small", text: "Nicht verfügbar." })));
  }
  return section(
    "Bilder und Videos",
    grid,
    h("button", {
      type: "button",
      class: "small",
      text: "Hochladen …",
      on: { click: () => pickFiles(true, (files) => insertMedia(files)) },
    }),
  );
}

// --- clipboard (elements) -------------------------------------------

const CLIP_PREFIX = "folien-elements:";

function inFormField(t) {
  return t && t.closest && t.closest("input, textarea, select, [contenteditable=true]");
}

document.addEventListener("copy", (e) => copyElements(e, false));
document.addEventListener("cut", (e) => copyElements(e, true));
function copyElements(e, cut) {
  if (e.defaultPrevented || editing || inFormField(e.target) || !sel.length) return;
  e.preventDefault();
  const els = selectedEls().map((el) => {
    const c = JSON.parse(JSON.stringify(el));
    ops.materialize(layout(), c, !!c.placeholder);
    delete c.placeholder;
    return c;
  });
  e.clipboardData.setData("text/plain", CLIP_PREFIX + JSON.stringify(els));
  if (cut) deleteSelected();
}

document.addEventListener("paste", (e) => {
  if (e.defaultPrevented || editing || inFormField(e.target)) return;
  const files = up.clipboardMedia(e.clipboardData);
  if (files.length) {
    e.preventDefault();
    insertMedia(files);
    return;
  }
  const data = e.clipboardData.getData("text/plain");
  if (!data) return;
  e.preventDefault();
  if (data.startsWith(CLIP_PREFIX)) {
    let els;
    try {
      els = JSON.parse(data.slice(CLIP_PREFIX.length));
    } catch (err) {
      return;
    }
    if (!Array.isArray(els)) return;
    const here = new Set(slide().elements.map((x) => x.id));
    change(() => {
      const copies = els.map((el) => {
        const c = ops.copyElement(el);
        if (here.size) {
          c.x += 30;
          c.y += 30;
        }
        return c;
      });
      slide().elements.push(...copies);
      sel = copies.map((c) => c.id);
    });
    return;
  }
  // Plain text: a new text box.
  const el = {
    id: ops.newId(),
    type: "text",
    x: 360,
    y: 340,
    w: 1200,
    h: 400,
    style: { font: "body", size: 40, color: "text", align: "left", valign: "top" },
    text: rt.fragmentFromPlain(data.slice(0, 20000)),
  };
  addElement(el);
});

// --- keyboard -------------------------------------------------------

function globalKeys(e) {
  const mod = e.ctrlKey || e.metaKey;
  const k = e.key.toLowerCase();
  if (mod && k === "z" && !e.shiftKey) undo();
  else if (mod && (k === "y" || (k === "z" && e.shiftKey))) redo();
  else if (mod && k === "s") save();
  else return false;
  e.preventDefault();
  return true;
}

document.addEventListener("keydown", (e) => {
  if (e.defaultPrevented) return;
  if (inFormField(e.target)) {
    if (!e.target.closest("[contenteditable=true]")) globalKeys(e);
    return; // the text editors handle their own keys
  }
  if (globalKeys(e)) return;
  const mod = e.ctrlKey || e.metaKey;
  const step = e.shiftKey ? 10 : 1;
  switch (e.key) {
    case "Delete":
    case "Backspace":
      deleteSelected();
      break;
    case "Escape":
      sel = [];
      selectionChanged();
      break;
    case "ArrowLeft":
      if (sel.length) nudge(-step, 0);
      else selectSlide(cur - 1);
      break;
    case "ArrowRight":
      if (sel.length) nudge(step, 0);
      else selectSlide(cur + 1);
      break;
    case "ArrowUp":
      if (sel.length) nudge(0, -step);
      else selectSlide(cur - 1);
      break;
    case "ArrowDown":
      if (sel.length) nudge(0, step);
      else selectSlide(cur + 1);
      break;
    case "PageUp":
      selectSlide(cur - 1);
      break;
    case "Tab":
      if (document.activeElement !== ui.stage) return;
      cycleSelection(e.shiftKey ? -1 : 1);
      break;
    case "PageDown":
      selectSlide(cur + 1);
      break;
    case "Enter":
    case "F2":
      if (sel.length === 1 && ["text", "table"].includes(findEl(sel[0]).type)) startEditing(sel[0], true);
      else return;
      break;
    default:
      if (mod && e.key.toLowerCase() === "d") duplicateSelected();
      else if (mod && e.key.toLowerCase() === "a") {
        sel = slide().elements.map((x) => x.id);
        selectionChanged();
      } else return;
  }
  e.preventDefault();
});

// --- properties panel -----------------------------------------------

const TRANSITIONS = [
  ["none", "Keiner"],
  ["fade", "Überblenden"],
  ["push-left", "Schieben (links)"],
  ["push-up", "Schieben (oben)"],
  ["wipe-left", "Wischen"],
  ["zoom", "Zoomen"],
];

function section(title, ...children) {
  return h("section", { class: "panel-section" }, h("h3", { text: title }), ...children);
}

function renderPanel() {
  const s = slide();
  const parts = [];

  parts.push(
    section(
      "Präsentation",
      selectField(
        "Design",
        deck.design,
        [...designs.values()].map((d) => [d.id, d.name]),
        (v) =>
          change(
            () => {
              deck.design = v;
              design = designs.get(v);
              fillNewSlideSelect();
            },
            { structure: true },
          ),
      ),
    ),
    footerSection(),
  );

  parts.push(
    section(
      "Folie " + (cur + 1),
      selectField(
        "Layout",
        s.layout,
        design.layouts.map((l) => [l.id, l.name]),
        (v) => change(() => ops.changeLayout(design, s, v)),
      ),
      h("label", { class: "field" }, h("span", { text: "Hintergrund" }),
        colorField(s.background, (c) => change(() => {
          if (c === undefined) delete s.background;
          else s.background = c;
        }), { defaultLabel: "Vom Design" })),
      // Hiding renumbers the slides after this one.
      checkField("Ausgeblendet", !!s.hidden, (on) =>
        change(() => {
          if (on) s.hidden = true;
          else delete s.hidden;
        }, { structure: true }),
      ),
      doc.footer
        ? checkField("Fusszeile zeigen", s.footer !== false, (on) =>
            change(() => {
              if (on) delete s.footer;
              else s.footer = false;
            }),
          )
        : null,
      selectField("Übergang", (s.transition && s.transition.type) || "none", TRANSITIONS, (v) =>
        change(() => {
          if (v === "none") delete s.transition;
          else s.transition = { type: v, duration: (s.transition && s.transition.duration) || 600 };
        }),
      ),
      s.transition
        ? numberField("Dauer (ms)", s.transition.duration || 600, (n) =>
            change(() => (s.transition.duration = Math.max(0, Math.min(10000, Math.round(n))))),
          { min: 0, max: 10000, step: 100 })
        : null,
    ),
  );

  const els = selectedEls();
  if (els.length === 0) parts.push(librarySection());
  if (els.length === 1) parts.push(elementSection(els[0]));
  else if (els.length > 1) {
    const btn = (label, title, kind) =>
      h("button", { type: "button", class: "small", text: label, title, on: { click: () => alignSelected(kind) } });
    parts.push(
      section(
        els.length + " Elemente",
        h(
          "div",
          { class: "align-grid" },
          btn("⇤", "Links ausrichten", "left"),
          btn("↔", "Horizontal zentrieren", "center"),
          btn("⇥", "Rechts ausrichten", "right"),
          btn("⤒", "Oben ausrichten", "top"),
          btn("↕", "Vertikal zentrieren", "middle"),
          btn("⤓", "Unten ausrichten", "bottom"),
          els.length > 2 ? btn("⋯", "Horizontal verteilen", "dist-h") : null,
          els.length > 2 ? btn("⋮", "Vertikal verteilen", "dist-v") : null,
        ),
      ),
    );
  }
  ui.panel.replaceChildren(...parts);
}

// The deck's footer fields (see "footer" in src/app-model.sld): changes
// redraw every thumbnail. An empty footer object is dropped.
function footerSection() {
  const f = doc.footer || {};
  const set = (k, v) =>
    change(() => {
      const next = Object.assign({}, doc.footer);
      if (v === undefined || v === false || v === "") delete next[k];
      else next[k] = v;
      if (k === "date" && v !== "fixed") delete next.dateText;
      if (k === "date" && v === "fixed" && !next.dateText) next.dateText = todayText();
      if (Object.keys(next).some((x) => x !== "titleSlides")) doc.footer = next;
      else delete doc.footer;
    }, { structure: true });
  return section(
    "Fusszeile",
    textField("Text", f.text, (v) => set("text", v.trim()), { maxLength: 500, ariaLabel: "Fusszeilentext" }),
    selectField("Datum", f.date || "none", [["none", "Kein Datum"], ["auto", "Aktuelles Datum"], ["fixed", "Festes Datum"]],
      (v) => set("date", v === "none" ? undefined : v)),
    f.date === "fixed"
      ? textField("Datumstext", f.dateText, (v) => set("dateText", v.trim()), { maxLength: 500, ariaLabel: "Festes Datum" })
      : null,
    checkField("Foliennummer", !!f.number, (on) => set("number", on)),
    doc.footer ? checkField("Auch auf Titelfolien", !!f.titleSlides, (on) => set("titleSlides", on)) : null,
  );
}

const TYPE_NAMES = {
  text: "Textfeld",
  shape: "Form",
  line: "Linie",
  image: "Bild",
  video: "Video",
  table: "Tabelle",
};

function elementSection(el) {
  const r = resolved(el);
  const setStyle = (k, v) =>
    change(() => {
      el.style = Object.assign({}, el.style);
      if (v === undefined) delete el.style[k];
      else el.style[k] = v;
    });
  const geo = (k, label) =>
    numberField(label, r[k], (n) =>
      change(() => {
        ownGeometry(el);
        el[k] = Math.round(n);
      }),
    );
  const ph = r.placeholder;
  const children = [
    ph
      ? h(
          "p",
          { class: "muted small" },
          "Platzhalter «" + ph.label + "»",
          el.x !== undefined || el.style
            ? h("button", {
                type: "button",
                class: "small",
                text: "Auf Layout zurücksetzen",
                on: { click: () => change(() => ops.resetToLayout(el)) },
              })
            : null,
        )
      : null,
    h("div", { class: "field-grid" }, geo("x", "X"), geo("y", "Y"), geo("w", "Breite"), geo("h", "Höhe")),
    el.type !== "line"
      ? numberField("Drehung (°)", r.rot || 0, (n) =>
          change(() => {
            ownGeometry(el);
            if (n % 360 === 0) delete el.rot;
            else el.rot = Math.max(-360, Math.min(360, n));
          }),
        )
      : null,
  ];

  if (el.type === "text") {
    children.push(
      selectField(
        "Schrift",
        r.style.font || "body",
        [["heading", "Titel"], ["body", "Text"], ["code", "Code"]],
        (v) => setStyle("font", v),
      ),
      numberField("Grösse", r.style.size, (n) => setStyle("size", Math.max(1, Math.min(1000, n))), {
        min: 1,
        max: 1000,
      }),
      h("label", { class: "field" }, h("span", { text: "Textfarbe" }),
        colorField(r.style.color, (c) => setStyle("color", c || "text"))),
      selectField(
        "Vertikal",
        r.style.valign || "top",
        [["top", "Oben"], ["middle", "Mitte"], ["bottom", "Unten"]],
        (v) => setStyle("valign", v),
      ),
      h("label", { class: "field" }, h("span", { text: "Füllung" }),
        colorField(r.style.fill || "none", (c) => setStyle("fill", c === "none" ? undefined : c), { none: true })),
      numberField("Innenabstand", r.style.pad || 0, (n) => setStyle("pad", Math.max(0, Math.min(400, n))), {
        min: 0,
        max: 400,
      }),
    );
  }
  if (el.type === "table") children.push(...tableFields(el, r, setStyle));
  if (el.type === "shape") {
    children.push(
      selectField(
        "Form",
        el.shape || "rect",
        [
          ["rect", "Rechteck"],
          ["rounded", "Abgerundet"],
          ["ellipse", "Ellipse"],
          ["triangle", "Dreieck"],
          ["arrow", "Pfeil"],
          ["chevron", "Chevron"],
        ],
        (v) => change(() => (el.shape = v)),
      ),
      h("label", { class: "field" }, h("span", { text: "Füllung" }),
        colorField(r.style.fill || "accent", (c) => setStyle("fill", c), { none: true })),
      h("label", { class: "field" }, h("span", { text: "Rahmen" }),
        colorField(r.style.stroke || "none", (c) => setStyle("stroke", c), { none: true })),
      numberField("Rahmenbreite", r.style.strokeWidth || 0, (n) =>
        setStyle("strokeWidth", Math.max(0, Math.min(1000, n))), { min: 0, max: 1000 }),
    );
  }
  if (el.type === "line") {
    children.push(
      h("label", { class: "field" }, h("span", { text: "Farbe" }),
        colorField(r.style.stroke || "text", (c) => setStyle("stroke", c))),
      numberField("Strichbreite", r.style.strokeWidth || 4, (n) =>
        setStyle("strokeWidth", Math.max(0, Math.min(1000, n))), { min: 0, max: 1000 }),
      h(
        "label",
        { class: "check" },
        h("input", {
          type: "checkbox",
          checked: !!el.flip,
          on: { change: (e) => change(() => (e.target.checked ? (el.flip = true) : delete el.flip)) },
        }),
        " Gespiegelt (/ statt \\)",
      ),
    );
  }
  if (el.type === "image" || el.type === "video") {
    const check = (key, label) =>
      h(
        "label",
        { class: "check" },
        h("input", {
          type: "checkbox",
          checked: !!el[key],
          on: { change: (e) => change(() => (e.target.checked ? (el[key] = true) : delete el[key])) },
        }),
        " " + label,
      );
    const alt = h("textarea", {
      class: "alt-text",
      rows: 2,
      maxLength: 2000,
      value: el.alt || "",
      placeholder: "Was zeigt das Bild? (für Screenreader)",
      "aria-label": "Alternativtext",
    });
    alt.addEventListener("change", () =>
      change(() => {
        if (alt.value.trim()) el.alt = alt.value.trim();
        else delete el.alt;
      }),
    );
    children.push(
      h("button", {
        type: "button",
        class: "small",
        text: el.asset ? "Ersetzen …" : "Datei wählen …",
        on: { click: () => pickFiles(false, (files) => insertMedia(files, null, el.id)) },
      }),
      selectField("Einpassen", el.fit || "contain", [["contain", "Ganz zeigen"], ["cover", "Füllen"]], (v) =>
        change(() => (el.fit = v)),
      ),
      el.type === "image" ? h("label", { class: "field stacked" }, h("span", { text: "Alternativtext" }), alt) : null,
      el.type === "video" ? check("autoplay", "Beim Zeigen abspielen") : null,
      el.type === "video" ? check("loop", "Endlos wiederholen") : null,
      el.type === "video" ? check("muted", "Ton aus") : null,
    );
  }
  const BUILDS = [
    ["", "Kein Aufbau"],
    ["appear", "Erscheinen"],
    ["fade", "Einblenden"],
    ["fly-left", "Von links"],
    ["fly-right", "Von rechts"],
    ["fly-up", "Von unten"],
    ["fly-down", "Von oben"],
    ["zoom", "Zoomen"],
  ];
  const maxOrder = () => Math.max(0, ...slide().elements.map((x) => (x.build ? x.build.order : 0)));
  children.push(
    selectField("Aufbau", el.build ? el.build.effect || "appear" : "", BUILDS, (v) =>
      change(() => {
        if (!v) delete el.build;
        else el.build = { order: el.build ? el.build.order : maxOrder() + 1, effect: v };
      }),
    ),
    el.build
      ? numberField("Reihenfolge", el.build.order, (n) =>
          change(() => (el.build.order = Math.max(1, Math.min(1000, Math.round(n))))),
        { min: 1, max: 1000 })
      : null,
  );
  children.push(
    numberField("Deckkraft (%)", Math.round((r.style.opacity === undefined ? 1 : r.style.opacity) * 100), (n) =>
      setStyle("opacity", n >= 100 ? undefined : Math.max(0, Math.min(100, n)) / 100), { min: 0, max: 100 }),
  );
  return section(TYPE_NAMES[el.type] || el.type, ...children);
}

// Table properties: text style, header row, rows and columns. Rows and
// columns are added and removed next to the cell being edited (else at
// the end).
function tableFields(el, r, setStyle) {
  const t = el.table;
  const at = editing && editing.id === el.id ? editing.cell : null;
  const row = at ? at[0] : t.rows.length - 1;
  const col = at ? at[1] : t.rows[0].length - 1;
  const act = (label, title, f) =>
    h("button", {
      type: "button",
      class: "small",
      text: label,
      title,
      on: {
        click: () => {
          if (editing) stopEditing();
          change(() => f(t));
        },
      },
    });
  return [
    numberField("Grösse", r.style.size, (n) => setStyle("size", Math.max(1, Math.min(1000, n))), {
      min: 1,
      max: 1000,
    }),
    h("label", { class: "field" }, h("span", { text: "Textfarbe" }),
      colorField(r.style.color, (c) => setStyle("color", c || "text"))),
    h(
      "label",
      { class: "check" },
      h("input", {
        type: "checkbox",
        checked: !!t.header,
        on: { change: (e) => change(() => (e.target.checked ? (t.header = true) : delete t.header)) },
      }),
      " Kopfzeile",
    ),
    h("p", { class: "muted small", text: t.rows.length + " Zeilen × " + t.rows[0].length + " Spalten" }),
    h(
      "div",
      { class: "align-grid" },
      act("↑+", "Zeile darüber einfügen", (t) => ops.insertRow(t, row)),
      act("↓+", "Zeile darunter einfügen", (t) => ops.insertRow(t, row + 1)),
      act("−", "Zeile löschen", (t) => ops.deleteRow(t, row)),
      act("←+", "Spalte links einfügen", (t) => ops.insertColumn(t, col)),
      act("→+", "Spalte rechts einfügen", (t) => ops.insertColumn(t, col + 1)),
      act("|−", "Spalte löschen", (t) => ops.deleteColumn(t, col)),
    ),
  ];
}

// --- start ----------------------------------------------------------

function renderAll() {
  fillNewSlideSelect();
  renderSlideList();
  renderCanvas();
  renderNotesEditor();
  renderPanel();
  updateToolbar();
}

async function getJSON(url) {
  const r = await fetch(url, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(url + ": " + r.status);
  return r.json();
}

async function main() {
  const [d, ds] = await Promise.all([getJSON(urls.deckUrl), getJSON(urls.designsUrl)]);
  designs = designMap(ds);
  doc = d.doc;
  deck = { id: d.id, title: d.title, design: d.design, status: d.status, revision: d.revision };
  design = designs.get(deck.design);
  const fromHash = parseInt(location.hash.slice(1), 10);
  if (Number.isFinite(fromHash)) cur = Math.max(0, Math.min(doc.slides.length - 1, fromHash - 1));
  buildSkeleton();
  await Promise.all([
    document.fonts.load("400 40px Inter"),
    document.fonts.load("900 40px Inter"),
  ]).catch(() => {});
  layoutStage();
  renderAll();
}

main().catch((err) => {
  root.replaceChildren(h("p", { class: "viewer-error", text: "Der Editor konnte nicht geladen werden." }));
  console.error(err);
});
