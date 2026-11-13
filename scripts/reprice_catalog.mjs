#!/usr/bin/env node
// For newly imported Newegg products: node scripts/reprice_catalog.mjs [--write] [--exact]
// Defaults to a non-destructive preview; --write raises prices below the minimum.
// --exact explicitly resets every cost-backed item to the current model minimum.
import fs from 'node:fs/promises';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const pricing=require('../catalog-pricing.js');
const path=new URL('../data.json',import.meta.url);
const data=JSON.parse(await fs.readFile(path,'utf8'));
const exact=process.argv.includes('--exact'),write=process.argv.includes('--write');
const byId=new Map();
let noCost=0,inactive=0;
for(const rec of [...data.products,...data.parts]){
  const cost=Number(rec.neweggPrice);
  if(!Number.isFinite(cost)||cost<=0){noCost++;if(rec.active!==false&&rec.category!=='Tech Service'&&rec.category!=='Donation'){rec.active=false;inactive++;}continue;}
  const target=pricing.quote(cost,data.settings).price;
  const existing=byId.get(rec.id);
  byId.set(rec.id,exact?target:Math.max(target,existing||0,Number(rec.price)||0));
}
let repriced=0;
for(const rec of [...data.products,...data.parts]){
  if(!byId.has(rec.id))continue;
  const next=byId.get(rec.id);
  if(rec.price!==next){rec.price=next;repriced++;}
}
console.log(JSON.stringify({uniqueCostBackedSKUs:byId.size,repricedRecords:repriced,missingCostRecords:noCost,deactivatedMissingCost:inactive,taxRate:data.settings.taxRate,shippingRate:data.settings.shippingRatePercent,write,exact},null,2));
if(write)await fs.writeFile(path,JSON.stringify(data,null,2)+'\n');
else console.log('DRY RUN: no file changed. Add --write to apply changes.');
