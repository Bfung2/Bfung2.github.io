import {createHash} from "node:crypto";
import {writeFile} from "node:fs/promises";
import {fileURLToPath} from "node:url";

// Public site checks only. Never request private customer URLs, Auth tokens,
// operational RPCs, PayPal capture, or payment endpoints from this monitor.
export const PUBLIC_CHECKS=[
 {path:"/",kind:"html"},
 {path:"/data.json",kind:"json"},
 {path:"/storefront-ux.css",kind:"css"},
 {path:"/owner-operations.css",kind:"css"},
 {path:"/build-compatibility.js",kind:"js"},
 {path:"/owner-operations.js",kind:"js"},
 {path:"/customer-accounts.js",kind:"js"},
 {path:"/order-tracking.js",kind:"js"}
];

const bytes=text=>Buffer.byteLength(text,"utf8");
export function validatePublicResponse(kind,body,contentType){
 const content=String(body??"");
 const type=String(contentType||"").toLowerCase();
 if(kind==="html"){
  if(!type.includes("html")||!content.toLowerCase().includes("<!doctype html")||
     !content.includes('id="app"')||!content.includes("Apex Computers"))
   return {ok:false,reason:"Homepage structure or HTML content type is incorrect"};
 }else if(kind==="json"){
  if(!type.includes("json"))return {ok:false,reason:"Catalog response is not JSON"};
  let parsed;
  try{parsed=JSON.parse(content);}catch{return {ok:false,reason:"Catalog JSON is invalid"};}
  if(!Array.isArray(parsed?.products)||!Array.isArray(parsed?.parts)||!parsed.settings||typeof parsed.settings!=="object")
   return {ok:false,reason:"Catalog products, parts, or settings missing"};
  return {ok:true,metadata:{products:parsed.products.length,parts:parsed.parts.length}};
 }else if(kind==="css"){
  if(!type.includes("css")||content.includes("<!doctype html"))
   return {ok:false,reason:"Stylesheet missing or served HTML"};
 }else if(kind==="js"){
  if(!/javascript|ecmascript/.test(type)||content.toLowerCase().includes("<!doctype html"))
   return {ok:false,reason:"JavaScript asset missing or served HTML"};
 }else return {ok:false,reason:"Unknown resource kind"};
 if(bytes(content)<30)return {ok:false,reason:"Response body unexpectedly small"};
 return {ok:true};
}

export async function inspectPublicStorefront({
 baseUrl="https://bfung2.github.io",
 fetchImpl=fetch,
 checks=PUBLIC_CHECKS,
 timeoutMs=15000,
 now=()=>new Date()
}={}){
 const base=new URL(baseUrl);
 if(base.protocol!=="https:"&&base.hostname!=="localhost"&&base.hostname!=="127.0.0.1")
  throw new Error("Only HTTPS production URLs or localhost are permitted");
 const output={schema_version:1,checked_at:now().toISOString(),base_url:base.origin,
  status:"ok",checks:[]};
 for(const check of checks){
  const url=new URL(check.path,base);
  const start=Date.now();
  let result={path:check.path,kind:check.kind,status:"fail",duration_ms:0};
  try{
   const response=await fetchImpl(url.toString(),{
    method:"GET",cache:"no-store",redirect:"follow",
    signal:AbortSignal.timeout(timeoutMs),
    headers:{"Accept":"text/html, application/json, text/css, text/javascript, */*"}
   });
   result.http_status=response.status;
   if(!response.ok){
    result.reason="HTTP "+response.status;
   }else{
    const text=await response.text();
    const checked=validatePublicResponse(check.kind,text,response.headers.get("content-type"));
    if(checked.ok){
     result.status="ok";
     result.size_bytes=bytes(text);
     // Checksum and record counts are public metadata only. Never log raw product data.
     if(check.kind==="json"){
      result.catalog_counts=checked.metadata;
      result.public_catalog_sha256=createHash("sha256").update(text).digest("hex");
     }
    }else result.reason=checked.reason;
   }
  }catch{
   result.reason="Network request failed or timed out";
  }
  result.duration_ms=Date.now()-start;
  output.checks.push(result);
 }
 if(output.checks.some(entry=>entry.status!=="ok"))output.status="fail";
 return output;
}
async function main(){
 const idx=process.argv.indexOf("--output");
 if(idx!==-1&&!process.argv[idx+1])throw new Error("--output needs a path");
 const report=await inspectPublicStorefront();
 const reportJson=JSON.stringify(report,null,2)+"\n";
 if(idx!==-1)await writeFile(process.argv[idx+1],reportJson,{encoding:"utf8"});
 for(const c of report.checks)
  process.stdout.write((c.status==="ok"?"PASS ":"FAIL ")+c.path+" | "+(c.http_status||"network")+" | "+c.duration_ms+"ms"+(c.reason?" | "+c.reason:"")+"\n");
 process.stdout.write("Public storefront health: "+report.status.toUpperCase()+"\n");
 if(report.status!=="ok")process.exitCode=1;
}
if(process.argv[1]&&fileURLToPath(import.meta.url)===process.argv[1])await main();
