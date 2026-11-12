import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';

const root=new URL('../',import.meta.url);
const source=(path)=>readFileSync(new URL(path,root),'utf8');
const customer=source('customer-accounts.js');
const html=source('index.html');
const sql=source('docs/sql/phase5_rpc_grants.sql');

// Customer signup stays enabled with independent PKCE session storage.
assert.match(customer,/\bconst CUSTOMER_EMAIL_READY\s*=\s*true\s*;/);
assert.match(customer,/storageKey\s*:\s*'apex\.customer\.auth'/);
assert.match(customer,/flowType\s*:\s*'pkce'/);
assert.match(customer,/customerRPC\('apex_customer_profile'\)/);
assert.match(customer,/customerRPC\('apex_customer_orders'\)/);
assert.match(customer,/customerRPC\('apex_customer_link_order'/);
assert.match(html,/customerAuthCallback/);
assert.match(html,/customer-accounts\.js/);

// Never ship server-only credentials in the public application.
// These are variable names, not secret values: the check prevents accidental use in browser sources.
for(const file of ['index.html','customer-accounts.js','staff-workspace.js','order-tracking.js','market-sales.js','promo-codes.js']){
  const text=source(file);
  assert.doesNotMatch(text,/\b(?:SUPABASE_SERVICE_ROLE_KEY|PAYPAL_CLIENT_SECRET|GOOGLE_CLIENT_SECRET|GOOGLE_REFRESH_TOKEN|SEND_EMAIL_HOOK_SECRET)\b/,file+' references a server-only secret');
}

// Version-control the exact privilege reductions already made in Supabase.
for(const signature of [
  'apex_claim_job(text,text)',
  'apex_employee_get_jobs()',
  'apex_employee_update_job(text,text,text)',
  'apex_log_job_activity()',
  'apex_owner_policy(text,text,text,bigint)',
  'apex_record_employee_login(text)'
]){
  assert.ok(sql.includes('REVOKE EXECUTE ON FUNCTION public.'+signature+' FROM anon, PUBLIC;'),signature+' anonymous grant not restricted');
}
for(const signature of [
  'apex_claim_job(text,text)','apex_employee_get_jobs()','apex_employee_update_job(text,text,text)',
  'apex_owner_policy(text,text,text,bigint)','apex_record_employee_login(text)'
]){
  assert.ok(sql.includes('GRANT EXECUTE ON FUNCTION public.'+signature+' TO authenticated;'),signature+' staff grant not preserved');
}
console.log('PASS: customer auth routing, public client secret boundaries, and versioned staff/owner RPC permission hardening.');
// These are static regression guards, NOT a live database security or cross-account test.
