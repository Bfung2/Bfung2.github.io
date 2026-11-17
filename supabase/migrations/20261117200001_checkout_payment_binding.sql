begin;
alter table public.apex_orders add column if not exists paypal_order_id text;
create unique index if not exists apex_orders_paypal_order_id_unique on public.apex_orders(paypal_order_id) where paypal_order_id is not null;
create or replace function public.apex_guard_payment_binding() returns trigger
language plpgsql set search_path='' as $$
begin
 if TG_OP='INSERT' then
  if NEW.paypal_order_id is not null then raise exception 'Payment binding is server controlled' using errcode='42501'; end if;
 elsif NEW.paypal_order_id is distinct from OLD.paypal_order_id then
  if coalesce(auth.jwt()->>'role','')<>'service_role' or OLD.paypal_order_id is not null or not NEW.pricing_locked or NEW.paypal_order_id is null or NEW.paypal_order_id !~ '^[A-Za-z0-9-]{8,80}$' then
   raise exception 'Payment binding is server controlled and immutable' using errcode='42501';
  end if;
 end if;
 return NEW;
end;
$$;
revoke all on function public.apex_guard_payment_binding() from public,anon,authenticated;
drop trigger if exists apex_guard_payment_binding on public.apex_orders;
create trigger apex_guard_payment_binding before insert or update on public.apex_orders for each row execute function public.apex_guard_payment_binding();
notify pgrst,'reload schema';
commit;
