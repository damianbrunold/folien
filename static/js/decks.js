// The deck lists (src/app-views.sld, decks-page): pictures of each deck's
// first slide, drawn when the card comes into view, and the "⋯" menus
// (one open at a time; a click elsewhere or Escape closes it). Also the
// zip import of the presentations page.

import "./import.js";
import { designMap, fitInto, renderSlide } from "./render.js";

const grid = document.querySelector(".deck-grid");

async function drawThumbs() {
  const frames = [...grid.querySelectorAll(".js-thumb[data-slide]")];
  if (!frames.length) return;
  const r = await fetch(grid.dataset.designsUrl, { headers: { Accept: "application/json" } });
  if (!r.ok) return;
  const designs = designMap(await r.json());
  const draw = (frame) => {
    const design = designs.get(frame.dataset.design);
    if (!design) return;
    try {
      const slide = JSON.parse(frame.dataset.slide);
      const base = frame.dataset.assetBase;
      fitInto(frame, renderSlide(slide, design, { assetUrl: (sha) => base + sha + "?w=640" }));
    } catch (e) {
      // A slide that does not draw leaves the frame empty.
    }
  };
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        io.unobserve(e.target);
        draw(e.target);
      }
    },
    { rootMargin: "200px" },
  );
  for (const f of frames) io.observe(f);
}

function wireMenus() {
  const menus = [...document.querySelectorAll("details.menu")];
  for (const m of menus) {
    m.addEventListener("toggle", () => {
      if (m.open) for (const other of menus) if (other !== m) other.open = false;
    });
  }
  document.addEventListener("click", (e) => {
    for (const m of menus) if (m.open && !m.contains(e.target)) m.open = false;
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    for (const m of menus) {
      if (!m.open) continue;
      m.open = false;
      m.querySelector("summary").focus();
    }
  });
}

if (grid) {
  drawThumbs();
  wireMenus();
}
