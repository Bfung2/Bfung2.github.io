-- Run once in Supabase SQL Editor before enabling the Policy editor.
-- Policy drafts are private. Only explicitly published versions are public.
create table if not exists public.apex_shop_policies (
  kind text primary key check (kind in ('warranty','returns')),
  draft_text text not null default '',
  draft_revision bigint not null default 0,
  published_text text,
  published_version bigint not null default 0,
  updated_at timestamptz not null default now(),
  published_at timestamptz
);
create table if not exists public.apex_shop_policy_history (
  kind text not null check (kind in ('warranty','returns')),
  version bigint not null,
  body text not null,
  published_at timestamptz not null default now(),
  published_by uuid not null,
  primary key (kind,version)
);
alter table public.apex_shop_policies enable row level security;
alter table public.apex_shop_policy_history enable row level security;
revoke all on public.apex_shop_policies from anon,authenticated;
revoke all on public.apex_shop_policy_history from anon,authenticated;

create or replace function public.apex_public_policy(p_kind text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare p public.apex_shop_policies%rowtype;
begin
  if p_kind not in ('warranty','returns') then raise exception 'Invalid policy type'; end if;
  select * into p from public.apex_shop_policies where kind=p_kind;
  if not found or p.published_version=0 then
    return jsonb_build_object('kind',p_kind,'published',false);
  end if;
  return jsonb_build_object('kind',p_kind,'published',true,'body',p.published_text,
    'version',p.published_version,'published_at',p.published_at);
end; $$;

create or replace function public.apex_owner_policy(
  p_action text, p_kind text, p_body text default null, p_revision bigint default null
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare p public.apex_shop_policies%rowtype;
declare versions jsonb;
begin
  if auth.uid() is null or coalesce(auth.jwt()->'app_metadata'->>'role','') <> 'admin' then
    raise exception 'Owner access required' using errcode='42501';
  end if;
  if p_kind not in ('warranty','returns') then raise exception 'Invalid policy type'; end if;
  insert into public.apex_shop_policies(kind) values(p_kind) on conflict(kind) do nothing;
  if p_action='save' then
    if p_body is null or length(p_body)>30000 then raise exception 'Policy body must be 0 to 30000 characters'; end if;
    update public.apex_shop_policies set draft_text=p_body,
      draft_revision=draft_revision+1,updated_at=now()
    where kind=p_kind and draft_revision=p_revision;
    if not found then raise exception 'Draft changed in another session; reload before saving'; end if;
  elsif p_action='publish' then
    select * into p from public.apex_shop_policies where kind=p_kind for update;
    if p.draft_revision<>p_revision then raise exception 'Draft changed in another session; reload before publishing'; end if;
    if length(trim(p.draft_text))=0 then raise exception 'A blank policy cannot be published'; end if;
    update public.apex_shop_policies
    set published_text=p.draft_text,published_version=p.published_version+1,published_at=now()
    where kind=p_kind;
    insert into public.apex_shop_policy_history(kind,version,body,published_by)
    values(p_kind,p.published_version+1,p.draft_text,auth.uid());
  elsif p_action <> 'read' then
    raise exception 'Invalid policy action';
  end if;
  select * into p from public.apex_shop_policies where kind=p_kind;
  select coalesce(jsonb_agg(jsonb_build_object('version',h.version,'published_at',h.published_at)
    order by h.version desc),'[]'::jsonb) into versions
    from public.apex_shop_policy_history h where h.kind=p_kind;
  return jsonb_build_object('kind',p_kind,'draft',p.draft_text,'revision',p.draft_revision,
    'published',p.published_version>0,'published_body',p.published_text,
    'version',p.published_version,'published_at',p.published_at,'history',versions);
end; $$;

revoke all on function public.apex_public_policy(text) from public;
revoke all on function public.apex_owner_policy(text,text,text,bigint) from public;
grant execute on function public.apex_public_policy(text) to anon,authenticated;
grant execute on function public.apex_owner_policy(text,text,text,bigint) to authenticated;
