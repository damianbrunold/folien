// The "⋯" menus (details.menu) of the deck lists and the overview: one
// open at a time, closed by a click elsewhere, on one of its links (a
// download stays on the page) or Escape (back to its button), and
// Up/Down move through an open menu's items. They work as
// plain details elements without this.

export function wireMenus() {
  const menus = [...document.querySelectorAll("details.menu")];
  for (const m of menus) {
    m.addEventListener("click", (e) => {
      if (e.target.closest(".menu-list a")) {
        m.open = false;
        m.querySelector("summary").focus();
      }
    });
    m.addEventListener("toggle", () => {
      if (m.open) for (const other of menus) if (other !== m) other.open = false;
    });
    m.addEventListener("keydown", (e) => {
      if (!m.open || (e.key !== "ArrowUp" && e.key !== "ArrowDown")) return;
      const items = [...m.querySelectorAll(".menu-list a, .menu-list button")];
      const i = items.indexOf(document.activeElement);
      const j = i < 0 ? 0 : (i + (e.key === "ArrowDown" ? 1 : -1) + items.length) % items.length;
      if (items[j]) items[j].focus();
      e.preventDefault();
      e.stopPropagation();
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
