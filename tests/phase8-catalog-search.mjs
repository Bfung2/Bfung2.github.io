import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";

const html=await fs.readFile(new URL("../index.html",import.meta.url),"utf8");
const availability=html.slice(html.indexOf("function apexPurchasable(rec){"),html.indexOf("function apexUnavailableCartItems(){"));
const search=html.slice(html.indexOf("/* Customer category synonyms"),html.indexOf("function globalSearchInput(value){"));
assert.ok(availability.startsWith("function apexPurchasable"));
assert.ok(search.startsWith("/* Customer category synonyms"));
const ctx=vm.createContext({
  gpuVendorOf:gpu=>/nvidia|geforce|rtx/i.test(gpu.name||"")?"NVIDIA":/radeon|\brx\b/i.test(gpu.name||"")?"AMD":""
});
vm.runInContext(availability+search,ctx);
ctx.item={id:"test",name:"MSI GeForce RTX 5070 OC",brand:"MSI",category:"Graphics card",keywords:["rtx 5070"],stockStatus:"In Stock",seller:"Newegg"};
const run=code=>vm.runInContext(code,ctx);
for(const query of ["gpu","graphics card","nvidia gpu","nvidia graphics card","nvidia rtx 5070","MSI RTX 5070"]){
  assert.equal(run("matchesProductSearch(item,"+JSON.stringify(query)+")"),true,query);
}
assert.equal(run('matchesProductSearch(item,"amd gpu")'),false);
ctx.item={name:"G.Skill Ripjaws DDR5",category:"Memory",brand:"G.Skill"};
for(const q of ["ram","memory","ddr5 ram"])assert.equal(run("matchesProductSearch(item,"+JSON.stringify(q)+")"),true,q);
ctx.item={name:"Samsung 990 Pro",category:"Storage",driveType:"SSD"};
for(const q of ["ssd","solid state drive","storage ssd"])assert.equal(run("matchesProductSearch(item,"+JSON.stringify(q)+")"),true,q);
ctx.item={name:"Seagate IronWolf 8TB",category:"Storage",driveType:"HDD"};
assert.equal(run('matchesProductSearch(item,"hard drive")'),true);
ctx.item={name:"Corsair RM850x",category:"Power supply"};
for(const q of ["psu","power supply"])assert.equal(run("matchesProductSearch(item,"+JSON.stringify(q)+")"),true,q);
ctx.item={name:"Thermalright Aqua",category:"CPU cooler",coolingType:"Liquid"};
assert.equal(run('matchesProductSearch(item,"water cooling")'),true);
ctx.item={name:"ASRock B650",category:"Motherboard"};
assert.equal(run('matchesProductSearch(item,"mobo")'),true);

// Explicitly disqualified listings must not reach checkout. Unknown evidence remains a review flag,
// not fabricated stock/seller certainty.
for(const status of ["Sold Out","Out of Stock","Backordered","Price verification required","Pre-order","Unavailable"]){
  ctx.record={seller:"Newegg",stockStatus:status};
  assert.equal(run("apexPurchasable(record)"),false,status);
}
ctx.record={seller:"Marketplace Computers",stockStatus:"In Stock"};
assert.equal(run("apexPurchasable(record)"),false);
ctx.record={seller:"Newegg",stockStatus:"In Stock"};
assert.equal(run("apexPurchasable(record)"),true);
ctx.record={stockStatus:"",seller:""};
assert.equal(run("apexPurchasable(record)"),true);
ctx.record={seller:"Newegg",stockStatus:"In Stock",active:false};
assert.equal(run("apexPurchasable(record)"),false);
console.log("PASS: category synonyms, multiword NVIDIA/GPU search, SSD/HDD, memory, cooler, known seller and inventory eligibility.");
