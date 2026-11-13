import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

const settings={
  shippingRatePercent:18, taxRate:11.5,
  pricingPolicy:{targetNetMarginPercent:20,assumedPaymentFeePercent:4.99,
    assumedPaymentFixedUSD:0.49,assumedTaxRatePercent:11.5,assumedShippingExpensePercent:18}
};
const ctx=vm.createContext({URL,Date,Math});
const source=await fs.readFile('catalog-pricing.js','utf8');
vm.runInContext(source,ctx);
const engine=ctx.apexProfitPricing;
assert.ok(engine&&typeof engine.quote==='function');
const validUrl='https://www.newegg.com/intel-core-i5/p/N82E16811111111';
const now=new Date('2026-11-13T12:00:00Z');

for(const cost of [.01,9.99,99,249.99,463.99,7189.99]){
  const quote=engine.quote(cost,settings);
  assert.ok(quote.price>cost, 'price must cover the supplier');
  assert.ok(quote.marginPercent>=20-1e-8, 'margin must be at least 20%');
  const cents=p=>Math.round(p*100);
  const p=cents(quote.price),c=cents(cost),s=Math.round(p*.18),t=Math.round(p*.115);
  const fee=Math.round((p+s+t)*.0499+49);
  assert.ok(p-c-fee>=p*.20-1e-8, 'exact cents margin must pass');
}
const current=engine.quote(249.99,settings);
assert.equal(current.price,340.62);
const earlier=engine.quote(249.99,{...settings,taxRate:14.5});
assert.ok(current.price<earlier.price,'lower modeled tax should reduce minimum price');

const record={id:'new-cpu',name:'CPU',category:'CPU',price:100,
  neweggPrice:249.99,seller:'Newegg',stockStatus:'In Stock',
  sourceUrl:validUrl,verifiedDate:'2026-11-12',active:true};
assert.equal(engine.eligibleForSale(record,now),true);
engine.applyToRecord(record,settings,{now});
assert.equal(record.price,current.price);
assert.equal(record.active,true);
for(const patch of [
  {seller:'Marketplace'}, {stockStatus:'Backordered'},
  {sourceUrl:'https://marketplace.example/p/123'},
  {verifiedDate:'2026-10-01'}
]){
  const copy={...record,...patch,active:true};
  engine.applyToRecord(copy,settings,{now});
  assert.equal(copy.active,false,JSON.stringify(patch));
}
const premium={...record,price:500,active:true};
engine.applyToRecord(premium,settings,{now});
assert.equal(premium.price,500,'owner may price higher but not below margin floor');

const data=JSON.parse(await fs.readFile('data.json','utf8'));
assert.equal(data.settings.shippingRatePercent,18);
assert.equal(data.settings.taxRate,11.5);
assert.equal(data.settings.pricingPolicy.assumedTaxRatePercent,11.5);
const mirrored=new Map();
let count=0,notPriced=0;
for(const rec of [...data.products,...data.parts]){
  const cost=Number(rec.neweggPrice);
  if(!Number.isFinite(cost)||cost<=0){notPriced++;assert.equal(rec.active,false);continue;}
  count++;
  const minimum=engine.quote(cost,data.settings).price;
  assert.ok(rec.price>=minimum-0.001,rec.name+' underpriced');
  if(mirrored.has(rec.id))assert.equal(mirrored.get(rec.id),rec.price);
  mirrored.set(rec.id,rec.price);
}
assert.equal(count,716);
assert.equal(notPriced,18);
assert.equal(mirrored.size,704);
const html=await fs.readFile('index.html','utf8');
assert.match(html,/<script src="catalog-pricing\.js"><\/script>/);
assert.match(html,/apexProfitPricing\.applyToRecord\(rec,S\.settings\)/);
assert.match(html,/supplierPricingFields\("p",p\)/);
assert.match(html,/supplierPricingFields\("q",p\)/);
assert.match(html,/raiseUnderpricedCatalogItems\(\)/);
console.log('PASS: new products and parts enforce margin floor and verified Newegg seller/stock; 716 priced records meet 20% model, proposed 11.5% tax and 18% shipping.');
