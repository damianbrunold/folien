// The read-only deck viewer on the deck page: thumbnails, the current
// slide large, its notes. Arrow keys, Page Up/Down, Home and End move
// between slides; the slide number is kept in the URL hash (#3).
//
// The page provides <div id="viewer" data-deck-url data-designs-url>.

import {
  designMap,
  fitInto,
  renderSlide,
  renderNotes,
} from "./render.js";

const root = document.getElementById("viewer");

async function getJSON(url) {
  const r = await fetch(url, { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error(url + ": " + r.status);
  return r.json();
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

async function main() {
  const [deck, designs] = await Promise.all([
    getJSON(root.dataset.deckUrl),
    getJSON(root.dataset.designsUrl),
  ]);
  const design = designMap(designs).get(deck.design);
  const slides = deck.doc.slides;

  const thumbs = el("div", "viewer-thumbs");
  const main = el("div", "viewer-main");
  const frame = el("div", "slide-frame");
  const bar = el("div", "viewer-bar");
  const prev = el("button", "small", "‹ Zurück");
  const next = el("button", "small", "Weiter ›");
  const counter = el("span");
  const notes = el("div", "viewer-notes");
  prev.type = next.type = "button";
  bar.append(prev, counter, next, el("span", "spacer"));
  main.append(frame, bar, notes);
  root.replaceChildren(thumbs, main);

  let current = 0;
  let unfit = null;
  const byId = new Map(slides.map((s, i) => [s.id, i]));
  const assetUrl = (sha) => root.dataset.deckUrl + "/assets/" + sha;
  const ctx = { assetUrl, videoControls: true, onLink: (id) => byId.has(id) && show(byId.get(id)) };

  const thumbButtons = slides.map((slide, i) => {
    const b = el("button", "thumb");
    b.type = "button";
    b.setAttribute("aria-label", "Folie " + (i + 1));
    if (slide.hidden) b.classList.add("hidden-slide");
    const f = el("div", "slide-frame");
    b.append(el("span", "num", String(i + 1)), f);
    b.addEventListener("click", () => show(i));
    thumbs.appendChild(b);
    fitInto(f, renderSlide(slide, design, { assetUrl, doc: deck.doc, index: i }));
    return b;
  });

  function show(i) {
    current = Math.max(0, Math.min(slides.length - 1, i));
    if (unfit) unfit();
    unfit = fitInto(frame, renderSlide(slides[current], design, { ...ctx, doc: deck.doc, index: current }));
    renderNotes(notes, slides[current].notes);
    counter.textContent = current + 1 + " / " + slides.length;
    prev.disabled = current === 0;
    next.disabled = current === slides.length - 1;
    thumbButtons.forEach((b, j) => b.classList.toggle("current", j === current));
    thumbButtons[current].scrollIntoView({ block: "nearest" });
    history.replaceState(null, "", "#" + (current + 1));
  }

  prev.addEventListener("click", () => show(current - 1));
  next.addEventListener("click", () => show(current + 1));
  document.addEventListener("keydown", (e) => {
    if (e.target.closest("input, textarea, select")) return;
    const k = e.key;
    if (k === "ArrowRight" || k === "ArrowDown" || k === "PageDown") show(current + 1);
    else if (k === "ArrowLeft" || k === "ArrowUp" || k === "PageUp") show(current - 1);
    else if (k === "Home") show(0);
    else if (k === "End") show(slides.length - 1);
    else return;
    e.preventDefault();
  });

  const fromHash = parseInt(location.hash.slice(1), 10);
  // Draw once the slide fonts are in, so the first paint has the right
  // line breaks.
  await Promise.all([
    document.fonts.load("400 40px Inter"),
    document.fonts.load("900 40px Inter"),
  ]).catch(() => {});
  show(Number.isFinite(fromHash) ? fromHash - 1 : 0);
}

main().catch((err) => {
  root.replaceChildren(el("p", "viewer-error", "Die Präsentation konnte nicht geladen werden."));
  console.error(err);
});
