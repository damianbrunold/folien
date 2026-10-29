// The read-only deck viewer on the deck page: thumbnails, the current
// slide large, its notes. Arrow keys, Page Up/Down, Home and End move
// between slides; the slide number is kept in the URL hash (#3). F5
// presents from the start, Shift+F5 from the slide shown, Alt+F5 opens the
// presenter console there.
//
// The page provides <div id="viewer" data-deck-url data-designs-url
// data-present-url data-presenter-url>.

import {
  designMap,
  fitInto,
  loadDesignFonts,
  renderSlide,
  renderNotes,
} from "./render.js";
import { installShortcutHelp, isTyping } from "./shortcuts.js";
import { remoteQrParts } from "./remote-qr.js";

const root = document.getElementById("viewer");

// The "QR-Code" button beside "Fernbedienung": shows or hides the
// remote's address as a QR code below the actions.
function wireRemoteQr() {
  const btn = document.querySelector(".js-remote-qr");
  if (!btn) return;
  btn.hidden = false;
  let box = null;
  btn.addEventListener("click", () => {
    if (box) {
      box.remove();
      box = null;
      btn.setAttribute("aria-expanded", "false");
      return;
    }
    box = document.createElement("div");
    box.id = "remote-qr-box";
    box.className = "remote-qr-box";
    box.append(...remoteQrParts(btn.dataset.remoteUrl, root.dataset.deckUrl));
    btn.closest(".actions").after(box);
    btn.setAttribute("aria-expanded", "true");
  });
}
wireRemoteQr();

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
  // Thumbnails get downscaled copies of images (videos ignore ?w).
  const thumbUrl = (sha) => assetUrl(sha) + "?w=640";
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
    fitInto(f, renderSlide(slide, design, { assetUrl: thumbUrl, doc: deck.doc, index: i }));
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
  installShortcutHelp("Tastenkürzel der Folienansicht", () => [
    [
      "Folien",
      [
        ["→ / ↓ / Bild ab", "Nächste Folie"],
        ["← / ↑ / Bild auf", "Vorherige Folie"],
        ["Pos1 / Ende", "Erste / letzte Folie"],
        ["F5", "Präsentieren ab der ersten Folie"],
        ["Umschalt+F5", "Präsentieren ab dieser Folie"],
        ["Alt+F5", "Referentenansicht ab dieser Folie"],
        ["? / F1", "Diese Hilfe"],
      ],
    ],
  ]);
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || isTyping(e.target) || e.target.closest("dialog")) return;
    const k = e.key;
    if (k === "F5" && !e.ctrlKey && !e.metaKey && root.dataset.presentUrl) {
      e.preventDefault();
      const base = e.altKey ? root.dataset.presenterUrl : root.dataset.presentUrl;
      window.open(base + "#" + (e.shiftKey || e.altKey ? current + 1 : 1), "_blank");
      return;
    }
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
  await loadDesignFonts(design);
  show(Number.isFinite(fromHash) ? fromHash - 1 : 0);
}

main().catch((err) => {
  root.replaceChildren(el("p", "viewer-error", "Die Präsentation konnte nicht geladen werden."));
  console.error(err);
});
