// Operations on the deck document used by the editor: new and copied
// slides and elements, layout changes, geometry. They mirror the server's
// (app model) where both create things (new-slide). No DOM, so tested
// with node (tests/js/).

import { findLayout, resolveElement } from "./render.js";
import { emptyText } from "./richtext-model.js";

const ID_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789";

export function newId() {
  const bytes = new Uint8Array(12);
  crypto.getRandomValues(bytes);
  let s = "";
  for (const b of bytes) s += ID_CHARS[b % ID_CHARS.length];
  return s;
}

function placeholderElement(role) {
  return role === "image"
    ? { id: newId(), type: "image", placeholder: role }
    : { id: newId(), type: "text", placeholder: role, text: emptyText() };
}

// A slide with layoutId: one element per placeholder, as (new-slide).
export function newSlide(design, layoutId) {
  const layout = findLayout(design, layoutId);
  return {
    id: newId(),
    layout: layoutId,
    elements: layout ? layout.placeholders.map((ph) => placeholderElement(ph.role)) : [],
  };
}

export function copyElement(el) {
  const c = JSON.parse(JSON.stringify(el));
  c.id = newId();
  return c;
}

// A copy of a slide with fresh ids for it and its elements.
export function copySlide(slide) {
  const c = JSON.parse(JSON.stringify(slide));
  c.id = newId();
  c.elements = c.elements.map((el) => Object.assign(el, { id: newId() }));
  return c;
}

function isEmptyElement(el) {
  if (el.type === "text") {
    return !el.text || el.text.paragraphs.every((p) => p.runs.every((r) => r.text === ""));
  }
  if (el.type === "image" || el.type === "video") return !el.asset;
  return false;
}

// Switches a slide to another layout of the design. Placeholders whose
// role the new layout has keep their content (and inherit the new
// position); the others keep their content as free elements where they
// were, or go if they were empty. New roles get empty placeholders.
export function changeLayout(design, slide, layoutId) {
  const oldLayout = findLayout(design, slide.layout);
  const newLayout = findLayout(design, layoutId);
  if (!newLayout) return;
  const roles = new Set(newLayout.placeholders.map((p) => p.role));
  const seen = new Set();
  const elements = [];
  for (const el of slide.elements) {
    if (!el.placeholder) {
      elements.push(el);
    } else if (roles.has(el.placeholder) && !seen.has(el.placeholder)) {
      seen.add(el.placeholder);
      for (const k of ["x", "y", "w", "h", "rot"]) delete el[k];
      elements.push(el);
    } else if (!isEmptyElement(el)) {
      materialize(oldLayout, el, true);
      elements.push(el);
    }
  }
  for (const el of elements) {
    if (el.placeholder && !roles.has(el.placeholder)) delete el.placeholder;
  }
  for (const ph of newLayout.placeholders) {
    if (!seen.has(ph.role)) elements.push(placeholderElement(ph.role));
  }
  slide.layout = layoutId;
  slide.elements = elements;
}

// Gives a placeholder element its inherited geometry as its own, so it
// can be moved and sized freely (it keeps its role). withStyle: also take
// over the inherited text style, for an element that is about to lose
// its role.
export function materialize(layout, el, withStyle) {
  const r = resolveElement(layout, el);
  el.x = r.x;
  el.y = r.y;
  el.w = r.w;
  el.h = r.h;
  if (withStyle) el.style = Object.assign({}, r.style);
}

// Drops a placeholder element's own geometry and style, so the layout's
// apply again.
export function resetToLayout(el) {
  for (const k of ["x", "y", "w", "h", "rot", "style"]) delete el[k];
}

// The axis-aligned bounding box of a resolved element (rotation included).
export function bounds(r) {
  if (!r.rot) return { x: r.x, y: r.y, w: r.w, h: r.h };
  const a = (r.rot * Math.PI) / 180;
  const cos = Math.abs(Math.cos(a));
  const sin = Math.abs(Math.sin(a));
  const w = r.w * cos + r.h * sin;
  const h = r.w * sin + r.h * cos;
  return { x: r.x + r.w / 2 - w / 2, y: r.y + r.h / 2 - h / 2, w, h };
}

// True if slide point (px, py) is inside the resolved element, grown by
// pad on each side (rotation included).
export function hits(r, px, py, pad) {
  let x = px;
  let y = py;
  if (r.rot) {
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const a = (-r.rot * Math.PI) / 180;
    const dx = px - cx;
    const dy = py - cy;
    x = cx + dx * Math.cos(a) - dy * Math.sin(a);
    y = cy + dx * Math.sin(a) + dy * Math.cos(a);
  }
  return x >= r.x - pad && x <= r.x + r.w + pad && y >= r.y - pad && y <= r.y + r.h + pad;
}

export function moveItem(arr, from, to) {
  const [x] = arr.splice(from, 1);
  arr.splice(to, 0, x);
}

// Snapping: the offset (or null) that moves one of the values in ours
// onto one of the targets, if one is within tolerance.
export function snapOffset(ours, targets, tolerance) {
  let best = null;
  for (const o of ours) {
    for (const t of targets) {
      const d = t - o;
      if (Math.abs(d) <= tolerance && (best === null || Math.abs(d) < Math.abs(best.d))) {
        best = { d, at: t };
      }
    }
  }
  return best;
}
