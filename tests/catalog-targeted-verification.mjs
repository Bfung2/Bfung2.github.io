import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const data=JSON.parse(await fs.readFile(new URL('../data.json',import.meta.url),'utf8'));
const feeRate=data.settings.pricingPolicy.assumedPaymentFeePercent/100;
const fixed=data.settings.pricingPolicy.assumedPaymentFixedUSD;
const cent=n=>Math.round((n+Number.EPSILON)*100)/100;
function sufficient(p){
 const ship=cent(p.price*data.settings.shippingRatePercent/100);
 const tax=cent(p.price*data.settings.pricingPolicy.assumedTaxRatePercent/100);
 const fee=cent((p.price+ship+tax)*feeRate+fixed);
 return p.price-p.neweggPrice-fee+0.0001>=p.price*.2;
}
for(const [id,baseline] of [['gpurx9070greasusprime3x',779.99],['gpu3060msiventus2x',463.99]]){
 const rows=[...data.products,...data.parts].filter(p=>p.id===id);assert.equal(rows.length,2);
 for(const p of rows){assert.equal(p.neweggPrice,baseline);assert.ok(sufficient(p));assert.equal(p.seller,'Newegg');assert.equal(p.active,true);assert.equal(p.stockStatus,'In Stock');assert.ok(p.sourceUrl.startsWith('https://www.newegg.com/'));assert.ok(p.lengthMm>0);assert.equal(p.tdp,'');assert.equal(p.watts,'');}
 assert.equal(rows[0].price,rows[1].price);
}
for(const id of ['gpu5060tiventus2x16','gpu5070gigawindforce3x'])for(const p of [...data.products,...data.parts].filter(p=>p.id===id)){
 if(p.seller!=='Newegg'||p.stockStatus!=='In Stock')assert.equal(p.active,false);
 else{assert.equal(p.active,true);assert.ok(sufficient(p));}
 assert.ok(p.lengthMm>0);assert.ok(p.specSourceUrl.startsWith('https://www.newegg.com/'));
}
assert.equal(data.parts.find(p=>p.id==='cooler13C-001F-00070').heightMm,168);
console.log('PASS: exact Newegg cost baselines preserved; model-based price target met, seller eligibility and sourced hardware fit metadata intact.');
