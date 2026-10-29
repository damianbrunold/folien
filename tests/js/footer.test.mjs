// Tests for the footer fields of static/js/render.js: footerElements
// agrees with (footer-elements) of src/app-model.sld, which the PDF and
// PPTX exports use. Run: node --test tests/js/

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { footerElements, slideNumber, todayText } from "../../static/js/render.js";

const root = new URL("../..", import.meta.url).pathname;
const designs = JSON.parse(
  execFileSync("scm", [root + "tests/js/designs-json.scm"], { encoding: "utf8" }),
);

const slide = (id, layout, more = {}) => ({ id, layout, elements: [], ...more });
const doc = {
  format: 1,
  footer: { text: "Fuss", number: true, date: "auto" },
  slides: [
    slide("t", "title"),
    slide("a", "section", { hidden: true }),
    slide("b", "title-content"),
    slide("c", "blank", { footer: false }),
    slide("d", "blank"),
  ],
};

function schemeFooters(design, d) {
  return JSON.parse(
    execFileSync("scm", [root + "tests/js/footer-json.scm", design, JSON.stringify(d)], {
      encoding: "utf8",
    }),
  );
}

for (const id of ["folien", "zh"]) {
  test("footerElements agrees with the server in " + id, () => {
    const design = designs.find((x) => x.id === id);
    for (const d of [doc, { ...doc, footer: { ...doc.footer, titleSlides: true, date: "fixed", dateText: "Mai" } }]) {
      const js = d.slides.map((_, i) => footerElements(d, design, i, "01.11.2026"));
      assert.deepEqual(js, schemeFooters(id, d));
    }
  });
}

test("slide numbers skip hidden slides", () => {
  assert.deepEqual(doc.slides.map((_, i) => slideNumber(doc, i)), [1, 2, 2, 3, 4]);
});

test("no footer, no fields", () => {
  const design = designs[0];
  assert.deepEqual(footerElements({ ...doc, footer: undefined }, design, 2), []);
  assert.deepEqual(footerElements(doc, design, 0), []);
  assert.deepEqual(footerElements(doc, design, 3), []);
});

test("todayText", () => {
  assert.equal(todayText(new Date(2026, 10, 1)), "01.11.2026");
});
