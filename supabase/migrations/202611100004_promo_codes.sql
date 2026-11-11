begin;
create or replace function public.apex_permission_keys() returns text[] language sql immutable set search_path='' as $$
select array['orders','requests','customer_details','claim_jobs','update_status','view_schedule','edit_schedule','view_reports','view_notes','edit_notes','manage_notes','prepare_sales','manage_promos'];
$$;
create table if not exists public.apex_promo_codes(
 code text primary key check(code ~ '^[A-Z0-9_-]{3,40}$'),
 kind text not null check(kind in ('percent','fixed')),
 amount numeric(12,2) not null check(amount>0 and (kind<>'percent' or amount<=100)),
 minimum_subtotal numeric(12,2) not null default 0 check(minimum_subtotal>=0),
 enabled boolean not null default true,
 expires_at timestamptz,
 updated_at timestamptz not null default now()
);
alter table public.apex_promo_codes enable row level security;
revoke all on public.apex_promo_codes from public,anon,authenticated;
grant all on public.apex_promo_codes to service_role;
alter table public.apex_orders add column if not exists promo_code text;
alter table public.apex_orders add column if not exists discount_amount numeric not null default 0;
alter table public.apex_orders add column if not exists pricing_locked boolean not null default false;
grant insert(promo_code) on public.apex_orders to anon,authenticated;
create or replace function public.apex_promo_discount(p_code text,p_subtotal numeric) returns numeric
language plpgsql security definer set search_path='' as $$
declare p public.apex_promo_codes;
begin
 if coalesce(trim(p_code),'')='' then return 0;end if;
 select * into p from public.apex_promo_codes where code=upper(trim(p_code)) and enabled and (expires_at is null or expires_at>now());
 if not found then raise exception 'Promo code is invalid, disabled or expired';end if;
 if p_subtotal<p.minimum_subtotal then raise exception 'This promo requires a subtotal of at least $%',p.minimum_subtotal;end if;
 return least(p_subtotal,round(case when p.kind='fixed' then p.amount else p_subtotal*p.amount/100 end,2));
end;
$$;
create or replace function public.apex_preview_promo(p_code text,p_subtotal numeric) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if p_subtotal is null or p_subtotal<0 or p_subtotal>1000000 then raise exception 'Invalid subtotal';end if;
 return jsonb_build_object('code',upper(trim(p_code)),'discount',public.apex_promo_discount(p_code,p_subtotal));
end;
$$;
create or replace function public.apex_manage_promos(p_action text default 'list',p_data jsonb default '{}') returns jsonb
language plpgsql security definer set search_path='' as $$
declare v_code text:=upper(trim(p_data->>'code'));
begin
 if not coalesce(public.apex_staff_can('manage_promos'),false) then raise exception 'Promo management permission required' using errcode='42501';end if;
 if p_action='save' then
  insert into public.apex_promo_codes(code,kind,amount,minimum_subtotal,enabled,expires_at)
  values(v_code,p_data->>'kind',(p_data->>'amount')::numeric,coalesce((p_data->>'minimum_subtotal')::numeric,0),coalesce((p_data->>'enabled')::boolean,true),nullif(p_data->>'expires_at','')::timestamptz)
  on conflict(code) do update set kind=excluded.kind,amount=excluded.amount,minimum_subtotal=excluded.minimum_subtotal,enabled=excluded.enabled,expires_at=excluded.expires_at,updated_at=now();
 elsif p_action='delete' then delete from public.apex_promo_codes where code=v_code;
 elsif p_action<>'list' then raise exception 'Invalid promo action';end if;
 if p_action<>'list' then perform public.apex_staff_audit('promo_'||p_action,null,jsonb_build_object('code',v_code));end if;
 return coalesce((select jsonb_agg(to_jsonb(p) order by code) from public.apex_promo_codes p),'[]');
end;
$$;
-- Only the payment Edge Function supplies the verified catalog prices. Snapshot once per order
-- so PayPal retries retain the same amount, even if an administrator later edits the promo.
create or replace function public.apex_lock_checkout_price(p_order text,p_items jsonb,p_subtotal numeric,p_shipping numeric,p_tax_rate numeric) returns jsonb
language plpgsql security definer set search_path='' as $$
declare o public.apex_orders;v_discount numeric;v_tax numeric;v_total numeric;
begin
 if coalesce(auth.jwt()->>'role','')<>'service_role' then raise exception 'Payment server required' using errcode='42501';end if;
 select * into o from public.apex_orders where id=p_order for update;
 if not found then raise exception 'Order not found';end if;
 if o.pricing_locked then return jsonb_build_object('subtotal',o.subtotal,'shipping',o.shipping,'tax',o.tax,'total',o.total,'discount',o.discount_amount,'promo_code',o.promo_code);end if;
 if p_subtotal is null or p_shipping is null or p_tax_rate is null or p_subtotal<0 or p_shipping<0 or p_tax_rate not between 0 and 25 then raise exception 'Invalid pricing inputs';end if;
 v_discount:=public.apex_promo_discount(o.promo_code,p_subtotal);
 v_tax:=round((p_subtotal-v_discount)*p_tax_rate/100,2);v_total:=round(p_subtotal-v_discount+p_shipping+v_tax,2);
 if v_total<=0 or v_total>1000000 then raise exception 'Discount leaves no payable balance. Contact Apex';end if;
 update public.apex_orders set items=p_items,subtotal=p_subtotal,shipping=p_shipping,tax=v_tax,total=v_total,discount_amount=v_discount,promo_code=nullif(upper(trim(promo_code)),''),pricing_locked=true where id=p_order;
 return jsonb_build_object('subtotal',p_subtotal,'shipping',p_shipping,'tax',v_tax,'total',v_total,'discount',v_discount,'promo_code',o.promo_code);
end;
$$;
revoke all on function public.apex_promo_discount(text,numeric),public.apex_preview_promo(text,numeric),public.apex_manage_promos(text,jsonb),public.apex_lock_checkout_price(text,jsonb,numeric,numeric,numeric) from public,anon,authenticated;
grant execute on function public.apex_preview_promo(text,numeric) to anon,authenticated;
grant execute on function public.apex_manage_promos(text,jsonb) to authenticated;
grant execute on function public.apex_lock_checkout_price(text,jsonb,numeric,numeric,numeric) to service_role;
notify pgrst,'reload schema';
commit;
