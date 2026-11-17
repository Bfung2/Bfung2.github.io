import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
const {quote}=createRequire(import.meta.url)('../catalog-pricing.js');
const data=JSON.parse(await fs.readFile('data.json','utf8'));
assert.ok(Array.isArray(data.products)&&Array.isArray(data.parts));
const ids=new Map();
for(const p of [...data.products,...data.parts]){
 assert.ok(p.id&&p.name);assert.ok(Number.isFinite(p.price)&&p.price>0);
 if(ids.has(p.id))assert.equal(p.price,ids.get(p.id),'Mirror price conflict: '+p.id);
 ids.set(p.id,p.price);
 if(p.active===false)continue;
 if(p.neweggPrice!=null){assert.equal(p.seller,'Newegg');assert.equal(p.stockStatus,'In Stock');assert.match(p.sourceUrl,/^https:\/\/www\.newegg\.com\//);assert.ok(p.price>=quote(p.neweggPrice,data.settings,p.extraCostUSD??0).price);}
}
console.log('PASS: current catalog structure, mirror prices and active supplier-price floors; empty catalog is supported.');
