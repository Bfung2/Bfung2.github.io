import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";

const source=await fs.readFile(new URL("../catalog-health.js",import.meta.url),"utf8");
const context=vm.createContext({window:{},URL,Date,console});
vm.runInContext(source,context);
const audit=context.window.ownerCatalogHealth;
const good={id:"good",name:"Apex valid SKU",category:"Graphics card",price:115,neweggPrice:100,
 seller:"Newegg",stockStatus:"In Stock",verifiedDate:"2026-11-11",
 sourceUrl:"https://www.newegg.com/p/N82E123",image:"https://example.invalid/img.png",
 keywords:["gpu","graphics card"],desc:"GPU"};
const bad={...good,id:"bad",name:"<img src=x onerror=alert(1)>",price:114,sourceUrl:"https://not-newegg.invalid/hack",
 stockStatus:"Backordered",seller:"Marketplace",verifiedDate:"2026-11-01"};
const input={products:[good,bad],parts:[{...good,id:"bad",price:117}]};
const result=audit.summary(input,new Date("2026-11-11T12:00:00Z"));
assert.equal(result.unique,2);
assert.equal(result.active,2);
assert.equal(result.critical,1);
assert.equal(result.stale,1);
assert.equal(result.attention,1);
assert.equal(result.clear,1);
const flags=result.rows.find(r=>r.id==="bad").flags.map(f=>f.id);
for(const issue of ["price_conflict","markup","source","seller","stock_ineligible","verification_stale"])assert.ok(flags.includes(issue),issue);
assert.equal(result.rows.find(r=>r.id==="bad").source,null);
const csv=audit.toCSV(result.rows);
assert.ok(csv.includes("apex_price"));
assert.ok(!csv.includes("https://not-newegg.invalid/hack"));
assert.ok(csv.includes('"<img src=x onerror=alert(1)>"')); // CSV is escaped by quotes; not HTML.
const formula=audit.toCSV([{id:"=1+1",name:"+cmd",category:"-",active:true,price:1,baseline:0,flags:[],source:null}]);
assert.ok(formula.includes("\"'=1+1\""));
const missing=audit.summary({products:[{id:"incomplete",name:"Incomplete"}],parts:[]},new Date("2026-11-11T12:00:00Z"));
assert.equal(missing.attention,1);assert.equal(missing.missing,1);
console.log("PASS: owner catalog health flags, SKU deduplication, stale evidence, markup, source validation, CSV formula escaping.");
