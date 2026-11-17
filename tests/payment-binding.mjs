import assert from 'node:assert/strict';
import fs from 'node:fs';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;
create function auth.jwt() returns jsonb language sql as $$select coalesce(nullif(current_setting('request.jwt',true),''),'{}')::jsonb$$;
grant usage on schema auth to anon,authenticated,service_role;grant execute on function auth.jwt() to anon,authenticated,service_role;
create table public.apex_orders(id text primary key,pricing_locked boolean default false);grant all on public.apex_orders to anon,authenticated,service_role;`);
const migration=fs.readFileSync('supabase/migrations/20261117200001_checkout_payment_binding.sql','utf8');
await db.exec(migration);await db.exec(migration);
async function role(name){await db.exec('reset role');await db.query("select set_config('request.jwt',$1,false)",[JSON.stringify({role:name})]);await db.exec('set role '+name);}
await role('anon');
await assert.rejects(db.exec("insert into public.apex_orders values('forged',true,'PAYPAL12345678')"));
await db.exec("insert into public.apex_orders(id) values('order')");
for(const name of ['anon','authenticated']){await role(name);await assert.rejects(db.exec("update public.apex_orders set paypal_order_id='PAYPAL12345678' where id='order'"));}
await role('service_role');await assert.rejects(db.exec("update public.apex_orders set paypal_order_id='PAYPAL12345678' where id='order'"));
await db.exec("update public.apex_orders set pricing_locked=true where id='order'");
await db.exec("update public.apex_orders set paypal_order_id='PAYPAL12345678' where id='order'");
await assert.rejects(db.exec("update public.apex_orders set paypal_order_id='DIFFERENT12345' where id='order'"));
await assert.rejects(db.exec("update public.apex_orders set paypal_order_id=null where id='order'"));
await db.exec("insert into public.apex_orders(id,pricing_locked) values('second',true)");
await assert.rejects(db.exec("update public.apex_orders set paypal_order_id='PAYPAL12345678' where id='second'"));
await assert.rejects(db.exec("update public.apex_orders set paypal_order_id='bad' where id='second'"));
assert.equal((await db.query("select paypal_order_id from public.apex_orders where id='order'")).rows[0].paypal_order_id,'PAYPAL12345678');
await db.close();
console.log('PASS: rerunnable payment binding, guest/customer denial, locked pricing prerequisite, immutable binding, provider uniqueness and invalid IDs.');
