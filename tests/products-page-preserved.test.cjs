const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const source = fs.readFileSync(path.join(__dirname, "../index.html"), "utf8");

test("Products page remains accessible and owner uploads remain available", () => {
  assert.match(source, /"\/products":products/);
  assert.match(source, /onclick="editProduct\(\)"/);
  assert.match(source, /Nothing listed yet/);
});

test("Retired PC builder has no route, public menu item, or homepage links", () => {
  assert.doesNotMatch(source, /"\/build":build/);
  assert.doesNotMatch(source, /function build\(\)\{/);
  assert.doesNotMatch(source, /href="#\/build"/);
  assert.match(source, /if\(r==="\/build"\)\{go\("\/products"\);return;\}/);
});
