import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
const html=await fs.readFile('index.html','utf8');
const server=await fs.readFile('supabase/functions/paypal-checkout/index.ts','utf8');
const context=vm.createContext({console,roundMoney:n=>Math.round((n+Number.EPSILON)*100)/100,S:{products:[],parts:[],settings:{buildFee:25,taxRate:10,shippingFee:5}},myCart:[],saveCart(){},render(){},toast(){}});
vm.runInContext(html.slice(html.indexOf('function apexPurchasable('),html.indexOf('/* ---------- global storefront search')),context);
vm.runInContext(stripTypeScriptTypes(server.slice(server.indexOf('function calculateOrder('),server.indexOf('Deno.serve('))),context);
const run=src=>vm.runInContext(src,context);
run(`S.products=[{id:'cpu',category:'CPU',name:'CPU',price:200},{id:'gpu',category:'Graphics card',name:'GPU',price:300}];`);
const product={kind:'product',id:'cpu',qty:2,price:0.01};
context.item=product;
assert.equal(run('apexResolveCartItem(item).price'),200);
assert.equal(run('calculateOrder([item],S).subtotal'),400);
for(const patch of [{active:false},{seller:'Marketplace'},{stockStatus:'Backordered'},{stockStatus:'Out of Stock'},{stockStatus:'Pre-order'}]){
 context.patch=patch;run('Object.assign(S.products[0],patch)');
 assert.equal(run('apexResolveCartItem(item)'),null);
 assert.throws(()=>run('calculateOrder([item],S)'),/unavailable/);
 run(`S.products[0]={id:'cpu',category:'CPU',name:'CPU',price:200}`);
}
context.item={kind:'product',id:'missing',qty:1,price:1};
assert.equal(run('apexResolveCartItem(item)'),null);assert.throws(()=>run('calculateOrder([item],S)'),/unavailable/);
context.item=product;run(`S.parts=[{...S.products[0],price:201}]`);
assert.equal(run('apexResolveCartItem(item)'),null);assert.throws(()=>run('calculateOrder([item],S)'),/unavailable/);
run('S.parts=[]');
context.item={kind:'build',id:'custom',parts:[{id:'cpu',price:1},{id:'gpu',price:1}],assembly:true,fee:0,price:2,qty:9};
assert.equal(run('apexResolveCartItem(item).price'),525);assert.equal(run('apexResolveCartItem(item).qty'),1);
assert.equal(run('calculateOrder([item],S).subtotal'),525);
run('myCart=[item]');assert.equal(run('cartTotals().total'),582.5);
run('S.products[1].active=false');assert.equal(run('apexUnavailableCartItems().length'),1);assert.throws(()=>run('calculateOrder([item],S)'),/unavailable/);
const data=JSON.parse(await fs.readFile('data.json','utf8'));
for(const id of ['gpu5060tiventus2x16','gpu5070gigawindforce3x']){
 const rows=[...data.products,...data.parts].filter(p=>p.id===id);
 assert.equal(new Set(rows.map(p=>p.price)).size,1);assert.ok(rows.every(p=>p.active===false));
 assert.ok(rows.every(p=>!p.longDesc.includes('Newegg price:')&&!p.longDesc.includes('Newegg direct price:')));
}
console.log('PASS: frontend and server reject unknown/unavailable/conflicting items, ignore forged prices, reprice builds and fees, and keep disabled GPU mirrors consistent.');
