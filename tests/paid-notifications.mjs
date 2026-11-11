import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import {stripTypeScriptTypes} from 'node:module';
const helperSource=await fs.readFile(new URL('../supabase/functions/paid-order-notify/message.ts',import.meta.url),'utf8');
const helpers=await import('data:text/javascript;base64,'+Buffer.from(stripTypeScriptTypes(helperSource)).toString('base64'));
let source=await fs.readFile(new URL('../supabase/functions/paid-order-notify/index.ts',import.meta.url),'utf8');
source=source.replace(/^import .*;\n/gm,'');source=stripTypeScriptTypes(source);
async function scenario({owner=false,service=false,gmailOk=true,recipient='employee@example.invalid'}={}){
 const calls=[],finished=[];let handler;
 const env={SUPABASE_URL:'https://example.invalid',SUPABASE_SERVICE_ROLE_KEY:'service-key',SUPABASE_ANON_KEY:'anon-key',GOOGLE_CLIENT_ID:'test-client',GOOGLE_CLIENT_SECRET:'test-secret',GOOGLE_REFRESH_TOKEN:'test-refresh'};
 const ctx=vm.createContext({Response,Request,TextEncoder,AbortSignal,URLSearchParams,btoa,console,...helpers,
  Deno:{env:{get:k=>env[k]},serve:fn=>handler=fn},
  createClient:(_url,key)=>key==='anon-key'?{auth:{getUser:async()=>({data:{user:owner?{email:'apexcomputers039@gmail.com'}:null}})}}:{rpc:async(name,args)=>{if(name==='apex_claim_paid_notifications')return {data:[{id:'mail-id',lease_token:'lease',recipient,payload:{id:'paid-order',ref:'AC-TEST',customer_name:'Customer',customer_email:'customer@example.invalid',shipping_address:'100 Example Street',total:50,items:[{name:'Product',price:50}]}}]};finished.push(args);return {error:null};}},
  fetch:async(url,options)=>{calls.push({url,options});return new Response(JSON.stringify(url.includes('oauth2')?{access_token:'mock-access'}:{}),{status:url.includes('gmail')&&!gmailOk?503:200});}
 });
 vm.runInContext(source,ctx);
 const response=await handler(new Request('https://example.invalid/functions/v1/paid-order-notify',{method:'POST',headers:{Authorization:service?'Bearer service-key':'Bearer customer-token','Content-Type':'application/json'},body:JSON.stringify({orderId:'paid-order',to:'attacker@example.invalid'})}));
 return {response,data:await response.json(),calls,finished};
}
let result=await scenario();assert.equal(result.response.status,403);assert.equal(result.calls.length,0);
result=await scenario({service:true});assert.equal(result.data.sent,1);const raw=JSON.parse(result.calls.find(c=>c.url.includes('gmail')).options.body).raw;const mime=Buffer.from(raw.replaceAll('-','+').replaceAll('_','/'),'base64').toString();assert.ok(mime.includes('To: employee@example.invalid'));assert.ok(!mime.includes('attacker@example.invalid'));assert.equal(result.finished[0].p_success,true);
result=await scenario({owner:true,gmailOk:false});assert.equal(result.data.failed,1);assert.equal(result.finished[0].p_success,false);
result=await scenario({service:true,recipient:''});assert.equal(result.data.failed,1);assert.equal(result.calls.filter(c=>c.url.includes('gmail')).length,0);
console.log('PASS: mocked notification authorization, fixed server recipients, successful send tracking, Gmail failures and missing employee email handling. No real email sent.');
