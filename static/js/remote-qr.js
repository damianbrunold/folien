// The remote control's address as a QR code, for the presenter console
// and the deck page: scanned with a phone's camera, it opens the remote,
// without signing in: the code carries a remote link (a token valid for
// 12 hours, for this deck's remote only). The server draws the code
// (/decks/<id>/remote-qr.svg) from this browser's origin, which is how
// the phone has to reach the site too. "Neuen Code erzeugen" ends every
// code given out before (POST <deck api>/remote-links/renew).

// The parts of the box: what the code allows, the code, the address as a
// link, the renewal, and a warning where this browser uses an address
// only it can reach. deckApiUrl: /api/decks/<id>.
export function remoteQrParts(remoteUrl, deckApiUrl) {
  const about = document.createElement("p");
  about.className = "remote-qr-about";
  about.textContent =
    "Mit der Kamera des Telefons scannen: Die Fernbedienung öffnet sich ohne Anmeldung. " +
    "Wer den Code hat, kann diese Präsentation 12 Stunden lang steuern und die Notizen lesen – " +
    "zeigen Sie ihn nicht dem Publikum.";
  const img = document.createElement("img");
  img.className = "remote-qr";
  img.width = 240;
  img.height = 240;
  img.alt = "QR-Code der Fernbedienung";
  const qrSrc = () =>
    remoteUrl + "-qr.svg?origin=" + encodeURIComponent(location.origin) + "&v=" + Date.now();
  img.src = qrSrc();
  const link = document.createElement("a");
  link.className = "remote-qr-link";
  link.href = remoteUrl;
  link.target = "_blank";
  link.textContent = "Ohne Code: " + location.origin + remoteUrl + " (mit Anmeldung)";
  const renew = document.createElement("button");
  renew.type = "button";
  renew.className = "small remote-qr-renew";
  renew.textContent = "Neuen Code erzeugen";
  renew.title = "Alle bisher gezeigten Codes dieser Präsentation werden ungültig";
  const status = document.createElement("p");
  status.className = "remote-qr-status";
  status.setAttribute("role", "status");
  renew.addEventListener("click", async () => {
    renew.disabled = true;
    try {
      const r = await fetch(deckApiUrl + "/remote-links/renew", { method: "POST" });
      if (!r.ok) throw new Error(String(r.status));
      img.src = qrSrc();
      status.textContent = "Neuer Code. Die bisherigen gelten nicht mehr.";
    } catch (e) {
      status.textContent = "Der Code konnte nicht erneuert werden.";
    } finally {
      renew.disabled = false;
    }
  });
  const parts = [about, img, link, renew, status];
  if (localOnly(location.hostname)) {
    const warn = document.createElement("p");
    warn.className = "remote-qr-warning";
    warn.textContent =
      "Achtung: «" + location.hostname + "» erreicht nur dieser Computer. Öffnen Sie Folien " +
      "über seine Netzwerkadresse (z. B. 192.168.…), damit das Telefon es findet.";
    parts.push(warn);
  }
  return parts;
}

function localOnly(host) {
  return host === "localhost" || host.endsWith(".localhost") || host.startsWith("127.") ||
    host === "[::1]" || host === "::1";
}
