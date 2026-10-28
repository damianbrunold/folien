// The slide player: shows positions of a deck ({slide, step}, see
// deck-nav.js) in a box, letterboxed, with slide transitions and build
// effects. Used by the presentation window and the presenter console.
//
//   const p = new Player(box, doc, design, { assetUrl, animate });
//   p.show({slide: 0, step: 0});
//
// Effects run with the Web Animations API, so the strict CSP (no inline
// styles) holds. Moving forward by one step animates the newly built
// elements; moving to the next slide plays its transition; anything else
// (going back, jumping) shows the position at once.

import { SLIDE_W, SLIDE_H, renderSlide } from "./render.js";
import { visibleOrder, buildOrders } from "./deck-nav.js";

const BUILD_MS = 500;

// Keyframes of build effects. Elements may be rotated: their own
// transform is kept at the end of each frame.
function buildKeyframes(effect, base) {
  const t = (s) => (s + " " + base).trim();
  switch (effect) {
    case "fade":
      return [{ opacity: 0 }, { opacity: 1 }];
    case "fly-left":
      return [{ transform: t("translateX(-2000px)") }, { transform: t("translateX(0)") }];
    case "fly-right":
      return [{ transform: t("translateX(2000px)") }, { transform: t("translateX(0)") }];
    case "fly-up":
      return [{ transform: t("translateY(1200px)") }, { transform: t("translateY(0)") }];
    case "fly-down":
      return [{ transform: t("translateY(-1200px)") }, { transform: t("translateY(0)") }];
    case "zoom":
      return [{ transform: t("scale(0.3)"), opacity: 0 }, { transform: t("scale(1)"), opacity: 1 }];
    default:
      return null; // appear
  }
}

// Keyframes of slide transitions for [outgoing, incoming].
function transitionKeyframes(type) {
  switch (type) {
    case "fade":
      return [null, [{ opacity: 0 }, { opacity: 1 }]];
    case "push-left":
      return [
        [{ transform: "translateX(0)" }, { transform: "translateX(-100%)" }],
        [{ transform: "translateX(100%)" }, { transform: "translateX(0)" }],
      ];
    case "push-up":
      return [
        [{ transform: "translateY(0)" }, { transform: "translateY(-100%)" }],
        [{ transform: "translateY(100%)" }, { transform: "translateY(0)" }],
      ];
    case "wipe-left":
      return [null, [{ clipPath: "inset(0 0 0 100%)" }, { clipPath: "inset(0 0 0 0)" }]];
    case "zoom":
      return [null, [{ transform: "scale(0.6)", opacity: 0 }, { transform: "scale(1)", opacity: 1 }]];
    default:
      return null;
  }
}

export class Player {
  // box: an element the player fills (it sets position: relative via CSS
  // class "player"). opts: assetUrl(sha), animate (default true),
  // onLink(slideId), onVideoClick.
  constructor(box, doc, design, opts = {}) {
    this.box = box;
    this.doc = doc;
    this.design = design;
    this.opts = opts;
    this.pos = null;
    this.layer = null; // the current slide's wrapper
    box.classList.add("player");
    this.ro = new ResizeObserver(() => this.fit());
    this.ro.observe(box);
  }

  destroy() {
    this.ro.disconnect();
    this.box.replaceChildren();
  }

  scale() {
    return Math.min(this.box.clientWidth / SLIDE_W, this.box.clientHeight / SLIDE_H);
  }

  // A wrapper (the slide's letterboxed box) around a rendered slide.
  makeLayer(slide, step) {
    const wrap = document.createElement("div");
    wrap.className = "player-layer";
    const el = renderSlide(slide, this.design, {
      step: visibleOrder(slide, step),
      assetUrl: this.opts.assetUrl,
      onLink: this.opts.onLink,
    });
    wrap.appendChild(el);
    this.place(wrap);
    this.wireVideos(wrap);
    return wrap;
  }

  place(wrap) {
    const s = this.scale();
    const w = SLIDE_W * s;
    const h = SLIDE_H * s;
    wrap.style.width = w + "px";
    wrap.style.height = h + "px";
    wrap.style.left = (this.box.clientWidth - w) / 2 + "px";
    wrap.style.top = (this.box.clientHeight - h) / 2 + "px";
    wrap.firstChild.style.transform = "scale(" + s + ")";
  }

  fit() {
    if (this.layer) this.place(this.layer);
  }

  // Videos: a click plays or pauses (and does not advance); autoplay
  // ones start when they become visible.
  wireVideos(wrap) {
    for (const v of wrap.querySelectorAll("video")) {
      v.addEventListener("click", (e) => {
        e.stopPropagation();
        if (v.paused) v.play().catch(() => {});
        else v.pause();
      });
    }
  }

  startVideos(nodes) {
    for (const node of nodes) {
      const id = node.dataset.id;
      const el = this.doc.slides[this.pos.slide].elements.find((x) => x.id === id);
      const v = node.querySelector("video");
      if (v && el && el.autoplay) v.play().catch(() => {});
    }
  }

  visibleNodes(wrap) {
    return Array.from(wrap.querySelectorAll(".slide > .el[data-id]")).filter(
      (n) => !n.classList.contains("build-pending"),
    );
  }

  show(pos) {
    const animate = this.opts.animate !== false;
    const prev = this.pos;
    const slide = this.doc.slides[pos.slide];
    this.pos = { slide: pos.slide, step: pos.step };

    // One build step forward on the same slide: reveal its elements.
    if (prev && this.layer && prev.slide === pos.slide && pos.step === prev.step + 1) {
      const order = buildOrders(slide)[pos.step - 1];
      const nodes = Array.from(
        this.layer.querySelectorAll('.el[data-build="' + order + '"]'),
      );
      for (const n of nodes) {
        n.classList.remove("build-pending");
        const frames = animate && buildKeyframes(n.dataset.effect, n.style.transform || "");
        if (frames) n.animate(frames, { duration: BUILD_MS, easing: "ease-out" });
      }
      this.startVideos(nodes);
      return;
    }

    const layer = this.makeLayer(slide, pos.step);
    const old = this.layer;
    this.box.appendChild(layer);
    this.layer = layer;
    const forward = prev && pos.slide !== prev.slide && pos.step === 0 &&
      pos.slide > prev.slide;
    const tr = slide.transition;
    const frames = animate && forward && old && tr && transitionKeyframes(tr.type);
    if (frames) {
      const opts = { duration: tr.duration || 600, easing: "ease-in-out" };
      if (frames[0]) old.animate(frames[0], opts);
      const a = layer.animate(frames[1], opts);
      a.finished.then(() => old.remove(), () => old.remove());
    } else if (old) {
      old.remove();
    }
    this.startVideos(this.visibleNodes(layer));
  }
}
