import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";
import {inspectPublicStorefront,PUBLIC_CHECKS,validatePublicResponse} from "../scripts/ops-monitor.mjs";

const ownerScript=await fs.readFile(new URL("../owner-operations.js",import.meta.url),"utf8");
const html=await fs.readFile(new URL("../index.html",import.meta.url),"utf8");
const migration=await fs.readFile(new URL("../supabase/migrations/20261112070000_phase11_ops_health.sql",import.meta.url),"utf8");
const monitorWorkflow=await fs.readFile(new URL("../.github/workflows/operations-monitor.yml",import.meta.url),"utf8");
new vm.Script(ownerScript);

const report={
 generated_at:"2026-11-11T22:00:00Z",
 notifications:{pending:20,orphaned:20,pending_with_order:0,pending_over_30m:0,failed_or_retry:0,expired_leases:0,sent:8},
 orders:{open:1,unassigned:1,older_than_48h:0,test:3},
 requests:{open:0,unassigned:0,older_than_48h:0},
 sales:{unsettled:2,paid_records:4,void_records:1}
};
let calls=0,draws=0;const badge={hidden:true,textContent:"",setAttribute(){}};
const ctx=vm.createContext({
 isOwner:true,Date,console,Number,Intl,
 document:{getElementById:id=>id==="opsAlertBadge"?badge:null},
 route:()=>"/operations",
 render:()=>draws++,
 supabaseClient:{rpc:async name=>{assert.equal(name,"apex_owner_ops_health");calls++;return {data:report,error:null};}},
});
vm.runInContext(ownerScript,ctx);
const evalCode=s=>vm.runInContext(s,ctx);
assert.equal(evalCode("opsCount('-10')"),0);
assert.equal(evalCode("opsCount('4.8')"),4);
let alerts=evalCode("opsAlerts("+JSON.stringify(report)+")");
assert.ok(alerts.some(x=>x.title.includes("Unmatched notification")));
assert.ok(alerts.some(x=>x.title==="Unassigned work"));
assert.ok(!alerts.some(x=>x.title.includes("retries")),"Do not invent failed sends from pending queue");
assert.ok(!alerts.some(x=>x.tone==="critical"),"Pending orphaned records are for review, not evidence of Gmail failures");
await evalCode("opsRefresh()");
assert.equal(calls,1);
assert.equal(draws,1);
assert.equal(badge.hidden,false);
assert.ok(badge.textContent.includes("alert"));
const page=evalCode("opsPage()");
assert.ok(page.includes("Operations center")&&page.includes("Pending notifications")&&page.includes("Unmatched notification"));
assert.ok(page.includes("20")&&page.includes("8")&&page.includes("owner operations")===false);
assert.ok(!page.includes("customer@example.invalid"),"Owner page must not render contact records");
ctx.isOwner=false;
assert.ok(evalCode("opsPage()").includes("Owner access required"));
await evalCode("opsRefresh()");
assert.equal(calls,1,"Non-owner client must not invoke RPC");
assert.ok(migration.includes("auth.users u")&&migration.includes("u.email_confirmed_at IS NOT NULL"));
assert.ok(migration.includes("REVOKE ALL ON FUNCTION public.apex_owner_ops_health() FROM PUBLIC, anon"));
assert.ok(migration.includes("GRANT EXECUTE ON FUNCTION public.apex_owner_ops_health() TO authenticated"));
assert.ok(!/SELECT\s+\*/i.test(migration),"Owner RPC should return only explicitly selected aggregate counts");
for(const text of ["/operations","owner-operations.js","owner-operations.css","opsRefreshIfStale()"]){
 assert.ok(html.includes(text),"Owner dashboard not wired: "+text);
}
assert.ok(html.includes('if(isEmployee && [')&&html.includes('"/operations"].includes(r)'),
 "Employee routes must reject owner operations");

const good={
 "/":{kind:"html",type:"text/html",body:'<!doctype html><html><head><title>Apex Computers</title></head><body><main id="app"></main></body></html>'},
 "/data.json":{kind:"json",type:"application/json",body:JSON.stringify({products:[{id:"test"}],parts:[{id:"build"}],settings:{shopName:"Apex Computers"}})}
};
for(const resource of PUBLIC_CHECKS){
 if(good[resource.path])continue;
 const body=resource.kind==="css"?"/* Apex public CSS */ body{color:#14201b}":"// Apex public JavaScript asset\nfunction apexHealthProbe(){return true;}";
 good[resource.path]={kind:resource.kind,type:resource.kind==="css"?"text/css":"text/javascript",body};
}
const mockFetch=async url=>{
 const path=new URL(url).pathname,asset=good[path];
 if(!asset)return new Response("Not found",{status:404,headers:{"content-type":"text/plain"}});
 return new Response(asset.body,{status:200,headers:{"content-type":asset.type}});
};
const healthy=await inspectPublicStorefront({fetchImpl:mockFetch});
assert.equal(healthy.status,"ok");
assert.equal(healthy.checks.length,PUBLIC_CHECKS.length);
assert.ok(healthy.checks.every(x=>x.status==="ok"));
assert.ok(healthy.checks.find(x=>x.path==="/data.json").public_catalog_sha256?.length===64);
const broken=await inspectPublicStorefront({fetchImpl:async url=>{
 if(new URL(url).pathname==="/owner-operations.js")return new Response("<!doctype html>Not found",{status:200,headers:{"content-type":"text/html"}});
 return mockFetch(url);
}});
assert.equal(broken.status,"fail");
assert.match(broken.checks.find(x=>x.path==="/owner-operations.js").reason,/JavaScript/);
const offline=await inspectPublicStorefront({fetchImpl:async()=>{throw Error("simulated outage");}});
assert.equal(offline.status,"fail");
assert.equal(offline.checks[0].reason,"Network request failed or timed out");
assert.equal(validatePublicResponse("json","{bad","application/json").ok,false);
assert.equal(validatePublicResponse("html","<!doctype html>","text/html").ok,false);
for(const text of ["schedule:","workflow_dispatch:","issues: write","steps.storefront_health.outcome == 'failure'","if: success()",
 "apex-public-catalog-recovery","retention-days: 30"]){
 assert.ok(monitorWorkflow.includes(text),"Missing scheduling/incident/backup rule "+text);
}
assert.ok(!monitorWorkflow.includes("SUPABASE_SERVICE_ROLE_KEY"),"Public monitor must not require database admin credentials");
console.log("PASS: Phase 11 owner-only metrics, queue alert classification, non-owner UI protection, scheduled public monitoring, incident dedup and catalog snapshot boundaries.");
