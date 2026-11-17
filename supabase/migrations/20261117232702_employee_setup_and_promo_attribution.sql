begin;
alter table public.employee_profiles add column if not exists setup_code_hash text;
alter table public.employee_profiles add column if not exists setup_code_expires_at timestamptz;
alter table public.apex_promo_codes add column if not exists employee_id uuid
 references public.employee_profiles(user_id) on delete set null;
alter table public.apex_orders add column if not exists promo_sales_employee_id uuid;
alter table public.staff_sales_credits add column if not exists promo_code text;
alter table public.staff_sales_credits add column if not exists discount_amount numeric;

create or replace function public.apex_manage_promos(p_action text default 'list',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_code text:=upper(trim(p_data->>'code')); v_employee uuid;
begin
 perform public.apex_require_staff_security();
 if not coalesce(public.apex_staff_can('manage_promos'),false) then raise exception 'Promo management permission required' using errcode='42501';end if;
 if p_action='save' then
  if exists(select 1 from public.apex_test_checkout_settings where code=v_code) then
   raise exception 'This code is reserved for owner test checkout';
  end if;
  if p_data ? 'employee_id' then
   if not public.apex_is_owner() then raise exception 'Only the owner can assign promo sales credit' using errcode='42501'; end if;
   v_employee:=nullif(p_data->>'employee_id','')::uuid;
   if v_employee is not null and not exists(select 1 from public.employee_profiles where user_id=v_employee and active)
    and not exists(select 1 from public.apex_promo_codes where code=v_code and employee_id=v_employee) then
    raise exception 'Choose an active employee';
   end if;
  end if;
  insert into public.apex_promo_codes(code,kind,amount,minimum_subtotal,enabled,expires_at,employee_id)
  values(v_code,p_data->>'kind',(p_data->>'amount')::numeric,coalesce((p_data->>'minimum_subtotal')::numeric,0),coalesce((p_data->>'enabled')::boolean,true),nullif(p_data->>'expires_at','')::timestamptz,v_employee)
  on conflict(code) do update set kind=excluded.kind,amount=excluded.amount,minimum_subtotal=excluded.minimum_subtotal,enabled=excluded.enabled,expires_at=excluded.expires_at,employee_id=case when p_data ? 'employee_id' then excluded.employee_id else apex_promo_codes.employee_id end,updated_at=now();
 elsif p_action='delete' then delete from public.apex_promo_codes where code=v_code;
 elsif p_action<>'list' then raise exception 'Invalid promo action';end if;
 if p_action<>'list' then perform public.apex_staff_audit('promo_'||p_action,null,jsonb_build_object('code',v_code,'employee_id',v_employee));end if;
 return coalesce((select jsonb_agg(to_jsonb(p) order by code) from public.apex_promo_codes p),'[]');
end;
$$;
create or replace function public.apex_lock_checkout_price(p_order text,p_items jsonb,p_subtotal numeric,p_shipping numeric,p_tax_rate numeric) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;v_discount numeric;v_tax numeric;v_total numeric; v_employee uuid; v_name text; v_sales_code text;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Payment server required' using errcode='42501';end if;
 select * into o from public.apex_orders where id=p_order for update;
 if not found then raise exception 'Order not found';end if;
 if o.pricing_locked then return jsonb_build_object('subtotal',o.subtotal,'shipping',o.shipping,'tax',o.tax,'total',o.total,'discount',o.discount_amount,'promo_code',o.promo_code);end if;
 if p_subtotal is null or p_shipping is null or p_tax_rate is null or p_subtotal<0 or p_shipping<0 or p_tax_rate not between 0 and 25 then raise exception 'Invalid pricing inputs';end if;
 -- Read the assignment and discount from the same promo revision.
 if nullif(trim(o.promo_code),'') is not null then
  select ep.user_id,ep.display_name,ep.sales_code into v_employee,v_name,v_sales_code
  from public.apex_promo_codes p
  left join public.employee_profiles ep on ep.user_id=p.employee_id and ep.active
  where p.code=upper(trim(o.promo_code)) for share of p;
 end if;
 v_discount:=public.apex_promo_discount(o.promo_code,p_subtotal);
 v_tax:=round((p_subtotal-v_discount)*p_tax_rate/100,2);v_total:=round(p_subtotal-v_discount+p_shipping+v_tax,2);
 if v_total<=0 or v_total>1000000 then raise exception 'Discount leaves no payable balance. Contact Apex';end if;
 update public.apex_orders set items=p_items,subtotal=p_subtotal,shipping=p_shipping,tax=v_tax,total=v_total,discount_amount=v_discount,promo_code=nullif(upper(trim(promo_code)),''),pricing_locked=true,
  promo_sales_employee_id=v_employee,
  sales_employee_id=coalesce(v_employee,o.sales_employee_id),
  sales_employee_name=coalesce(v_name,o.sales_employee_name),
  sales_employee_code=coalesce(v_sales_code,o.sales_employee_code)
 where id=p_order;
 return jsonb_build_object('subtotal',p_subtotal,'shipping',p_shipping,'tax',v_tax,'total',v_total,'discount',v_discount,'promo_code',o.promo_code);
end;
$$;

-- New attribution is populated only by the server's one-time price lock.
create or replace function public.apex_guard_promo_attribution() returns trigger
language plpgsql set search_path='' as $$
begin
 if TG_OP='INSERT' then
  NEW.promo_sales_employee_id:=null;
 elsif NEW.promo_sales_employee_id is distinct from OLD.promo_sales_employee_id
  and (coalesce(auth.jwt()->>'role','')<>'service_role' or OLD.pricing_locked or not NEW.pricing_locked) then
  raise exception 'Promo attribution is controlled by checkout' using errcode='42501';
 end if;
 return NEW;
end;
$$;
revoke all on function public.apex_guard_promo_attribution() from public,anon,authenticated;
drop trigger if exists apex_guard_promo_attribution on public.apex_orders;
create trigger apex_guard_promo_attribution before insert or update on public.apex_orders
for each row execute function public.apex_guard_promo_attribution();

-- Record one contribution in the same transaction as the verified capture. The
-- assigned promo takes precedence over a customer link for an unsettled sale.
create or replace function public.apex_credit_paid_promo() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then
  return NEW;
 end if;
 insert into public.staff_sales_credits(job_kind,job_id,employee_id,employee_name,customer_name,reference,promo_code,discount_amount)
 select 'order',NEW.id,p.user_id,NEW.sales_employee_name,coalesce(NEW.customer_name,''),
  coalesce(NEW.ref,NEW.id),NEW.promo_code,NEW.discount_amount
 from public.employee_profiles p
 where p.user_id=NEW.promo_sales_employee_id
  and not exists(select 1 from public.staff_sales_settlements s where s.job_kind='order' and s.job_id=NEW.id)
 on conflict(job_kind,job_id) do update set employee_id=excluded.employee_id,
  employee_name=excluded.employee_name,credited_at=now(),
  promo_code=excluded.promo_code,discount_amount=excluded.discount_amount;
 return NEW;
end;
$$;
revoke all on function public.apex_credit_paid_promo() from public,anon,authenticated;
drop trigger if exists apex_credit_paid_promo on public.apex_orders;
create trigger apex_credit_paid_promo after update of status on public.apex_orders
for each row when (NEW.status='paid' and NEW.pricing_locked and not NEW.is_test
 and OLD.paypal_capture_id is null and NEW.paypal_capture_id is not null
 and NEW.promo_sales_employee_id is not null)
execute function public.apex_credit_paid_promo();
notify pgrst,'reload schema';
commit;
