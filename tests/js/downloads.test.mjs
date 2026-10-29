// Tests for the file name of a download (static/js/downloads.js). Run:
// node --test tests/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import { dispositionName } from "../../static/js/downloads.js";

test("the file name comes from Content-Disposition", () => {
  // as the server sends it: an ASCII fallback, then the UTF-8 name
  assert.equal(
    dispositionName("attachment; filename=\"Folien _ Pr_sentationen.zip\"; filename*=UTF-8''Folien%20%E2%80%93%20Pr%C3%A4sentationen.zip"),
    "Folien – Präsentationen.zip",
  );
  assert.equal(dispositionName('attachment; filename="plain.pdf"'), "plain.pdf");
  assert.equal(dispositionName("attachment; filename*=UTF-8''%E0%A4%A"), null);
  assert.equal(dispositionName(null), null);
});
