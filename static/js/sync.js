// Keeping the windows that present a deck together: the presentation,
// the presenter console (usually two windows on one computer) and a
// remote control on another device.
//
// Windows on the same computer talk over a BroadcastChannel; everything
// else goes through the server: POST <deck api>/events, received by every
// window as server-sent events (GET <deck api>/events). Messages:
//   {type: "state", pos, blank}  where a window is now
//   {type: "goto", pos}          please go there (from the remote)
//   {type: "blank", blank}       null, "black" or "white"
//   {type: "hello"}              a window started: tell it the state
// Positions are absolute, so a message that arrives twice (directly and
// through the server) does no harm.

export class Sync {
  // opts: deckId, eventsUrl, onMessage(msg, via) with via "local" or
  // "remote", onConnection(connected), remote (default true): also use
  // the server.
  constructor(opts) {
    this.opts = opts;
    this.id = Math.random().toString(36).slice(2, 12);
    if (typeof BroadcastChannel !== "undefined") {
      this.bc = new BroadcastChannel("folien-" + opts.deckId);
      this.bc.onmessage = (e) => {
        if (e.data && e.data.from !== this.id) opts.onMessage(e.data, "local");
      };
    }
    if (opts.remote !== false && typeof EventSource !== "undefined") {
      this.es = new EventSource(opts.eventsUrl);
      this.es.onmessage = (e) => {
        let m;
        try {
          m = JSON.parse(e.data);
        } catch (err) {
          return;
        }
        if (m && m.from !== this.id) opts.onMessage(m, "remote");
      };
      this.es.onopen = () => opts.onConnection && opts.onConnection(true);
      this.es.onerror = () => opts.onConnection && opts.onConnection(false);
    }
  }

  // To the other windows on this computer.
  local(msg) {
    if (this.bc) this.bc.postMessage(Object.assign({}, msg, { from: this.id }));
  }

  // Through the server, to all windows of the deck anywhere.
  remote(msg) {
    if (!this.es) return Promise.resolve();
    return fetch(this.opts.eventsUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(Object.assign({}, msg, { from: this.id })),
    }).catch(() => {});
  }

  both(msg) {
    this.local(msg);
    this.remote(msg);
  }

  close() {
    if (this.bc) this.bc.close();
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
  await Promise.all([
    document.fonts.load("400 40px Inter"),
    document.fonts.load("900 40px Inter"),
  ]).catch(() => {});
  return { deck, doc: deck.doc, design };
}

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
