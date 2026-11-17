import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const {PGlite}=await import(process.env.PGLITE_MODULE||'@electric-sql/pglite');
const db=new PGlite();
const sql=statement=>db.exec(statement);
const rows=async(statement,...params)=>(await db.query(statement,params)).rows;
const alice='00000000-0000-4000-8000-000000000001',ben='00000000-0000-4000-8000-000000000002';
await sql(`create role anon; create role authenticated; create role service_role;
 create schema auth;
 create function auth.jwt() returns jsonb language sql as $$select jsonb_build_object('role',current_setting('test.caller',true))$$;
 create function public.apex_is_owner() returns boolean language sql as $$select current_setting('test.caller',true)='owner'$$;
 create function public.apex_staff_can(text) returns boolean language sql as $$select current_setting('test.caller',true) in ('owner','manager')$$;
 create function public.apex_require_staff_security() returns void language plpgsql as $$begin
  if not public.apex_staff_can('manage_promos') then raise exception 'Staff required'; end if; end$$;
 create function public.apex_staff_audit(text,uuid,jsonb) returns void language sql as $$select$$;
 create table employee_profiles(user_id uuid primary key,active boolean,display_name text,sales_code text);
 create table apex_orders(id text primary key,ref text,customer_name text,items jsonb,subtotal numeric,shipping numeric,
  tax numeric,total numeric,status text default 'pending',is_test boolean default false,paypal_capture_id text,
  sales_employee_id uuid,sales_employee_name text,sales_employee_code text);
 create table staff_sales_credits(job_kind text,job_id text,employee_id uuid,employee_name text,customer_name text,
  reference text,credited_at timestamptz default now(),unique(job_kind,job_id));
 create table staff_sales_settlements(job_kind text,job_id text);
 create table apex_test_checkout_settings(code text);
 insert into apex_test_checkout_settings values('RESERVED');
 insert into employee_profiles values ('${alice}',true,'Alice','ALICE'),('${ben}',true,'Ben','BEN');`);
for(const file of ['202611100004_promo_codes.sql','20261117232702_employee_setup_and_promo_attribution.sql']){
 const migration=await readFile('supabase/migrations/'+file,'utf8');
 await sql(migration);
 if(file.includes('employee_setup'))await sql(migration);
}
const caller=name=>rows("select set_config('test.caller',$1,false)",name);
const save=(code,amount,assignment={})=>rows("select apex_manage_promos('save',$1)",{code,kind:'percent',amount,...assignment});
const setPrice=id=>rows("select apex_lock_checkout_price($1,'[]',100,10,10) as price",id);
const capture=id=>rows("update apex_orders set status='paid',paypal_capture_id='CAPTURE-'||id where id=$1",id);
await caller('owner');
await save('APEX10',10,{employee_id:alice});
await assert.rejects(save('RESERVED',10,{employee_id:alice}),/reserved/);
await caller('manager');
await assert.rejects(save('APEX10',20,{employee_id:ben}),/Only the owner/);
await save('APEX10',10);
await caller('anon');
const [{preview}]=await rows("select apex_preview_promo('apex10',100) as preview");
assert.deepEqual(preview,{code:'APEX10',discount:10});
await sql("insert into apex_orders(id,promo_code,promo_sales_employee_id) values('order','apex10','"+ben+"')");
assert.equal((await rows("select promo_sales_employee_id from apex_orders where id='order'"))[0].promo_sales_employee_id,null);
await assert.rejects(rows("update apex_orders set promo_sales_employee_id=$1,pricing_locked=true where id='order'",ben),/controlled by checkout/);
await caller('service_role');
const [{price}]=await setPrice('order');
assert.deepEqual(price,{subtotal:100,shipping:10,tax:9,total:109,discount:10,promo_code:'apex10'});
assert.deepEqual(await rows('select * from staff_sales_credits'),[]);
await caller('owner');
await save('APEX10',20,{employee_id:ben});
await caller('service_role');
assert.equal((await setPrice('order'))[0].price.discount,10);
await rows("insert into staff_sales_credits(job_kind,job_id,employee_id,employee_name) values('order','order',$1,'Ben')",ben);
await capture('order');
await capture('order');
assert.deepEqual(await rows('select employee_id,promo_code,discount_amount from staff_sales_credits'),[
 {employee_id:alice,promo_code:'APEX10',discount_amount:'10.00'},
]);
await sql("insert into apex_orders(id,promo_code,is_test) values('test','APEX10',true),('unassigned',null,false)");
await setPrice('test');
await capture('test');
await setPrice('unassigned');
await capture('unassigned');
assert.equal((await rows('select * from staff_sales_credits')).length,1);
await db.close();
console.log('PASS: owner assignment, discount privacy, server-only snapshots, paid-only credit, duplicate capture protection, and promo precedence.');
