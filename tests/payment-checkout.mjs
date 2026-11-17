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
async function scenario({action='capture',checkoutToken=receipt,orderPatch={},providerDetails=detail(),captureStatus=201,failSave=false,method='POST',bodyPatch={},bindRace=false,saveRace=false}={}) {
 let handler;const calls=[],writes=[];
 const order={id:'order',ref:'AC-TEST',tracking_token:receipt,pricing_locked:true,paypal_order_id:provider,paypal_capture_id:null,status:'requested',fulfillment_stage:'received',items:[{kind:'product',id:'cpu',qty:1}],total,...orderPatch};
 const admin={from:()=>{let patch,filters=[];const q={select:()=>q,eq:(k,v)=>{filters.push([k,v]);return q;},is:(k,v)=>{filters.push([k,v]);return q;},update:p=>{patch=p;return q;},maybeSingle:async()=>{
  if(patch){writes.push(patch);if(failSave)return {error:{message:'write unavailable'}};if(bindRace&&patch.paypal_order_id){order.paypal_order_id=provider;return {data:null};}if(saveRace&&patch.paypal_capture_id){order.paypal_capture_id='CAPTURE123';order.status='shipped';return {data:null};}Object.assign(order,patch);}
  return {data:{...order},error:null};
 }};return q;},rpc:async()=>({data:{subtotal:120,shipping:2.4,tax:8.4,total,discount:0},error:null}),functions:{invoke:async()=>{calls.push('notify');return {data:{success:true},error:null};}}};
 const env={PAYPAL_CLIENT_ID:'client',PAYPAL_CLIENT_SECRET:'secret',PAYPAL_ENVIRONMENT:'sandbox',SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'service'};
 const ctx=vm.createContext({Request,Response,console:{error(){}},btoa,quoteActualShipping:async()=>({charge:2.4,carrierCost:2.4}),createClient:()=>admin,Deno:{env:{get:k=>env[k]},serve:fn=>handler=fn},fetch:async(url,opts={})=>{
  calls.push((opts.method||'GET')+' '+url);
  if(url.includes('oauth2'))return Response.json({access_token:'token'});
  if(url.includes('raw.githubusercontent'))return Response.json(catalog);
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
console.log('PASS: receipt authorization, provider binding, pre-capture identity/amount checks, ambiguous response recovery, duplicate/concurrent capture, fulfillment preservation, cancelled/refunded denial and create binding races.');
