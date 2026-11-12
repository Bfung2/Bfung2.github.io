import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
const context=vm.createContext({sessionStorage:{getItem:()=>null},setInterval(){},Date,URLSearchParams,console});
vm.runInContext(await fs.readFile(new URL('../market-sales.js',import.meta.url),'utf8'),context);
const run=s=>vm.runInContext(s,context);
run(`marketDrafts.items=[{id:'wait',expires_at:'2999-01-01'},{id:'expired',expires_at:'2000-01-01'},{id:'submitted',submitted_at:'2026-01-01',expires_at:'2000-01-01'},{id:'paid',submitted_at:'2026-01-01',expires_at:'2000-01-01'},{id:'test',submitted_at:'2026-01-01',expires_at:'2000-01-01'}];marketProgress=[{draft_id:'paid',payment_status:'paid'},{draft_id:'test',payment_status:'test_completed'}]`);
assert.deepEqual(JSON.parse(run('JSON.stringify(marketDrafts.items.map(marketDraftBucket))')),['waiting','expired','submitted','paid','test']);
for(const state of ['waiting','expired','submitted','paid','test']){run(`marketDraftFilter='${state}'`);assert.equal(run('marketFilteredDrafts().length'),1);}
run("marketDraftFilter='all'");assert.equal(run('marketFilteredDrafts().length'),5);assert.ok(run('marketDraftFilters()').includes('Waiting for customer (1)'));
console.log('PASS: waiting, submitted, paid, test and expired customer-link filters and counts; submitted links do not regress to expired.');
