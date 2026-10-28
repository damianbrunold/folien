// The presentation page: loads the deck from the server and presents it
// (present-app.js), with the presenter console and the remote in step.

import { startPresentation } from "./present-app.js";
import { loadDeck } from "./sync.js";

const root = document.getElementById("present");
const urls = root.dataset;

loadDeck(urls)
  .then(({ deck, doc, design }) =>
    startPresentation(root, {
      deck,
      doc,
      design,
      assetUrl: (sha) => urls.deckUrl + "/assets/" + sha,
      exitUrl: urls.viewUrl,
      eventsUrl: urls.eventsUrl,
    }),
  )
  .catch((err) => {
    const p = document.createElement("p");
    p.className = "present-error";
    p.textContent = "Die Präsentation konnte nicht geladen werden.";
    root.replaceChildren(p);
    console.error(err);
  });
