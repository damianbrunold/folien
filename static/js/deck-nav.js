// Moving through a deck while presenting. A position is {slide, step}:
// the slide index and how many build steps of it are shown. Build steps
// are the distinct build orders of the slide's elements, ascending (so
// orders 1, 3 make two steps). Hidden slides are skipped, except the one
// you are on. Shared by the player, the presenter console and the remote;
// no DOM, so tested with node (tests/js/).

// The distinct build orders of a slide, ascending.
export function buildOrders(slide) {
  const set = new Set();
  for (const el of slide.elements) if (el.build && el.build.order) set.add(el.build.order);
  return [...set].sort((a, b) => a - b);
}

export function stepCount(slide) {
  return buildOrders(slide).length;
}

// The highest build order visible at step (for renderSlide's ctx.step).
export function visibleOrder(slide, step) {
  const orders = buildOrders(slide);
  return step <= 0 ? 0 : orders[Math.min(step, orders.length) - 1];
}

function visibleIndices(doc) {
  const out = [];
  doc.slides.forEach((s, i) => {
    if (!s.hidden) out.push(i);
  });
  return out;
}

export function first(doc) {
  const v = visibleIndices(doc);
  return { slide: v.length ? v[0] : 0, step: 0 };
}

export function last(doc) {
  const v = visibleIndices(doc);
  const i = v.length ? v[v.length - 1] : doc.slides.length - 1;
  return { slide: i, step: stepCount(doc.slides[i]) };
}

// The next position: the next build step, else the next visible slide
// with nothing built; null at the end.
export function next(doc, pos) {
  const s = doc.slides[pos.slide];
  if (s && pos.step < stepCount(s)) return { slide: pos.slide, step: pos.step + 1 };
  for (let i = pos.slide + 1; i < doc.slides.length; i++) {
    if (!doc.slides[i].hidden) return { slide: i, step: 0 };
  }
  return null;
}

// The previous position: one build step back, else the previous visible
// slide fully built; null at the start.
export function prev(doc, pos) {
  if (pos.step > 0) return { slide: pos.slide, step: pos.step - 1 };
  for (let i = pos.slide - 1; i >= 0; i--) {
    if (!doc.slides[i].hidden) return { slide: i, step: stepCount(doc.slides[i]) };
  }
  return null;
}

// Slide i (0-based), at its start; clamped into the deck.
export function slideStart(doc, i) {
  return { slide: Math.max(0, Math.min(doc.slides.length - 1, i)), step: 0 };
}

// A position from untrusted input (another window, the remote), clamped
// into the deck; null if it is not one.
export function clampPos(doc, pos) {
  if (!pos || !Number.isInteger(pos.slide) || !Number.isInteger(pos.step)) return null;
  if (pos.slide < 0 || pos.slide >= doc.slides.length) return null;
  const n = stepCount(doc.slides[pos.slide]);
  return { slide: pos.slide, step: Math.max(0, Math.min(n, pos.step)) };
}

export function samePos(a, b) {
  return !!a && !!b && a.slide === b.slide && a.step === b.step;
}

// "3 / 12" counting visible slides (a hidden slide shows its index).
export function slideLabel(doc, pos) {
  const v = visibleIndices(doc);
  const k = v.indexOf(pos.slide);
  return (k >= 0 ? k + 1 : pos.slide + 1) + " / " + v.length;
}
