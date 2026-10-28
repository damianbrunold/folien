// Importing a bundle (a zip exported by folien) from the presentations
// page: the file goes to POST /api/import as it is, and the new deck
// opens in the editor.

const input = document.querySelector(".js-import");
const status = document.querySelector(".js-import-status");

if (input) {
  input.addEventListener("change", async () => {
    const file = input.files && input.files[0];
    if (!file) return;
    status.textContent = "Importiere " + file.name + " …";
    status.classList.remove("error-text");
    try {
      const r = await fetch(input.dataset.importUrl, {
        method: "POST",
        headers: { "Content-Type": "application/zip" },
        body: file,
      });
      const j = await r.json().catch(() => ({}));
      if (r.status === 201 && j.id) {
        location.href = input.dataset.deckBase + j.id + "/edit";
        return;
      }
      status.textContent =
        j.error || (r.status === 413 ? "Die Datei ist zu gross." : "Der Import ist fehlgeschlagen (" + r.status + ").");
    } catch (e) {
      status.textContent = "Keine Verbindung.";
    }
    status.classList.add("error-text");
    input.value = "";
  });
}
