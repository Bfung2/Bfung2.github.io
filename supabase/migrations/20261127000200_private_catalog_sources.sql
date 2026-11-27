begin;
create table if not exists public.apex_catalog_sources (
 version uuid primary key,
 sku text not null check (length(sku) between 1 and 160),
 source_url text not null check(length(source_url)<=1000),
 supplier_cost numeric not null check (supplier_cost between 0 and 100000),
 extra_cost numeric not null check (extra_cost between 0 and 100000),
 created_at timestamptz not null default now()
);
alter table public.apex_catalog_sources enable row level security;
revoke all on public.apex_catalog_sources from public, anon, authenticated;
grant select on public.apex_catalog_sources to service_role;

create or replace function public.apex_owner_catalog_source(p_action text,p_sku text,p_version uuid,p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.apex_catalog_sources;
begin
 if not coalesce(public.apex_is_owner(),false) then raise exception 'Verified owner access required' using errcode='42501'; end if;
 if p_action='save' then
  insert into public.apex_catalog_sources(version,sku,source_url,supplier_cost,extra_cost)
  values(p_version,p_sku,coalesce(p_data->>'url',''),coalesce((p_data->>'cost')::numeric,0),coalesce((p_data->>'extra')::numeric,0))
  on conflict(version) do nothing;
 elsif p_action<>'read' then
  raise exception 'Unknown catalog action';
 end if;
 select * into r from public.apex_catalog_sources where version=p_version and sku=p_sku;
 if not found then raise exception 'Private supplier record unavailable'; end if;
 return jsonb_build_object('sourceUrl',r.source_url,'neweggPrice',r.supplier_cost,'extraCostUSD',r.extra_cost);
end;
$$;
revoke all on function public.apex_owner_catalog_source(text,text,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.apex_owner_catalog_source(text,text,uuid,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
