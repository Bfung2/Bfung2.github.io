import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const data=JSON.parse(await fs.readFile('data.json','utf8'));
const changes=JSON.parse(await fs.readFile('audits/2026-11-12/confirmed-catalog-changes.json','utf8'));
const records=[...data.products,...data.parts];
for(const id of new Set(changes.map(c=>c.id))){
 const rows=records.filter(p=>p.id===id);assert.ok(rows.length);
 for(const p of rows){
  if(/out\s*of\s*stock|back[\s-]*order|sold\s*out|unavailable|discontinued|price\s*verification\s*required|pre[\s-]*order/i.test(p.stockStatus||''))assert.equal(p.active,false,p.name);
  if(p.stockStatus==='In Stock'&&p.verifiedDate==='2026-11-12'){
   assert.equal(p.seller,'Newegg',p.name);
   assert.ok(/^https:\/\/www\.newegg\.com\/.*\/p\/|^https:\/\/www\.newegg\.com\/p\//.test(p.sourceUrl),p.name);
   assert.equal(Math.round((p.price-p.neweggPrice)*100),1500,p.name);
  }
 }
 if(rows.length>1)assert.equal(new Set(rows.map(p=>p.price)).size,1,id);
}
console.log('PASS: evidence-backed price markup, inactive ineligible inventory and same-ID consistency.');
