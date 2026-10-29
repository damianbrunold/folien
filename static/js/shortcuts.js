// Keyboard help, shared by the pages: a dialog listing the page's keys,
// opened with "?" or F1 (installShortcutHelp), and the test whether a key
// goes to a text field rather than to the page.
//
// groups: [[heading, [[keys, what], ...]], ...]; keys like "Strg+Enter"
// (several alternatives joined by " / ").

export function isTyping(target) {
  return !!(target && target.closest && target.closest("input, textarea, select, [contenteditable=true]"));
}

let dialog = null;

export function showShortcutHelp(title, groups) {
  if (dialog) dialog.remove();
  dialog = document.createElement("dialog");
  dialog.className = "shortcut-help";
  dialog.setAttribute("aria-label", title);
  const h = document.createElement("h2");
  h.textContent = title;
  dialog.appendChild(h);
  for (const [heading, rows] of groups) {
    const section = document.createElement("section");
    const h3 = document.createElement("h3");
    h3.textContent = heading;
    const dl = document.createElement("dl");
    for (const [keys, what] of rows) {
      const dt = document.createElement("dt");
      keys.split(" / ").forEach((alt, i) => {
        if (i) dt.append(" / ");
        alt.split("+").forEach((k, j) => {
          if (j) dt.append("+");
          const kbd = document.createElement("kbd");
          kbd.textContent = k;
          dt.appendChild(kbd);
        });
      });
      const dd = document.createElement("dd");
      dd.textContent = what;
      dl.append(dt, dd);
    }
    section.append(h3, dl);
    dialog.appendChild(section);
  }
  const close = document.createElement("button");
  close.type = "button";
  close.textContent = "Schliessen";
  close.addEventListener("click", () => dialog.close());
  const form = document.createElement("div");
  form.className = "shortcut-help-actions";
  form.appendChild(close);
  dialog.appendChild(form);
  const before = document.activeElement;
  dialog.addEventListener("close", () => {
    dialog.remove();
    dialog = null;
    if (before && before.focus) before.focus();
  });
  document.body.appendChild(dialog);
  dialog.showModal();
  close.focus();
}

export function shortcutHelpOpen() {
  return !!dialog;
}

// "?" (outside text fields) and F1 open the help; getGroups is called
// each time, so it can depend on the page's state.
export function installShortcutHelp(title, getGroups) {
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented || dialog) return;
    const help = e.key === "F1" || (e.key === "?" && !e.ctrlKey && !e.metaKey && !e.altKey && !isTyping(e.target));
    if (!help) return;
    e.preventDefault();
    showShortcutHelp(title, getGroups());
  });
}
