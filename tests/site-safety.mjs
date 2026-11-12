import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";

const root=path.resolve(new URL("..",import.meta.url).pathname);
const html=await fs.readFile(path.join(root,"index.html"),"utf8");
const json=JSON.parse(await fs.readFile(path.join(root,"data.json"),"utf8"));
const scripts=[...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
assert.ok(scripts.length>=2,"Expected storefront scripts");
let checked=0;
for(const [,attrs,source] of scripts){
 const remote=/\bsrc\s*=\s*["']([^"']+)["']/i.exec(attrs)?.[1];
 if(remote){
  if(/^https?:\/\//i.test(remote))continue;
  await fs.access(path.join(root,remote.split("?")[0]));
 }else{
  new vm.Script(source,{filename:"index.html inline script "+(++checked)});
 }
}
for(const file of ["customer-accounts.js","order-tracking.js","staff-workspace.js","market-sales.js","apex-policies.js"]){
 new vm.Script(await fs.readFile(path.join(root,file),"utf8"),{filename:file});
}
for(const key of ["orders","requests","accounts","customer_profiles","apex_orders","apex_service_requests","customer_order_links"]){
 assert.ok(!Object.hasOwn(json,key),"Private customer information cannot be stored in public data.json under "+key);
}
assert.ok(Array.isArray(json.products)&&Array.isArray(json.parts),"Catalog structure must stay compatible with storefront");
assert.ok(json.settings&&typeof json.settings==="object","Site settings must remain available");
assert.ok(html.includes("customerLinkReceipt(o.trackingToken)"),"Secure customer history linking integration is missing");
assert.ok(html.includes('"/warranty"')&&html.includes('"/returns"'),"Public policies must remain routable");
assert.ok(!html.includes('const OWNER_PASSWORD ='),"Never put hard-coded owner passwords in client JavaScript");
console.log("PASS: storefront script syntax, local script assets, public catalog privacy, policy routes, customer history integration.");
