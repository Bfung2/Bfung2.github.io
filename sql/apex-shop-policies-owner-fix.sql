-- Apply this after PR #103 if the editor says Owner access required.
-- Owner is identified by a confirmed email in auth.users or a trusted app_metadata admin role.
-- Never authorize based on editable user_metadata.
create or replace function public.apex_owner_policy(
  p_action text, p_kind text, p_body text default null, p_revision bigint default null
) returns jsonb language plpgsql volatile security definer set search_path = ''
as $$
declare p public.apex_shop_policies%rowtype;
declare versions jsonb;
begin
  if auth.uid() is null or not (
    coalesce(auth.jwt()->'app_metadata'->>'role','') = 'admin'
    or exists (
      select 1 from auth.users u
      where u.id = auth.uid()
        and lower(u.email) = 'apexcomputers039@gmail.com'
        and u.email_confirmed_at is not null
    )
  ) then
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


revoke all on function public.apex_owner_policy(text,text,text,bigint) from public;
grant execute on function public.apex_owner_policy(text,text,text,bigint) to authenticated;
