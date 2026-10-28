// The presentation window: the deck full-window (F: fullscreen), driven
// by keys, clicks, swipes, the presenter console and the remote.
//
// Keys: → ↓ Space PageDown Enter N: next; ← ↑ PageUp Backspace P:
// previous; Home/End; B or .: black; W or ,: white; a number then Enter:
// that slide; F: fullscreen. After the last slide comes an end screen.

import { Player } from "./player.js";
import * as nav from "./deck-nav.js";
import { Sync, posFromHash, hashOf, loadDeck, presentKey } from "./sync.js";

const root = document.getElementById("present");
const urls = root.dataset;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

async function main() {
  const { deck, doc, design } = await loadDeck(urls);
  document.title = deck.title + " · Folien";

  const stage = el("div", "present-stage");
  const blank = el("div", "present-blank");
  const end = el("div", "present-end", "Ende der Präsentation – Esc oder ← zurück");
  const hint = el("div", "present-hint", "F Vollbild · ← → blättern · B schwarz · W weiss");
  const controls = el("div", "present-controls");
  const btn = (label, title, f) => {
    const b = el("button", "present-btn", label);
    b.type = "button";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.addEventListener("click", (e) => {
      e.stopPropagation();
      f();
    });
    return b;
  };
  const counter = el("span", "present-counter");
  controls.append(
    btn("‹", "Zurück", () => step("prev")),
    counter,
    btn("›", "Weiter", () => step("next")),
    btn("⛶", "Vollbild (F)", toggleFullscreen),
    btn("✕", "Beenden", () => (location.href = urls.viewUrl)),
  );
  root.replaceChildren(stage, blank, end, controls, hint);
  setTimeout(() => hint.classList.add("gone"), 3500);

  const assetUrl = (sha) => urls.deckUrl + "/assets/" + sha;
  const byId = new Map(doc.slides.map((s, i) => [s.id, i]));
  const player = new Player(stage, doc, design, {
    assetUrl,
    onLink: (id) => byId.has(id) && go(nav.slideStart(doc, byId.get(id)), "self"),
  });

  let pos = nav.clampPos(doc, posFromHash(location.hash)) || nav.first(doc);
  let blanked = null; // null, "black", "white"
  let atEnd = false;

  const sync = new Sync({
    deckId: deck.id,
    eventsUrl: urls.eventsUrl,
    onMessage(m, via) {
      if (m.type === "hello") {
        const state = { type: "state", pos, blank: blanked };
        if (via === "local") sync.local(state);
        else sync.remote(state);
        return;
      }
      if (m.type === "state" || m.type === "goto") {
        const p = nav.clampPos(doc, m.pos);
        if (p) go(p, "other");
      }
      if (m.type === "state" || m.type === "blank") setBlank(m.blank || null, "other");
      // Requests from the remote: confirm the new state to it.
      if (m.type === "goto" || m.type === "blank") sync.remote({ type: "state", pos, blank: blanked });
    },
  });

  function render() {
    blank.className = "present-blank" + (blanked ? " " + blanked : "");
    end.classList.toggle("shown", atEnd);
    counter.textContent = nav.slideLabel(doc, pos);
    history.replaceState(null, "", location.pathname + location.search + hashOf(pos));
  }

  function announce() {
    sync.both({ type: "state", pos, blank: blanked });
  }

  // origin "self": this window decided (tell the others); "other": it
  // came from another window or the remote.
  function go(p, origin) {
    atEnd = false;
    if (!nav.samePos(p, pos) || !player.pos) {
      pos = p;
      player.show(pos);
    }
    if (origin === "self") blanked = null;
    render();
    if (origin === "self") announce();
  }

  function setBlank(b, origin) {
    blanked = b;
    render();
    if (origin === "self") announce();
  }

  function step(what) {
    if (what === "next") {
      const n = nav.next(doc, pos);
      if (n) go(n, "self");
      else {
        atEnd = true;
        render();
      }
    } else if (what === "prev") {
      if (atEnd) {
        atEnd = false;
        render();
        return;
      }
      const p = nav.prev(doc, pos);
      if (p) go(p, "self");
    } else if (what === "first") go(nav.first(doc), "self");
    else if (what === "last") go(nav.last(doc), "self");
    else if (what === "black") setBlank(blanked === "black" ? null : "black", "self");
    else if (what === "white") setBlank(blanked === "white" ? null : "white", "self");
    else if (what === "fullscreen") toggleFullscreen();
  }

  function toggleFullscreen() {
    if (document.fullscreenElement) document.exitFullscreen().catch(() => {});
    else document.documentElement.requestFullscreen().catch(() => {});
  }

  // A number typed before Enter jumps to that slide.
  let digits = "";
  document.addEventListener("keydown", (e) => {
    if (/^[0-9]$/.test(e.key)) {
      digits += e.key;
      return;
    }
    if (e.key === "Enter" && digits) {
      go(nav.slideStart(doc, parseInt(digits, 10) - 1), "self");
      digits = "";
      e.preventDefault();
      return;
    }
    digits = "";
    if (e.key === "Escape" && atEnd) {
      location.href = urls.viewUrl;
      return;
    }
    const what = presentKey(e);
    if (what) {
      e.preventDefault();
      step(what);
    }
  });

  stage.addEventListener("click", (e) => {
    if (e.target.closest("a, video")) return;
    step("next");
  });
  end.addEventListener("click", () => step("prev"));
  blank.addEventListener("click", () => setBlank(null, "self"));

  // Swipes on touch screens.
  let touch = null;
  root.addEventListener("touchstart", (e) => {
    touch = e.touches.length === 1 ? { x: e.touches[0].clientX, y: e.touches[0].clientY } : null;
  }, { passive: true });
  root.addEventListener("touchend", (e) => {
    if (!touch) return;
    const dx = e.changedTouches[0].clientX - touch.x;
    const dy = e.changedTouches[0].clientY - touch.y;
    if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy)) step(dx < 0 ? "next" : "prev");
    touch = null;
  });

  // The controls show while the mouse moves.
  let idle;
  document.addEventListener("mousemove", () => {
    controls.classList.add("shown");
    document.body.classList.remove("no-cursor");
    clearTimeout(idle);
    idle = setTimeout(() => {
      controls.classList.remove("shown");
      document.body.classList.add("no-cursor");
    }, 2500);
  });

  player.show(pos);
  render();
  // Opened by the presenter console: take over its state.
  sync.local({ type: "hello" });
}

main().catch((err) => {
  root.replaceChildren(el("p", "present-error", "Die Präsentation konnte nicht geladen werden."));
  console.error(err);
});
