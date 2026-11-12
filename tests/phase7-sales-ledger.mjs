import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

const staff=await fs.readFile(new URL('../staff-workspace.js',import.meta.url),'utf8');
const helper=await fs.readFile(new URL('../staff-sales-ledger.js',import.meta.url),'utf8');
const index=await fs.readFile(new URL('../index.html',import.meta.url),'utf8');
const sql=await fs.readFile(new URL('../supabase/migrations/20261112053000_phase7_sales_receipt_privacy.sql',import.meta.url),'utf8');
const start=staff.indexOf("let staffSalesView='pending'");
const end=staff.indexOf('function staffCommissionSummary',start);
assert.ok(start>0&&end>start,'Sales filters and summary markers must remain present');

const items=[
 {job_kind:'order',job_id:'A',reference:'AC-PAID',employee_id:'alice',employee_name:'Alice',commission_cents:2000,settlement_status:'paid',credited_at:'2026-11-01T10:00:00Z',settled_at:'2026-11-02T10:00:00Z',commission_note:'Cash',is_test:false},
 {job_kind:'order',job_id:'B',reference:'AC-TEST',employee_id:'alice',employee_name:'Alice',commission_cents:9900,settlement_status:'paid',credited_at:'2026-11-03T10:00:00Z',settled_at:'2026-11-04T10:00:00Z',is_test:true},
 {job_kind:'order',job_id:'C',reference:'=HYPERLINK("https://example.invalid")',employee_id:'alice',employee_name:'Alice',commission_cents:1500,settlement_status:'pending',credited_at:'2026-11-10T10:00:00Z',is_test:false},
 {job_kind:'request',job_id:'D',reference:'REQ-EMPTY',employee_id:'alice',employee_name:'Alice',commission_cents:null,settlement_status:'pending',credited_at:'2026-10-02T10:00:00Z',is_test:false},
 {job_kind:'order',job_id:'E',reference:'AC-VOID',employee_id:'bob',employee_name:'Bob',commission_cents:500,settlement_status:'void',credited_at:'2026-11-08T10:00:00Z',settled_at:'2026-11-11T10:00:00Z',is_test:false}
];
const holder={innerHTML:''};
const ctx=vm.createContext({
 isOwner:true,staffSales:{items},
 document:{getElementById:id=>id==='staffSalesResults'?holder:null},
 esc:value=>String(value??'').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;'),
 money:value=>'$'+Number(value).toFixed(2),
 toast(){},URL,Blob,setTimeout,
 staffSalesList:entries=>'rendered '+entries.length
});
vm.runInContext(staff.slice(start,end),ctx);
vm.runInContext(helper,ctx);
const run=s=>vm.runInContext(s,ctx);
const stats=run("staffEmployeeLedgerStats('alice')");
assert.match(stats,/Paid: 1 real, 1 test/);
assert.match(stats,/Outstanding: \$15\.00/);
assert.match(stats,/1 missing amount/);
assert.ok(!stats.includes('$99.00'),'Test commissions must never be counted as real unpaid');

run("staffSalesView='paid';staffSalesTestFilter='real'");
assert.equal(run('staffSalesExportRows().length'),1);
let csv=run('staffSalesCsvText(staffSalesExportRows())');
assert.ok(csv.includes('AC-PAID'));
assert.ok(!csv.includes('AC-TEST'));
assert.ok(csv.includes('"20.00"'));
assert.ok(!csv.includes('customer@example.invalid'),'CSV should not include private contact fields');

run("staffSalesView='pending';staffSalesTestFilter='all';staffSalesDateFrom='2026-11-01';staffSalesDateTo='2026-11-30'");
assert.equal(run('staffSalesExportRows().length'),1,'Date filter should only include November credit');
csv=run('staffSalesCsvText(staffSalesExportRows())');
assert.ok(csv.includes("'=HYPERLINK"),'Excel formula injection must be neutralized');
assert.ok(!csv.includes('REQ-EMPTY'));
assert.match(run("staffCsvCell('+SUM(A1:A5)')"),/^"'\+SUM/);
assert.match(run("staffCsvCell('@SUM(A1:A5)')"),/^"'@SUM/);
assert.ok(run('staffSalesToolbar()').includes('CSV'));

run("staffSalesSearch='not-found'");
run('staffRefreshSalesResultRows()');
assert.equal(holder.innerHTML,'rendered 5','Typing a search should replace only the result area, not the input');
run("staffSalesSearch='';staffSalesDateFrom='';staffSalesDateTo=''");
ctx.isOwner=false;
assert.equal(run('staffSalesToolbar()'),'','Non-owner cannot see owner-only download control');
assert.equal(run('staffSalesExportRows().length'),0,'Non-owner cannot export rows via helper');

assert.ok(index.includes('<script src="staff-sales-ledger.js"></script>'));
assert.ok(index.indexOf('staff-workspace.js')<index.indexOf('staff-sales-ledger.js'));
assert.ok(staff.includes('staffRefreshSalesResultRows()'));
assert.ok(staff.includes('const updated=await staffRPC('),'Payment actions should check backend result');
assert.ok(sql.includes("public.apex_staff_can('own_sales_receipts')"));
assert.ok(sql.includes("item - 'customer_name'"));
assert.ok(sql.includes("- 'commission_note'"));
console.log('PASS: Phase 7 payout counts, real/test split, owner CSV export, date and employee filters, spreadsheet safety, live search, and SQL customer detail masking.');
