// A minimal WebDriver BiDi client for headless Firefox, enough for the
// browser tests: start Firefox, open pages, run script, send pointer and
// key input, take screenshots. Needs node --experimental-websocket on
// node 20 (WebSocket is global from node 22 on).

import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

export const Keys = {
  backspace: "",
  tab: "",
  enter: "",
  shift: "",
  ctrl: "",
  escape: "",
  end: "",
  home: "",
  left: "",
  up: "",
  right: "",
  down: "",
  delete: "",
};

export async function launchFirefox({ port = 9333 } = {}) {
  const profile = mkdtempSync(join(tmpdir(), "folien-ff-"));
  const proc = spawn(
    "firefox",
    ["--headless", "--no-remote", "--profile", profile, "--remote-debugging-port", String(port), "about:blank"],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("firefox did not start")), 30000);
    proc.stderr.on("data", (d) => {
      if (String(d).includes("WebDriver BiDi listening")) {
        clearTimeout(timer);
        resolve();
      }
    });
    proc.on("exit", (c) => reject(new Error("firefox exited " + c)));
  });
  const ws = new WebSocket(`ws://127.0.0.1:${port}/session`);
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = reject;
  });
  const b = new Browser(ws, proc, profile);
  await b.send("session.new", { capabilities: {} });
  const tree = await b.send("browsingContext.getTree", {});
  b.context = tree.contexts[0].context;
  return b;
}

class Browser {
  constructor(ws, proc, profile) {
    this.ws = ws;
    this.proc = proc;
    this.profile = profile;
    this.nextId = 1;
    this.pending = new Map();
    this.logs = [];
    ws.onmessage = (m) => {
      const msg = JSON.parse(m.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.type === "error") reject(new Error(msg.error + ": " + msg.message));
        else resolve(msg.result);
      } else if (msg.method === "log.entryAdded") {
        this.logs.push(msg.params.level + ": " + msg.params.text);
      }
    };
  }

  send(method, params) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
  }

  async open(url, width = 1400, height = 900) {
    await this.send("session.subscribe", { events: ["log.entryAdded"] }).catch(() => {});
    await this.send("browsingContext.setViewport", {
      context: this.context,
      viewport: { width, height },
    });
    await this.send("browsingContext.navigate", { context: this.context, url, wait: "complete" });
  }

  // Evaluates an expression (awaiting promises) and returns its value,
  // passed through JSON.
  async eval(expression) {
    const r = await this.send("script.evaluate", {
      expression: `(async () => JSON.stringify(await (${expression})))()`,
      target: { context: this.context },
      awaitPromise: true,
      resultOwnership: "none",
    });
    if (r.type !== "success") {
      throw new Error("script error: " + JSON.stringify(r.exceptionDetails && r.exceptionDetails.text));
    }
    const v = r.result.value;
    return v === undefined ? undefined : JSON.parse(v);
  }

  // Waits until expression is truthy; returns its value.
  async waitFor(expression, timeout = 5000) {
    const end = Date.now() + timeout;
    for (;;) {
      const v = await this.eval(expression).catch(() => undefined);
      if (v) return v;
      if (Date.now() > end) throw new Error("timed out waiting for " + expression);
      await new Promise((r) => setTimeout(r, 50));
    }
  }

  pointer(actions) {
    return this.send("input.performActions", {
      context: this.context,
      actions: [{ type: "pointer", id: "mouse", parameters: { pointerType: "mouse" }, actions }],
    });
  }

  click(x, y, count = 1) {
    const acts = [{ type: "pointerMove", x: Math.round(x), y: Math.round(y) }];
    for (let i = 0; i < count; i++) {
      acts.push({ type: "pointerDown", button: 0 }, { type: "pointerUp", button: 0 });
    }
    return this.pointer(acts);
  }

  drag(x1, y1, x2, y2, steps = 8) {
    const acts = [
      { type: "pointerMove", x: Math.round(x1), y: Math.round(y1) },
      { type: "pointerDown", button: 0 },
    ];
    for (let i = 1; i <= steps; i++) {
      acts.push({
        type: "pointerMove",
        x: Math.round(x1 + ((x2 - x1) * i) / steps),
        y: Math.round(y1 + ((y2 - y1) * i) / steps),
        duration: 16,
      });
    }
    acts.push({ type: "pointerUp", button: 0 });
    return this.pointer(acts);
  }

  // Types text; modifiers: keys held down meanwhile (e.g. [Keys.ctrl]).
  keys(text, modifiers = []) {
    const acts = [];
    for (const m of modifiers) acts.push({ type: "keyDown", value: m });
    for (const ch of text) acts.push({ type: "keyDown", value: ch }, { type: "keyUp", value: ch });
    for (const m of modifiers.slice().reverse()) acts.push({ type: "keyUp", value: m });
    return this.send("input.performActions", {
      context: this.context,
      actions: [{ type: "key", id: "kb", actions: acts }],
    });
  }

  // Another tab, as an object with the same methods acting on it.
  async newTab(url) {
    const r = await this.send("browsingContext.create", { type: "tab" });
    const tab = Object.create(this, { context: { value: r.context } });
    if (url) await tab.open(url);
    return tab;
  }

  async screenshot() {
    const r = await this.send("browsingContext.captureScreenshot", { context: this.context });
    return Buffer.from(r.data, "base64");
  }

  async close() {
    try {
      await this.send("session.end", {});
    } catch (e) {
      // already gone
    }
    this.ws.close();
    this.proc.kill();
    await new Promise((r) => this.proc.on("exit", r));
    rmSync(this.profile, { recursive: true, force: true });
  }
}
