// The presenter console: the current slide (as the audience sees it),
// what the next click shows, the notes, a timer and the clock; an
// overview of all slides (G) to jump to one, which only the console
// shows: the audience sees the slide jumped to. It opens
// the presentation window for the audience (move it to the projector and
// press F there) and keeps it in step; both windows take the same keys.
// The remote control (a phone) follows and steers both through the
// server. Shared by the console page (presenter.js) and the offline
// player (offline.js), which have different sources for the deck.

import { Player } from "./player.js";
import { renderSlide, renderNotes, fitInto } from "./render.js";
import * as nav from "./deck-nav.js";
import { Sync, posFromHash, hashOf, presentKey, PRESENT_KEYS } from "./sync.js";
import { installShortcutHelp, shortcutHelpOpen } from "./shortcuts.js";
import { remoteQrParts } from "./remote-qr.js";

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

// The console for doc in root. opts: deck ({id, title}), doc, design,
// assetUrl(sha), previewUrl(sha) (images of the next slide's preview;
// default assetUrl), thumbUrl(sha) (the overview's; default previewUrl), presentUrl (the audience window's page), exitUrl
// (or a function of the position: where "Beenden" goes), exitTitle, eventsUrl and remoteUrl, deckUrl (the server: remote control
// and its QR code; none: no remote), windows (talk to the audience window
// directly: see Sync).
export function startPresenter(root, opts) {
  const { deck, doc, design, assetUrl } = opts;
  const previewUrl = opts.previewUrl || assetUrl;
  const thumbUrl = opts.thumbUrl || previewUrl;
  document.title = deck.title + " (Referentenansicht) · Folien";

  // --- layout ---
  const title = el("h1", "p-title", deck.title);
  const label = el("span", "p-label");
  const timer = el("span", "p-timer", "00:00");
  const now = el("span", "p-clock");
  const conn = el("span", "p-conn", "");
  const audienceBtn = button("Publikumsfenster öffnen", "Die Präsentation in einem eigenen Fenster", openAudience, "primary");
  const pauseBtn = button("Pause", "Zeit anhalten", togglePause);
  const overviewBtn = button("Übersicht", "Alle Folien, um zu einer zu springen (G)", () => toggleOverview());
  overviewBtn.setAttribute("aria-expanded", "false");
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
    overviewBtn,
    opts.remoteUrl
      ? button("Fernbedienung", "Fernbedienung auf einem anderen Gerät öffnen", showRemote)
      : el("span"),
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
    button("Beenden", opts.exitTitle || "Zurück zur Übersicht", () => {
      location.href = typeof opts.exitUrl === "function" ? opts.exitUrl(pos) : opts.exitUrl;
    }),
  );
  // The overview: over the current slide and the side, until a slide is
  // chosen or Esc.
  const overview = el("div", "p-overview");
  overview.hidden = true;
  overview.setAttribute("role", "dialog");
  overview.setAttribute("aria-label", "Alle Folien");
  const main = el("main", "p-main");
  main.append(current, side, overview);
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
      unfitNext = fitInto(nextFrame, renderSlide(s, design, { step: nav.visibleOrder(s, n.step), assetUrl: previewUrl, doc, index: n.slide }));
      nextLabel.textContent = n.slide === pos.slide ? "Als Nächstes: nächster Schritt" : "Als Nächstes";
    } else {
      unfitNext = null;
      nextFrame.replaceChildren(el("div", "p-end", "Ende"));
      nextLabel.textContent = "Als Nächstes";
    }
  }

  const sync = new Sync({
    deckId: deck.id,
    eventsUrl: opts.eventsUrl,
    windows: !!opts.windows,
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
    const url = opts.presentUrl + "#" + (pos.slide + 1) + (pos.step ? "." + pos.step : "");
    audience = window.open(url, "folien-audience-" + deck.id, features);
    if (audience) {
      sync.addPeer(audience);
      audience.focus();
    }
  }

  function showRemote() {
    const old = root.querySelector(".p-remote-info");
    if (old) old.remove();
    const box = el("div", "p-remote-info");
    box.setAttribute("role", "dialog");
    box.setAttribute("aria-label", "Fernbedienung");
    const opener = document.activeElement;
    const done = () => {
      box.remove();
      if (opener && opener.focus) opener.focus();
    };
    const close = button("Schliessen", "Schliessen", done);
    box.append(...remoteQrParts(opts.remoteUrl, opts.deckUrl), close);
    box.addEventListener("keydown", (e) => {
      if (e.key === "Escape") {
        e.stopPropagation();
        done();
      }
    });
    root.appendChild(box);
    close.focus();
  }

  // --- overview ---
  // The thumbnails are drawn the first time it opens.
  let thumbs = null;
  function buildThumbs() {
    let shown = 0;
    thumbs = doc.slides.map((slide, i) => {
      const b = el("button", "p-thumb");
      b.type = "button";
      b.tabIndex = -1;
      const num = slide.hidden ? "ausgeblendet" : String(++shown);
      b.setAttribute("aria-label", slide.hidden ? "Ausgeblendete Folie (" + (i + 1) + ")" : "Folie " + num);
      if (slide.hidden) b.classList.add("hidden-slide");
      const f = el("div", "slide-frame");
      b.append(el("span", "p-thumb-num", num), f);
      b.addEventListener("click", () => jumpTo(i));
      overview.appendChild(b);
      fitInto(f, renderSlide(slide, design, { assetUrl: thumbUrl, doc, index: i }));
      return b;
    });
  }

  function overviewOpen() {
    return !overview.hidden;
  }

  function toggleOverview(open = !overviewOpen()) {
    overview.hidden = !open;
    overviewBtn.setAttribute("aria-expanded", String(open));
    overviewBtn.classList.toggle("primary", open);
    if (!open) return;
    if (!thumbs) buildThumbs();
    thumbs.forEach((b, i) => b.classList.toggle("current", i === pos.slide));
    focusThumb(pos.slide);
  }

  function focusThumb(i) {
    const k = Math.max(0, Math.min(thumbs.length - 1, i));
    thumbs.forEach((b, j) => (b.tabIndex = j === k ? 0 : -1));
    thumbs[k].focus();
    thumbs[k].scrollIntoView({ block: "nearest" });
  }

  function jumpTo(i) {
    toggleOverview(false);
    go(nav.slideStart(doc, i), "self");
    overviewBtn.focus();
  }

  // Keys while the overview is open: arrows move, Enter or Space jump,
  // Esc or G close it.
  function overviewKey(e) {
    const at = thumbs.indexOf(document.activeElement);
    const i = at >= 0 ? at : pos.slide;
    // thumbnails in a row: those level with the first
    const cols = Math.max(1, thumbs.filter((b) => b.offsetTop === thumbs[0].offsetTop).length);
    const moves = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -cols, ArrowDown: cols };
    if (e.key in moves) focusThumb(i + moves[e.key]);
    else if (e.key === "Home") focusThumb(0);
    else if (e.key === "End") focusThumb(thumbs.length - 1);
    else if (e.key === "Enter" || e.key === " ") jumpTo(i);
    else if (e.key === "Escape" || e.key === "g" || e.key === "G") {
      toggleOverview(false);
      overviewBtn.focus();
    } else if (e.key !== "Tab") return;
    if (e.key !== "Tab") e.preventDefault();
  }

  installShortcutHelp("Tastenkürzel in der Referentenansicht", () => [
    [
      "Präsentation steuern",
      [
        ...PRESENT_KEYS,
        ["G", "Übersicht aller Folien (Pfeiltasten, Enter springt, Esc schliesst)"],
        ["Tab", "Zu den Knöpfen (Zeit, Notizen, Schwarz …)"],
        ["? / F1", "Diese Hilfe"],
      ],
    ],
  ]);

  // A number typed before Enter jumps to that slide (counting the shown
  // ones, as the label does).
  let digits = "";
  document.addEventListener("keydown", (e) => {
    if (shortcutHelpOpen() || e.target.closest("input, textarea, select")) return;
    if (overviewOpen()) {
      overviewKey(e);
      return;
    }
    if (/^[0-9]$/.test(e.key) && !e.ctrlKey && !e.metaKey && !e.altKey) {
      digits += e.key;
      return;
    }
    if (e.key === "Enter" && digits) {
      const i = nav.slideByNumber(doc, parseInt(digits, 10));
      digits = "";
      e.preventDefault();
      if (i !== null) go(nav.slideStart(doc, i), "self");
      return;
    }
    digits = "";
    if ((e.key === "g" || e.key === "G") && !e.ctrlKey && !e.metaKey && !e.altKey) {
      e.preventDefault();
      toggleOverview(true);
      return;
    }
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
