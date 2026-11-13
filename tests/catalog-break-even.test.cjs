const test = require("node:test");
const assert = require("node:assert/strict");
const { quote, applyToRecord } = require("../catalog-pricing.js");
const catalog = require("../data.json");

test("stored prices recover supplier costs and modeled payment/shipping expenses", () => {
  const settings = catalog.settings;
  assert.equal(settings.pricingPolicy.targetNetMarginPercent, 0);
  const all = [...catalog.products, ...catalog.parts];
  const mirrors = new Map();
  for (const rec of all) {
    if (mirrors.has(rec.id)) assert.equal(rec.price, mirrors.get(rec.id), "Conflicting price for " + rec.id);
    mirrors.set(rec.id, rec.price);
    if (!(Number(rec.neweggPrice) > 0)) {
      assert.equal(rec.active, false, "Item without verified Newegg cost must remain inactive: " + rec.name);
      continue;
    }
    const result = quote(rec.neweggPrice, settings, rec.extraCostUSD ?? 0);
    assert.equal(rec.price, result.price, "Unexpected break-even price for " + rec.name);
    assert.ok(result.contribution >= 0 && result.contribution < 0.02, "Not near break-even: " + rec.name);
  }
  // An intentionally empty catalog is valid; owner uploads may add items again later.
});

test("updating a supplier cost does not retain the previous 20% markup", () => {
  const settings = catalog.settings;
  const sample = [...catalog.products, ...catalog.parts].find(rec => Number(rec.neweggPrice) > 0) || {
    id: "fixture", name: "Example part", neweggPrice: 100, price: 115,
    active: true, seller: "Newegg", stockStatus: "In Stock"
  };
  const rec = { ...sample, price: sample.price + 1000 };
  const expected = quote(rec.neweggPrice, settings, rec.extraCostUSD ?? 0).price;
  applyToRecord(rec, settings);
  assert.equal(rec.price, expected);
});

test("optional additional costs are fully recovered", () => {
  const q = quote(100, catalog.settings, 12.75);
  assert.ok(q.contribution >= 0 && q.contribution < 0.02);
  assert.ok(q.price > quote(100, catalog.settings).price);
});
