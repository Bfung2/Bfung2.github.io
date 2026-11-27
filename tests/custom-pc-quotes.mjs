import assert from 'node:assert/strict';
import fs from 'node:fs';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();

await db.exec(`
  create role anon; create role authenticated; create role service_role;
  create function public.apex_is_owner() returns boolean language sql as
  $$select current_setting('test.owner',true)='true'$$;
  create table public.employee_activity_logs(actor_name text,event_type text,details jsonb);
  create function public.apex_staff_audit(text,uuid,jsonb) returns void language sql as
  $$insert into public.employee_activity_logs values('Owner',$1,$3)$$;
  create table public.apex_orders(
    id text primary key, ref text unique, customer_name text, customer_email text, customer_phone text,
    shipping_address text, notes text, items jsonb, subtotal numeric, shipping numeric, tax numeric, total numeric,
    status text, tracking_token text, pricing_locked boolean, paypal_capture_id text, fulfillment_stage text default 'received',
    discount_amount numeric default 0, is_test boolean default false
  );
  create table public.apex_order_costs(order_id text, costs jsonb, revision integer);
  create table public.apex_refund_records(order_id text, recorded_at timestamptz, reference text);
`);
for (const migration of ['20261127000100_custom_pc_quotes.sql', '20261127000200_private_catalog_sources.sql']) {
  const sql = fs.readFileSync('supabase/migrations/' + migration, 'utf8');
  await db.exec(sql);
  await db.exec(sql);
}

const token = 'a'.repeat(64);
const customer = async (action, data = {}, capability = token) =>
  (await db.query('select public.apex_pc_quote_customer($1,$2,$3::jsonb) as data', [action,capability,data])).rows[0].data;
const owner = async (action, data = {}) =>
  (await db.query('select public.apex_pc_quote_owner($1,$2::jsonb) as data',[action,data])).rows[0].data;
const source = async (action, data = {}) =>
  (await db.query('select public.apex_owner_catalog_source($1,$2,$3::uuid,$4::jsonb) as data',
    [action,'sku','55555555-5555-4555-8555-555555555555',data])).rows[0].data;
async function role(name, verified = false) {
  await db.exec('reset role');
  await db.query("select set_config('test.owner',$1,false)",[String(verified)]);
  await db.exec('set role ' + name);
}

await role('anon');
await assert.rejects(owner('list'));
await assert.rejects(customer('request',{}));
await assert.rejects(customer('status',{},'b'.repeat(64)));
const request = {name:'Customer',email:'buyer@example.com',budget:'1500',use:'Gaming',resolution:'1440p',delivery:'pickup'};
assert.equal((await customer('request',request)).status,'requested');
assert.equal((await customer('request',request)).status,'requested');
await assert.rejects(customer('accept',{revision:0}));
await assert.rejects(db.query('select token from public.apex_pc_quotes'));
await role('authenticated');
await assert.rejects(owner('list'));
await assert.rejects(source('read'));
await role('authenticated',true);
const [quote] = await owner('list');
assert.equal(quote.customer_email,request.email);
const draft = {id:quote.id,revision:0,parts:'CPU and GPU',subtotal:150000,shipping:0,tax:10000,
  costs:{parts:100000,freight:1000,labor:10000,packing:1000,postage:0,commission:0,other:0},
  fee_bps:499,fee_fixed:49};
await assert.rejects(owner('offer',draft),/Below|below/);
await assert.rejects(owner('offer',{...draft,shipping:500,confirm_low:true}),/delivery charge/);
const offer = await owner('offer',{...draft,confirm_low:true});
assert.equal(offer.estimate.profit,29967);
assert.equal(offer.offer.total,160000);
await assert.rejects(owner('offer',{...draft,confirm_low:true}),/changed/);
const privateSource = {url:'https://www.newegg.com/p/N82E123',cost:100,extra:10};
assert.equal((await source('save',privateSource)).neweggPrice,100);
assert.equal((await source('read')).sourceUrl,privateSource.url);

await role('anon');
await assert.rejects(source('read'));
await assert.rejects(db.query('select source_url from public.apex_catalog_sources'));
const review = await customer('status');
assert.equal(review.offer.parts,'CPU and GPU');
assert.equal(review.offer.total,160000);
assert.ok(!JSON.stringify(review).includes('29967'));
assert.ok(!('customer_email' in review));
await assert.rejects(customer('accept',{revision:0}));
assert.equal((await customer('change',{revision:1,message:'More RAM'})).status,'changes');
await assert.rejects(customer('accept',{revision:1}));
await role('authenticated',true);
const newOffer = await owner('offer',{...draft,parts:'CPU, GPU and more RAM',revision:2,confirm_low:true});
await db.exec('reset role');
await db.exec("update public.apex_pc_quotes set expires_at=now()-interval '1 hour'");
await role('anon');
assert.equal((await customer('status')).expired,true);
await assert.rejects(customer('accept',{revision:newOffer.revision}),/expired/);
await role('authenticated',true);
const finalOffer = await owner('offer',{...draft,revision:3,confirm_low:true});
await role('anon');
const accepted = await customer('accept',{revision:finalOffer.revision});
assert.equal(accepted.status,'accepted');
assert.equal(accepted.order.id,(await customer('accept',{revision:finalOffer.revision})).order.id);
assert.notEqual(accepted.order.trackingToken,token);
const changed = await customer('change',{revision:accepted.revision,message:'Please call before pickup'});
assert.equal(changed.status,'accepted');
assert.equal(changed.offer.total,160000);
await role('authenticated',true);
const [finances] = (await owner('finance',{order:accepted.order.id})).orders;
assert.equal(finances.estimated_profit,29967);
assert.equal(finances.total,1600);
await db.exec('reset role');
const { rows } = await db.query('select * from public.apex_orders');
assert.equal(rows.length,1);
assert.equal(rows[0].pricing_locked,true);
assert.equal(rows[0].items[0].specification,'CPU and GPU');
assert.equal(rows[0].status,'requested');
assert.equal((await db.query("select count(*)::int as n from public.employee_activity_logs where event_type='custom_pc_offer_accepted'")).rows[0].n,1);
await db.close();
console.log('PASS: quote privacy, owner access, profit math, revision and expiry, idempotent acceptance, immutable totals, tracking and supplier privacy.');
