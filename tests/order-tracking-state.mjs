import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';
const values=new Map();let resolveFirst,resolveSecond;
const ctx=vm.createContext({crypto:webcrypto,Uint8Array,URLSearchParams,URL,Date,console,location:{origin:'https://bfung2.github.io',pathname:'/',hash:'#/track-order'},localStorage:{getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)},route:()=>'/track-order',render(){},esc:s=>String(s??'').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),money:n=>'$'+Number(n).toFixed(2),supabaseClient:{rpc:async(n,{p_token})=>new Promise(resolve=>{if(p_token==='a'.repeat(64))resolveFirst=resolve;else resolveSecond=resolve;})}});
vm.runInContext(await fs.readFile(new URL('../order-tracking.js',import.meta.url),'utf8'),ctx);const run=s=>vm.runInContext(s,ctx);
const t1=run('newOrderTrackingToken()'),t2=run('newOrderTrackingToken()');assert.match(t1,/^[a-f0-9]{64}$/);assert.notEqual(t1,t2);
run(`rememberOrderTracking({ref:'AC-ONE',trackingToken:'${t1}',email:'must-not-save@test.invalid',address:'Private address'})`);assert.ok(!values.get('apex.trackingLinks').includes('must-not-save'));assert.ok(!values.get('apex.trackingLinks').includes('Private address'));
run(`rememberOrderTracking({ref:'AC-ONE',tracking_token:'${t1}'})`);assert.equal(run('savedOrderTracking().length'),1);
assert.ok(run("trackingNext({is_test:true,stage:'delivered'})").includes('simulated'));assert.ok(run("trackingNext({payment_confirmed:false})").includes('not been confirmed'));assert.ok(run("trackingNext({payment_confirmed:true,stage:'cancelled'})").includes('does not confirm a refund'));
const first=run("loadCustomerTracking('a'.repeat(64))"),second=run("loadCustomerTracking('b'.repeat(64))");resolveSecond({data:{ref:'SECOND'}});await second;resolveFirst({data:{ref:'OLD'}});await first;assert.equal(run('orderTracking.data.ref'),'SECOND');
run("location.hash='#/track-order?token='+ 'b'.repeat(64);orderTracking.data={ref:'AC-TEST',is_test:true,stage:'testing',total:0,updated_at:new Date().toISOString(),items:[{name:'<unsafe>',qty:1}],events:[]}");const markup=run('customerTrackingPage()');assert.ok(markup.includes('TEST · NO PAYMENT TAKEN'));assert.ok(markup.includes('&lt;unsafe&gt;'));assert.ok(!markup.includes('<unsafe>'));
console.log('PASS: secure unique tokens, device storage excludes contact details, deduplicated links, test/unpaid/cancelled labels, stale response isolation and escaped tracking content.');

run("orderTracking.data.delivery={carrier:'UPS',tracking_number:'<bad>',estimated_completion:'2026-12-01',pickup_instructions:'Call Apex'}");const deliveryMarkup=run('customerTrackingPage()');assert.ok(deliveryMarkup.includes('Apex estimate'));assert.ok(deliveryMarkup.includes('&lt;bad&gt;'));assert.ok(deliveryMarkup.includes('Call Apex'));console.log('PASS: delivery details rendered as escaped text with explicit estimated-date wording.');
