// The deck lists (src/app-views.sld, decks-page): pictures of each deck's
// first slide, drawn when the card comes into view, and the "⋯" menus
// (one open at a time; a click elsewhere or Escape closes it). Also the
// zip import of the presentations page, and the keyboard: arrows move
// between the cards (and within an open menu), "/" goes to the search,
// "n" to the new presentation's title, "?" shows the keys.

import "./import.js";
import { designMap, fitInto, renderSlide } from "./render.js";
import { installShortcutHelp, isTyping } from "./shortcuts.js";
import { wireMenus } from "./menus.js";
import { wireDownloads } from "./downloads.js";

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

// Arrows from card to card (focus on the card's title link): left and
// right in reading order, up and down to the nearest card of the row
// above or below.
function wireCardKeys() {
  grid.addEventListener("keydown", (e) => {
    if (e.ctrlKey || e.metaKey || e.altKey || isTyping(e.target)) return;
    const arrows = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"];
    if (!arrows.includes(e.key)) return;
    // in an open menu, menus.js moves through its items
    if (e.target.closest("details.menu[open]")) return;
    const cards = [...grid.querySelectorAll(".deck-card")];
    const card = e.target.closest(".deck-card");
    const i = cards.indexOf(card);
    if (i < 0) return;
    let target = null;
    if (e.key === "ArrowLeft") target = cards[i - 1];
    else if (e.key === "ArrowRight") target = cards[i + 1];
    else {
      const top = card.offsetTop;
      const rows = cards.filter((c) => (e.key === "ArrowDown" ? c.offsetTop > top : c.offsetTop < top));
      if (rows.length) {
        const rowTop = e.key === "ArrowDown"
          ? Math.min(...rows.map((c) => c.offsetTop))
          : Math.max(...rows.map((c) => c.offsetTop));
        const row = rows.filter((c) => c.offsetTop === rowTop);
        target = row.reduce((a, b) =>
          Math.abs(b.offsetLeft - card.offsetLeft) < Math.abs(a.offsetLeft - card.offsetLeft) ? b : a,
        );
      }
    }
    if (!target) return;
    const link = target.querySelector(".deck-title a") || target.querySelector("a, button, summary");
    if (link) link.focus();
    e.preventDefault();
  });
}

function wirePageKeys() {
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || e.ctrlKey || e.metaKey || e.altKey || isTyping(e.target)) return;
    let field = null;
    if (e.key === "/") field = document.querySelector(".search-bar input[name=q]");
    else if (e.key === "n" || e.key === "N") field = document.querySelector("form.row-form input[name=title]");
    if (!field) return;
    e.preventDefault();
    field.focus();
    field.select();
  });
  installShortcutHelp("Tastenkürzel der Präsentationsliste", () => [
    [
      "Liste",
      [
        ["Tab", "Zur nächsten Präsentation oder Aktion"],
        ["← / → / ↑ / ↓", "Zur Präsentation daneben, darüber oder darunter"],
        ["Enter", "Öffnen (bearbeiten)"],
        ["Enter auf ⋯", "Weitere Aktionen; darin ↑ / ↓, Esc schliesst"],
        ["/", "Suchen"],
        ["N", "Neue Präsentation: Titel eingeben"],
        ["? / F1", "Diese Hilfe"],
      ],
    ],
  ]);
}

wirePageKeys();
if (grid) {
  drawThumbs();
  wireMenus();
  wireDownloads();
  wireCardKeys();
}
