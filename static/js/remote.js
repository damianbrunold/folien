// The remote control, for a phone: big Back and Next buttons, the slide
// number and its notes. It follows the presentation through the server
// and asks it to go to the position after or before the current one;
// the presentation answers with its new state.

import * as nav from "./deck-nav.js";
import { renderNotes } from "./render.js";
import { Sync, loadDeck } from "./sync.js";

const root = document.getElementById("remote");
const urls = root.dataset;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

async function main() {
  const { deck, doc } = await loadDeck(urls);
  document.title = deck.title + " (Fernbedienung) · Folien";

  const status = el("div", "r-status", "Verbinde …");
  const label = el("div", "r-label");
  const prevBtn = el("button", "r-btn r-prev", "‹");
  const nextBtn = el("button", "r-btn r-next", "Weiter ›");
  const blackBtn = el("button", "r-small", "Schwarz");
  const notes = el("div", "r-notes");
  for (const b of [prevBtn, nextBtn, blackBtn]) b.type = "button";
  prevBtn.setAttribute("aria-label", "Zurück");
  const buttons = el("div", "r-buttons");
  buttons.append(prevBtn, nextBtn);
  root.replaceChildren(el("h1", "r-title", deck.title), status, label, buttons, blackBtn, notes);

  let pos = nav.first(doc);
  let blanked = null;
  let heard = false; // has a presentation answered?

  function render() {
    label.textContent = "Folie " + nav.slideLabel(doc, pos);
    blackBtn.textContent = blanked === "black" ? "Bild wieder zeigen" : "Schwarz";
    if (!renderNotes(notes, doc.slides[pos.slide].notes)) notes.replaceChildren(el("p", "muted", "Keine Notizen."));
    prevBtn.disabled = !nav.prev(doc, pos);
    nextBtn.disabled = !nav.next(doc, pos);
  }

  const sync = new Sync({
    deckId: deck.id,
    eventsUrl: urls.eventsUrl,
    onConnection(ok) {
      if (!ok) status.textContent = "Keine Verbindung – versuche erneut …";
      else {
        status.textContent = heard ? "Verbunden" : "Verbunden – warte auf die Präsentation …";
        sync.remote({ type: "hello" });
      }
    },
    onMessage(m) {
      if (m.type !== "state") return;
      const p = nav.clampPos(doc, m.pos);
      if (!p) return;
      heard = true;
      status.textContent = "Verbunden";
      pos = p;
      blanked = m.blank || null;
      render();
    },
  });

  function goto(p) {
    if (!p) return;
    pos = p; // at once; the presentation confirms
    render();
    sync.remote({ type: "goto", pos: p });
    if (navigator.vibrate) navigator.vibrate(15);
  }

  nextBtn.addEventListener("click", () => goto(nav.next(doc, pos)));
  prevBtn.addEventListener("click", () => goto(nav.prev(doc, pos)));
  blackBtn.addEventListener("click", () => {
    blanked = blanked === "black" ? null : "black";
    render();
    sync.remote({ type: "blank", blank: blanked });
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight" || e.key === "PageDown" || e.key === " ") goto(nav.next(doc, pos));
    else if (e.key === "ArrowLeft" || e.key === "PageUp") goto(nav.prev(doc, pos));
    else return;
    e.preventDefault();
  });
  render();
}

main().catch((err) => {
  root.replaceChildren(el("p", "present-error", "Die Fernbedienung konnte nicht geladen werden."));
  console.error(err);
});
