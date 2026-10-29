// The offline player (player/index.html in a bundle, or an offline
// export): the same presentation as the app's, from the data in
// window.FOLIEN_BUNDLE, with the images and videos of its assets folder,
// or, in the one-file export, from base64 blocks in the page
// (<script type="application/x-folien-asset" data-sha data-mime>), which
// become blob URLs. No server: no presenter console or remote. Built into
// one classic script by src/app-jsbundle.sld, since browsers do not load
// modules from files.

import { startPresentation } from "./present-app.js";
import { loadDesignFonts } from "./render.js";

const root = document.getElementById("present");
const data = window.FOLIEN_BUNDLE;
const urls = Object.assign({}, data.assets);

for (const block of document.querySelectorAll('script[type="application/x-folien-asset"]')) {
  const bin = atob(block.textContent.trim());
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  urls[block.dataset.sha] = URL.createObjectURL(new Blob([bytes], { type: block.dataset.mime }));
  block.remove(); // the text is not needed any more
}

loadDesignFonts(data.design).then(() =>
    startPresentation(root, {
      deck: data.deck,
      doc: data.doc,
      design: data.design,
      assetUrl: (sha) => urls[sha] || "",
      exitUrl: null,
      eventsUrl: null,
    }),
  );
