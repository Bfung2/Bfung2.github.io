import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const data=JSON.parse(await fs.readFile(new URL('../data.json',import.meta.url),'utf8'));
for(const [id,baseline] of [['gpurx9070greasusprime3x',779.99],['gpu3060msiventus2x',463.99]]){const rows=[...data.products,...data.parts].filter(p=>p.id===id);assert.equal(rows.length,2);for(const p of rows){assert.equal(p.neweggPrice,baseline);assert.equal(p.price,Math.round((baseline+15)*100)/100);assert.equal(p.seller,'Newegg');assert.equal(p.active,true);assert.equal(p.stockStatus,'In Stock');assert.ok(p.sourceUrl.startsWith('https://www.newegg.com/'));assert.ok(p.lengthMm>0);assert.equal(p.tdp,'');assert.equal(p.watts,'');}}
for(const id of ['gpu5060tiventus2x16','gpu5070gigawindforce3x'])for(const p of [...data.products,...data.parts].filter(p=>p.id===id)){assert.equal(p.active,false);assert.ok(p.lengthMm>0);assert.ok(p.specSourceUrl.startsWith('https://www.newegg.com/'));}
assert.equal(data.parts.find(p=>p.id==='cooler13C-001F-00070').heightMm,168);
console.log('PASS: verified duplicate records synchronized at baseline + $15, eligibility retained, marketplace listings disabled, and sourced fit metadata present.');
