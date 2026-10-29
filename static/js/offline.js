// The offline player (player/index.html in a bundle, or an offline
// export): the same presentation as the app's, from the data in
// window.FOLIEN_BUNDLE, with the images and videos of its assets folder,
// or, in the one-file export, from base64 blocks in the page
// (<script type="application/x-folien-asset" data-sha data-mime>), which
// become blob URLs. With ?referent in the address the page is the
// presenter console instead (R switches to it), which opens the
// presentation for the audience as a second window of the same page; the
// two talk directly (see Sync). No server: no remote. Built into one
// classic script by src/app-jsbundle.sld, since browsers do not load
// modules from files.

import { startPresentation } from "./present-app.js";
import { startPresenter } from "./presenter-app.js";
import { loadDesignFonts } from "./render.js";
import { hashOf } from "./sync.js";

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

// This page without query and hash: the presentation; with ?referent:
// the console.
const page = location.href.split(/[?#]/)[0];
const presenter = /^\?referent\b/.test(location.search);
const opts = {
  deck: data.deck,
  doc: data.doc,
  design: data.design,
  assetUrl: (sha) => urls[sha] || "",
  eventsUrl: null,
  windows: true,
};

loadDesignFonts(data.design).then(() => {
  if (presenter) {
    document.body.className = "presenter-body";
    root.id = root.className = "presenter";
    startPresenter(root, {
      ...opts,
      presentUrl: page,
      exitUrl: (pos) => page + hashOf(pos),
      exitTitle: "Zurück zur Präsentation",
    });
  } else {
    startPresentation(root, { ...opts, exitUrl: null, presenterUrl: page + "?referent" });
  }
});
