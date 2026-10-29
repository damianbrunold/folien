// The presenter console page: loads the deck from the server and shows
// the console (presenter-app.js), with the audience window and the remote
// in step.

import { startPresenter } from "./presenter-app.js";
import { loadDeck } from "./sync.js";

const root = document.getElementById("presenter");
const urls = root.dataset;

loadDeck(urls)
  .then(({ deck, doc, design }) => {
    const assetUrl = (sha) => urls.deckUrl + "/assets/" + sha;
    startPresenter(root, {
      deck,
      doc,
      design,
      assetUrl,
      previewUrl: (sha) => assetUrl(sha) + "?w=1280",
      presentUrl: urls.presentUrl,
      exitUrl: urls.viewUrl,
      eventsUrl: urls.eventsUrl,
      remoteUrl: urls.remoteUrl,
      deckUrl: urls.deckUrl,
    });
  })
  .catch((err) => {
    const p = document.createElement("p");
    p.className = "present-error";
    p.textContent = "Die Referentenansicht konnte nicht geladen werden.";
    root.replaceChildren(p);
    console.error(err);
  });
