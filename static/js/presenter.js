// The presenter console: the current slide (as the audience sees it),
// what the next click shows, the notes, a timer and the clock. It opens
// the presentation window for the audience (move it to the projector and
// press F there) and keeps it in step; both windows take the same keys.
// The remote control (a phone) follows and steers both through the
// server.

import { Player } from "./player.js";
import { renderSlide, renderNotes, fitInto } from "./render.js";
import * as nav from "./deck-nav.js";
import { Sync, posFromHash, loadDeck, presentKey, PRESENT_KEYS } from "./sync.js";
import { installShortcutHelp, shortcutHelpOpen } from "./shortcuts.js";

const root = document.getElementById("presenter");
const urls = root.dataset;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function button(label, title, f, cls) {
  const b = el("button", "pbtn" + (cls ? " " + cls : ""), label);
  b.type = "button";
  b.title = title;
  b.addEventListener("click", f);
  return b;
}

function two(n) {
  return (n < 10 ? "0" : "") + n;
}

function clock(ms) {
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  return (h ? h + ":" : "") + two(Math.floor((s % 3600) / 60)) + ":" + two(s % 60);
}

function storage(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key);
    localStorage.setItem(key, value);
  } catch (e) {
    return null;
  }
  return null;
}

async function main() {
  const { deck, doc, design } = await loadDeck(urls);
  document.title = deck.title + " (Referentenansicht) · Folien";
  const assetUrl = (sha) => urls.deckUrl + "/assets/" + sha;

  // --- layout ---
  const title = el("h1", "p-title", deck.title);
  const label = el("span", "p-label");
  const timer = el("span", "p-timer", "00:00");
  const now = el("span", "p-clock");
  const conn = el("span", "p-conn", "");
  const audienceBtn = button("Publikumsfenster öffnen", "Die Präsentation in einem eigenen Fenster", openAudience, "primary");
  const pauseBtn = button("Pause", "Zeit anhalten", togglePause);
  const header = el("header", "p-header");
  header.append(
    title,
    label,
    el("span", "p-spacer"),
    timer,
    pauseBtn,
    button("↺", "Zeit zurücksetzen", resetTimer),
    now,
    conn,
    button("Fernbedienung", "Fernbedienung auf einem anderen Gerät öffnen", showRemote),
    audienceBtn,
  );

  const current = el("div", "p-current");
  const nextFrame = el("div", "slide-frame");
  const nextLabel = el("div", "p-next-label", "Als Nächstes");
  const nextBox = el("div", "p-next");
  nextBox.append(nextLabel, nextFrame);
  const notes = el("div", "p-notes");
  const notesBar = el("div", "p-notes-bar");
  notesBar.append(
    el("span", "p-notes-title", "Notizen"),
    button("A−", "Kleinere Schrift", () => setNotesSize(notesSize - 2)),
    button("A+", "Grössere Schrift", () => setNotesSize(notesSize + 2)),
  );
  const side = el("div", "p-side");
  side.append(nextBox, notesBar, notes);

  const blankState = el("span", "p-blank-state");
  const footer = el("footer", "p-footer");
  footer.append(
    button("‹ Zurück", "Zurück (←)", () => step("prev")),
    button("Weiter ›", "Weiter (→, Leertaste)", () => step("next"), "primary"),
    button("Schwarz", "Schwarzer Bildschirm (B)", () => step("black")),
    button("Weiss", "Weisser Bildschirm (W)", () => step("white")),
    blankState,
    el("span", "p-spacer"),
    button("Beenden", "Zurück zur Übersicht", () => (location.href = urls.viewUrl)),
  );
  const main = el("main", "p-main");
  main.append(current, side);
  root.replaceChildren(header, main, footer);

  // --- state ---
  const player = new Player(current, doc, design, { assetUrl });
  let pos = nav.clampPos(doc, posFromHash(location.hash)) || nav.first(doc);
  let blanked = null;
  let unfitNext = null;

  let notesSize = parseInt(storage("folien-notes-size") || "20", 10);
  function setNotesSize(n) {
    notesSize = Math.max(12, Math.min(48, n));
    notes.style.fontSize = notesSize + "px";
    storage("folien-notes-size", String(notesSize));
  }
  setNotesSize(notesSize);

  function render() {
    label.textContent =
      "Folie " + nav.slideLabel(doc, pos) +
      (nav.stepCount(doc.slides[pos.slide])
        ? " · Schritt " + pos.step + "/" + nav.stepCount(doc.slides[pos.slide])
        : "");
    blankState.textContent = blanked === "black" ? "Bildschirm schwarz" : blanked === "white" ? "Bildschirm weiss" : "";
    if (!renderNotes(notes, doc.slides[pos.slide].notes)) {
      notes.replaceChildren(el("p", "p-no-notes", "Keine Notizen."));
    }
    const n = nav.next(doc, pos);
    if (unfitNext) unfitNext();
    if (n) {
      const s = doc.slides[n.slide];
      unfitNext = fitInto(nextFrame, renderSlide(s, design, { step: nav.visibleOrder(s, n.step), assetUrl: (sha) => assetUrl(sha) + "?w=1280", doc, index: n.slide }));
      nextLabel.textContent = n.slide === pos.slide ? "Als Nächstes: nächster Schritt" : "Als Nächstes";
    } else {
      unfitNext = null;
      nextFrame.replaceChildren(el("div", "p-end", "Ende"));
      nextLabel.textContent = "Als Nächstes";
    }
  }

  const sync = new Sync({
    deckId: deck.id,
    eventsUrl: urls.eventsUrl,
    onConnection(ok) {
      conn.textContent = ok ? "" : "⚠ keine Verbindung zum Server";
    },
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
      if (m.type === "state" || m.type === "blank") {
        blanked = m.blank || null;
        render();
      }
      if (m.type === "goto" || m.type === "blank") sync.remote({ type: "state", pos, blank: blanked });
    },
  });

  function go(p, origin) {
    if (!nav.samePos(p, pos) || !player.pos) {
      pos = p;
      player.show(pos);
    }
    if (origin === "self") {
      blanked = null;
      sync.both({ type: "state", pos, blank: blanked });
    }
    render();
    startTimer();
  }

  function step(what) {
    if (what === "next") {
      const n = nav.next(doc, pos);
      if (n) go(n, "self");
    } else if (what === "prev") {
      const p = nav.prev(doc, pos);
      if (p) go(p, "self");
    } else if (what === "first") go(nav.first(doc), "self");
    else if (what === "last") go(nav.last(doc), "self");
    else if (what === "black" || what === "white") {
      blanked = blanked === what ? null : what;
      sync.both({ type: "state", pos, blank: blanked });
      render();
    }
  }

  // --- timer ---
  let started = null; // when the timer (re)started
  let elapsed = 0; // ms before that
  let paused = false;
  function startTimer() {
    if (started === null && !paused) started = Date.now();
  }
  function togglePause() {
    if (paused) {
      paused = false;
      started = Date.now();
      pauseBtn.textContent = "Pause";
    } else {
      if (started !== null) elapsed += Date.now() - started;
      started = null;
      paused = true;
      pauseBtn.textContent = "Weiter";
    }
  }
  function resetTimer() {
    elapsed = 0;
    started = paused ? null : Date.now();
  }
  setInterval(() => {
    timer.textContent = clock(elapsed + (started !== null ? Date.now() - started : 0));
    const d = new Date();
    now.textContent = two(d.getHours()) + ":" + two(d.getMinutes());
  }, 500);

  // --- windows ---
  let audience = null;
  async function openAudience() {
    let features = "popup,width=1280,height=720";
    // On a second screen, if the browser can tell (Window Management API).
    try {
      if (window.getScreenDetails) {
        const sd = await window.getScreenDetails();
        const other = sd.screens.find((s) => s !== sd.currentScreen);
        if (other) {
          features = "popup,left=" + other.availLeft + ",top=" + other.availTop +
            ",width=" + other.availWidth + ",height=" + other.availHeight;
        }
      }
    } catch (e) {
      // no permission: the window opens on this screen
    }
    const url = urls.presentUrl + "#" + (pos.slide + 1) + (pos.step ? "." + pos.step : "");
    audience = window.open(url, "folien-audience-" + deck.id, features);
    if (audience) audience.focus();
  }

  function showRemote() {
    const box = el("div", "p-remote-info");
    const link = el("a", "", location.origin + urls.remoteUrl);
    link.href = urls.remoteUrl;
    link.target = "_blank";
    box.append(
      el("p", "", "Öffnen Sie diese Adresse auf dem Telefon und melden Sie sich mit demselben Konto an:"),
      link,
      button("Schliessen", "Schliessen", () => box.remove()),
    );
    root.appendChild(box);
  }

  installShortcutHelp("Tastenkürzel in der Referentenansicht", () => [
    [
      "Präsentation steuern",
      [...PRESENT_KEYS, ["Tab", "Zu den Knöpfen (Zeit, Notizen, Schwarz …)"], ["? / F1", "Diese Hilfe"]],
    ],
  ]);

  document.addEventListener("keydown", (e) => {
    if (shortcutHelpOpen() || e.target.closest("input, textarea, select")) return;
    const what = presentKey(e);
    if (what && what !== "fullscreen") {
      e.preventDefault();
      step(what);
    }
  });

  player.show(pos);
  render();
  sync.local({ type: "hello" });
}

main().catch((err) => {
  root.replaceChildren(el("p", "present-error", "Die Referentenansicht konnte nicht geladen werden."));
  console.error(err);
});
