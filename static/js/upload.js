// Uploading images and videos: preparing files in the browser and sending
// them to POST <deck api>/assets.
//
// Images end up as PNG or JPEG (what the PDF export can embed) of at most
// MAX_SIDE pixels: JPEG files within that size go up unchanged; PNGs are
// redrawn on a canvas, which gives the 8-bit RGBA PNG the PDF export
// takes (a PNG may be paletted or 16-bit); anything else (WebP, GIF,
// BMP) is redrawn as JPEG when it is opaque and PNG when it has
// transparency. SVG stays SVG. Videos go up as they are, with a poster frame (JPEG) taken from
// the first second, which is what PDF and thumbnails show.

export const MAX_SIDE = 3840;

export const ACCEPT =
  "image/png,image/jpeg,image/gif,image/webp,image/bmp,image/svg+xml,video/mp4,video/webm,video/quicktime";

export function isVideo(file) {
  return file.type.startsWith("video/");
}

export function isImage(file) {
  return file.type.startsWith("image/");
}

function canvasBlob(canvas, type, quality) {
  return new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("canvas"))), type, quality),
  );
}

function withExtension(name, ext) {
  const base = name.replace(/\.[^./\\]*$/, "");
  return (base || "bild") + ext;
}

function svgSize(file) {
  return new Promise((resolve) => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      resolve({ width: img.naturalWidth || 800, height: img.naturalHeight || 600 });
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      resolve({ width: 800, height: 600 });
    };
    img.src = url;
  });
}

function hasTransparency(ctx, w, h) {
  const data = ctx.getImageData(0, 0, w, h).data;
  for (let i = 3; i < data.length; i += 4) if (data[i] < 255) return true;
  return false;
}

// {blob, name, width, height} ready to upload.
export async function prepareImage(file) {
  const name = file.name || "bild";
  if (file.type === "image/svg+xml") {
    return Object.assign({ blob: file, name }, await svgSize(file));
  }
  let bmp;
  try {
    bmp = await createImageBitmap(file);
  } catch (e) {
    throw new Error("Dieses Bildformat kann nicht gelesen werden.");
  }
  const w = bmp.width;
  const h = bmp.height;
  const fits = Math.max(w, h) <= MAX_SIDE;
  if (fits && file.type === "image/jpeg") {
    bmp.close();
    return { blob: file, name, width: w, height: h };
  }
  const s = Math.min(1, MAX_SIDE / Math.max(w, h));
  const cw = Math.max(1, Math.round(w * s));
  const ch = Math.max(1, Math.round(h * s));
  const canvas = document.createElement("canvas");
  canvas.width = cw;
  canvas.height = ch;
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bmp, 0, 0, cw, ch);
  bmp.close();
  const png = file.type === "image/png" || (file.type !== "image/jpeg" && hasTransparency(ctx, cw, ch));
  const blob = png ? await canvasBlob(canvas, "image/png") : await canvasBlob(canvas, "image/jpeg", 0.9);
  return { blob, name: withExtension(name, png ? ".png" : ".jpg"), width: cw, height: ch };
}

function once(target, event, timeout) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timeout")), timeout);
    target.addEventListener(event, () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    target.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error("Dieses Video kann der Browser nicht lesen."));
    }, { once: true });
  });
}

// A poster frame of a video (a File or a URL): {blob, name, width, height}.
export async function videoPoster(src, name) {
  const url = typeof src === "string" ? src : URL.createObjectURL(src);
  const v = document.createElement("video");
  v.muted = true;
  v.playsInline = true;
  v.preload = "auto";
  try {
    v.src = url;
    await once(v, "loadeddata", 20000);
    const t = Math.min(1, (v.duration || 0) / 10);
    if (t > 0) {
      v.currentTime = t;
      await once(v, "seeked", 20000);
    }
    const w = v.videoWidth || 1280;
    const h = v.videoHeight || 720;
    const s = Math.min(1, 1920 / Math.max(w, h));
    const canvas = document.createElement("canvas");
    canvas.width = Math.round(w * s);
    canvas.height = Math.round(h * s);
    canvas.getContext("2d").drawImage(v, 0, 0, canvas.width, canvas.height);
    const blob = await canvasBlob(canvas, "image/jpeg", 0.85);
    return { blob, name: withExtension(name || "video", ".poster.jpg"), width: w, height: h };
  } finally {
    if (typeof src !== "string") URL.revokeObjectURL(url);
    v.removeAttribute("src");
    v.load();
  }
}

// Sends a blob as an asset of the deck; resolves with the asset
// ({sha, mime, size, width, height, name}). onProgress(fraction).
export function upload(deckUrl, blob, name, size, onProgress) {
  const q = new URLSearchParams({ name });
  if (size && size.width) q.set("w", String(Math.round(size.width)));
  if (size && size.height) q.set("h", String(Math.round(size.height)));
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open("POST", deckUrl + "/assets?" + q.toString());
    xhr.setRequestHeader("Content-Type", blob.type || "application/octet-stream");
    xhr.responseType = "json";
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && onProgress) onProgress(e.loaded / e.total);
    };
    xhr.onload = () => {
      if (xhr.status === 201) resolve(xhr.response);
      else if (xhr.status === 413) reject(new Error("Die Datei ist zu gross."));
      else if (xhr.status === 415) reject(new Error("Dieser Dateityp wird nicht unterstützt."));
      else if (xhr.status === 403) reject(new Error("Die Präsentation ist schreibgeschützt."));
      else reject(new Error("Hochladen fehlgeschlagen (" + xhr.status + ")."));
    };
    xhr.onerror = () => reject(new Error("Keine Verbindung."));
    xhr.send(blob);
  });
}

// The images and videos of a deck: [{sha, mime, ...}], newest first.
export async function listAssets(deckUrl) {
  const r = await fetch(deckUrl + "/assets", { headers: { Accept: "application/json" } });
  if (!r.ok) throw new Error("assets " + r.status);
  return r.json();
}

// Images and videos from a list of files (drop, paste, file input).
export function mediaFiles(fileList) {
  return Array.from(fileList || []).filter((f) => isImage(f) || isVideo(f));
}

// Images and videos on the clipboard: some browsers offer a pasted
// screenshot only as a clipboard item, not in files.
export function clipboardMedia(dt) {
  if (!dt) return [];
  const files = mediaFiles(dt.files);
  if (files.length) return files;
  return mediaFiles(
    Array.from(dt.items || [])
      .filter((i) => i.kind === "file")
      .map((i) => i.getAsFile())
      .filter(Boolean),
  );
}
