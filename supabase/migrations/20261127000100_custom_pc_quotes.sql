begin;

create table if not exists public.apex_pc_quotes (
 id uuid primary key,
 token text unique not null check (token ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default now(),
 customer_name text not null,
 customer_email text not null,
 request jsonb not null,
 status text not null default 'requested' check (status in ('requested','offered','changes','accepted')),
 revision integer not null default 0,
 offer jsonb,
 estimate jsonb,
 expires_at timestamptz,
 change_message text,
 order_id text unique
);
create index if not exists apex_pc_quote_queue on public.apex_pc_quotes(created_at desc,id desc);
alter table public.apex_pc_quotes enable row level security;
revoke all on public.apex_pc_quotes from public, anon, authenticated;
grant select on public.apex_pc_quotes to service_role;

create or replace function public.apex_pc_quote_customer(p_action text, p_token text, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 q public.apex_pc_quotes;
 o public.apex_orders;
 v_id uuid;
 v_text text;
 v_addr text;
 v_ref text;
begin
 if coalesce(p_token,'') !~ '^[a-f0-9]{64}$' then raise exception 'Quote link unavailable'; end if;
 if p_action='request' then
  if p_data is null or octet_length(p_data::text)>10000
   or length(trim(coalesce(p_data->>'name',''))) not between 1 and 120
   or length(coalesce(p_data->>'email','')) not between 3 and 254
   or p_data->>'email' !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
   or coalesce(p_data->>'budget','') !~ '^[0-9]{2,5}$'
   or length(trim(coalesce(p_data->>'use',''))) not between 1 and 1000
   or coalesce(p_data->>'resolution','') not in ('1080p','1440p','4K','Unsure')
   or coalesce(p_data->>'delivery','') not in ('pickup','shipping')
   or length(coalesce(p_data->>'details',''))>1500 then
   raise exception 'Check your contact information and build requirements';
  end if;
  if p_data->>'delivery'='shipping' then
   if length(trim(coalesce(p_data->>'street',''))) not between 5 and 150
    or length(trim(coalesce(p_data->>'city',''))) not between 1 and 80
    or coalesce(p_data->>'state','') !~ '^[A-Z]{2}$'
    or coalesce(p_data->>'zip','') !~ '^[0-9]{5}(-[0-9]{4})?$' then
    raise exception 'Enter a complete US shipping address';
   end if;
   v_addr:=concat_ws(', ',trim(p_data->>'street'),trim(p_data->>'city'),(p_data->>'state')||' '||(p_data->>'zip'));
  else
   v_addr:='Local pickup';
  end if;
  insert into public.apex_pc_quotes(id,token,customer_name,customer_email,request)
  values(gen_random_uuid(),p_token,trim(p_data->>'name'),lower(trim(p_data->>'email')),
   jsonb_build_object('budget',p_data->>'budget','use',p_data->>'use','resolution',p_data->>'resolution',
    'delivery',p_data->>'delivery','address',v_addr,'details',left(coalesce(p_data->>'details',''),1500)))
  on conflict(token) do nothing;
 end if;

 select * into q from public.apex_pc_quotes where token=p_token for update;
 if not found then raise exception 'Quote link unavailable'; end if;
 if p_action='change' then
  v_text:=trim(coalesce(p_data->>'message',''));
  if q.status not in ('offered','accepted') or (p_data->>'revision')::integer is distinct from q.revision
   or length(v_text) not between 1 and 1500 then
   raise exception 'Refresh the quote and enter your requested changes';
  end if;
  insert into public.employee_activity_logs(actor_name,event_type,details) values('Customer','custom_pc_change_requested',jsonb_build_object('quote_id',q.id,'order_id',q.order_id));
  update public.apex_pc_quotes set status=case when status='accepted' then status else 'changes' end,change_message=v_text,revision=revision+1 where id=q.id returning * into q;
 elsif p_action='accept' and q.status<>'accepted' then
  if q.status<>'offered' or q.expires_at<=now() or (p_data->>'revision')::integer is distinct from q.revision then
   raise exception 'The offer changed or expired. Refresh or ask Apex for a new offer';
  end if;
  v_id:=gen_random_uuid();
  v_ref:='AC-PC-'||upper(left(replace(v_id::text,'-',''),16));
  insert into public.apex_orders(id,ref,customer_name,customer_email,customer_phone,shipping_address,notes,items,
   subtotal,shipping,tax,total,status,tracking_token,pricing_locked)
  values(v_id::text,v_ref,q.customer_name,q.customer_email,'',q.request->>'address',q.offer->>'parts',
   jsonb_build_array(jsonb_build_object('id',q.id,'kind','quote','qty',1,'name','Custom PC build','price',(q.offer->>'subtotal')::numeric/100,'specification',q.offer->>'parts')),
   (q.offer->>'subtotal')::numeric/100,(q.offer->>'shipping')::numeric/100,(q.offer->>'tax')::numeric/100,
   (q.offer->>'total')::numeric/100,'requested',replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),true);
  insert into public.employee_activity_logs(actor_name,event_type,details) values('Customer','custom_pc_offer_accepted',jsonb_build_object('quote_id',q.id,'order_id',v_id));
  update public.apex_pc_quotes set status='accepted',order_id=v_id::text,revision=revision+1 where id=q.id returning * into q;
 elsif p_action not in ('request','status','accept') then
  raise exception 'Unknown quote action';
 end if;

 if q.order_id is not null then
  select * into o from public.apex_orders where id=q.order_id;
 end if;
 return jsonb_build_object('status',q.status,'revision',q.revision,'offer',q.offer,'expires_at',q.expires_at,
  'expired',coalesce(q.expires_at<=now(),false),'change_message',q.change_message,
  'order',case when o.id is not null then jsonb_build_object('id',o.id,'ref',o.ref,'trackingToken',o.tracking_token,
   'paid',o.paypal_capture_id is not null or o.status='paid','closed',o.fulfillment_stage='cancelled' or o.status in ('cancelled','refunded')) end);
end;
$$;

create or replace function public.apex_pc_quote_owner(p_action text,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
 q public.apex_pc_quotes;
 v_costs jsonb:=p_data->'costs';
 v_offer jsonb;
 v_sub integer;
 v_ship integer;
 v_tax integer;
 v_key text;
 v_cost integer;
 v_parts text:=trim(coalesce(p_data->>'parts',''));
 v_profit integer;
 v_total integer;
begin
 if not coalesce(public.apex_is_owner(),false) then raise exception 'Verified owner access required' using errcode='42501'; end if;
 if p_action='list' then
  return coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc) from
   (select * from public.apex_pc_quotes where p_data->>'before' is null or (created_at,id)<((p_data->>'before')::timestamptz,(p_data->>'before_id')::uuid)
    order by created_at desc,id desc limit 50) r),'[]'::jsonb);
 end if;
 if p_action='finance' then
  return jsonb_build_object('orders',coalesce((select jsonb_agg(to_jsonb(r)) from (
   select o.id,o.ref,o.subtotal,o.discount_amount,o.shipping,o.tax,o.total,o.paypal_capture_id is not null as paid,
    o.is_test,c.costs,coalesce(c.revision,0) as revision,(quote.estimate->>'profit')::integer as estimated_profit,
    coalesce((select jsonb_agg(to_jsonb(f) order by f.recorded_at,f.reference) from public.apex_refund_records f where f.order_id=o.id),'[]') as refunds
   from public.apex_pc_quotes quote join public.apex_orders o on o.id=quote.order_id
   left join public.apex_order_costs c on c.order_id=o.id where o.id=p_data->>'order'
  ) r),'[]'),'next',null);
 end if;
 if p_action<>'offer' then raise exception 'Unknown owner action'; end if;
 select * into q from public.apex_pc_quotes where id=(p_data->>'id')::uuid for update;
 if not found or q.status='accepted' or (p_data->>'revision')::integer is distinct from q.revision then
  raise exception 'The quote changed. Refresh before sending an offer';
 end if;
 if length(v_parts) not between 1 and 3000 or length(coalesce(p_data->>'message',''))>1500 then
  raise exception 'Add the parts list and keep the offer message under 1,500 characters';
 end if;
 foreach v_key in array array['subtotal','shipping','tax'] loop
  if coalesce(p_data->>v_key,'') !~ '^[0-9]{1,7}$' then raise exception 'Enter valid quote prices'; end if;
 end loop;
 v_sub:=(p_data->>'subtotal')::integer;
 v_ship:=(p_data->>'shipping')::integer;
 v_tax:=(p_data->>'tax')::integer;
 v_total:=v_sub+v_ship+v_tax;
 if v_sub<=0 or v_total>10000000 or (q.request->>'delivery'='pickup' and v_ship<>0) then raise exception 'Check the quote total and delivery charge'; end if;
 v_cost:=0;
 foreach v_key in array array['parts','freight','labor','packing','postage','commission','other'] loop
  if coalesce(v_costs->>v_key,'') !~ '^[0-9]{1,7}$' then raise exception 'Enter all estimated expenses'; end if;
  v_cost:=v_cost+(v_costs->>v_key)::integer;
 end loop;
 if (v_costs->>'parts')::integer<=0 then raise exception 'Enter the estimated parts cost'; end if;
 if coalesce(p_data->>'fee_bps','') !~ '^[0-9]{1,4}$' or coalesce(p_data->>'fee_fixed','') !~ '^[0-9]{1,5}$' then
  raise exception 'Enter valid estimated processing fees';
 end if;
 v_cost:=v_cost+round(v_total::numeric*(p_data->>'fee_bps')::integer/10000)::integer+(p_data->>'fee_fixed')::integer;
 v_profit:=v_sub+v_ship-v_cost;
 if v_profit<35000 and coalesce(p_data->>'confirm_low','false')<>'true' then
  raise exception 'Confirm the offer below your $350 target before publishing';
 end if;
 v_offer:=jsonb_build_object('parts',v_parts,'message',coalesce(p_data->>'message',''),'subtotal',v_sub,
  'shipping',v_ship,'tax',v_tax,'total',v_total,'delivery',q.request->>'delivery');
 update public.apex_pc_quotes set offer=v_offer,status='offered',revision=revision+1,expires_at=now()+interval '7 days',
  estimate=jsonb_build_object('costs',v_costs,'fee_bps',p_data->'fee_bps','fee_fixed',p_data->'fee_fixed','profit',v_profit)
 where id=q.id returning * into q;
 perform public.apex_staff_audit('custom_pc_offer_published',null,jsonb_build_object('quote_id',q.id,'revision',q.revision));
 return to_jsonb(q);
end;
$$;

revoke all on function public.apex_pc_quote_customer(text,text,jsonb),public.apex_pc_quote_owner(text,jsonb) from public,anon,authenticated;
grant execute on function public.apex_pc_quote_customer(text,text,jsonb) to anon,authenticated;
grant execute on function public.apex_pc_quote_owner(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
