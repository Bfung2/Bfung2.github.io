import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const data=JSON.parse(await fs.readFile('data.json','utf8'));
const changes=JSON.parse(await fs.readFile('audits/2026-11-12/confirmed-catalog-changes.json','utf8'));
const records=[...data.products,...data.parts];
const policy=data.settings.pricingPolicy;
assert.equal(data.settings.shippingRatePercent,18);
assert.equal(data.settings.taxRate,11.5);
assert.equal(policy.targetNetMarginPercent,20);
const cent=n=>Math.round((n+Number.EPSILON)*100)/100;
function netFor(p){
 const subtotal=p.price,ship=cent(subtotal*data.settings.shippingRatePercent/100),tax=cent(subtotal*policy.assumedTaxRatePercent/100);
 const fee=cent((subtotal+ship+tax)*policy.assumedPaymentFeePercent/100+policy.assumedPaymentFixedUSD);
 return cent(subtotal-p.neweggPrice-fee);
}
const ids=new Map();
let priced=0,unknown=0;
for(const p of records){
 if(/out\s*of\s*stock|back[\s-]*order|sold\s*out|unavailable|discontinued|price\s*verification\s*required|pre[\s-]*order/i.test(p.stockStatus||'')) assert.equal(p.active,false,p.name);
 if(p.neweggPrice===undefined||p.neweggPrice===null){unknown++;assert.equal(p.active,false,p.id);continue;}
 priced++;
 assert.ok(netFor(p)+0.0001>=p.price*.20,p.name+" below 20% margin");
 if(ids.has(p.id))assert.equal(p.price,ids.get(p.id),p.id);
 ids.set(p.id,p.price);
}
for(const id of new Set(changes.map(c=>c.id))){
 const rows=records.filter(p=>p.id===id);assert.ok(rows.length,id);
 for(const p of rows){if(p.stockStatus==='In Stock'&&p.verifiedDate==='2026-11-12'){assert.equal(p.seller,'Newegg',p.name);assert.match(p.sourceUrl,/^https:\/\/www\.newegg\.com\/(?:.*\/)?p\//,p.name);assert.ok(netFor(p)+0.0001>=p.price*.2,p.name);}}
}
assert.equal(records.length,734);
assert.equal(priced,716);
assert.equal(unknown,18);
assert.equal(ids.size,704);
console.log('PASS: 704 baseline-priced unique SKUs maintain the 20% modeled Pay Later margin; inactive unknown-cost SKUs stay disabled; mirrored prices align.');
