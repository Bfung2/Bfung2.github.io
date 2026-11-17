begin;
create index if not exists apex_orders_finance_cursor on public.apex_orders(created_at desc,id desc) where not is_test;
create or replace function public.apex_owner_finance_page(p_before timestamptz default null,p_before_id text default null,p_limit integer default 50) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare rows_json jsonb;last_row jsonb;more boolean;
begin
 if not coalesce(public.apex_is_owner(),false) then raise exception 'Verified owner required' using errcode='42501';end if;
 if p_limit is null or p_limit<1 or p_limit>100 or (p_before is null)<>(p_before_id is null) then raise exception 'Invalid page';end if;
 select coalesce(jsonb_agg(to_jsonb(t) order by t.created_at desc,t.id desc),'[]') into rows_json from (
 select o.id,o.ref,o.created_at,o.subtotal,o.discount_amount,o.shipping,o.tax,o.total,(nullif(o.paypal_capture_id,'') is not null) as paid,o.is_test,c.costs,coalesce(c.revision,0) as revision,
 coalesce((select jsonb_agg(to_jsonb(r) order by r.recorded_at,r.reference) from public.apex_refund_records r where r.order_id=o.id),'[]') as refunds
 from public.apex_orders o left join public.apex_order_costs c on c.order_id=o.id where not o.is_test and (p_before is null or (o.created_at,o.id)<(p_before,p_before_id)) order by o.created_at desc,o.id desc limit p_limit+1) t;
 more:=jsonb_array_length(rows_json)>p_limit;
 if more then rows_json:=rows_json-p_limit;end if;
 last_row:=rows_json->(jsonb_array_length(rows_json)-1);
 return jsonb_build_object('orders',rows_json,'next',case when more then jsonb_build_object('before',last_row->>'created_at','id',last_row->>'id') else null end);
end;
$$;
revoke all on function public.apex_owner_finance_page(timestamptz,text,integer) from public,anon;
grant execute on function public.apex_owner_finance_page(timestamptz,text,integer) to authenticated;
create or replace function public.apex_customer_order_status(p_token text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare t public.customer_order_tracking;refunded bigint:=0;
begin
 if p_token is null or p_token !~ '^[a-f0-9]{64}$' then raise exception 'Tracking link is invalid or unavailable';end if;
 select * into t from public.customer_order_tracking where token=p_token;
 if not found then raise exception 'Tracking link is invalid or unavailable';end if;
 if not coalesce((t.snapshot->>'is_test')::boolean,false) then
 select coalesce(sum(amount),0) into refunded from (
 select reference,max(amount_cents) as amount from (
 select reference,amount_cents from public.apex_refund_records where order_id=t.order_id and verified_at is not null
 union all select reference,amount_cents from public.apex_refund_inbox where order_id=t.order_id) evidence group by reference) refunds;
 end if;
 return t.snapshot||jsonb_build_object('refund',jsonb_build_object('amount_cents',refunded,'status',case when refunded<=0 then 'none' when refunded>=round((t.snapshot->>'total')::numeric*100) then 'full' else 'partial' end),'updated_at',t.updated_at,'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.recorded_at desc) from (select recorded_at,stage,message,payment_confirmed from public.customer_order_tracking_events where order_id=t.order_id order by recorded_at desc limit 50) e),'[]'));
end;
$$;
revoke all on function public.apex_customer_order_status(text) from public;
grant execute on function public.apex_customer_order_status(text) to anon,authenticated;
notify pgrst,'reload schema';
commit;
