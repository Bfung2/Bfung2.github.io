import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";

const js=await fs.readFile(new URL("../staff-workspace.js",import.meta.url),"utf8");
const start=js.indexOf("let staffSalesView='pending'");
const end=js.indexOf("function staffCommissionSummary",start);
assert.ok(start>0&&end>start,"Sales view source markers must exist");
const ctx=vm.createContext({
 isOwner:true,
 staffSales:{items:[]},
 esc:s=>String(s??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c])),
 money:n=>"$"+Number(n).toFixed(2)
});
vm.runInContext(js.slice(start,end),ctx);
const run=e=>vm.runInContext(e,ctx);
const items=[
 {job_kind:"order",job_id:"A1",reference:"ORD-A",employee_id:"a",employee_name:"Alice",customer_name:"Customer Alpha",commission_cents:1500,settlement_status:"pending",is_test:false},
 {job_kind:"order",job_id:"A2",reference:"TEST-A",employee_id:"a",employee_name:"Alice",customer_name:"Simulation",commission_cents:10000,settlement_status:"pending",is_test:true},
 {job_kind:"order",job_id:"B1",reference:"ORD-B",employee_id:"b",employee_name:"Bob",customer_name:"Customer Beta",commission_cents:2500,settlement_status:"paid",is_test:false},
 {job_kind:"request",job_id:"B2",reference:"LEAD-B",employee_id:"b",employee_name:"Bob",customer_name:"Lead",commission_cents:null,settlement_status:"pending",is_test:false},
 {job_kind:"order",job_id:"A3",reference:"VOID-A",employee_id:"a",employee_name:"Alice",customer_name:"Voided",commission_cents:300,settlement_status:"void",is_test:false}
];
ctx.items=items;
assert.equal(run("staffVisibleContributions(items).length"),3);
run("staffSalesTestFilter='real'");
assert.equal(run("staffVisibleContributions(items).length"),2);
run("staffSalesEmployeeFilter='b'");
assert.equal(run("staffVisibleContributions(items).length"),1);
run("staffSalesSearch='LEAD-B'");
assert.equal(run("staffVisibleContributions(items)[0].job_id"),"B2");
run("staffSalesSearch='not a match'");
assert.equal(run("staffVisibleContributions(items).length"),0);
run("staffSalesSearch='';staffSalesEmployeeFilter='';staffSalesTestFilter='all';staffSalesView='paid'");
assert.equal(run("staffVisibleContributions(items).length"),1);
const html=run("staffEmployeeCommissionOverview(items)");
assert.ok(html.includes("$15.00"));
assert.ok(html.includes("$25.00"));
assert.ok(html.includes("Missing amounts"));
assert.ok(!html.includes("$100.00")); // test commission isn't real revenue
ctx.isOwner=false;
assert.equal(run("staffEmployeeCommissionOverview(items)"),"");
console.log("PASS: staff sales filters, owner-only payout summary, missing amounts and real/test separation.");
