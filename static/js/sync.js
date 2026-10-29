// Keeping the windows that present a deck together: the presentation,
// the presenter console (usually two windows on one computer) and a
// remote control on another device.
//
// Windows on the same computer talk over a BroadcastChannel; everything
// else goes through the server, which relays each message to every window
// of the deck: over a WebSocket (<deck api>/socket) both ways, or, where
// that cannot connect (a proxy without WebSocket support), as server-sent
// events (GET <deck api>/events) and POSTs to the same URL. Messages:
//   {type: "state", pos, blank}  where a window is now
//   {type: "goto", pos}          please go there (from the remote)
//   {type: "blank", blank}       null, "black" or "white"
//   {type: "hello"}              a window started: tell it the state
//   {type: "ping"}               the server's keepalive (ignored)
// Positions are absolute, so a message that arrives twice (directly and
// through the server) does no harm.

import { loadDesignFonts } from "./render.js";

export class Sync {
  // opts: deckId, eventsUrl, onMessage(msg, via) with via "local" or
  // "remote", onConnection(connected), remote (default true): also use
  // the server.
  constructor(opts) {
    this.opts = opts;
    this.id = Math.random().toString(36).slice(2, 12);
    try {
      this.bc = new BroadcastChannel("folien-" + opts.deckId);
      this.bc.onmessage = (e) => {
        if (e.data && e.data.from !== this.id) opts.onMessage(e.data, "local");
      };
    } catch (e) {
      this.bc = null; // no channel (an old browser, or a page opened from a file)
    }
    this.closed = false;
    if (opts.remote !== false && opts.eventsUrl) {
      if (typeof WebSocket !== "undefined") this.openSocket(0);
      else this.openEvents();
    }
  }

  // A message from the server, as text.
  received(data) {
    let m;
    try {
      m = JSON.parse(data);
    } catch (err) {
      return;
    }
    if (m && m.type !== "ping" && m.from !== this.id) this.opts.onMessage(m, "remote");
  }

  socketUrl() {
    const u = new URL(this.opts.eventsUrl.replace(/\/events$/, "/socket"), location.href);
    u.protocol = u.protocol === "https:" ? "wss:" : "ws:";
    return u.href;
  }

  // The WebSocket; after a drop it reconnects (waiting longer each time).
  // One that never opened gives way to server-sent events for good.
  openSocket(attempt) {
    let opened = false;
    const ws = new WebSocket(this.socketUrl());
    this.ws = ws;
    ws.onopen = () => {
      opened = true;
      attempt = 0;
      if (this.opts.onConnection) this.opts.onConnection(true);
    };
    ws.onmessage = (e) => this.received(e.data);
    ws.onclose = () => {
      if (this.ws === ws) this.ws = null;
      if (this.closed) return;
      if (this.opts.onConnection) this.opts.onConnection(false);
      if (!opened && attempt === 0) {
        this.openEvents();
      } else {
        const wait = Math.min(30000, 1000 * 2 ** Math.min(attempt, 5));
        this.retry = setTimeout(() => this.openSocket(attempt + 1), wait);
      }
    };
  }

  openEvents() {
    if (typeof EventSource === "undefined") return;
    this.es = new EventSource(this.opts.eventsUrl);
    this.es.onmessage = (e) => this.received(e.data);
    this.es.onopen = () => this.opts.onConnection && this.opts.onConnection(true);
    this.es.onerror = () => this.opts.onConnection && this.opts.onConnection(false);
  }

  // To the other windows on this computer.
  local(msg) {
    if (this.bc) this.bc.postMessage(Object.assign({}, msg, { from: this.id }));
  }

  // Through the server, to all windows of the deck anywhere.
  remote(msg) {
    const text = JSON.stringify(Object.assign({}, msg, { from: this.id }));
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(text);
      return Promise.resolve();
    }
    if (this.opts.remote === false || !this.opts.eventsUrl) return Promise.resolve();
    // Not connected (yet): the server relays a POST to the WebSocket
    // listeners as well.
    return fetch(this.opts.eventsUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: text,
    }).catch(() => {});
  }

  both(msg) {
    this.local(msg);
    this.remote(msg);
  }

  close() {
    this.closed = true;
    clearTimeout(this.retry);
    if (this.bc) this.bc.close();
    if (this.ws) this.ws.close();
    if (this.es) this.es.close();
  }
}

// "#3.2" <-> {slide: 2, step: 2}
export function posFromHash(hash) {
  const m = /^#(\d+)(?:\.(\d+))?$/.exec(hash || "");
  return m ? { slide: parseInt(m[1], 10) - 1, step: m[2] ? parseInt(m[2], 10) : 0 } : null;
}

export function hashOf(pos) {
  return "#" + (pos.slide + 1) + (pos.step ? "." + pos.step : "");
}

export async function loadDeck(urls) {
  const get = async (u) => {
    const r = await fetch(u, { headers: { Accept: "application/json" } });
    if (!r.ok) throw new Error(u + ": " + r.status);
    return r.json();
  };
  const [deck, designs] = await Promise.all([get(urls.deckUrl), get(urls.designsUrl)]);
  const design = designs.find((d) => d.id === deck.design);
  await loadDesignFonts(design);
  return { deck, doc: deck.doc, design };
}

// The keys of presenting, for the keyboard help (presentKey reads them).
export const PRESENT_KEYS = [
  ["→ / ↓ / Bild ab / Leertaste / Enter / N", "Weiter (nächster Aufbauschritt oder nächste Folie)"],
  ["← / ↑ / Bild auf / Rücktaste / P", "Zurück"],
  ["Pos1 / Ende", "Erste / letzte Folie"],
  ["Ziffern+Enter", "Zur Folie mit dieser Nummer"],
  ["B / .", "Schwarzer Bildschirm (nochmals: zurück)"],
  ["W / ,", "Weisser Bildschirm (nochmals: zurück)"],
];

// The keys of presenting, shared by the presentation and the console.
export function presentKey(e) {
  if (e.ctrlKey || e.metaKey || e.altKey) return null;
  switch (e.key) {
    case "ArrowRight":
    case "ArrowDown":
    case "PageDown":
    case " ":
    case "Enter":
    case "n":
    case "N":
      return "next";
    case "ArrowLeft":
    case "ArrowUp":
    case "PageUp":
    case "Backspace":
    case "p":
    case "P":
      return "prev";
    case "Home":
      return "first";
    case "End":
      return "last";
    case "b":
    case "B":
    case ".":
      return "black";
    case "w":
    case "W":
    case ",":
      return "white";
    case "f":
    case "F":
      return "fullscreen";
    default:
      return null;
  }
}
