// Downloads the server builds first (a.js-download: ZIP bundle,
// PowerPoint, offline player): a plain link gives no sign of life until
// the file is ready, so the file is fetched here instead, with a notice
// while it is made and when it has come, and saved from memory (menus.js
// closes the menu the link was in). Without this script the links
// download as usual.

let toast = null;
let hideTimer = null;

function notify(text, kind, stay) {
  if (!toast) {
    toast = document.createElement("div");
    toast.className = "toast";
    toast.setAttribute("role", "status");
    toast.setAttribute("aria-live", "polite");
    document.body.appendChild(toast);
  }
  clearTimeout(hideTimer);
  toast.textContent = text;
  toast.className = "toast shown" + (kind ? " " + kind : "");
  if (!stay) hideTimer = setTimeout(() => toast.classList.remove("shown"), 5000);
}

// The file name of a Content-Disposition header: filename*=UTF-8''…, else
// filename="…".
export function dispositionName(header) {
  if (!header) return null;
  const star = /filename\*=UTF-8''([^;]+)/i.exec(header);
  if (star) {
    try {
      return decodeURIComponent(star[1].trim());
    } catch (e) {
      // fall through to the plain name
    }
  }
  const plain = /filename="([^"]*)"/i.exec(header);
  return plain ? plain[1] : null;
}

const busy = new Set();

async function download(link) {
  const url = link.href;
  if (busy.has(url)) {
    notify("Die Datei wird noch erstellt …", "", true);
    return;
  }
  busy.add(url);
  link.setAttribute("aria-busy", "true");
  notify("Die Datei wird erstellt … der Download beginnt, sobald sie bereit ist.", "", true);
  try {
    const r = await fetch(url, { credentials: "same-origin" });
    if (!r.ok) throw new Error(url + ": " + r.status);
    const name = dispositionName(r.headers.get("Content-Disposition")) || "download";
    const blob = await r.blob();
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 60000);
    notify("Heruntergeladen: " + name, "success");
  } catch (err) {
    console.error(err);
    notify("Das Herunterladen ist fehlgeschlagen. Bitte noch einmal versuchen.", "error");
  } finally {
    busy.delete(url);
    link.removeAttribute("aria-busy");
  }
}

export function wireDownloads() {
  document.addEventListener("click", (e) => {
    const link = e.target.closest && e.target.closest("a.js-download");
    // a new tab or window, or saving the link: the browser's own way
    if (!link || e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    download(link);
  });
}
