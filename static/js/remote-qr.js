// The remote control's address as a QR code, for the presenter console
// and the deck page: scanned with a phone's camera, it opens the remote
// (after signing in, if the phone is not yet). The server draws the code
// (/decks/<id>/remote-qr.svg) from this browser's origin, which is how
// the phone has to reach the site too.

// The parts of the box: the code, the address as a link, and a warning
// where this browser uses an address only it can reach.
export function remoteQrParts(remoteUrl) {
  const img = document.createElement("img");
  img.className = "remote-qr";
  img.width = 240;
  img.height = 240;
  img.alt = "QR-Code der Fernbedienung: " + location.origin + remoteUrl;
  img.src = remoteUrl + "-qr.svg?origin=" + encodeURIComponent(location.origin);
  const link = document.createElement("a");
  link.className = "remote-qr-link";
  link.href = remoteUrl;
  link.target = "_blank";
  link.textContent = location.origin + remoteUrl;
  const parts = [img, link];
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
