// The slide renderer: draws a slide of a deck document as DOM, in slide
// coordinates (1920 x 1080 units = CSS pixels), and scales it into a
// frame. Shared by the viewer, the thumbnails, and later the editor, the
// player, the presenter console and the offline player, so that a slide
// looks the same everywhere.
//
// The document format is described in src/app-model.sld, the designs in
// src/app-designs.sld (served as JSON by /api/designs). Only element.style
// is set from script: the CSP forbids style attributes in markup, not
// CSSOM.

export const SLIDE_W = 1920;
export const SLIDE_H = 1080;

const SVG_NS = "http://www.w3.org/2000/svg";

// --- designs ----------------------------------------------------------

export function designMap(designs) {
  const m = new Map();
  for (const d of designs) m.set(d.id, d);
  return m;
}

export function findLayout(design, id) {
  return design.layouts.find((l) => l.id === id) || null;
}

// A colour token ("accent") or "#rrggbb" as a CSS colour.
export function cssColor(design, c) {
  if (!c || c === "none") return "transparent";
  if (c[0] === "#") return c;
  return design.colors[c] || design.colors.text;
}

function fontOf(design, token) {
  return design.fonts[token] || design.fonts.body;
}

// The geometry and style an element is drawn with: its own, over those of
// its layout placeholder when it is one.
export function resolveElement(layout, el) {
  const ph =
    el.placeholder && layout
      ? layout.placeholders.find((p) => p.role === el.placeholder)
      : null;
  const pick = (k, dflt) => (el[k] !== undefined ? el[k] : ph ? ph[k] : dflt);
  return {
    el,
    placeholder: ph,
    x: pick("x", 0),
    y: pick("y", 0),
    w: pick("w", 100),
    h: pick("h", 100),
    rot: el.rot || 0,
    style: Object.assign({}, ph ? ph.style : {}, el.style || {}),
  };
}

// --- helpers ----------------------------------------------------------

function div(cls) {
  const d = document.createElement("div");
  if (cls) d.className = cls;
  return d;
}

function place(node, r) {
  node.style.left = r.x + "px";
  node.style.top = r.y + "px";
  node.style.width = r.w + "px";
  node.style.height = r.h + "px";
  if (r.rot) node.style.transform = "rotate(" + r.rot + "deg)";
}

// True if a rich text has no visible characters.
export function isEmptyText(text) {
  if (!text || !text.paragraphs) return true;
  return text.paragraphs.every((p) => p.runs.every((r) => r.text === ""));
}

// --- rich text --------------------------------------------------------

// Fills target with the paragraphs of a rich text. base: the box's text
// style {font, size, color, align}; sizes are slide units. ctx.onLink is
// called for "#slide-..." links.
export function renderRichText(target, text, base, design, ctx) {
  const font = fontOf(design, base.font);
  const settings = design.text;
  // Per list level: the running number and the list type it counts.
  const counters = [];
  const kinds = [];
  for (const para of text.paragraphs || []) {
    const p = div("para");
    p.style.textAlign = para.align || base.align || "left";
    const level = para.level || 0;
    const list = para.list || "none";
    // The paragraph's first run sets the size used for spacing and markers.
    const size = (para.runs[0] && para.runs[0].size) || base.size;
    p.style.marginBottom = settings.paraSpacing * size + "px";
    if (list !== "none") {
      counters.length = kinds.length = level + 1;
      if (kinds[level] !== list) counters[level] = 0;
      kinds[level] = list;
      counters[level] = (counters[level] || 0) + 1;
      p.classList.add("list");
      p.style.paddingLeft = (level + 1) * 1.1 * size + "px";
      const marker = document.createElement("span");
      marker.className = "marker";
      marker.textContent =
        list === "number" ? counters[level] + "." : settings.bullet;
      marker.style.width = 1.1 * size + "px";
      marker.style.marginLeft = -1.1 * size + "px";
      p.appendChild(marker);
    } else {
      counters.length = kinds.length = 0;
    }
    let any = false;
    for (const run of para.runs) {
      if (run.text === "") continue;
      any = true;
      let node;
      if (run.link) {
        node = document.createElement("a");
        node.href = run.link;
        if (run.link.startsWith("#slide-")) {
          node.addEventListener("click", (e) => {
            e.preventDefault();
            if (ctx.onLink) ctx.onLink(run.link.slice(7));
          });
        } else {
          node.target = "_blank";
          node.rel = "noopener noreferrer";
        }
      } else {
        node = document.createElement("span");
      }
      node.textContent = run.text;
      if (run.b) node.style.fontWeight = "900";
      if (run.i) node.style.fontStyle = "italic";
      if (run.u) node.style.textDecoration = "underline";
      if (run.color) node.style.color = cssColor(design, run.color);
      if (run.size) node.style.fontSize = run.size + "px";
      p.appendChild(node);
    }
    // An empty paragraph keeps its line.
    if (!any) p.appendChild(document.createElement("br"));
    target.appendChild(p);
  }
  target.style.fontFamily = font.family + ", Arial, Helvetica, sans-serif";
  target.style.fontWeight = String(font.weight);
  target.style.fontSize = base.size + "px";
  target.style.lineHeight = String(settings.lineHeight);
  target.style.color = cssColor(design, base.color);
}

// --- elements ---------------------------------------------------------

function renderText(r, design, ctx) {
  const box = div("el el-text");
  place(box, r);
  const s = r.style;
  box.classList.add("valign-" + (s.valign || "top"));
  if (s.fill) box.style.backgroundColor = cssColor(design, s.fill);
  const inner = div("text-inner");
  const text = r.el.text || { paragraphs: [] };
  if (isEmptyText(text) && r.placeholder && ctx.editing) {
    // The prompt of an empty placeholder, only while editing.
    inner.classList.add("prompt");
    renderRichText(
      inner,
      { paragraphs: [{ runs: [{ text: r.placeholder.label }] }] },
      s,
      design,
      ctx,
    );
  } else {
    renderRichText(inner, text, s, design, ctx);
  }
  box.appendChild(inner);
  return box;
}

// Tables: equal columns; each row is at least h / rows high and grows
// with its text (the PDF and PPTX exports size rows the same way). The
// header row is set in the heading font on the accent colour, body rows
// are banded; text is centred vertically in its cell. Cells carry
// data-r/data-c for the editor.
export const TABLE_PAD_X = 16;
export const TABLE_PAD_Y = 10;

// The text style of a cell: the element's, header cells in the heading
// font on the accent colour.
export function cellStyle(style, header) {
  return header ? Object.assign({}, style, { font: "heading", color: "on-accent" }) : style;
}

// The fill token of row i: the header on the accent colour, body rows
// banded.
export function tableRowFill(table, i) {
  if (i === 0 && table.header) return "accent";
  return (i - (table.header ? 1 : 0)) % 2 === 1 ? "light" : "background";
}

function renderTable(r, design, ctx) {
  const box = div("el el-table");
  place(box, r);
  const table = r.el.table || { rows: [] };
  const rows = table.rows;
  const cols = rows.length ? rows[0].length : 1;
  box.style.gridTemplateColumns = "repeat(" + cols + ", minmax(0, 1fr))";
  box.style.gridAutoRows = "minmax(" + r.h / Math.max(rows.length, 1) + "px, auto)";
  rows.forEach((row, i) => {
    const header = i === 0 && !!table.header;
    const fill = tableRowFill(table, i);
    row.forEach((cell, j) => {
      const c = div("cell");
      c.dataset.r = i;
      c.dataset.c = j;
      c.style.padding = TABLE_PAD_Y + "px " + TABLE_PAD_X + "px";
      c.style.backgroundColor = cssColor(design, fill);
      const inner = div("text-inner");
      renderRichText(inner, cell, cellStyle(r.style, header), design, ctx);
      c.appendChild(inner);
      box.appendChild(c);
    });
  });
  return box;
}

function renderShape(r, design) {
  const s = r.style;
  const kind = r.el.shape || "rect";
  const fill = cssColor(design, s.fill || "accent");
  const stroke = cssColor(design, s.stroke || "none");
  const sw = s.strokeWidth || 0;
  if (kind === "rect" || kind === "rounded" || kind === "ellipse") {
    const d = div("el el-shape");
    place(d, r);
    d.style.backgroundColor = fill;
    if (sw > 0 && stroke !== "transparent") {
      d.style.border = sw + "px solid " + stroke;
    }
    if (kind === "ellipse") d.style.borderRadius = "50%";
    if (kind === "rounded") d.style.borderRadius = Math.min(r.w, r.h) * 0.12 + "px";
    return d;
  }
  // Other shapes as SVG paths in the element's box.
  const d = div("el el-shape");
  place(d, r);
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 " + r.w + " " + r.h);
  svg.setAttribute("width", r.w);
  svg.setAttribute("height", r.h);
  svg.setAttribute("preserveAspectRatio", "none");
  const path = document.createElementNS(SVG_NS, "path");
  path.setAttribute("d", shapePath(kind, r.w, r.h));
  path.setAttribute("fill", fill);
  if (sw > 0) {
    path.setAttribute("stroke", stroke);
    path.setAttribute("stroke-width", sw);
  }
  svg.appendChild(path);
  d.appendChild(svg);
  return d;
}

export function shapePath(kind, w, h) {
  switch (kind) {
    case "triangle":
      return `M${w / 2} 0 L${w} ${h} L0 ${h} Z`;
    case "arrow": {
      const t = h * 0.3;
      const head = Math.min(w * 0.4, h);
      return `M0 ${t} L${w - head} ${t} L${w - head} 0 L${w} ${h / 2} L${w - head} ${h} L${w - head} ${h - t} L0 ${h - t} Z`;
    }
    case "chevron": {
      const k = Math.min(w * 0.4, h / 2);
      return `M0 0 L${w - k} 0 L${w} ${h / 2} L${w - k} ${h} L0 ${h} L${k} ${h / 2} Z`;
    }
    default:
      return `M0 0 H${w} V${h} H0 Z`;
  }
}

function renderLine(r, design) {
  // A line from the box's top-left to its bottom-right corner (w or h may
  // be 0); "flip" draws the other diagonal.
  const s = r.style;
  const sw = s.strokeWidth || 4;
  const d = div("el el-line");
  place(d, { x: r.x, y: r.y, w: Math.max(r.w, 1), h: Math.max(r.h, 1), rot: r.rot });
  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("width", Math.max(r.w, 1));
  svg.setAttribute("height", Math.max(r.h, 1));
  svg.setAttribute("overflow", "visible");
  const line = document.createElementNS(SVG_NS, "line");
  const flip = !!r.el.flip;
  line.setAttribute("x1", 0);
  line.setAttribute("y1", flip ? r.h : 0);
  line.setAttribute("x2", r.w);
  line.setAttribute("y2", flip ? 0 : r.h);
  line.setAttribute("stroke", cssColor(design, s.stroke || "text"));
  line.setAttribute("stroke-width", sw);
  line.setAttribute("stroke-linecap", "round");
  svg.appendChild(line);
  d.appendChild(svg);
  return d;
}

function renderMedia(r, design, ctx) {
  const box = div("el el-media");
  place(box, r);
  const el = r.el;
  if (!el.asset) {
    if (ctx.editing) {
      box.classList.add("empty");
      box.textContent = r.placeholder ? r.placeholder.label : "Bild";
    }
    return box;
  }
  const url = ctx.assetUrl ? ctx.assetUrl(el.asset) : "";
  let media;
  if (el.type === "video") {
    media = document.createElement("video");
    media.src = url;
    if (el.poster && ctx.assetUrl) media.poster = ctx.assetUrl(el.poster);
    media.preload = "metadata";
    media.playsInline = true;
    media.loop = !!el.loop;
    media.muted = !!el.muted;
    if (ctx.videoControls) media.controls = true;
  } else {
    media = document.createElement("img");
    media.src = url;
    media.alt = el.alt || "";
    media.draggable = false;
  }
  media.style.objectFit = el.fit || "contain";
  box.appendChild(media);
  return box;
}

function renderElement(r, design, ctx) {
  switch (r.el.type) {
    case "text":
      return renderText(r, design, ctx);
    case "shape":
      return renderShape(r, design);
    case "line":
      return renderLine(r, design);
    case "image":
    case "video":
      return renderMedia(r, design, ctx);
    case "table":
      return renderTable(r, design, ctx);
    default:
      return null;
  }
}

// --- slides -----------------------------------------------------------

// The highest build step of a slide (0 if nothing builds).
export function buildSteps(slide) {
  let n = 0;
  for (const el of slide.elements) if (el.build) n = Math.max(n, el.build.order);
  return n;
}

// A slide as a 1920 x 1080 element. ctx:
//   editing       show prompts of empty placeholders
//   step          build step shown (elements with build.order > step are
//                 hidden); default: everything
//   assetUrl(id)  the URL of an uploaded asset
//   onLink(id)    a "#slide-<id>" link was clicked
//   videoControls show the controls of videos
export function renderSlide(slide, design, ctx = {}) {
  const root = div("slide");
  root.style.width = SLIDE_W + "px";
  root.style.height = SLIDE_H + "px";
  root.style.backgroundColor = cssColor(design, slide.background || "background");
  const layout = findLayout(design, slide.layout);
  if (layout) {
    for (const deco of layout.decorations) {
      const node = renderElement(resolveElement(null, deco), design, ctx);
      if (node) {
        node.classList.add("deco");
        root.appendChild(node);
      }
    }
  }
  const step = ctx.step === undefined ? Infinity : ctx.step;
  for (const el of slide.elements) {
    const r = resolveElement(layout, el);
    const node = renderElement(r, design, ctx);
    if (!node) continue;
    node.dataset.id = el.id;
    if (r.style.opacity !== undefined) node.style.opacity = String(r.style.opacity);
    if (el.build) {
      node.dataset.build = el.build.order;
      node.dataset.effect = el.build.effect || "appear";
      if (el.build.order > step) node.classList.add("build-pending");
    }
    root.appendChild(node);
  }
  return root;
}

// Puts slideEl into frame (a box with the slide's aspect ratio) and keeps
// it scaled to the frame's width. Returns a function that stops that.
export function fitInto(frame, slideEl) {
  frame.replaceChildren(slideEl);
  const fit = () => {
    const s = frame.clientWidth / SLIDE_W;
    slideEl.style.transform = "scale(" + s + ")";
  };
  fit();
  const ro = new ResizeObserver(fit);
  ro.observe(frame);
  return () => ro.disconnect();
}

// Notes (rich text) as ordinary page text, not in slide units.
export function renderNotes(target, notes) {
  target.replaceChildren();
  if (!notes || isEmptyText(notes)) return false;
  for (const para of notes.paragraphs) {
    const p = document.createElement("p");
    for (const run of para.runs) {
      const s = document.createElement("span");
      s.textContent = run.text;
      if (run.b) s.style.fontWeight = "700";
      if (run.i) s.style.fontStyle = "italic";
      if (run.u) s.style.textDecoration = "underline";
      p.appendChild(s);
    }
    target.appendChild(p);
  }
  return true;
}
