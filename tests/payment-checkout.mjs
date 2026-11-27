// Mocked payment lifecycle: no network, production writes or money movement.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
const source=stripTypeScriptTypes(fs.readFileSync('supabase/functions/paypal-checkout/index.ts','utf8').replace(/^import .*;\n/gm,''));
const receipt='a'.repeat(64), provider='PAYPAL12345678';
const product={id:'cpu',name:'CPU',category:'CPU',price:120,neweggPrice:100,seller:'Newegg',stockStatus:'In Stock'};
const catalog={products:[product],parts:[],settings:{taxRate:7,shippingRatePercent:2,buildFee:0}};
const total=130.8;
function detail(patch={}) {return {id:provider,status:'APPROVED',purchase_units:[{custom_id:'order',amount:{value:String(total),currency_code:'USD'}}],...patch};}
function complete() {const d=detail({status:'COMPLETED'});d.purchase_units[0].payments={captures:[{id:'CAPTURE123',status:'COMPLETED',amount:{value:String(total),currency_code:'USD'}}]};return d;}
async function scenario({action='capture',checkoutToken=receipt,orderPatch={},providerDetails=detail(),captureStatus=201,failSave=false,method='POST',bodyPatch={},bindRace=false,saveRace=false,discount=0,quoteOffer=null,privateSources=[],catalogPatch={}}={}) {
 let handler;const calls=[],writes=[];
 const order={id:'order',ref:'AC-TEST',tracking_token:receipt,pricing_locked:true,paypal_order_id:provider,paypal_capture_id:null,status:'requested',fulfillment_stage:'received',items:[{kind:'product',id:'cpu',qty:1}],total,...orderPatch};
 const admin={from:table=>{let patch,filters=[];const q={select:()=>q,in:async()=>({data:privateSources}),eq:(k,v)=>{filters.push([k,v]);return q;},is:(k,v)=>{filters.push([k,v]);return q;},update:p=>{patch=p;return q;},maybeSingle:async()=>{
  if(table==="apex_pc_quotes")return {data:quoteOffer?{offer:quoteOffer}:null};
  if(patch){writes.push(patch);if(failSave)return {error:{message:'write unavailable'}};if(bindRace&&patch.paypal_order_id){order.paypal_order_id=provider;return {data:null};}if(saveRace&&patch.paypal_capture_id){order.paypal_capture_id='CAPTURE123';order.status='shipped';return {data:null};}Object.assign(order,patch);}
  return {data:{...order},error:null};
 }};return q;},rpc:async()=>({data:{subtotal:120,shipping:2.4,tax:8.4,total:total-discount,discount},error:null}),functions:{invoke:async()=>{calls.push('notify');return {data:{success:true},error:null};}}};
 const env={PAYPAL_CLIENT_ID:'client',PAYPAL_CLIENT_SECRET:'secret',PAYPAL_ENVIRONMENT:'sandbox',SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'service'};
 const ctx=vm.createContext({Request,Response,console:{error(){}},btoa,URL,quoteActualShipping:async()=>({charge:2.4,carrierCost:2.4}),createClient:()=>admin,Deno:{env:{get:k=>env[k]},serve:fn=>handler=fn},fetch:async(url,opts={})=>{
  calls.push((opts.method||'GET')+' '+url);
  if(url.includes('oauth2'))return Response.json({access_token:'token'});
  if(url.includes('raw.githubusercontent'))return Response.json({...catalog,...catalogPatch});
  if(url.endsWith('/capture')){providerDetails=complete();return Response.json({}, {status:captureStatus});}
  if(url.endsWith('/v2/checkout/orders'))return Response.json({id:provider});
  return Response.json(providerDetails);
 }});
 vm.runInContext(source,ctx);
 const response=await handler(new Request('https://example.invalid', {method,headers:{'Content-Type':'application/json'},...(method==='POST'?{body:JSON.stringify({action,orderId:'order',checkoutToken,paypalOrderId:provider,...bodyPatch})}:{})}));
 return {status:response.status,body:await response.json(),calls,writes,order};
}
let r=await scenario({checkoutToken:''});assert.equal(r.status,403);assert.equal(r.calls.length,0);
r=await scenario({checkoutToken:'b'.repeat(64)});assert.equal(r.status,403);assert.equal(r.calls.length,0);
r=await scenario({action:'unknown'});assert.equal(r.status,400);assert.equal(r.calls.length,0);
r=await scenario({orderPatch:{is_test:true}});assert.equal(r.status,409);assert.equal(r.calls.length,0);
for(const patch of [{pricing_locked:false},{paypal_order_id:'OTHERPAYPAL'},{fulfillment_stage:'cancelled'},{status:'refunded'}]){
 r=await scenario({orderPatch:patch});assert.equal(r.status,409,JSON.stringify(patch));assert.equal(r.calls.filter(c=>c.includes('/capture')).length,0);
}
for(const d of [detail({id:'OTHERPAYPAL'}),detail({purchase_units:[{custom_id:'other',amount:{value:String(total),currency_code:'USD'}}]}),detail({purchase_units:[{custom_id:'order',amount:{value:'1',currency_code:'USD'}}]})]){
 r=await scenario({providerDetails:d});assert.equal(r.status,409);assert.equal(r.calls.filter(c=>c.includes('/capture')).length,0);
}
r=await scenario();assert.equal(r.status,200);assert.equal(r.body.success,true);assert.equal(r.writes.length,1);assert.equal(r.calls.filter(c=>c.includes('/capture')).length,1);assert.equal(r.calls.filter(c=>c==='notify').length,1);
r=await scenario({providerDetails:complete(),orderPatch:{status:'cancelled'}});assert.equal(r.status,409);assert.equal(r.writes.length,0);
r=await scenario({providerDetails:complete()});assert.equal(r.status,200);assert.equal(r.calls.filter(c=>c.includes('/capture')).length,0);assert.equal(r.writes.length,1);
r=await scenario({providerDetails:complete(),orderPatch:{paypal_capture_id:'CAPTURE123',status:'shipped'}});assert.equal(r.status,200);assert.equal(r.order.status,'shipped');assert.equal(r.writes.length,0);assert.ok(!r.calls.includes('notify'));
r=await scenario({providerDetails:complete(),saveRace:true});assert.equal(r.status,200);assert.equal(r.order.status,'shipped');assert.ok(!r.calls.includes('notify'));
r=await scenario({captureStatus:422});assert.equal(r.status,200); // canonical success wins over an ambiguous POST response
r=await scenario({failSave:true});assert.equal(r.status,500);assert.match(r.body.error,/Payment succeeded/);
const refunded=complete();refunded.purchase_units[0].payments.captures[0].status='REFUNDED';r=await scenario({providerDetails:refunded});assert.equal(r.status,409);assert.equal(r.writes.length,0);
r=await scenario({action:'create'});assert.equal(r.status,200);assert.equal(r.body.id,provider);assert.equal(r.writes.length,0);assert.ok(!r.calls.some(c=>c.endsWith('/v2/checkout/orders')));
r=await scenario({action:'create',orderPatch:{paypal_order_id:null,pricing_locked:false}});assert.equal(r.status,200);assert.equal(r.order.paypal_order_id,provider);
r=await scenario({action:'create',orderPatch:{paypal_order_id:null},bindRace:true});assert.equal(r.status,200);assert.equal(r.body.id,provider);

r=await scenario({action:'create',orderPatch:{paypal_order_id:null},discount:20});assert.equal(r.status,409);assert.ok(!r.calls.some(c=>c.endsWith('/v2/checkout/orders')));

const quoteItems=[{id:'quote',kind:'quote',qty:1,name:'Custom PC build'}];
const quoteAmounts={subtotal:120,shipping:2.4,tax:8.4,total};
const quoteOffer={subtotal:12000,shipping:240,tax:840,total:13080};
const quoteOrder={...quoteAmounts,items:quoteItems,paypal_order_id:null};
r=await scenario({action:'create',orderPatch:quoteOrder,quoteOffer});
assert.equal(r.status,200);assert.equal(r.body.pricing.total,total);
assert.ok(!r.calls.some(c=>c.includes('raw.githubusercontent')));
for(const invalid of [{orderPatch:quoteOrder},{orderPatch:{...quoteOrder,total:1},quoteOffer},
 {orderPatch:{...quoteOrder,pricing_locked:false},quoteOffer}]){
 r=await scenario({action:'create',...invalid});
 assert.equal(r.status,409);assert.ok(!r.calls.some(c=>c.endsWith('/v2/checkout/orders')));
}
const version='55555555-5555-4555-8555-555555555555';
const {neweggPrice,...publicProduct}=product;
const privateProduct={...publicProduct,supplierVersion:version,verifiedDate:new Date().toISOString().slice(0,10)};
const sourceRow={version,sku:'cpu',source_url:'https://www.newegg.com/p/N82E123',supplier_cost:100,extra_cost:0};
const privateOrder={action:'create',orderPatch:{paypal_order_id:null},catalogPatch:{products:[privateProduct]}};
r=await scenario({...privateOrder,privateSources:[sourceRow]});assert.equal(r.status,200);
r=await scenario(privateOrder);assert.equal(r.status,500);
r=await scenario({...privateOrder,privateSources:[{...sourceRow,sku:'another'}]});assert.equal(r.status,500);
r=await scenario({...privateOrder,privateSources:[{...sourceRow,source_url:'https://www.newegg.com/p/pl?d=gpu'}]});assert.equal(r.status,500);
r=await scenario({...privateOrder,privateSources:[{...sourceRow,supplier_cost:200}]});assert.equal(r.status,409);

console.log('PASS: receipt authorization, provider binding, pre-capture identity/amount checks, ambiguous response recovery, duplicate/concurrent capture, fulfillment preservation, cancelled/refunded denial and create binding races and under-cost promo rejection.');
