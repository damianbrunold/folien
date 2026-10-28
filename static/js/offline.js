// The offline player of a bundle (player/index.html in the zip): the same
// presentation as the app's, from the data in deck-data.js, with the
// images and videos of the bundle's assets folder. No server: no
// presenter console or remote. Built into one classic script by
// src/app-jsbundle.sld, since browsers do not load modules from files.

import { startPresentation } from "./present-app.js";

const root = document.getElementById("present");
const data = window.FOLIEN_BUNDLE;

Promise.all([
  document.fonts.load("400 40px Inter"),
  document.fonts.load("900 40px Inter"),
])
  .catch(() => {})
  .then(() =>
    startPresentation(root, {
      deck: data.deck,
      doc: data.doc,
      design: data.design,
      assetUrl: (sha) => data.assets[sha] || "",
      exitUrl: null,
      eventsUrl: null,
    }),
  );
