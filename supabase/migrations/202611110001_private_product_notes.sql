begin;

create or replace function public.apex_permission_keys() returns text[] language sql immutable set search_path='' as $$
select array['orders','requests','customer_details','claim_jobs','update_status','view_schedule','edit_schedule','view_reports','view_notes','edit_notes','manage_notes','prepare_sales','manage_promos','own_sales_receipts','view_product_notes','edit_product_notes'];
$$;
create or replace function public.apex_note_allowed(p_note uuid,p_edit boolean default false) returns boolean
language sql volatile security definer set search_path = '' as $$
select public.apex_is_owner() or exists(select 1 from public.staff_notes n where n.id=p_note and
case when n.entity_type='product' then
 coalesce(public.apex_staff_can('view_product_notes'),false) and (not p_edit or coalesce(public.apex_staff_can('edit_product_notes'),false))
else coalesce(public.apex_staff_can('view_notes'),false)
 and (n.all_staff or exists(select 1 from public.staff_role_assignments a where a.user_id=auth.uid() and (a.role_id=any(n.view_role_ids) or a.role_id=any(n.edit_role_ids))))
 and (not p_edit or (public.apex_staff_can('edit_notes') and exists(select 1 from public.staff_role_assignments a where a.user_id=auth.uid() and a.role_id=any(n.edit_role_ids)))) end);
$$;
create or replace function public.apex_staff_get_notes(p_type text default null,p_entity text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not (coalesce(public.apex_staff_can('view_notes'),false) or coalesce(public.apex_staff_can('view_product_notes'),false)) then raise exception 'Notes access required' using errcode='42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(n)||jsonb_build_object('can_edit',public.apex_note_allowed(n.id,true)) order by n.updated_at desc)
    from public.staff_notes n where public.apex_note_allowed(n.id) and (p_type is null or n.entity_type=p_type) and (p_entity is null or n.entity_id=p_entity)),'[]');
end;
$$;
create or replace function public.apex_staff_save_note(p_data jsonb,p_delete boolean default false) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_id uuid:=nullif(p_data->>'id','')::uuid; v_old public.staff_notes; v_manage boolean:=public.apex_staff_can('manage_notes'); v_view uuid[];v_edit uuid[];v_type text;v_entity text;
begin
  if v_id is not null then
    select * into v_old from public.staff_notes where id=v_id for update;
    if not found or not coalesce(public.apex_note_allowed(v_id,true),false) then raise exception 'Note editing access required' using errcode='42501'; end if;
    if v_old.revision is distinct from (p_data->>'revision')::integer then raise exception 'This note changed. Refresh and try again'; end if;
  elsif not coalesce(v_manage,false) then raise exception 'Note creation permission required' using errcode='42501'; end if;
  -- Product permissions are independent of general notes. Only the owner may
  -- create, delete, retarget or change audience settings on product notes.
  if v_old.entity_type='product' then
    v_manage:=public.apex_is_owner();
  elsif coalesce(p_data->>'entity_type','')='product' and not public.apex_is_owner() then
    raise exception 'Only the owner can create or retarget product notes' using errcode='42501';
  elsif not coalesce(public.apex_staff_can('view_notes'),false) then
    raise exception 'Notes access required' using errcode='42501';
  end if;
  if p_delete then
    if v_id is null or not coalesce(v_manage,false) then raise exception 'Note management permission required' using errcode='42501'; end if;
    delete from public.staff_notes where id=v_id;
  else
    if v_manage then
      if jsonb_typeof(p_data->'view_role_ids') is distinct from 'array' or jsonb_typeof(p_data->'edit_role_ids') is distinct from 'array' then raise exception 'Choose role access'; end if;
      select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_view from jsonb_array_elements_text(p_data->'view_role_ids');
      select coalesce(array_agg(distinct value::uuid),'{}'::uuid[]) into v_edit from jsonb_array_elements_text(p_data->'edit_role_ids');
      if exists(select 1 from unnest(v_view||v_edit) r where not exists(select 1 from public.staff_roles where id=r)) then raise exception 'A selected role no longer exists'; end if;
      v_type:=p_data->>'entity_type';v_entity:=coalesce(p_data->>'entity_id','');
      if v_type='employee' and not exists(select 1 from public.employee_profiles where user_id::text=v_entity) then raise exception 'Choose an existing employee'; end if;
      if v_type='product' and length(trim(v_entity))=0 then raise exception 'Choose a product or part'; end if;
      if v_id is null then
        insert into public.staff_notes(entity_type,entity_id,title,body,all_staff,view_role_ids,edit_role_ids,created_by)
        values(v_type,v_entity,trim(p_data->>'title'),p_data->>'body',coalesce((p_data->>'all_staff')::boolean,false),v_view,v_edit,auth.uid()) returning id into v_id;
      else
        update public.staff_notes set entity_type=v_type,entity_id=v_entity,title=trim(p_data->>'title'),body=p_data->>'body',
          all_staff=coalesce((p_data->>'all_staff')::boolean,false),view_role_ids=v_view,edit_role_ids=v_edit,revision=revision+1,updated_at=now() where id=v_id;
      end if;
      -- Non-owner note managers cannot create or move a note outside their own editing access.
      if not coalesce(public.apex_note_allowed(v_id,true),false) then raise exception 'Include one of your roles in editing access' using errcode='42501'; end if;
    else
      -- Content editors cannot change the target or access lists, even by crafting an API request.
      update public.staff_notes set title=trim(p_data->>'title'),body=p_data->>'body',revision=revision+1,updated_at=now() where id=v_id;
    end if;
  end if;
  perform public.apex_staff_audit(case when p_delete then 'note_deleted' else 'note_saved' end,null,jsonb_build_object('note_id',v_id));
  return v_id;
end;
$$;

-- Public catalog metadata only. Never accepts note bodies or changes existing content.
create or replace function public.apex_sync_product_notes(p_products jsonb) returns integer
language plpgsql security definer set search_path='' as $$
declare p jsonb; added integer:=0; n integer;
begin
 if not public.apex_is_owner() then raise exception 'Owner authentication required' using errcode='42501'; end if;
 if jsonb_typeof(p_products) is distinct from 'array' or jsonb_array_length(p_products)>5000 then raise exception 'Invalid catalog'; end if;
 -- Serialize owner refreshes to prevent duplicate initial notes.
 perform pg_advisory_xact_lock(74941394);
 for p in select value from jsonb_array_elements(p_products) loop
  if length(coalesce(p->>'id','')) not between 1 and 200 or length(coalesce(p->>'name','')) not between 1 and 500 then raise exception 'Invalid product'; end if;
  insert into public.staff_notes(entity_type,entity_id,title,body,created_by)
  select 'product',p->>'id',left(p->>'name',160),
    'Apex product: https://bfung2.github.io/#/products?product='||(p->>'id')||case when coalesce(p->>'sourceUrl','') like 'https://%' then E'\nNewegg source: '||(p->>'sourceUrl') else '' end,auth.uid()
  where not exists(select 1 from public.staff_notes where entity_type='product' and entity_id=p->>'id');
  get diagnostics n=row_count; added:=added+n;
 end loop;
 return added;
end;
$$;
revoke all on function public.apex_sync_product_notes(jsonb) from public,anon;
grant execute on function public.apex_sync_product_notes(jsonb) to authenticated;
-- Idempotent backfill: owner-only until an employee is explicitly granted access.
insert into public.staff_notes(entity_type,entity_id,title,body)
select 'product',v.id,v.title,v.body from (values
('v19fuwr','GIGABYTE X870 AORUS ELITE WIFI7','Apex product: https://bfung2.github.io/#/products?product=v19fuwr
Product link: https://www.newegg.com/gigabyte-x870-aorus-elite-wifi7-atx-motherboard-amd-x870-am5/p/N82E16813145519'),
('xjyzxl1','GIGABYTE X870E AORUS ELITE WIFI7 AM5','Apex product: https://bfung2.github.io/#/products?product=xjyzxl1'),
('yo23yhu','GIGABYTE X870 AORUS ELITE WIFI7 ICE AM5','Apex product: https://bfung2.github.io/#/products?product=yo23yhu'),
('trxntnj','ASUS TUF GAMING B650E-E WIFI','Apex product: https://bfung2.github.io/#/products?product=trxntnj'),
('asrock717','ASRock B650M Pro RS WiFi','Apex product: https://bfung2.github.io/#/products?product=asrock717
Product link: https://www.newegg.com/asrock-b650m-pro-rs-wifi-micro-atx-motherboard-amd-b650-am5/p/N82E16813162131'),
('asrockea0','ASRock B650M Pro RS','Apex product: https://bfung2.github.io/#/products?product=asrockea0'),
('asrock62e','ASRock B650M-HDV/M.2','Apex product: https://bfung2.github.io/#/products?product=asrock62e'),
('asrock1d6','ASRock B650M-HDV/M.2 White','Apex product: https://bfung2.github.io/#/products?product=asrock1d6'),
('gigaby584','GIGABYTE B650M AORUS ELITE AX','Apex product: https://bfung2.github.io/#/products?product=gigaby584'),
('gigabyec2','GIGABYTE B650M AORUS ELITE AX ICE','Apex product: https://bfung2.github.io/#/products?product=gigabyec2'),
('gigaby612','GIGABYTE B650M GAMING PLUS WIFI','Apex product: https://bfung2.github.io/#/products?product=gigaby612'),
('gigaby53e','GIGABYTE B650M D3HP AX','Apex product: https://bfung2.github.io/#/products?product=gigaby53e'),
('gigabya25','GIGABYTE B650M C V3','Apex product: https://bfung2.github.io/#/products?product=gigabya25'),
('msib65b6f','MSI B650M PROJECT ZERO','Apex product: https://bfung2.github.io/#/products?product=msib65b6f'),
('asustu5b8','ASUS TUF GAMING B650M-PLUS WIFI','Apex product: https://bfung2.github.io/#/products?product=asustu5b8'),
('asustu64e','ASUS TUF GAMING B650M-E WIFI','Apex product: https://bfung2.github.io/#/products?product=asustu64e'),
('asrock442','ASRock B850M Pro RS WiFi','Apex product: https://bfung2.github.io/#/products?product=asrock442'),
('asrockac6','ASRock B850M Pro RS','Apex product: https://bfung2.github.io/#/products?product=asrockac6'),
('asrock3f3','ASRock B850M Pro-A','Apex product: https://bfung2.github.io/#/products?product=asrock3f3'),
('asrockbd4','ASRock B850M Pro-A WiFi','Apex product: https://bfung2.github.io/#/products?product=asrockbd4'),
('asrock0d7','ASRock B850M Steel Legend WiFi','Apex product: https://bfung2.github.io/#/products?product=asrock0d7'),
('asrock836','ASRock B850M Riptide WiFi','Apex product: https://bfung2.github.io/#/products?product=asrock836'),
('asrockad4','ASRock B850M Challenger WiFi','Apex product: https://bfung2.github.io/#/products?product=asrockad4'),
('asrock4f4','ASRock B850M Rock WiFi','Apex product: https://bfung2.github.io/#/products?product=asrock4f4'),
('gigaby47e','GIGABYTE B850M DS3H','Apex product: https://bfung2.github.io/#/products?product=gigaby47e'),
('gigabyb6b','GIGABYTE B850M EAGLE WIFI6E','Apex product: https://bfung2.github.io/#/products?product=gigabyb6b'),
('gigabyf94','GIGABYTE B850M EAGLE WIFI6E ICE','Apex product: https://bfung2.github.io/#/products?product=gigabyf94'),
('intel1851a1','ASRock B860 Rock WiFi 7','Apex product: https://bfung2.github.io/#/products?product=intel1851a1'),
('intel1851a2','ASRock B860 Challenger WiFi','Apex product: https://bfung2.github.io/#/products?product=intel1851a2'),
('intel1851a3','ASRock B860 Pro RS','Apex product: https://bfung2.github.io/#/products?product=intel1851a3'),
('intel1851a4','ASRock Z890 Pro RS','Apex product: https://bfung2.github.io/#/products?product=intel1851a4'),
('intel1851a5','GIGABYTE B860 GAMING X WIFI6E','Apex product: https://bfung2.github.io/#/products?product=intel1851a5'),
('intel1851m1','GIGABYTE B860M EAGLE PLUS WIFI6E','Apex product: https://bfung2.github.io/#/products?product=intel1851m1
Product link: https://www.newegg.com/gigabyte-b860m-eagle-plus-wifi6e-micro-atx-motherboard-intel-b860-lga-1851/p/N82E16813145560'),
('intel1851m2','GIGABYTE B860M AORUS ELITE WIFI6E','Apex product: https://bfung2.github.io/#/products?product=intel1851m2'),
('intel1851m3','ASUS PRIME B860M-A WIFI-CSM','Apex product: https://bfung2.github.io/#/products?product=intel1851m3'),
('intel1851m4','ASRock H810M-X WIFI','Apex product: https://bfung2.github.io/#/products?product=intel1851m4'),
('intel1700a1','MSI PRO B760-P WIFI DDR4','Apex product: https://bfung2.github.io/#/products?product=intel1700a1'),
('intel1700a2','GIGABYTE Z790 AORUS ELITE AX','Apex product: https://bfung2.github.io/#/products?product=intel1700a2'),
('intel1700a3','ASUS Z790 GAMING WIFI7','Apex product: https://bfung2.github.io/#/products?product=intel1700a3'),
('intel1700m1','ASUS B760M-AYW WIFI D4 II','Apex product: https://bfung2.github.io/#/products?product=intel1700m1'),
('intel1700m2','ASRock B760M PRO RS WiFi','Apex product: https://bfung2.github.io/#/products?product=intel1700m2
Product link: https://www.newegg.com/asrock-b760m-pro-rs-wifi-micro-atx-motherboard-intel-b760-lga-1700/p/N82E16813162228'),
('intel1700m3','ASRock B760M PRO RS','Apex product: https://bfung2.github.io/#/products?product=intel1700m3'),
('intel1700m4','MSI PRO B760M-P DDR4','Apex product: https://bfung2.github.io/#/products?product=intel1700m4'),
('amd-r5-5500','AMD Ryzen 5 5500','Apex product: https://bfung2.github.io/#/products?product=amd-r5-5500
Product link: https://www.newegg.com/amd-ryzen-5-5000-series-ryzen-5-5500-cezanne-socket-am4-desktop-cpu-processor/p/N82E16819113737'),
('amd-r5-5600x','AMD Ryzen 5 5600X','Apex product: https://bfung2.github.io/#/products?product=amd-r5-5600x
Product link: https://www.newegg.com/amd-ryzen-5-5000-series-ryzen-5-5600x-vermeer-socket-am4-desktop-cpu-processor/p/N82E16819113666'),
('amd-r7-5800x3d-anniv','AMD Ryzen 7 5800X3D 10th Anniversary Edition','Apex product: https://bfung2.github.io/#/products?product=amd-r7-5800x3d-anniv
Product link: https://www.newegg.com/amd-ryzen-7-5800x3d-10th-anniversary-edition-ryzen-7-5000-series-vermeer-zen-3-socket-am4-desktop-cpu-processor/p/N82E16819113940'),
('amd-r9-5900xt','AMD Ryzen 9 5900XT','Apex product: https://bfung2.github.io/#/products?product=amd-r9-5900xt
Product link: https://www.newegg.com/amd-ryzen-9-5000-series-ryzen-9-5900xt-vermeer-socket-am4-desktop-cpu-processor/p/N82E16819113845'),
('amd-r5-7600x','AMD Ryzen 5 7600X','Apex product: https://bfung2.github.io/#/products?product=amd-r5-7600x
Product link: https://www.newegg.com/amd-ryzen-5-7600x-ryzen-5-7000-series-raphael-zen-4-socket-am5/p/N82E16819113770'),
('amd-r7-7700x','AMD Ryzen 7 7700X','Apex product: https://bfung2.github.io/#/products?product=amd-r7-7700x
Product link: https://www.newegg.com/amd-ryzen-7-7700x-ryzen-7-7000-series-raphael-zen-4-socket-am5/p/N82E16819113768'),
('amd-r7-7800x3d','AMD Ryzen 7 7800X3D','Apex product: https://bfung2.github.io/#/products?product=amd-r7-7800x3d
Product link: https://www.newegg.com/amd-ryzen-7-7800x3d-ryzen-7-7000-series-raphael-zen-4-socket-am5/p/N82E16819113793'),
('amd-r9-7900x','AMD Ryzen 9 7900X','Apex product: https://bfung2.github.io/#/products?product=amd-r9-7900x
Product link: https://www.newegg.com/amd-ryzen-9-7900x-ryzen-9-7000-series-raphael-zen-4-socket-am5/p/N82E16819113769'),
('amd-r5-9600x','AMD Ryzen 5 9600X','Apex product: https://bfung2.github.io/#/products?product=amd-r5-9600x
Product link: https://www.newegg.com/amd-ryzen-5-9000-series-ryzen-5-9600x-granite-ridge-socket-am5-desktop-cpu-processor/p/N82E16819113844'),
('amd-r7-9700x','AMD Ryzen 7 9700X','Apex product: https://bfung2.github.io/#/products?product=amd-r7-9700x
Product link: https://www.newegg.com/amd-ryzen-7-9000-series-ryzen-7-9700x-granite-ridge-socket-am5-desktop-cpu-processor/p/N82E16819113843'),
('amd-r9-9900x','AMD Ryzen 9 9900X','Apex product: https://bfung2.github.io/#/products?product=amd-r9-9900x
Product link: https://www.newegg.com/amd-ryzen-9-9000-series-ryzen-9-9900x-granite-ridge-socket-am5-desktop-cpu-processor/p/N82E16819113842'),
('amd-r9-9950x','AMD Ryzen 9 9950X','Apex product: https://bfung2.github.io/#/products?product=amd-r9-9950x
Product link: https://www.newegg.com/amd-ryzen-9-9000-series-ryzen-9-9950x-granite-ridge-socket-am5-desktop-cpu-processor/p/N82E16819113841'),
('amd-r9-9950x3d','AMD Ryzen 9 9950X3D','Apex product: https://bfung2.github.io/#/products?product=amd-r9-9950x3d
Product link: https://www.newegg.com/amd-ryzen-9-9000-series-ryzen-9-9950x3d-granite-ridge-socket-am5-desktop-cpu-processor/p/N82E16819113884'),
('gpurx9070greasusprime3x','ASUS Prime Radeon RX 9070 GRE EVO OC 12GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070greasusprime3x'),
('gpurx9070gigagaming3x','GIGABYTE Gaming Radeon RX 9070 16GB OC','Apex product: https://bfung2.github.io/#/products?product=gpurx9070gigagaming3x'),
('gpu5060ventus2x','MSI Ventus GeForce RTX 5060 8GB VENTUS 2X OC','Apex product: https://bfung2.github.io/#/products?product=gpu5060ventus2x'),
('gpu5060tiventus2x16','MSI Ventus GeForce RTX 5060 Ti 16GB VENTUS 2X OC BLACK PLUS','Apex product: https://bfung2.github.io/#/products?product=gpu5060tiventus2x16'),
('gpu5060tiventus3x16','MSI Ventus GeForce RTX 5060 Ti 16GB VENTUS 3X OC','Apex product: https://bfung2.github.io/#/products?product=gpu5060tiventus3x16'),
('gpurx9070gresapphirepulse2x','SAPPHIRE PULSE Radeon RX 9070 GRE 12GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070gresapphirepulse2x'),
('gpu3060msiventus2x','MSI Ventus GeForce RTX 3060 12GB VENTUS 2X 12G OCV1','Apex product: https://bfung2.github.io/#/products?product=gpu3060msiventus2x'),
('gpu3050msiventus2x6','MSI Ventus GeForce RTX 3050 6GB VENTUS 2X 6G OC','Apex product: https://bfung2.github.io/#/products?product=gpu3050msiventus2x6
Product link: https://www.newegg.com/msi-rtx-3050-ventus-2x-6g-oc-geforce-rtx-3050-6gb-graphics-card-double-fans/p/N82E16814137878'),
('gpu5070gigawindforce3x','GIGABYTE WindForce GeForce RTX 5070 12GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu5070gigawindforce3x'),
('gpu5070tigigawindforce3x','GIGABYTE WindForce GeForce RTX 5070 Ti 16GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu5070tigigawindforce3x
Product link: https://www.newegg.com/gigabyte-windforce-gv-n507twf3oc-16gd-geforce-rtx-5070-ti-16gb-graphics-card-triple-fans/p/N82E16814932771'),
('gpu5090aorusif2x','GIGABYTE AORUS GeForce RTX 5090 32GB','Apex product: https://bfung2.github.io/#/products?product=gpu5090aorusif2x
Product link: https://www.newegg.com/gigabyte-gv-n5090aorus-if-32gd-geforce-rtx-5090-32gb-graphics-card/p/N82E16814932838'),
('gpu5080windforce3x','GIGABYTE WINDFORCE GeForce RTX 5080 16GB','Apex product: https://bfung2.github.io/#/products?product=gpu5080windforce3x
Product link: https://www.newegg.com/gigabyte-windforce-gv-n5080wf3oc-16gd-geforce-rtx-5080-16gb-graphics-card-triple-fans/p/N82E16814932754'),
('gpu3060gigagaming3x','GIGABYTE Gaming OC GeForce RTX 3060 12GB','Apex product: https://bfung2.github.io/#/products?product=gpu3060gigagaming3x
Product link: https://www.newegg.com/gigabyte-gv-n3060gaming-oc-12gd-geforce-rtx-3060-12gb-graphics-card-windforce-3x/p/N82E16814932433'),
('gpu3050msiventus2x8','MSI Ventus GeForce RTX 3050 8GB VENTUS 2X XS OC','Apex product: https://bfung2.github.io/#/products?product=gpu3050msiventus2x8
Product link: https://www.newegg.com/msi-rtx-3050-ventus-2x-xs-8g-oc-geforce-rtx-3050-8gb-graphics-card-double-fans/p/N82E16814137810'),
('intel-u9-285k','Intel Core Ultra 9 285K','Apex product: https://bfung2.github.io/#/products?product=intel-u9-285k
Product link: https://www.newegg.com/intel-core-ultra-9-285k-arrow-lake-lga-1851-desktop-cpu-processor/p/N82E16819118505'),
('intel-u5-245k','Intel Core Ultra 5 245K','Apex product: https://bfung2.github.io/#/products?product=intel-u5-245k
Product link: https://www.newegg.com/intel-core-ultra-5-245k-arrow-lake-lga-1851-desktop-cpu-processor/p/N82E16819118508'),
('intel-i5-14400f','Intel Core i5-14400F','Apex product: https://bfung2.github.io/#/products?product=intel-i5-14400f
Product link: https://www.newegg.com/intel-core-i5-14th-gen-core-i5-14400f-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118489'),
('intel-i7-14700','Intel Core i7-14700','Apex product: https://bfung2.github.io/#/products?product=intel-i7-14700
Product link: https://www.newegg.com/intel-core-i7-14th-gen-core-i7-14700-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118476'),
('intel-i5-14500','Intel Core i5-14500','Apex product: https://bfung2.github.io/#/products?product=intel-i5-14500
Product link: https://www.newegg.com/intel-core-i5-14th-gen-core-i5-14500-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118478'),
('gpurx9060xtsapphirepulse2x16','SAPPHIRE PULSE Radeon RX 9060 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9060xtsapphirepulse2x16
Product link: https://www.newegg.com/sapphire-tech-pulse-11350-03-20g-radeon-rx-9060-xt-16gb-graphics-card-double-fans/p/N82E16814202457?Item=N82E16814202457&SoldByNewegg=1'),
('gpu5070tigigagaming3x','GIGABYTE Gaming GeForce RTX 5070 Ti 16GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu5070tigigagaming3x'),
('gpurx9070xtasrocksteellegend3x','ASRock Steel Legend Radeon RX 9070 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070xtasrocksteellegend3x'),
('gpu5060tigigabyteeagle2x8','GIGABYTE Eagle GeForce RTX 5060 Ti 8GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu5060tigigabyteeagle2x8'),
('gpurx9070xtsapphirenitro3x','SAPPHIRE NITRO+ Radeon RX 9070 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070xtsapphirenitro3x'),
('am4asrock550m','ASRock B550M PRO4','Apex product: https://bfung2.github.io/#/products?product=am4asrock550m
Product link: https://www.newegg.com/asrock-b550m-pro4-micro-atx-amd-motherboard-amd-b550-am4/p/N82E16813157939'),
('am4msi550mp','MSI PRO B550M-P','Apex product: https://bfung2.github.io/#/products?product=am4msi550mp
Product link: https://www.newegg.com/msi-pro-micro-atx-13-144-765-amd-b550-am4/p/N82E16813144765'),
('am4asus550tuf','ASUS TUF GAMING B550-PLUS WIFI II','Apex product: https://bfung2.github.io/#/products?product=am4asus550tuf
Product link: https://www.newegg.com/asus-tuf-gaming-b550-plus-wifi-ii-atx-amd-motherboard-amd-b550-am4/p/N82E16813119518'),
('am4gigabyte550eagle','GIGABYTE B550 EAGLE WIFI6','Apex product: https://bfung2.github.io/#/products?product=am4gigabyte550eagle
Product link: https://www.newegg.com/gigabyte-b550-eagle-wifi6-atx-motherboards-amd-amd-b550-am4/p/N82E16813145567'),
('am4msi550gaming','MSI B550 GAMING WIFI6E','Apex product: https://bfung2.github.io/#/products?product=am4msi550gaming
Product link: https://www.newegg.com/msi-gaming-atx-13-144-768-amd-b550-am4/p/N82E16813144768'),
('intel-u5-245kf','Intel Core Ultra 5 245KF','Apex product: https://bfung2.github.io/#/products?product=intel-u5-245kf
Product link: https://www.newegg.com/intel-core-ultra-5-245kf-arrow-lake-lga-1851-desktop-cpu-processor/p/N82E16819118509?Item=N82E16819118509'),
('intel-i9-14900k','Intel Core i9-14900K','Apex product: https://bfung2.github.io/#/products?product=intel-i9-14900k
Product link: https://www.newegg.com/intel-core-i9-14th-gen-core-i9-14900k-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118462?Item=N82E16819118462'),
('intel-i9-14900kf','Intel Core i9-14900KF','Apex product: https://bfung2.github.io/#/products?product=intel-i9-14900kf
Product link: https://www.newegg.com/intel-core-i9-14th-gen-core-i9-14900kf-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118464?Item=N82E16819118464'),
('intel-i7-14700k','Intel Core i7-14700K','Apex product: https://bfung2.github.io/#/products?product=intel-i7-14700k
Product link: https://www.newegg.com/intel-core-i7-14th-gen-core-i7-14700k-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118466?Item=N82E16819118466'),
('intel-i7-14700kf','Intel Core i7-14700KF','Apex product: https://bfung2.github.io/#/products?product=intel-i7-14700kf
Product link: https://www.newegg.com/intel-core-i7-14th-gen-core-i7-14700kf-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118468?Item=N82E16819118468'),
('intel-i5-14600k','Intel Core i5-14600K','Apex product: https://bfung2.github.io/#/products?product=intel-i5-14600k
Product link: https://www.newegg.com/intel-core-i5-14th-gen-core-i5-14600k-raptor-lake-lga-1700-desktop-cpu-processor/p/N82E16819118470?Item=N82E16819118470'),
('intel-i9-12900k','Intel Core i9-12900K','Apex product: https://bfung2.github.io/#/products?product=intel-i9-12900k
Product link: https://www.newegg.com/intel-core-i9-12th-gen-core-i9-12900k-alder-lake-lga-1700-desktop-cpu-processor/p/N82E16819118339?Item=N82E16819118339'),
('intel-i7-12700k','Intel Core i7-12700K','Apex product: https://bfung2.github.io/#/products?product=intel-i7-12700k
Product link: https://www.newegg.com/intel-core-i7-12th-gen-core-i7-12700k-alder-lake-lga-1700-desktop-cpu-processor/p/N82E16819118343?Item=N82E16819118343'),
('intel-i7-12700kf','Intel Core i7-12700KF','Apex product: https://bfung2.github.io/#/products?product=intel-i7-12700kf
Product link: https://www.newegg.com/intel-core-i7-12th-gen-core-i7-12700kf-alder-lake-lga-1700-desktop-cpu-processor/p/N82E16819118345?Item=N82E16819118345'),
('intel-u9-285','Intel Core Ultra 9 285','Apex product: https://bfung2.github.io/#/products?product=intel-u9-285
Product link: https://www.newegg.com/intel-core-ultra-9-285-arrow-lake-lga-1851-desktop-cpu-processor/p/N82E16819118574?Item=N82E16819118574'),
('intel-u7-265','Intel Core Ultra 7 265','Apex product: https://bfung2.github.io/#/products?product=intel-u7-265
Product link: https://www.newegg.com/intel-core-ultra-7-265-arrow-lake-lga-1851-desktop-cpu-processor/p/N82E16819118575?Item=N82E16819118575'),
('amd-r7-5800xt','AMD Ryzen 7 5800XT','Apex product: https://bfung2.github.io/#/products?product=amd-r7-5800xt
Product link: https://www.newegg.com/amd-ryzen-7-5800xt-ryzen-7-5000-series-vermeer-zen-3-socket-am4-processors-desktops/p/274-000M-00257'),
('amd-r7-7700x3d','AMD Ryzen 7 7700X3D','Apex product: https://bfung2.github.io/#/products?product=amd-r7-7700x3d
Product link: https://www.newegg.com/ryzen-7-7700x3d-ryzen-7000-series-raphael-zen-4-socket-am5-amd-cpu/p/N82E16819113941'),
('amd-r7-9800x3d','AMD Ryzen 7 9800X3D','Apex product: https://bfung2.github.io/#/products?product=amd-r7-9800x3d
Product link: https://www.newegg.com/amd-ryzen-7-9000-series-ryzen-7-9800x3d-granite-ridge-zen-5-socket-am5-desktop-cpu-processor/p/N82E16819113877'),
('newegg-n82e16823193175','ASUS ROG 20th Edition Azoth Extreme - Wireless Mechanical Gaming Keyboard - 75% TKL, ROG NX Snow V2 Linear Switch, Aluminum Chassis, Carbon Fiber, Color OLED Sc','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823193175
Product link: https://www.newegg.com/p/N82E16823193175'),
('newegg-n82e16823193170','ASUS ROG Strix Morph 96 Wireless Gaming Keyboard, Mechanical Switches, 2.4GHz/Bluetooth, Compact 96% Layout, RGB, PC','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823193170
Product link: https://www.newegg.com/p/N82E16823193170'),
('newegg-n82e16823193159','ASUS TUF Gaming K3 Gen II Hatsune Miku Edition Optical-Mechanical RGB Keyboard with IP57 Waterproof and Dust Resistance','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823193159
Product link: https://www.newegg.com/p/N82E16823193159'),
('newegg-n82e16823816143','Corsair K55 RGB PRO Membrane Wired Gaming Keyboard – IP42 Dust and Spill-Resistant, 6 Macro Keys w/ Elgato Integration, iCUE Compatible – Black','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823816143
Product link: https://www.newegg.com/corsair-k55-rgb-pro-ch-9226765-na-rubber-dome-mechanical-keyboard/p/N82E16823816143'),
('newegg-n82e16823816175','Corsair Vanguard 96 Wired Mechanical Gaming Keyboard – 96% Layout, MLX Plasma Linear Switches, 8000Hz Polling, LCD Display, Virtual Stream Deck, G-Keys, SOCD Fl','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823816175
Product link: https://www.newegg.com/p/N82E16823816175'),
('newegg-n82e16823942014','MCHOSE ACE 68 60% Mechanical Gaming Keyboard Wired Rapid Trigger Hall Effect Keyboard Magnetic Switch Hyper-Fast 8000Hz Adjustable Actuation, Hot Swap, RGB PC M','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823942014
Product link: https://www.newegg.com/p/N82E16823942014'),
('newegg-n82e16823936004','MONTECH MKey Pro Newegg 25th Anniversary Limited Gold Edition Mechanical Gaming Keyboard, Tri-Mode Bluetooth 5.2 / 2.4GHz Wireless / USB-C Wired, 75% Layout, Ho','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823936004
Product link: https://www.newegg.com/p/N82E16823936004'),
('newegg-n82e16823167074','MSI FORGE GK600 TKL Wireless Gaming Keyboard – MARS Edition, Hot-Swappable 5-Pin, Tri-Mode (2.4GHz/Bluetooth/USB-C), Linear Mechanical Switches, RGB','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823167074
Product link: https://www.newegg.com/p/N82E16823167074'),
('newegg-n82e16823167034','MSI Vigor GK30 USB Wired RGB Gaming Keyboard, Water Repellent','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823167034
Product link: https://www.newegg.com/p/N82E16823167034'),
('newegg-32n-0003-001a8','Redragon K556 RGB LED Backlit Wired Mechanical Gaming Keyboard, Aluminum Base, 104 Standard Keys Linear & Quiet Red Switches','Apex product: https://bfung2.github.io/#/products?product=newegg-32n-0003-001a8
Product link: https://www.newegg.com/redragon-k556-red-switch-black/p/32N-0003-001A8'),
('newegg-32n-0003-00147','Redragon K582 SURARA RGB LED Backlit Mechanical Gaming Keyboard with 104 Keys-Linear and Quiet-Red Switches','Apex product: https://bfung2.github.io/#/products?product=newegg-32n-0003-00147
Product link: https://www.newegg.com/redragon-surara-red-switch-linear-quiet-black/p/32N-0003-00147'),
('newegg-32n-0003-001p6','Redragon K689 Wired Gasket RGB Gaming Keyboard, 108 Keys Mechanical Keyboard w/Extra 4 Hotkeys, Upgraded Hot-swappable Socket, 3-Layer Noise Dampening, Mixed Co','Apex product: https://bfung2.github.io/#/products?product=newegg-32n-0003-001p6
Product link: https://www.newegg.com/p/32N-0003-001P6'),
('newegg-n82e16823201148','Rosewill NEON K96 Tri-Mode Wireless Gaming Keyboard - Smart Display & Knob, 96% Layout, Hot-Swap, Software Support, 98 Keys, RGB, PBT Keycaps & Blue Switches','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823201148
Product link: https://www.newegg.com/p/N82E16823201148'),
('newegg-n82e16823201143','Rosewill Neon S75 Wireless Mechanical Gaming Keyboard, 80-Key Layout w/ Volume Knob, Bluetooth / 2.4GHz / USB-C, Hot-Swappable Blue Switches, RGB Backlit, 6000m','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823201143
Product link: https://www.newegg.com/rosewill-neon-k75-tri-mode-wireless-gaming-keyboard-neon-k75-bl-mechanical-keyboard-clicky/p/N82E16823201143'),
('newegg-n82e16823201139','Rosewill Neon S96 Wireless Mechanical Gaming Keyboard, 98-Key Layout w/ Volume Knob, Bluetooth / 2.4GHz / USB-C, Hot-Swappable Red Switches, RGB Backlit, 3750mA','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16823201139
Product link: https://www.newegg.com/p/N82E16823201139'),
('newegg-n82e16824942003','ABS 34" Ultrawide UWQHD 2K 1440P (Quasi 4K)  240Hz with AMD FreeSync 1ms HDR400 1500R Curved Gaming Computer Monitor with Height Adjustable stand GQ341NE','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824942003
Product link: https://www.newegg.com/p/N82E16824942003'),
('newegg-n82e16824028028','ASRock 24 inch (24.5" viewable) Full HD 144Hz IPS with AMD FreeSync Gaming Computer Monitor with VGA port CL25FFBE','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824028028
Product link: https://www.newegg.com/p/N82E16824028028'),
('newegg-n82e16824028029','ASRock 27 inch Full HD 144Hz IPS with AMD FreeSync Gaming Computer Monitor with VGA port CL27FFBE','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824028029
Product link: https://www.newegg.com/p/N82E16824028029'),
('newegg-n82e16824946006','ASRock Phantom Gaming 27" QHD 2K 1440p 360Hz 0.03ms AMD FreeSync Premium Pro HDR400 OLED Gaming Computer Monitor with Height Adjustable, Swivel & Tilt stand PGO','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824946006
Product link: https://www.newegg.com/p/N82E16824946006'),
('newegg-n82e16824281334','ASUS 24 (23.8" viewable) Full HD 1080P 120hz IPS with Adaptive Sync, 1ms low blue light Eye Care Gaming Computer Monitor VY249HGR','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281334
Product link: https://www.newegg.com/p/N82E16824281334'),
('newegg-n82e16824281339','ASUS 27"  Full HD1080P 120hz IPS with AMD Adaptive Sync 1ms Eye Care Plus, Blue Light Filter, Flicker Free for both Work and Gaming Monitor VY279HGR','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281339
Product link: https://www.newegg.com/p/N82E16824281339'),
('newegg-n82e16824281179','ASUS 27" 1440P Video Conference Monitor (BE279QSK) - QHD (2560 x 1440), IPS, Built-in 2MP Webcam, Mic Array, Speakers, Eye Care, Wall Mountable, AI Noise-cancel','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281179
Product link: https://www.newegg.com/p/N82E16824281179'),
('newegg-n82e16824281434','ASUS ROG 32" 4K 240Hz Tandem RGB OLED Gaming Monitor (PG32UCWM) - Dual Mode HD 480Hz, TrueBlack Glossy, Neo Proximity Sensor, 0.03ms, GaNFET technology, G-SYNC ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281434
Product link: https://www.newegg.com/p/N82E16824281434'),
('newegg-n82e16824281399','ASUS ROG Strix 27 inch QHD 2K 1440P 240Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281399
Product link: https://www.newegg.com/p/N82E16824281399'),
('newegg-n82e16824281381','ASUS ROG Strix 27" QHD 2K 1440P 180Hz fast IPS with AMD FreeSync (AMD Adaptive Sync) & G-Sync compatible HDR400 1ms DCI-P3 95%, USB-C  built-in Ai Gaming Comput','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281381
Product link: https://www.newegg.com/p/N82E16824281381'),
('newegg-n82e16824281388','ASUS ROG Strix 27" QHD 2K 1440P 260Hz IPS with AMD FreeSync Premium & G-Sync Compatible 0.3ms Fast IPS Hatsune Miku Edition Gaming Computer Monitor with Height ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281388
Product link: https://www.newegg.com/p/N82E16824281388'),
('newegg-n82e16824281427','ASUS ROG Strix 34 inch UltraWide QHD 2K 1440P  280Hz G-Sync Compatible HDR500 0.03ms USB-C OLED Curved Gaming Computer Monitor XG34WCDMS','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281427
Product link: https://www.newegg.com/p/N82E16824281427'),
('newegg-n82e16824281389','ASUS ROG Strix 34" Ultrawide OLED HDR Gaming Computer Monitor (XG34WCDG) - 3440x1440, 175Hz, 0.03ms, OLED Care Pro, True 10-bit, G-SYNC Compatible, DisplayWidge','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281389
Product link: https://www.newegg.com/p/N82E16824281389'),
('newegg-n82e16824281415','ASUS ROG Swift 27 inch (26.5" viewable) Dual Mode QHD 1440P 540Hz Full HD 720Hz AMD FreeSync Premium Pro & G-SYNC compatible 0.02ms HDR500 OLED Gaming Computer ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281415
Product link: https://www.newegg.com/p/N82E16824281415'),
('newegg-n82e16824281348','ASUS ROG Swift 27" UHD 4K 240Hz with FreeSync Premium & G-Sync Compatible 0.03ms HDR400 Semi-Glossy OLED Gaming Computer Monitor with Height Adjustable, Pivot, ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281348
Product link: https://www.newegg.com/p/N82E16824281348'),
('newegg-n82e16824281380','ASUS TUF Gaming 24 inch (23.8" viewable) Full HD 1080P 240hz Fast IPS with AMD FreeSync Premium & G-Sync Compatible 0.3ms Gaming Computer Monitor VG249QM5A','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281380
Product link: https://www.newegg.com/p/N82E16824281380'),
('newegg-n82e16824281353','ASUS TUF Gaming 27" QHD 2K 1440P 180Hz with AMD FreeSync, 0.5ms, 1500R, Extreme Low Motion Blur Curved Gaming Computer Monitor VG27WQ3B','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281353
Product link: https://www.newegg.com/p/N82E16824281353'),
('newegg-n82e16824281242','ASUS TUF Gaming 32" (31.5" viewable) QHD 2K 1440P 170Hz AMD FreeSync Premium (Adaptive Sync) 1ms HDR10 Built-in Speakers Gaming Computer Monitor VG32AQA1A','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281242
Product link: https://www.newegg.com/p/N82E16824281242'),
('newegg-n82e16824281355','ASUS TUF Gaming 34 inch UltraWide QHD 2K 1440P 180Hz AMD FreeSync Premium Pro (Adaptive Sync) 1ms HDR400 ELMB Curved Gaming Computer Monitor with Height Adjusta','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281355
Product link: https://www.newegg.com/p/N82E16824281355'),
('newegg-n82e16824281432','ASUS TUF Gaming Series 5 27" FHD Monitor (VG279QML5A) - Fast-IPS, 240Hz, 0.3ms, G-SYNC Compatible, FreeSync Premium, 99% sRGB, Height adjustable','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281432
Product link: https://www.newegg.com/p/N82E16824281432'),
('newegg-n82e16824281440','ASUS TUF Gaming Series 5 34" Curved Ultrawide Monitor (VG34WQ5A) - WQHD (3440x1440), Dual mode (WQHD 200Hz or HD 400Hz), Fast VA, 0.5ms, DisplayHDR400, DisplayW','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824281440
Product link: https://www.newegg.com/p/N82E16824281440'),
('newegg-n82e16824011553','ACER AOPEN 27 inch Full HD 144Hz with AMD FreeSync Computer Monitor for both work and gaming with VGA port 27KA0 P0bi','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011553
Product link: https://www.newegg.com/p/N82E16824011553'),
('newegg-n82e16824011452','Acer Nitro 27 " WQHD 2K 1440P 170Hz 1ms AMD FreeSync Premium Gaming Computer Monitor KG271U Pbiip','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011452
Product link: https://www.newegg.com/p/N82E16824011452'),
('newegg-n82e16824011485','Acer Nitro 27" WQHD 2K 1440P 240HZ IPS 0.5ms with AMD FreeSync Premium HDR400 Gaming Computer Monitor with Speakers VG272U W2BMIIPX','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011485
Product link: https://www.newegg.com/p/N82E16824011485'),
('newegg-n82e16824011516','Acer Nitro 27" WQHD 2K 1440P 270hz IPS with AMD FreeSync Premium 0.5ms, sRGB 99%, Gaming Computer Monitor XV270U Z1bmiiprx','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011516
Product link: https://www.newegg.com/p/N82E16824011516'),
('newegg-n82e16824011530','Acer Nitro 29" (29.5" viewable) Ultrawide Full HD 1080P 200hz with AMD FreeSync Premium Technology 1ms sRGB 100% 1800R Curved Gaming Computer Monitor ED300C X1b','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011530
Product link: https://www.newegg.com/p/N82E16824011530'),
('newegg-n82e16824011537','Acer Nitro 34 inch UltraWide QHD 2K 1440P 120Hz AMD FreeSync Premium 120Hz 1ms Curved Gaming Computer Monitor ED340CUR J0biip','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011537
Product link: https://www.newegg.com/p/N82E16824011537'),
('newegg-n82e16824011531','Acer Nitro 34" QHD 2K 1440P 240Hz with AMD FreeSync Premium (AMD Adaptive Sync) Gaming Computer Monitor XZ340CUR W0BMIIPHX','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011531
Product link: https://www.newegg.com/p/N82E16824011531'),
('newegg-n82e16824011509','Acer Predator 32 inch UHD 4K 240Hz AMD FreeSync Premium (Adaptive Sync) 0.03ms HDR400 USB-C Built-in Speakers OLED Gaming Computer Monitor with Height Adjustabl','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824011509
Product link: https://www.newegg.com/p/N82E16824011509'),
('newegg-n82e16824260972','Dell 24" 144Hz IPS Monitor 4 ms GTG (Fast) 8 ms GTG 1 ms GTG/MPRT FreeSync (AMD Adaptive Sync) NTSC 72% Flat Panel SE2426H','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824260972
Product link: https://www.newegg.com/p/N82E16824260972'),
('newegg-n82e16824012119','GIGABYTE - G27Q20 - 27" SuperSpeed IPS Gaming Monitor - QHD 2560 x 1440 - 200 Hz/OC 210 Hz - 0.5ms GTG - AMD FreeSync Premium, G-SYNC Compatible - HDMI, DP - He','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012119
Product link: https://www.newegg.com/p/N82E16824012119'),
('newegg-n82e16824012118','GIGABYTE 27 inch QHD 2K 1440P 240Hz OLED Gaming Computer Monitor GO27Q24A','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012118
Product link: https://www.newegg.com/p/N82E16824012118'),
('newegg-n82e16824012107','GIGABYTE 27 inch QHD 2K 1440P 280Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Til','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012107
Product link: https://www.newegg.com/p/N82E16824012107'),
('newegg-n82e16824012111','GIGABYTE 27" QHD 2K 1440P 280Hz with AMD FreeSync Premium Pro & G-SYNC Compatible 0.03ms HDR500 USB-C KVM OLED Gaming Computer Monitor with Height adjustable, P','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012111
Product link: https://www.newegg.com/p/N82E16824012111'),
('newegg-n82e16824012102','GIGABYTE 27" UHD 4K 240Hz with AMD FreeSync Premium Pro &, G-SYNC Compatible HDR400 USB-C KVM OLED Gaming Computer Monitor with Height adjustable, pivot, tilt a','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012102
Product link: https://www.newegg.com/p/N82E16824012102'),
('newegg-n82e16824012090','GIGABYTE 32 inch (31.5" viewable) QHD 2K 1440P 180Hz AMD FreeSync (Adaptive Sync) 1ms HDR10 Curved Gaming Computer Monitor GS32QCA','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012090
Product link: https://www.newegg.com/p/N82E16824012090'),
('newegg-n82e16824012113','GIGABYTE 34 inch QHD 2K 1440P 200Hz AMD FreeSync Premium HDR400 Built-in Speakers Curved Gaming Computer Monitor with Height Adjustable & Tilt Stand G34WQC2','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824012113
Product link: https://www.newegg.com/p/N82E16824012113'),
('newegg-n82e16824026520','LG UltraGear 32" Dual Mode UHD 4K 165Hz Full HD 330Hz AMD FreeSync Premium Pro & G-Sync compatible HDR400 OLED Gaming Computer Monitor with Height Adjustable, S','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824026520
Product link: https://www.newegg.com/p/N82E16824026520'),
('newegg-n82e16824026512','LG Ultragear 34" WQHD 2K 1440P 240Hz with FreeSync Premium 1ms HDR400 USB-C DCI-P3 95% Built-in Speakers Curved Gaming Computer Monitor with Height Adjustable, ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824026512
Product link: https://www.newegg.com/p/N82E16824026512'),
('newegg-n82e16824475479','MSI 24 inch (23.8" viewable) Full HD 144Hz IPS AMD FreeSync 1ms HDR Ready Ai Vision Less Blue Light Pro Anti-Flicker Gaming Computer Monitor G242L E14','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475479
Product link: https://www.newegg.com/p/N82E16824475479'),
('newegg-n82e16824475576','MSI 24 inch (24.5" viewable) Full HD 144Hz IPS AMD FreeSync 1ms  FHD Computer Monitor with VGA port for both work and gaming PRO MP251 E14L','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475576
Product link: https://www.newegg.com/p/N82E16824475576'),
('newegg-n82e16824475496','MSI 24 inch Full HD 144Hz IPS with AMD FreeSync 1ms HDR Ready 102% sRGB LCD Gaming Computer Monitor with accessory slot on stand for both Work and Gaming PRO MP','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475496
Product link: https://www.newegg.com/p/N82E16824475496'),
('newegg-n82e16824475433','MSI 24" (24.5" viewable) Full HD 300Hz IPS with AMD FreeSync Premium 0.5ms HDR Ready Ai vision Gaming Computer Monitor MAG 255XF','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475433
Product link: https://www.newegg.com/p/N82E16824475433'),
('newegg-n82e16824475593','MSI 26.5" 320Hz QD-OLED Gaming Monitor FreeSync Premium Pro & G-Sync Compatible Adobe RGB 98% / DCI-P3 99.7% / sRGB 143.73% (CIE1976 Standard) MAG OLED 271QP X3','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475593
Product link: https://www.newegg.com/p/N82E16824475593'),
('newegg-n82e16824475528','MSI 27 inch Dual Mode UHD 4K 160Hz FHD 320Hz Mini LED IPS AMD FreeSync Premium Pro & G-Sync Compatible HDR1000 USB-C Gaming Computer Monitor Height Adjustable, ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475528
Product link: https://www.newegg.com/p/N82E16824475528'),
('newegg-n82e16824475488','MSI 27 inch Dual Mode UHD 4K 160Hz Full HD 320Hz IPS AMD FreeSync (Adaptive Sync) 0.5ms HDR400 Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & T','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475488
Product link: https://www.newegg.com/p/N82E16824475488'),
('newegg-n82e16824475535','MSI 27 inch QHD 2K 1440P 240Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel & Tilt sta','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475535
Product link: https://www.newegg.com/p/N82E16824475535'),
('newegg-n82e16824475541','MSI 27 inch QHD 2K 1440P 240Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel & Tilt sta','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475541
Product link: https://www.newegg.com/p/N82E16824475541'),
('newegg-n82e16824475503','MSI 27 inch QHD 2K 1440P 280Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms HDR400 USB-C OLED Gaming Computer Monitor with Height Adjustable, Swivel, Piv','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475503
Product link: https://www.newegg.com/p/N82E16824475503'),
('newegg-n82e16824475529','MSI 27 inch QHD 2K 1440P 300Hz Rapid IPS AMD FreeSync (Adaptive Sync) Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt Stand MAG 275QPF X30','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475529
Product link: https://www.newegg.com/p/N82E16824475529'),
('newegg-n82e16824475360','MSI 27 inch QHD 2K 1440P 360Hz with FreeSync Premium Pro 0.03ms HDR400 USB-C OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel & Tilt Stand PC ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475360
Product link: https://www.newegg.com/p/N82E16824475360'),
('newegg-n82e16824475501','MSI 27 inch QHD 2K 1440P 500Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms HDR500 USB-C OLED Gaming Computer Monitor with Height Adjustable, Swivel, Piv','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475501
Product link: https://www.newegg.com/p/N82E16824475501'),
('newegg-n82e16824475523','MSI 27 inch UHD 4K 240Hz AMD FreeSync Premium Pro & G-Sync Compatible HDR400 USB-C Ai Vision OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475523
Product link: https://www.newegg.com/p/N82E16824475523'),
('newegg-n82e16824475579','MSI 27 inch WQHD 2K 1440P 320Hz IPS AMD FreeSync Premium & G-Sync Compatible 0.5ms HDR400 Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt S','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475579
Product link: https://www.newegg.com/p/N82E16824475579'),
('newegg-n82e16824475540','MSI 27 inch WQHD 2K 1440P 500Hz AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms HDR500 USB-C OLED Gaming Computer Monitor for both PC and Console Gaming MPG','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475540
Product link: https://www.newegg.com/p/N82E16824475540'),
('newegg-n82e16824475568','MSI 27" (26.5" viewable) UHD 4K 120Hz AMD FreeSync Premium Pro (Adaptive Sync) 0.03ms USB-C PIP PBP OLED Computer Monitor with Height Adjustable, Swivel, Pivot ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475568
Product link: https://www.newegg.com/p/N82E16824475568'),
('newegg-n82e16824475509','MSI 27" Dual Mode UHD 4K 144Hz Full HD 288Hz IPS with Adaptive-Sync 1ms HDR400 Ai Crosshair Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475509
Product link: https://www.newegg.com/p/N82E16824475509'),
('newegg-n82e16824475397','MSI 27" QHD 2K 1440P 180Hz with AMD FreeSync Sync 0.5ms HDR Ready support VRR Ai Vision Less Blue Light Anti-Flicker Curved Gaming Computer Monitor MAG 27CQ6F','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475397
Product link: https://www.newegg.com/p/N82E16824475397'),
('newegg-n82e16824475369','MSI 27" WQHD 2K 1440P 100Hz IPS with Adaptive Sync 1ms Built-in Speakers LCD Computer Monitor with phone accessory slot stand for both Work & Gaming PRO MP275Q','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475369
Product link: https://www.newegg.com/p/N82E16824475369'),
('newegg-n82e16824475536','MSI 27" WQHD 2K 1440P 180HZ AMD FreeSync (AMD Adaptive Sync) 0.5ms HDR Ready Curved Gaming Computer Monitor with Height Adjustable, Swivel, Pivot and Tilt stand','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475536
Product link: https://www.newegg.com/p/N82E16824475536'),
('newegg-n82e16824475582','MSI 32 inch UHD 4K 240Hz AMD FreeSync Premium Pro & G-Sync Compatible USB-C OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt Stand MAG ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475582
Product link: https://www.newegg.com/p/N82E16824475582'),
('newegg-n82e16824475572','MSI 32 inch UHD 4K 240Hz Adaptive Sync HDR500 OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel & Tilt Stand MPG 322UR QD-OLED X24','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475572
Product link: https://www.newegg.com/p/N82E16824475572'),
('newegg-n82e16824475396','MSI 32" (31.5" viewable) Full HD 250Hz with Adaptive Sync 1ms HDR Ready Ai Vision Blue light reduction Anti-Flicker Curved Gaming Computer Monitor MAG32C6X','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475396
Product link: https://www.newegg.com/p/N82E16824475396'),
('newegg-n82e16824475398','MSI 32" (31.5" viewable) UHD 4K 165Hz with AMD FreeSync Premium Pro 0.03ms HDR400 USB-C OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel & Til','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475398
Product link: https://www.newegg.com/p/N82E16824475398'),
('newegg-n82e16824475508','MSI 32" DUAL MODE UHD 4K 160Hz Full HD 320Hz IPS AMD FreeSync 0.5ms HDR400 Ai Vision RGB lighting Gaming Computer Monitor with Height Adjustable, Swivel, Pivot ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475508
Product link: https://www.newegg.com/p/N82E16824475508'),
('newegg-n82e16824475452','MSI 32" UHD 4K 165Hz Nvidia G-Sync Compatible 0.03ms HDR 400 USB-C 1700R Curved OLED Gaming Computer Monitor with Height Adjustable, Swivel & Tilt Stand for bot','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475452
Product link: https://www.newegg.com/p/N82E16824475452'),
('newegg-n82e16824475454','MSI 32" UHD 4K 240Hz  AMD FreeSync Premium Pro & G-Sync Compatible 0.03ms HDR400 USB-C white OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475454
Product link: https://www.newegg.com/p/N82E16824475454'),
('newegg-n82e16824475358','MSI 32" UHD 4K 240Hz AMD FreeSync Premium 0.03ms HDR400 OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt stand MAG 321UPX QD-OLED','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475358
Product link: https://www.newegg.com/p/N82E16824475358'),
('newegg-n82e16824475451','MSI 32" UHD 4K 240Hz G-Sync Compatible 0.03ms HDR400 USB-C KVM RGB Ai Vision OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt stand for','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475451
Product link: https://www.newegg.com/p/N82E16824475451'),
('newegg-n82e16824475395','MSI 32" WQHD 2K 1440P 180Hz with AMD FreeSync 0.5ms HDR400 101% sRGB Curved Gaming Computer Monitor MAG 32CQ6F','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475395
Product link: https://www.newegg.com/p/N82E16824475395'),
('newegg-n82e16824475549','MSI 34 inch UltraWide QHD 1440P 360Hz AMD FreeSync Premium Pro & G-Sync Compatible USB-C OLED Curved Gaming Computer Monitor with Height Adjustable, Swivel, Piv','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475549
Product link: https://www.newegg.com/p/N82E16824475549'),
('newegg-n82e16824475554','MSI 34 inch UltraWide QHD 2K 1440P 120Hz Adaptive Sync 1ms HDR Ready Built-in Speaker Curved Computer Monitor PRO MP341CQ E12','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475554
Product link: https://www.newegg.com/p/N82E16824475554'),
('newegg-n82e16824475555','MSI 34 inch UltraWide QHD 2K 1440P 120Hz Adaptive Sync 1ms HDR Ready Built-in Speaker White Curved Computer Monitor PRO MP341CQW E12','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475555
Product link: https://www.newegg.com/p/N82E16824475555'),
('newegg-n82e16824475581','MSI 34 inch UltraWide QHD 2K 1440P 280Hz AMD FreeSync Premium Pro & G-Sync Compatible Curved OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475581
Product link: https://www.newegg.com/p/N82E16824475581'),
('newegg-n82e16824475564','MSI 34 inch Ultrawide QHD 2K 1440P 200Hz Adaptive Sync 0.5ms HDR Ready Curved Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt Stand MAG 345','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475564
Product link: https://www.newegg.com/p/N82E16824475564'),
('newegg-n82e16824475356','MSI 49" DQHD 2K 1440P 144Hz AMD FreeSync Premium Pro  0.03ms HDR400 DCI-P3 99% USB-C VRR KVM OLED 1800R Curved Gaming Computer Monitor with Height Adjustable, S','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475356
Product link: https://www.newegg.com/p/N82E16824475356'),
('newegg-n82e16824475591','MSI PRO MAX Ultrawide 34 inch QHD 2K 144OP 144Hz Adaptive Sync OLED Silver White Monitor with Height Adjustable, Pivot, Swivel & Tilt Stand PRO MAX 341QPXW14G','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824475591
Product link: https://www.newegg.com/p/N82E16824475591'),
('newegg-n82e16824027383','SAMSUNG 27 inch Odyssey G53F QHD 2K 1440P 200Hz IPS AMD FreeSync Premium 1ms HDR10 USB-C Auto Source Switch Gaming Computer Monitor LS27FG532ENXZA','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027383
Product link: https://www.newegg.com/p/N82E16824027383'),
('newegg-n82e16824027392','SAMSUNG 32 inch Movingstyle M7 UHD 4K USB-C Adjustable Rolling Stand, Smart TV Apps, Built-in Speakers, Gaming Hub, AI Picture Optimizer, SmartThings Modern Whi','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027392
Product link: https://www.newegg.com/p/N82E16824027392'),
('newegg-n82e16824027394','SAMSUNG ODYSSEY G7 32 inch Dual Mode UHD 4K 165Hz Full HD 330Hz AMD FreeSync Premium Pro  & G-SYNC Compatible HDR400 OLED Gaming Computer Monitor with Height, S','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027394
Product link: https://www.newegg.com/p/N82E16824027394'),
('newegg-n82e16824027395','SAMSUNG Odyssey 27 inch Max 5K 180Hz QHD 2K 1440P 360Hz IPS AMD FreeSync Premium & G-Sync Compatible USB-C Gaming Computer Monitor with Height Adjustable, Pivot','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027395
Product link: https://www.newegg.com/p/N82E16824027395'),
('newegg-n82e16824027396','SAMSUNG Odyssey 27 inch UHD 4K 240Hz AMD  FreeSync Premium Pro (Adaptive Sync) HDR400 USB-C OLED Gaming Computer Monitor with Height Adjustable, Pivot, Swivel, ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027396
Product link: https://www.newegg.com/p/N82E16824027396'),
('newegg-n82e16824027402','SAMSUNG Odyssey 32 inch Max 6K 165Hz 3K 330Hz IPS AMD FreeSync Premium & G-Sync Compatible HDR10+ Gaming Computer Monitor with Height Adjustable, Pivot, Swivel,','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027402
Product link: https://www.newegg.com/p/N82E16824027402'),
('newegg-n82e16824027393','SAMSUNG Odyssey G6 27 inch QHD 2K 1440P 240Hz AMD FreeSync Premium HDR10 OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt Stand LS27HG6','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027393
Product link: https://www.newegg.com/p/N82E16824027393'),
('newegg-n82e16824027378','SAMSUNG Odyssey G6 27" QHD 2K 1440P 350Hz IPS AMD FreeSync Premium & G-Sync Compatible 1ms HDR400 Gaming Computer Monitor with Height Adjustable, Pivot, Swivel ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027378
Product link: https://www.newegg.com/p/N82E16824027378'),
('newegg-n82e16824027374','SAMSUNG Odyssey G7 40" WUHD 4K 180Hz AMD FreeSync Premium Pro 1ms HDR600 1000R PBP PIP Curved Gaming Computer Monitor with Height Adjustable, Swivel & Tilt Stan','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027374
Product link: https://www.newegg.com/p/N82E16824027374'),
('newegg-n82e16824027310','SAMSUNG Odyssey G9 49" DUAL QHD 2K 1440P 240Hz AMD FreeSync Premium Pro 1ms HDR1000 PBP PIP Curved Gaming Computer Monitor with Height Adjustable, Swivel & Tilt','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027310
Product link: https://www.newegg.com/p/N82E16824027310'),
('newegg-n82e16824027362','SAMSUNG Odyssey G9 49" Dual QHD 2K 1440P 144Hz AMD FreeSync Premium Pro 1ms HDR600 PBP PIP Curved Gaming Computer Monitor with Height Adjustable, Swivel & Tilt ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027362
Product link: https://www.newegg.com/p/N82E16824027362'),
('newegg-n82e16824027398','SAMSUNG ViewFinity 40 inch UltraWide WUHD 5K2K 144Hz AMD FreeSync Premium (Adaptive Sync) Thunderbolt 5 Curved Gaming Computer Monitor with Height Adjustable, S','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027398
Product link: https://www.newegg.com/p/N82E16824027398'),
('newegg-n82e16824027387','Samsung Odyssey G50SF 27" QHD 2K 1440P 180Hz NVIDIA G-Sync Compatible 0.03ms HDR10 OLED Gaming Computer Monitor with Height Adjustable, Swivel, Pivot & Tilt Sta','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027387
Product link: https://www.newegg.com/p/N82E16824027387'),
('newegg-n82e16824027368','Samsung Odyssey G8 32" UHD 4K 240Hz FreeSync Premium Pro & G-Sync compatible 0.03ms HDR400 Glare Free OLED Gaming Computer Monitor with Height Adjustable, Swive','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027368
Product link: https://www.newegg.com/p/N82E16824027368'),
('newegg-n82e16824027358','Samsung S3 27" Full HD 100Hz with AMD FreeSync 1800R Curved Computer Monitor with Built-in Speakers for both Work & Casual Gaming LS27D396GANXZA','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16824027358
Product link: https://www.newegg.com/p/N82E16824027358'),
('newegg-n82e16826785287','ASUS ROG 20th Edition Harpe II Extreme - Wireless Esports Gaming Mouse - 82g Lightweight, Tri-Mode Connectivity, 65K DPI, 8K Hz Polling, 24K Gold-Plated, Web Co','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16826785287
Product link: https://www.newegg.com/p/N82E16826785287'),
('newegg-n82e16826785269','ASUS TUF Gaming Mini Wireless Mouse Hatsune Miku Edition','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16826785269
Product link: https://www.newegg.com/p/N82E16826785269'),
('newegg-n82e16826197674','Logitech PRO X2 SUPERSTRIKE LIGHTSPEED Wireless Gaming Mouse, Ultra-Fast Performance, Ultra Lightweight (61 g), Customizable Click Haptics, USB-C charging, for ','Apex product: https://bfung2.github.io/#/products?product=newegg-n82e16826197674
Product link: https://www.newegg.com/p/N82E16826197674'),
('newegg-32k-000n-00173','Razer DeathAdder Essential Gaming Mouse: 6400 DPI Optical Sensor - 5 Programmable Buttons - Mechanical Switches - Rubber Side Grips - Classic Black','Apex product: https://bfung2.github.io/#/products?product=newegg-32k-000n-00173
Product link: https://www.newegg.com/razer-rz01-03850100-r3u1-deathadder-essential-wired/p/32K-000N-00173'),
('newegg-32k-000n-00375','Razer Viper V3 HyperSpeed Wireless Esports Gaming Mouse: 82g Lightweight Design - 30K DPI Optical Sensor - Up to 280 Hr Battery Life - Mechanical Switches Gen-2','Apex product: https://bfung2.github.io/#/products?product=newegg-32k-000n-00375
Product link: https://www.newegg.com/p/32K-000N-00375'),
('newegg-32k-005k-000r2','Redragon M991 Wireless Gaming Mouse, 26000 DPI 3-Mode Gamer Mice w/Rapid Fire Key, 9 Macro Buttons, Powerful Capacity and RGB Backlight for PC/Mac/Laptop','Apex product: https://bfung2.github.io/#/products?product=newegg-32k-005k-000r2
Product link: https://www.newegg.com/p/32K-005K-000R2'),
('o59opzm','Intel Core i7-14700KF','Apex product: https://bfung2.github.io/#/products?product=o59opzm'),
('gshvuwn','Intel Core i7-14700','Apex product: https://bfung2.github.io/#/products?product=gshvuwn'),
('h8olo1u','Intel Core i7-14700F','Apex product: https://bfung2.github.io/#/products?product=h8olo1u'),
('r89m00v','Intel Core i5-14600K','Apex product: https://bfung2.github.io/#/products?product=r89m00v'),
('9mbrbjk','Intel Core i5-14600KF','Apex product: https://bfung2.github.io/#/products?product=9mbrbjk'),
('llw40wt','Intel Core i5-14400','Apex product: https://bfung2.github.io/#/products?product=llw40wt'),
('6skacce','Team T-Force Delta RGB','Apex product: https://bfung2.github.io/#/products?product=6skacce'),
('y69jed9','CORSAIR Vengeance RGB','Apex product: https://bfung2.github.io/#/products?product=y69jed9'),
('2ewivv1','CORSAIR Vengeance RGB','Apex product: https://bfung2.github.io/#/products?product=2ewivv1'),
('zvpnb23','G.SKILL Trident Z5 RGB','Apex product: https://bfung2.github.io/#/products?product=zvpnb23'),
('eldmo2c','CORSAIR Vengeance RGB','Apex product: https://bfung2.github.io/#/products?product=eldmo2c'),
('jfhjltb','CORSAIR Vengeance','Apex product: https://bfung2.github.io/#/products?product=jfhjltb'),
('3yuf9vc','CORSAIR Vengeance RGB 32GB','Apex product: https://bfung2.github.io/#/products?product=3yuf9vc'),
('jgz2gex','CORSAIR Vengeance 16GB','Apex product: https://bfung2.github.io/#/products?product=jgz2gex'),
('s5irrlt','CORSAIR Vengeance RGB 16GB','Apex product: https://bfung2.github.io/#/products?product=s5irrlt'),
('kfftksl','CORSAIR Vengeance RGB 32GB','Apex product: https://bfung2.github.io/#/products?product=kfftksl'),
('52qat7g','CORSAIR Vengeance RGB 16GB','Apex product: https://bfung2.github.io/#/products?product=52qat7g'),
('h85yrlo','CORSAIR Vengeance RGB 16GB','Apex product: https://bfung2.github.io/#/products?product=h85yrlo'),
('d0mpe9h','CORSAIR Vengeance 32GB','Apex product: https://bfung2.github.io/#/products?product=d0mpe9h'),
('8fjd834','CORSAIR Dominator Titanium 64GB','Apex product: https://bfung2.github.io/#/products?product=8fjd834'),
('8eospyr','Klevv Bolt V 64GB','Apex product: https://bfung2.github.io/#/products?product=8eospyr'),
('go6mecn','Team T-Force Delta ECO 32GB','Apex product: https://bfung2.github.io/#/products?product=go6mecn'),
('oo7bhle','G.SKILL Trident Z5 Royal Neol Series 32GB','Apex product: https://bfung2.github.io/#/products?product=oo7bhle'),
('lbr43vq','CORSAIR Vengeance RGB 64GB','Apex product: https://bfung2.github.io/#/products?product=lbr43vq'),
('sabkwcr','G.SKILL Trident Z Royal Series 64GB','Apex product: https://bfung2.github.io/#/products?product=sabkwcr'),
('2f31r8b','CORSAIR Vengeance RGB Pro SL 16GB','Apex product: https://bfung2.github.io/#/products?product=2f31r8b'),
('3lr8mbx','CORSAIR Vengeance RGB Pro 16GB','Apex product: https://bfung2.github.io/#/products?product=3lr8mbx'),
('njee07b','Team T-Force Delta RGB 16GB','Apex product: https://bfung2.github.io/#/products?product=njee07b'),
('3w823jj','CORSAIR Vengeance RGB Pro SL 32GB','Apex product: https://bfung2.github.io/#/products?product=3w823jj'),
('q7ai1hl','CORSAIR Vengeance LPX 32GB','Apex product: https://bfung2.github.io/#/products?product=q7ai1hl'),
('zbkwdjp','CORSAIR Vengeance LPX 16GB','Apex product: https://bfung2.github.io/#/products?product=zbkwdjp'),
('59ilhzy','CORSAIR Vengeance RGB Pro 32GB','Apex product: https://bfung2.github.io/#/products?product=59ilhzy'),
('xjse0tl','G.SKILL Ripjaws V Series 32GB','Apex product: https://bfung2.github.io/#/products?product=xjse0tl'),
('9iz3zri','G.SKILL TridentZ RGB Series 32GB','Apex product: https://bfung2.github.io/#/products?product=9iz3zri'),
('r38ntlx','G.SKILL Ripjaws V Series 16GB','Apex product: https://bfung2.github.io/#/products?product=r38ntlx'),
('dcnprko','CORSAIR Vengeance RGB Pro 16GB','Apex product: https://bfung2.github.io/#/products?product=dcnprko'),
('ko54jkz','Team T-Force Delta RGB 16GB','Apex product: https://bfung2.github.io/#/products?product=ko54jkz'),
('rx9m78y','ASUS TUF GAMING X870E-PLUS WIFI7 AMD','Apex product: https://bfung2.github.io/#/products?product=rx9m78y'),
('jwxdzbt','GIGABYTE B850 AORUS ELITE WIFI7 ICE AMD AM5','Apex product: https://bfung2.github.io/#/products?product=jwxdzbt'),
('5yliq5w','MSI MAG B850 TOMAHAWK MAX WIFI Motherboard','Apex product: https://bfung2.github.io/#/products?product=5yliq5w'),
('e797b7k','MSI MAG X870 TOMAHAWK','Apex product: https://bfung2.github.io/#/products?product=e797b7k'),
('o3rfpwc','ASUS ROG STRIX X870E-E GAMING WIFI AMD','Apex product: https://bfung2.github.io/#/products?product=o3rfpwc'),
('rcdo2rx','ASUS B850 MAX GAMING WIFI','Apex product: https://bfung2.github.io/#/products?product=rcdo2rx'),
('5ury8p7','MSI B650 GAMING PLUS WIFI','Apex product: https://bfung2.github.io/#/products?product=5ury8p7'),
('gpu3050v2x','MSI Ventus GeForce RTX 3050 8GB VENTUS 2X XS OC','Apex product: https://bfung2.github.io/#/products?product=gpu3050v2x'),
('gpu5070tish3x','MSI SHADOW GeForce RTX 5070 Ti 16GB SHADOW 3X OC','Apex product: https://bfung2.github.io/#/products?product=gpu5070tish3x'),
('gpu9060xtdual','ASUS Dual Radeon RX 9060 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpu9060xtdual'),
('gpurx9070xtnitro','SAPPHIRE NITRO+ Radeon RX 9070 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070xtnitro'),
('gpu9060xtgigagaming3x','GIGABYTE Gaming Radeon RX 9060 XT 16GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu9060xtgigagaming3x'),
('gpu5060gigablp3x','GIGABYTE Low Profile GeForce RTX 5060 8GB OC','Apex product: https://bfung2.github.io/#/products?product=gpu5060gigablp3x'),
('gpu5090aorusmasterice3x','GIGABYTE AORUS GeForce RTX 5090 MASTER ICE 32GB','Apex product: https://bfung2.github.io/#/products?product=gpu5090aorusmasterice3x'),
('gpu9070xtasrocksteellegend3x','ASRock Steel Legend Radeon RX 9070 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpu9070xtasrocksteellegend3x
Product link: https://www.newegg.com/asrock-steel-legend-rx9070xt-sl-16g-radeon-rx-9070-xt-16gb-graphics-card-triple-fans/p/N82E16814930136?Item=N82E16814930136&SoldByNewegg=1'),
('gpurx9070xtsapphirepulse3x','SAPPHIRE PULSE Radeon RX 9070 XT 16GB','Apex product: https://bfung2.github.io/#/products?product=gpurx9070xtsapphirepulse3x
Product link: https://www.newegg.com/sapphire-tech-pulse-11348-03-20g-radeon-rx-9070-xt-16gb-graphics-card-triple-fans/p/N82E16814202450?Item=N82E16814202450&SoldByNewegg=1'),
('gpurtx5060gigabytewindforce2x','GIGABYTE WINDFORCE GeForce RTX 5060 8GB OC','Apex product: https://bfung2.github.io/#/products?product=gpurtx5060gigabytewindforce2x
Product link: https://www.newegg.com/gigabyte-windforce-gv-n5060wf2oc-8gd-geforce-rtx-5060-8gb-graphics-card-double-fans/p/N82E16814932804'),
('gpurtx5060zotacamp2x','ZOTAC GAMING GeForce RTX 5060 AMP 8GB','Apex product: https://bfung2.github.io/#/products?product=gpurtx5060zotacamp2x
Product link: https://www.newegg.com/zotac-rtx-5060-amp-geforce-rtx-5060-8gb-graphics-card-double-fans/p/N82E16814500658?Item=N82E16814500658'),
('gpurtx5060tigigabyteeaglemax3x8','GIGABYTE EAGLE GeForce RTX 5060 Ti 8GB OC MAX','Apex product: https://bfung2.github.io/#/products?product=gpurtx5060tigigabyteeaglemax3x8
Product link: https://www.newegg.com/gigabyte-gv-n506teagle-oc-8gd-geforce-rtx-5060-ti-8gb-graphics-card-double-fans/p/N82E16814932812?Item=N82E16814932812'),
('gpurtx5060tiasustuf3x8','ASUS TUF Gaming GeForce RTX 5060 Ti 8GB OC','Apex product: https://bfung2.github.io/#/products?product=gpurtx5060tiasustuf3x8
Product link: https://www.newegg.com/asus-tuf-gaming-tuf-rtx5060ti-o8g-gaming-geforce-rtx-5060-ti-8gb-graphics-card-triple-fans/p/N82E16814126792?Item=N82E16814126792'),
('psu550m','MONTECH BETA 2 550W','Apex product: https://bfung2.github.io/#/products?product=psu550m
Product link: https://www.newegg.com/montech-atx-550-w-80-plus-bronze-certified-power-supplies-black-beta-2-550w/p/N82E16817959015'),
('psu550r','Rosewill VNW550 550W','Apex product: https://bfung2.github.io/#/products?product=psu550r
Product link: https://www.newegg.com/p/N82E16817182484'),
('psu650a','ASRock PRO Series PRO-650G 650W','Apex product: https://bfung2.github.io/#/products?product=psu650a
Product link: https://www.newegg.com/asrock-pro-series-atx-3-1-compatible-650-w-80-plus-gold-certified-power-supply-black-pro-650g/p/N82E16817955024?Item=N82E16817955024&SoldByNewegg=1'),
('psu650b','MSI MAG A650BN 650W','Apex product: https://bfung2.github.io/#/products?product=psu650b
Product link: https://www.newegg.com/msi-intel-atx-12v-650-w-80-plus-bronze-certified-power-supply-black-mag-a650bn/p/N82E16817701013?Item=N82E16817701013&SoldByNewegg=1'),
('psu650m','MSI MAG A650GL 650W','Apex product: https://bfung2.github.io/#/products?product=psu650m
Product link: https://www.newegg.com/msi-atx12v-650-w-80-plus-gold-certified-power-supply-black-mag-a650gl/p/N82E16817701023?Item=N82E16817701023&SoldByNewegg=1'),
('psu750c','CORSAIR RM750e (2025) 750W','Apex product: https://bfung2.github.io/#/products?product=psu750c
Product link: https://www.newegg.com/corsair-rmx-series-atx-3-1-compatible-750-w-cybenetics-gold-power-supply-black-rm750e/p/N82E16817139339'),
('psu750m','MSI MAG A750GL PCIE5 750W','Apex product: https://bfung2.github.io/#/products?product=psu750m
Product link: https://www.newegg.com/msi-atx12v-750-w-80-plus-gold-certified-power-supplies-black-mag-a750gl-pcie5/p/N82E16817701022'),
('psu750s','CORSAIR SF750 750W SFX','Apex product: https://bfung2.github.io/#/products?product=psu750s
Product link: https://www.newegg.com/corsair-sf-series-sfx-750-w-80-plus-platinum-certified-power-supply-cp-9020284-na/p/N82E16817139330'),
('psu750b','MONTECH BETA 2 750W','Apex product: https://bfung2.github.io/#/products?product=psu750b
Product link: https://www.newegg.com/montech-atx-750-w-80-plus-bronze-certified-power-supplies-beta-2-750w/p/N82E16817959017'),
('psu750g','MONTECH Century II 750W','Apex product: https://bfung2.github.io/#/products?product=psu750g
Product link: https://www.newegg.com/montech-atx-3-1-pcie-5-1-750-w-80-plus-gold-certified-power-supplies-silver-century-ii-750w/p/N82E16817959021'),
('psu850c','CORSAIR RM850e (2025) 850W','Apex product: https://bfung2.github.io/#/products?product=psu850c
Product link: https://www.newegg.com/corsair-rmx-series-atx-3-1-compatible-850-w-cybenetics-gold-power-supply-black-rm850e/p/N82E16817139336'),
('psu850m','MSI MPG A850GS PCIE5 850W','Apex product: https://bfung2.github.io/#/products?product=psu850m
Product link: https://www.newegg.com/msi-atx12v-850-w-up-to-90-power-supplies-black-mpg-a850gs-pcie5/p/N82E16817701031'),
('psu850b','be quiet! Pure Power 13 M 850W','Apex product: https://bfung2.github.io/#/products?product=psu850b
Product link: https://www.newegg.com/be-quiet-temperature-controlled-quality-fan-850-w-80-plus-gold-certified-power-supply-black-bp027eu/p/N82E16817222043'),
('psu850s','CORSAIR SF850 850W SFX','Apex product: https://bfung2.github.io/#/products?product=psu850s
Product link: https://www.newegg.com/corsair-sf-series-sfx-850-w-80-plus-platinum-certified-power-supply-cp-9020256-na/p/N82E16817139331'),
('psu850p','be quiet! Power Zone 2 850W','Apex product: https://bfung2.github.io/#/products?product=psu850p
Product link: https://www.newegg.com/be-quiet-power-zone-2-atx12v-3-1-850-w-80-plus-platinum-and-cybenetics-platinum-efficiency-power-supplies-black/p/N82E16817222040'),
('psu850t','be quiet! Dark Power 14 850W','Apex product: https://bfung2.github.io/#/products?product=psu850t
Product link: https://www.newegg.com/p/N82E16817222047?Item=N82E16817222047'),
('psu100c','CORSAIR RM1000e (2025) 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100c
Product link: https://www.newegg.com/corsair-rmx-series-atx-3-1-compatible-1000-w-cybenetics-gold-power-supply-black-rm1000e/p/N82E16817139337?Item=N82E16817139337&SoldByNewegg=1'),
('psu100b','be quiet! Power Zone 2 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100b
Product link: https://www.newegg.com/be-quiet-power-zone-2-atx12v-3-1-1000-w-80-plus-platinum-and-cybenetics-platinum-efficiency-power-supplies-black/p/N82E16817222039?Item=N82E16817222039&SoldByNewegg=1'),
('psu100a','ASRock Phantom Gaming PG-1000G 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100a
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1000-w-cybenetics-gold-power-supply-black-pg-1000g/p/N82E16817955005?Item=N82E16817955005&SoldByNewegg=1'),
('psu100t','be quiet! Dark Power 14 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100t
Product link: https://www.newegg.com/p/N82E16817222048?Item=N82E16817222048&SoldByNewegg=1'),
('psu120r','Rosewill CMG1200G5 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120r
Product link: https://www.newegg.com/rosewill-atx-3-0-compatible-atx-3-1-compatible-1200-w-80-plus-gold-certified-power-supplies-cmg1200g5/p/N82E16817182454'),
('psu120c','CORSAIR HX1200i (2025) 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120c
Product link: https://www.newegg.com/corsair-hx1200i-atx-3-1-compatible-1200-w-up-to-92-efficiency-power-supplies-black/p/N82E16817139344'),
('psu120a','ASUS ROG Loki SFX-L 1200W Titanium','Apex product: https://bfung2.github.io/#/products?product=psu120a
Product link: https://www.newegg.com/asus-1200-w-80-plus-titanium-certified-power-supply-black-rog-loki-1200t-sfx-l-gaming/p/N82E16817320049'),
('psu120m','MSI MAG A1200PLS PCIE5 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120m
Product link: https://www.newegg.com/msi-atx-3-1-1200-w-80-plus-platinum-certified-power-supplies-mag-a1200pls-pcie5/p/N82E16817701044'),
('psu120b','be quiet! Pure Power 13 M 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120b
Product link: https://www.newegg.com/be-quiet-atx12v-3-1-1200-w-80-plus-gold-certified-power-supplies-black-pure-power-13-m-1200w/p/N82E16817222050'),
('psu120s','ASRock Steel Legend SL-1200G 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120s
Product link: https://www.newegg.com/p/N82E16817955020?Item=N82E16817955020&SoldByNewegg=1'),
('psu120t','Thermaltake Toughpower GF3 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120t
Product link: https://www.newegg.com/thermaltake-toughpower-gf3-series-atx-12v-v3-0-eps-v2-93-1200-w-80-plus-gold-certified-power-supply-ps-tpd-1200fnfagu-4/p/N82E16817153436'),
('psu130a','ASRock Phantom Gaming PG-1300G 1300W','Apex product: https://bfung2.github.io/#/products?product=psu130a
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1300-w-cybenetics-gold-power-supply-black-pg-1300g/p/N82E16817955004?Item=N82E16817955004&SoldByNewegg=1'),
('psu130t','ASRock Taichi TC-1300T 1300W','Apex product: https://bfung2.github.io/#/products?product=psu130t
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1300-w-cybenetics-titanium-power-supply-black-tc-1300t/p/N82E16817955002?Item=N82E16817955002&SoldByNewegg=1'),
('psu150b','be quiet! Straight Power 12 1500W','Apex product: https://bfung2.github.io/#/products?product=psu150b
Product link: https://www.newegg.com/be-quiet-straight-power-atx-3-0-compatible-1500-w-80-plus-platinum-certified-power-supplies-black/p/1HU-004H-000T5?Item=1HU-004H-000T5&SoldByNewegg=1'),
('psu150c','CORSAIR HX1500i (2025) 1500W','Apex product: https://bfung2.github.io/#/products?product=psu150c
Product link: https://www.newegg.com/corsair-hx1500i-atx-3-1-compatible-1500-w-up-to-92-efficiency-power-supplies-black/p/N82E16817139343?Item=N82E16817139343&SoldByNewegg=1'),
('psu150s','SilverStone SST-ST1500-TI 1500W','Apex product: https://bfung2.github.io/#/products?product=psu150s
Product link: https://www.newegg.com/silverstone-atx12v-1500-w-80-plus-titanium-certified-power-supply-ps-st1500-ti/p/N82E16817256196?Item=N82E16817256196&SoldByNewegg=1'),
('psu150n','NZXT C1500 Platinum 1500W','Apex product: https://bfung2.github.io/#/products?product=psu150n
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-1500-w-80-plus-platinum-certified-power-supplies-black-pa-5p1bb-us/p/1HU-001J-000C6?Item=1HU-001J-000C6&SoldByNewegg=1'),
('psu160a','ASRock Phantom Gaming PG-1600G 1600W','Apex product: https://bfung2.github.io/#/products?product=psu160a
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1600-w-cybenetics-gold-power-supply-black-pg-1600g/p/N82E16817955003?Item=N82E16817955003&SoldByNewegg=1'),
('psu160m','MSI MEG Ai1600T PCIE5 1600W','Apex product: https://bfung2.github.io/#/products?product=psu160m
Product link: https://www.newegg.com/msi-atx12v-1600-w-up-to-94-power-supplies-black-meg-ai1600t-pcie5/p/N82E16817701028?Item=N82E16817701028&SoldByNewegg=1'),
('psu500t','Thermaltake Smart Series 500W','Apex product: https://bfung2.github.io/#/products?product=psu500t
Product link: https://www.newegg.com/thermaltake-smart-500w-intel-atx-12v-2-31-eps-12v-2-92-500-w-80-plus-certified-power-supply-black-ps-spd-0500npcwus-w/p/N82E16817153233?Item=N82E16817153233&SoldByNewegg=1'),
('psu500m','MSI MAG A500DN II 500W','Apex product: https://bfung2.github.io/#/products?product=psu500m
Product link: https://www.newegg.com/p/N82E16817701047?Item=N82E16817701047&SoldByNewegg=1'),
('psu600t','Thermaltake Smart Series 600W','Apex product: https://bfung2.github.io/#/products?product=psu600t
Product link: https://www.newegg.com/thermaltake-smart-series-intel-atx-12v-v2-3-eps12v-80-plus-certified-power-supply-ps-spd-0600npcwus-w/p/N82E16817153232?Item=N82E16817153232&SoldByNewegg=1'),
('psu600g','Thermaltake Toughpower GX2 600W','Apex product: https://bfung2.github.io/#/products?product=psu600g
Product link: https://www.newegg.com/thermaltake-toughpower-gx2-gold-intel-atx-12v-v2-3-eps-12v-600-w-80-plus-gold-certified-power-supply-ps-tpd-0600nnfagu-2/p/N82E16817153415?Item=N82E16817153415&SoldByNewegg=1'),
('psu105t','Thermaltake Toughpower GF A3 1050W','Apex product: https://bfung2.github.io/#/products?product=psu105t
Product link: https://www.newegg.com/thermaltake-toughpower-gf-a3-series-atx-atx-3-0-compatible-1050-w-80-plus-gold-certified-power-supply-black-ps-tpd-1050fnfagu-l/p/N82E16817153448?Item=N82E16817153448&SoldByNewegg=1'),
('psu125m','MSI MPG A1250GS PCIE5 II 1250W','Apex product: https://bfung2.github.io/#/products?product=psu125m
Product link: https://www.newegg.com/msi-atx12v-1250-w-80-plus-gold-certified-power-supply-black-mpg-a1250gs-pcie5-ii/p/N82E16817701037?Item=N82E16817701037&SoldByNewegg=1'),
('psu165t','Thermaltake Toughpower GF3 1650W','Apex product: https://bfung2.github.io/#/products?product=psu165t
Product link: https://www.newegg.com/thermaltake-toughpower-gf3-series-ps-tpd-1650fnfagu-4-1650-w/p/N82E16817153434?Item=N82E16817153434&SoldByNewegg=1'),
('psu100s','SAMA G1000 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100s
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-1000-w-80-plus-gold-certified-power-supplies-g1000w-black/p/1HU-02S6-00066?Item=1HU-02S6-00066&SoldByNewegg=1'),
('psu120p','SAMA P1200 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120p
Product link: https://www.newegg.com/sama-p-series-atx-3-1-compatible-1200-w-80-plus-platinum-certified-power-supplies-p1200w-black/p/1HU-02S6-00072?Item=1HU-02S6-00072&SoldByNewegg=1'),
('psu120h','Phanteks AMP GH 1200W','Apex product: https://bfung2.github.io/#/products?product=psu120h
Product link: https://www.newegg.com/phanteks-intel-atx-3-1-pcie-gen5-1-750-w-80-plus-platinum-certified-power-supply-white-ph-p750gh-bk01/p/N82E16817987031?Item=N82E16817987031'),
('psu850r','Rosewill VMG850 850W','Apex product: https://bfung2.github.io/#/products?product=psu850r
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-850-w-80-plus-gold-certified-power-supply-vmg850/p/N82E16817182468?Item=N82E16817182468&SoldByNewegg=1'),
('psu100m','MSI MPG A1000GS PCIE5 II 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100m
Product link: https://www.newegg.com/msi-atx12v-1000-w-80-plus-gold-certified-power-supply-black-mpg-a1000gs-pcie5-ii/p/N82E16817701038?Item=N82E16817701038&SoldByNewegg=1'),
('psu650c','ASRock Challenger CL-650G 650W','Apex product: https://bfung2.github.io/#/products?product=psu650c
Product link: https://www.newegg.com/asrock-atx-3-1-650-w-80-plus-gold-certified-power-supply-black-cl-650g/p/N82E16817955016?Item=N82E16817955016&SoldByNewegg=1'),
('psu650g','MONTECH Century II 650W','Apex product: https://bfung2.github.io/#/products?product=psu650g
Product link: https://www.newegg.com/montech-atx-3-1-pcie-5-1-650-w-80-plus-gold-certified-power-supplies-silver-century-ii-650w/p/N82E16817959020?Item=N82E16817959020&SoldByNewegg=1'),
('psu850n','NZXT C850 Gold 850W','Apex product: https://bfung2.github.io/#/products?product=psu850n
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-850-w-80-plus-gold-certified-power-supplies-black-pa-8g2bb-us/p/N82E16817116050?Item=N82E16817116050&SoldByNewegg=1'),
('psu100r','Rosewill VMG1000 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100r
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-1000-w-80-plus-gold-certified-power-supply-vmg1000/p/N82E16817182469?Item=N82E16817182469&SoldByNewegg=1'),
('psu100g','MSI MAG A1000GLS PCIE5 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100g
Product link: https://www.newegg.com/msi-atx12v-1000-w-80-plus-gold-certified-power-supply-black-mag-a1000gls-pcie5/p/N82E16817701032?Item=N82E16817701032&SoldByNewegg=1'),
('psu100n','NZXT C1000 Gold 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100n
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-1000-w-80-plus-gold-certified-power-supplies-black-pa-0g2bb-us/p/N82E16817116052?Item=N82E16817116052&SoldByNewegg=1'),
('psu750r','Rosewill VMG750 750W','Apex product: https://bfung2.github.io/#/products?product=psu750r
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-750-w-80-plus-gold-certified-power-supply-vmg750/p/N82E16817182467?Item=N82E16817182467&SoldByNewegg=1'),
('psu750p','ASRock Phantom Gaming PG-750G 750W','Apex product: https://bfung2.github.io/#/products?product=psu750p
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-750-w-cybenetics-gold-power-supply-black-pg-750g/p/N82E16817955007?Item=N82E16817955007&SoldByNewegg=1'),
('psucl750b','ASRock Challenger CL-750B 750W','Apex product: https://bfung2.github.io/#/products?product=psucl750b
Product link: https://www.newegg.com/asrock-atx-750-w-80-plus-bronze-certified-power-supplies-cl-750b/p/N82E16817955017?Item=N82E16817955017&SoldByNewegg=1'),
('psu100w','ASRock Steel Legend SL-1000GW 1000W White','Apex product: https://bfung2.github.io/#/products?product=psu100w
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1000-w-80-plus-gold-certified-power-supply-white-sl-1000gw/p/N82E16817955012?Item=N82E16817955012&SoldByNewegg=1'),
('psu100sl','ASRock Steel Legend SL-1000G 1000W','Apex product: https://bfung2.github.io/#/products?product=psu100sl
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-1000-w-cybenetics-titanium-power-supply-black-sl-1000g/p/N82E16817955008?Item=N82E16817955008&SoldByNewegg=1'),
('psu1200p','ASRock Steel Legend SL-1200P 1200W','Apex product: https://bfung2.github.io/#/products?product=psu1200p
Product link: https://www.newegg.com/asrock-atx-3-1-1200-w-80-plus-platinum-certified-power-supply-black-sl-1200p/p/N82E16817955030?Item=N82E16817955030&SoldByNewegg=1'),
('psu1000s','Corsair SF1000 1000W SFX','Apex product: https://bfung2.github.io/#/products?product=psu1000s
Product link: https://www.newegg.com/corsair-sf-series-sfx-1000-w-80-plus-platinum-certified-power-supply-cp-9020257-na/p/N82E16817139332?Item=N82E16817139332&SoldByNewegg=1'),
('psu1050m','MONTECH Century II 1050W','Apex product: https://bfung2.github.io/#/products?product=psu1050m
Product link: https://www.newegg.com/montech-atx-1050-w-80-plus-gold-certified-power-supply-silver-century-ii-1050/p/N82E16817959009?Item=N82E16817959009&SoldByNewegg=1'),
('psu1100ss','SilverStone SST-ST1100-TI 1100W','Apex product: https://bfung2.github.io/#/products?product=psu1100ss
Product link: https://www.newegg.com/silverstone-atx12v-1100-w-80-plus-titanium-certified-power-supply-sst-st1100-ti/p/N82E16817256194?Item=N82E16817256194&SoldByNewegg=1'),
('psu850nw','NZXT C850 Gold 850W White','Apex product: https://bfung2.github.io/#/products?product=psu850nw
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-850-w-80-plus-gold-certified-power-supplies-white-pa-8g2bw-us/p/N82E16817116051?Item=N82E16817116051&SoldByNewegg=1'),
('psu850cm','Cooler Master V850 SFX Gold 850W','Apex product: https://bfung2.github.io/#/products?product=psu850cm
Product link: https://www.newegg.com/cooler-master-atx3-0-sfx-12v-ver-3-42-850-w-80-plus-gold-certified-90-typical-load-power-supply-black-mpy-8501-sfhagv-3u1/p/N82E16817171238?Item=N82E16817171238&SoldByNewegg=1'),
('psu850as','ASRock Phantom Gaming PG-850PSF 850W SFX','Apex product: https://bfung2.github.io/#/products?product=psu850as
Product link: https://www.newegg.com/asrock-atx-3-1-850-w-80-plus-platinum-certified-power-supply-black-pg-850psf/p/N82E16817955029?Item=N82E16817955029&SoldByNewegg=1'),
('psu1000tt','Thermaltake Toughpower PT 1000W','Apex product: https://bfung2.github.io/#/products?product=psu1000tt
Product link: https://www.newegg.com/p/N82E16817153483?Item=N82E16817153483&SoldByNewegg=1'),
('psu850tt','Thermaltake Toughpower SFX 850W Platinum','Apex product: https://bfung2.github.io/#/products?product=psu850tt
Product link: https://www.newegg.com/thermaltake-toughpower-sfx-atx-12v-3-1-850-w-80-plus-platinum-certified-power-supply-black-sfx-0850ah8flp/p/N82E16817153466?Item=N82E16817153466&SoldByNewegg=1'),
('psuvsb650','Rosewill VSB650 650W','Apex product: https://bfung2.github.io/#/products?product=psuvsb650
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-650-w-80-plus-bronze-certified-power-supply-vsb650/p/N82E16817182464?Item=N82E16817182464&SoldByNewegg=1'),
('psuvsb750','Rosewill VSB750 750W','Apex product: https://bfung2.github.io/#/products?product=psuvsb750
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-750-w-80-plus-bronze-certified-power-supply-vsb750/p/N82E16817182465?Item=N82E16817182465&SoldByNewegg=1'),
('psuvsb850','Rosewill VSB850 850W','Apex product: https://bfung2.github.io/#/products?product=psuvsb850
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-850-w-80-plus-bronze-certified-power-supply-vsb850/p/N82E16817182466?Item=N82E16817182466&SoldByNewegg=1'),
('psubm3650','Thermaltake Smart BM3 650W','Apex product: https://bfung2.github.io/#/products?product=psubm3650
Product link: https://www.newegg.com/thermaltake-atx-3-0-compatible-650-w-meet-80-plus-bronze-at-115vac-input-power-supply-spd-650ah2clb/p/N82E16817153456?Item=N82E16817153456&SoldByNewegg=1'),
('psucor850shift','CORSAIR RM850x Shift 850W','Apex product: https://bfung2.github.io/#/products?product=psucor850shift
Product link: https://www.newegg.com/corsair-rm850x-shift-atx-atx-3-0-compatible-850-w-80-plus-gold-certified-power-supply-black/p/N82E16817139351?Item=N82E16817139351&SoldByNewegg=1'),
('psucor1000shift','CORSAIR RM1000x Shift 1000W','Apex product: https://bfung2.github.io/#/products?product=psucor1000shift
Product link: https://www.newegg.com/p/N82E16817139350?Item=N82E16817139350&SoldByNewegg=1'),
('psuasrock850sl','ASRock Steel Legend SL-850G 850W','Apex product: https://bfung2.github.io/#/products?product=psuasrock850sl
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-850-w-cybenetics-titanium-power-supply-black-sl-850g/p/N82E16817955009?Item=N82E16817955009&SoldByNewegg=1'),
('psuasrock750pro','ASRock PRO-750G 750W','Apex product: https://bfung2.github.io/#/products?product=psuasrock750pro
Product link: https://www.newegg.com/asrock-pro-series-atx-3-1-compatible-750-w-80-plus-gold-certified-power-supply-black-pro-750g/p/N82E16817955023?Item=N82E16817955023&SoldByNewegg=1'),
('psuasrock750sl','ASRock Steel Legend SL-750G 750W','Apex product: https://bfung2.github.io/#/products?product=psuasrock750sl
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-750-w-80-plus-gold-certified-power-supply-black-sl-750g/p/N82E16817955010?Item=N82E16817955010&SoldByNewegg=1'),
('psuasrockpro1000','ASRock PRO-1000G 1000W','Apex product: https://bfung2.github.io/#/products?product=psuasrockpro1000
Product link: https://www.newegg.com/asrock-atx-3-1-non-modular-1000-w-80-plus-gold-certified-power-supply-pro-1000g/p/N82E16817955037?Item=N82E16817955037'),
('psuasrock850gw','ASRock Steel Legend SL-850GW 850W White','Apex product: https://bfung2.github.io/#/products?product=psuasrock850gw
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-850-w-80-plus-gold-certified-power-supply-white-sl-850w/p/N82E16817955013?Item=N82E16817955013'),
('psumsi850gl','MSI MAG A850GL PCIE5 850W','Apex product: https://bfung2.github.io/#/products?product=psumsi850gl
Product link: https://www.newegg.com/msi-atx12v-850-w-80-plus-gold-certified-power-supplies-black-mag-a850gl-pcie5/p/N82E16817701021?Item=N82E16817701021'),
('psucorrm1000x','CORSAIR RM1000x 1000W','Apex product: https://bfung2.github.io/#/products?product=psucorrm1000x
Product link: https://www.newegg.com/corsair-rmx-series-atx-3-1-compatible-1000-w-cybenetics-gold-power-supply-black-rm1000x/p/N82E16817139334'),
('psucorrm850x','CORSAIR RM850x 850W','Apex product: https://bfung2.github.io/#/products?product=psucorrm850x
Product link: https://www.newegg.com/corsair-rmx-series-atx-3-1-compatible-850-w-cybenetics-gold-power-supply-black-rm850x/p/N82E16817139333'),
('psuasrockcl750g','ASRock Challenger CL-750G 750W','Apex product: https://bfung2.github.io/#/products?product=psuasrockcl750g
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-ready-750-w-80-plus-gold-certified-power-supply-black-cl-750g/p/N82E16817955015'),
('psusf1200zillion','Super Flower Zillion FP 1200W','Apex product: https://bfung2.github.io/#/products?product=psusf1200zillion
Product link: https://www.newegg.com/super-flower-atx-3-1-1200-w-cybenetics-platinum-power-supplies-black/p/1HU-024C-000C1'),
('psusf850zillion','Super Flower Zillion FP 850W','Apex product: https://bfung2.github.io/#/products?product=psusf850zillion
Product link: https://www.newegg.com/super-flower-atx-3-1-850w-cybenetics-platinum-power-supplies-black/p/1HU-024C-000C0'),
('psuasrockcl550b','ASRock Challenger CL-550B 550W','Apex product: https://bfung2.github.io/#/products?product=psuasrockcl550b
Product link: https://www.newegg.com/asrock-atx-550-w-80-plus-bronze-certified-power-supplies-black-cl-550b/p/N82E16817955019'),
('psuseasonicgx1000','SeaSonic FOCUS GX-1000 ATX 3 (2024) 1000W','Apex product: https://bfung2.github.io/#/products?product=psuseasonicgx1000
Product link: https://www.newegg.com/seasonic-usa-focus-gx-atx-3-atx-3-1-1000-w-80-plus-gold-certified-power-supplies-gx-1000/p/N82E16817151270'),
('psuasusprime750','ASUS Prime AP-750G 750W','Apex product: https://bfung2.github.io/#/products?product=psuasusprime750
Product link: https://www.newegg.com/asus-atx12v-750-w-80-plus-gold-certified-power-supplies-ap-750g/p/N82E16817320045'),
('psumontechbeta2650','MONTECH BETA 2 650W','Apex product: https://bfung2.github.io/#/products?product=psumontechbeta2650
Product link: https://www.newegg.com/montech-atx-650-w-80-plus-bronze-certified-power-supplies-beta-2-650w/p/N82E16817959016'),
('psumsgamdias1000','Gamdias HELIOS P2-1000G 1000W','Apex product: https://bfung2.github.io/#/products?product=psumsgamdias1000
Product link: https://www.newegg.com/gamdias-technology-atx-3-1-compatible-1000-w-80-plus-gold-certified-power-supply-black-helios-p2-1000g/p/N82E16817311015'),
('psucorsairhx1000i','CORSAIR HX1000i 1000W (2023)','Apex product: https://bfung2.github.io/#/products?product=psucorsairhx1000i
Product link: https://www.newegg.com/corsair-hxi-series-atx-3-0-compatible-1000-w-80-plus-platinum-certified-power-supply-hx1000i-2023/p/N82E16817139313'),
('psuttgt850','Thermaltake Toughpower GT 850W','Apex product: https://bfung2.github.io/#/products?product=psuttgt850
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-850-w-meet-80-plus-gold-at-115vac-input-power-supplies-black-ps-tpt-0850fnfagu-3/p/1HU-0014-006W8'),
('psumsi650bn3','MSI MAG A650BN PCIE5 III 650W','Apex product: https://bfung2.github.io/#/products?product=psumsi650bn3
Product link: https://www.newegg.com/p/N82E16817701041'),
('psuasusloki750','ASUS ROG Loki SFX-L 750W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasusloki750
Product link: https://www.newegg.com/asus-rog-loki-atx-3-0-compatible-atx12v-750-w-80-plus-platinum-certified-power-supply-rog-loki-750p-sfx-l-gaming/p/N82E16817320037'),
('psumontech550','MONTECH Century II 550W','Apex product: https://bfung2.github.io/#/products?product=psumontech550
Product link: https://www.newegg.com/montech-atx-3-1-550-w-80-plus-gold-certified-power-supplies-silver-century-ii-550w/p/N82E16817959019'),
('psubequietpz2750','be quiet! Power Zone 2 750W','Apex product: https://bfung2.github.io/#/products?product=psubequietpz2750
Product link: https://www.newegg.com/be-quiet-power-zone-2-atx12v-3-1-750-w-80-plus-platinum-and-cybenetics-platinum-efficiency-power-supplies-black/p/N82E16817222041'),
('psuasusrogstrix1000p','ASUS ROG Strix 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasusrogstrix1000p
Product link: https://www.newegg.com/asus-atx-3-1-atx12v-1000-w-80-plus-platinum-certified-58-power-supply-black-rog-strix-1000p-gaming-e/p/N82E16817320067'),
('psuasusrogstrix1200p','ASUS ROG Strix 1200W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasusrogstrix1200p
Product link: https://www.newegg.com/asus-atx-3-1-atx12v-1200-w-80-plus-platinum-certified-58-power-supply-black-rog-strix-1200p-gaming-e/p/N82E16817320069'),
('psurosewillcmg1200','Rosewill CMG5 1200W','Apex product: https://bfung2.github.io/#/products?product=psurosewillcmg1200
Product link: https://www.newegg.com/rosewill-atx-3-0-compatible-atx-3-1-compatible-1200-w-80-plus-gold-certified-power-supplies-cmg1200g5/p/N82E16817182454'),
('psuttgf1750','Thermaltake Toughpower GF1 (2024) 750W','Apex product: https://bfung2.github.io/#/products?product=psuttgf1750
Product link: https://www.newegg.com/thermaltake-toughpower-gf1-2024-series-atx-12v-v2-4-eps-v2-92-750-w-80-plus-gold-certified-power-supplies-ps-tpd-0750fnfagu-p/p/N82E16817153461'),
('psumsi850gls','MSI MAG A850GLS PCIE5 850W','Apex product: https://bfung2.github.io/#/products?product=psumsi850gls
Product link: https://www.newegg.com/msi-atx12v-850-w-80-plus-gold-certified-power-supply-black-mag-a850gls-pcie5/p/N82E16817701033'),
('psuttpt1200','Thermaltake Toughpower PT 1200W','Apex product: https://bfung2.github.io/#/products?product=psuttpt1200
Product link: https://www.newegg.com/p/N82E16817153482'),
('psuasrockpro750b','ASRock PRO-750B 750W','Apex product: https://bfung2.github.io/#/products?product=psuasrockpro750b
Product link: https://www.newegg.com/asrock-pro-series-atx-3-1-compatible-750-w-80-plus-bronze-certified-power-supply-black-pro-750b/p/N82E16817955026'),
('psuttpsfx750','Thermaltake Toughpower SFX 750W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuttpsfx750
Product link: https://www.newegg.com/thermaltake-toughpower-sfx-atx-12v-3-1-750-w-80-plus-platinum-certified-power-supply-black-sfx-0750ah8flp/p/N82E16817153465'),
('psunzxt1200g','NZXT C1200 Gold 1200W','Apex product: https://bfung2.github.io/#/products?product=psunzxt1200g
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-1200-w-80-plus-gold-certified-power-supplies-black-pa-2g2bb-us/p/N82E16817116054'),
('psunzxtc850core','NZXT C850 Gold Core 850W','Apex product: https://bfung2.github.io/#/products?product=psunzxtc850core
Product link: https://www.newegg.com/nzxt-c-series-gold-core-atx-3-1-compatible-eps12v-850-w-80-plus-gold-certified-power-supply-black-c850-gold-core/p/N82E16817116057'),
('psuphanteksgh1000','Phanteks AMP GH 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuphanteksgh1000
Product link: https://www.newegg.com/phanteks-intel-atx-3-1-pcie-gen5-1-750-w-80-plus-platinum-certified-power-supply-white-ph-p750gh-bk01/p/N82E16817987029'),
('psucorsaircx750m25','CORSAIR CX750M (2025) 750W','Apex product: https://bfung2.github.io/#/products?product=psucorsaircx750m25
Product link: https://www.newegg.com/p/N82E16817139345'),
('psuasrockcl850g','ASRock Challenger CL-850G 850W','Apex product: https://bfung2.github.io/#/products?product=psuasrockcl850g
Product link: https://www.newegg.com/asrock-atx3-1-pcie5-1-ready-850-w-80-plus-gold-certified-power-supply-black-cl-850g/p/N82E16817955014'),
('psumsi1000glwhite','MSI MAG A1000GL PCIE5 1000W White','Apex product: https://bfung2.github.io/#/products?product=psumsi1000glwhite
Product link: https://www.newegg.com/msi-atx12v-1000-w-80-plus-gold-certified-power-supply-mag-a1000gl-pcie5-white/p/N82E16817701039'),
('psucorsaircx650','CORSAIR CX650 650W','Apex product: https://bfung2.github.io/#/products?product=psucorsaircx650
Product link: https://www.newegg.com/corsair-cx-series-atx-650-w-80-plus-bronze-certified-power-supplies-cx650/p/N82E16817139322'),
('psuseasonicgx650','SeaSonic CORE GX-650 ATX3 650W','Apex product: https://bfung2.github.io/#/products?product=psuseasonicgx650
Product link: https://www.newegg.com/seasonic-usa-core-atx-3-atx-3-1-650-w-80-plus-gold-certified-power-supplies-black-gx-650/p/N82E16817151280'),
('psunzxtc1000core','NZXT C1000 Gold Core 1000W','Apex product: https://bfung2.github.io/#/products?product=psunzxtc1000core
Product link: https://www.newegg.com/nzxt-c-series-gold-core-atx-3-1-compatible-eps12v-1000-w-80-plus-gold-certified-power-supply-black-c1000-gold-core/p/N82E16817116058'),
('psuasrocksl850p','ASRock Steel Legend SL-850P 850W','Apex product: https://bfung2.github.io/#/products?product=psuasrocksl850p
Product link: https://www.newegg.com/asrock-atx-3-1-1000-w-80-plus-platinum-certified-power-supply-black-pg-1000psf/p/N82E16817955032'),
('psunzxt1000atx31','NZXT C1000 Gold 1000W ATX 3.1','Apex product: https://bfung2.github.io/#/products?product=psunzxt1000atx31
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-1000-w-80-plus-gold-certified-power-supplies-black-pa-0g2bb-us/p/N82E16817116052'),
('psulianlisx1200p','Lian Li SX1200P Platinum 1200W','Apex product: https://bfung2.github.io/#/products?product=psulianlisx1200p
Product link: https://www.newegg.com/p/1HU-01PP-00041'),
('psuasrocksl1000p','ASRock Steel Legend SL-1000P 1000W','Apex product: https://bfung2.github.io/#/products?product=psuasrocksl1000p
Product link: https://www.newegg.com/asrock-atx-3-1-1000-w-80-plus-platinum-certified-power-supply-black-pg-1000psf/p/N82E16817955031'),
('psuasusrogstrix1000white','ASUS ROG Strix 1000W Platinum White','Apex product: https://bfung2.github.io/#/products?product=psuasusrogstrix1000white
Product link: https://www.newegg.com/asus-atx-3-1-atx12v-1000-w-80-plus-platinum-certified-58-power-supply-rog-strix-1000p-gaming-white-e/p/N82E16817320068'),
('psuphanteksgh750','Phanteks AMP GH 750W Gold','Apex product: https://bfung2.github.io/#/products?product=psuphanteksgh750
Product link: https://www.newegg.com/phanteks-intel-atx-3-1-pcie-gen5-1-750-w-80-plus-platinum-certified-power-supply-black-ph-p750gh-bk01/p/N82E16817987025'),
('psurosewillvnw650','Rosewill VNW650 650W','Apex product: https://bfung2.github.io/#/products?product=psurosewillvnw650
Product link: https://www.newegg.com/p/N82E16817182485'),
('psusamag650','SAMA G650 650W','Apex product: https://bfung2.github.io/#/products?product=psusamag650
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-650-w-80-plus-gold-certified-power-supplies-g650w-black/p/1HU-02S6-00065'),
('psusamag750','SAMA G750 750W','Apex product: https://bfung2.github.io/#/products?product=psusamag750
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-750-w-80-plus-gold-certified-power-supplies-g750w-black/p/1HU-02S6-00074'),
('psusamag850','SAMA G850 850W','Apex product: https://bfung2.github.io/#/products?product=psusamag850
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-850-w-80-plus-gold-certified-power-supplies-g850w-black/p/1HU-02S6-00071'),
('psuseasonicsakura1000','SeaSonic FOCUS GX-1000 SAKURA 1000W','Apex product: https://bfung2.github.io/#/products?product=psuseasonicsakura1000
Product link: https://www.newegg.com/p/N82E16817151284'),
('psuasusloki1000','ASUS ROG Loki SFX-L 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasusloki1000
Product link: https://www.newegg.com/asus-rog-loki-atx-12v-1000-w-80-plus-platinum-certified-power-supply-rog-loki-1000p-sfx-l-gaming/p/N82E16817320035'),
('psurosewillvit500','Rosewill VIT500 500W Flex ATX','Apex product: https://bfung2.github.io/#/products?product=psurosewillvit500
Product link: https://www.newegg.com/p/N82E16817182489'),
('psuasusprime850','ASUS Prime AP-850G 850W','Apex product: https://bfung2.github.io/#/products?product=psuasusprime850
Product link: https://www.newegg.com/asus-atx12v-850-w-80-plus-gold-certified-power-supplies-ap-850g/p/N82E16817320046'),
('psuttpsfx1000','Thermaltake Toughpower SFX 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuttpsfx1000
Product link: https://www.newegg.com/thermaltake-toughpower-sfx-atx-12v-3-1-1000-w-80-plus-platinum-certified-power-supply-black-sfx-1000ah8flp/p/N82E16817153467'),
('psubequietpro131600','be quiet! Dark Power PRO 13 1600W Titanium','Apex product: https://bfung2.github.io/#/products?product=psubequietpro131600
Product link: https://www.newegg.com/be-quiet-atx-3-0-compatible-1600-w-80-plus-titanium-certified-power-supplies-black/p/1HU-004H-000S8'),
('psubequietpro131300','be quiet! Dark Power PRO 13 1300W Titanium','Apex product: https://bfung2.github.io/#/products?product=psubequietpro131300
Product link: https://www.newegg.com/p/1HU-004H-000S7'),
('psuasrockpg1000psf','ASRock Phantom Gaming PG-1000PSF 1000W SFX','Apex product: https://bfung2.github.io/#/products?product=psuasrockpg1000psf
Product link: https://www.newegg.com/asrock-atx-3-1-1000-w-80-plus-platinum-certified-power-supply-black-pg-1000psf/p/N82E16817955028'),
('psumsi600dn2','MSI MAG A600DN II 600W','Apex product: https://bfung2.github.io/#/products?product=psumsi600dn2
Product link: https://www.newegg.com/p/N82E16817701046'),
('psuttgfa3850','Thermaltake Toughpower GF A3 850W','Apex product: https://bfung2.github.io/#/products?product=psuttgfa3850
Product link: https://www.newegg.com/thermaltake-toughpower-gf-a3-series-atx-atx-3-0-compatible-850-w-80-plus-gold-certified-power-supply-black-ps-tpd-0850fnfagu-l/p/N82E16817153449'),
('psurosewillvng650','Rosewill VNG650 650W','Apex product: https://bfung2.github.io/#/products?product=psurosewillvng650
Product link: https://www.newegg.com/rosewill-atx-3-1-compatible-650-w-80-plus-gold-certified-power-supply-vng650/p/N82E16817182471'),
('psumontechbeta2850','MONTECH BETA 2 850W','Apex product: https://bfung2.github.io/#/products?product=psumontechbeta2850
Product link: https://www.newegg.com/montech-atx-850-w-80-plus-bronze-certified-power-supplies-beta-2-850w/p/N82E16817959018'),
('psuasusrogthor1000','ASUS ROG Thor 1000W Platinum III','Apex product: https://bfung2.github.io/#/products?product=psuasusrogthor1000
Product link: https://www.newegg.com/p/N82E16817320057'),
('psusamag750white','SAMA G750 750W White','Apex product: https://bfung2.github.io/#/products?product=psusamag750white
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-750-w-80-plus-gold-certified-power-supplies-g750w-white/p/1HU-02S6-00067'),
('psuasustuf1000p','ASUS TUF Gaming 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasustuf1000p
Product link: https://www.newegg.com/asus-atx-3-1-atx12v-1000-w-80-plus-platinum-certified-power-supply-black-tuf-gaming-1000p/p/N82E16817320073'),
('psusilverstone450sfx','SilverStone SST-ST45SF-V3 450W SFX','Apex product: https://bfung2.github.io/#/products?product=psusilverstone450sfx
Product link: https://www.newegg.com/silverstone-sfx-series-450-w-80-plus-bronze-certified-power-supply-sst-st45sf-v3/p/N82E16817256176'),
('psuttgf3850','Thermaltake Toughpower GF3 850W','Apex product: https://bfung2.github.io/#/products?product=psuttgf3850
Product link: https://www.newegg.com/thermaltake-toughpower-gf3-series-atx-12v-v3-0-eps-v2-93-850-w-80-plus-gold-certified-power-supply-ps-tpd-0850fnfagu-4/p/N82E16817153438'),
('psusilverstone300sfx','SilverStone SST-ST30SF-V2 300W SFX','Apex product: https://bfung2.github.io/#/products?product=psusilverstone300sfx
Product link: https://www.newegg.com/silverstone-sfx-series-300-w-80-plus-bronze-certified-power-supply-sst-st30sf-v2/p/N82E16817256175'),
('psuttgt750','Thermaltake Toughpower GT 750W','Apex product: https://bfung2.github.io/#/products?product=psuttgt750
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-750-w-meet-80-plus-gold-at-115vac-input-power-supplies-black-ps-tpt-0750fnfagu-3/p/1HU-0014-006W7'),
('psunzxtc750core','NZXT C750 Gold Core 750W','Apex product: https://bfung2.github.io/#/products?product=psunzxtc750core
Product link: https://www.newegg.com/nzxt-c-series-gold-core-atx-3-1-compatible-eps12v-750-w-80-plus-gold-certified-power-supply-black-c750-gold-core/p/N82E16817116056'),
('psuasrockprom850g','ASRock PRO-M850G 850W','Apex product: https://bfung2.github.io/#/products?product=psuasrockprom850g
Product link: https://www.newegg.com/asrock-atx-3-1-850-w-80-plus-gold-certified-power-supplies-pro-m850g/p/N82E16817955034'),
('psuasrockprom1000g','ASRock PRO-M1000G 1000W','Apex product: https://bfung2.github.io/#/products?product=psuasrockprom1000g
Product link: https://www.newegg.com/asrock-atx-3-1-1000-w-80-plus-gold-certified-power-supplies-pro-m1000g/p/N82E16817955033'),
('psusilverstonesx750gold','SilverStone SX750 Gold 750W SFX','Apex product: https://bfung2.github.io/#/products?product=psusilverstonesx750gold
Product link: https://www.newegg.com/silverstone-technology-sfx-750-w-80-plus-gold-certified-power-supplies/p/1HU-00RG-00280'),
('psucmelite850gold','Cooler Master Elite Gold 850W','Apex product: https://bfung2.github.io/#/products?product=psucmelite850gold
Product link: https://www.newegg.com/cooler-master-atx-3-1-atx12v-850-w-80-plus-gold-certified-power-supplies-mpx-8505-afag-bus/p/N82E16817171251'),
('psusamag1000white','SAMA G1000 1000W White','Apex product: https://bfung2.github.io/#/products?product=psusamag1000white
Product link: https://www.newegg.com/sama-g-series-atx-3-1-compatible-1000-w-80-plus-gold-certified-power-supplies-g1000w-white/p/1HU-02S6-00070'),
('psunzxt850white','NZXT C850 850W White ATX 3.1','Apex product: https://bfung2.github.io/#/products?product=psunzxt850white
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-850-w-80-plus-gold-certified-power-supplies-white-pa-8g2bw-us/p/N82E16817116051'),
('psudarkflashdg750','darkFlash DG750 750W','Apex product: https://bfung2.github.io/#/products?product=psudarkflashdg750
Product link: https://www.newegg.com/darkflash-atx-3-1-ready-pcie-5-1-ready-750-w-80-plus-gold-certified-power-supplies-black-df-dg-750-bk/p/N82E16817950001'),
('psuttgf31000','Thermaltake Toughpower GF3 1000W','Apex product: https://bfung2.github.io/#/products?product=psuttgf31000
Product link: https://www.newegg.com/thermaltake-toughpower-gf3-series-atx-atx-3-0-compatible-1000-w-80-plus-gold-certified-power-supply-ps-tpd-1000fnfagu-4/p/N82E16817153437'),
('psusamap1000','SAMA P1000 1000W Platinum','Apex product: https://bfung2.github.io/#/products?product=psusamap1000
Product link: https://www.newegg.com/sama-p-series-atx-3-1-compatible-1000-w-80-plus-platinum-certified-power-supplies-p1000w-black/p/1HU-02S6-00064'),
('psusamap1200','SAMA P1200 1200W Platinum','Apex product: https://bfung2.github.io/#/products?product=psusamap1200
Product link: https://www.newegg.com/sama-p-series-atx-3-1-compatible-1200-w-80-plus-platinum-certified-power-supplies-p1200w-black/p/1HU-02S6-00072'),
('psuasrockprom750g','ASRock PRO-M750G 750W','Apex product: https://bfung2.github.io/#/products?product=psuasrockprom750g
Product link: https://www.newegg.com/asrock-atx-3-1-750-w-80-plus-gold-certified-power-supplies-pro-m750g/p/N82E16817955035'),
('psunzxt850black','NZXT C850 850W Black ATX 3.1','Apex product: https://bfung2.github.io/#/products?product=psunzxt850black
Product link: https://www.newegg.com/nzxt-atx12v-v3-1-eps12v-v2-92-850-w-80-plus-gold-certified-power-supplies-black-pa-8g2bb-us/p/N82E16817116050'),
('psuttgfa31200','Thermaltake Toughpower GF A3 1200W','Apex product: https://bfung2.github.io/#/products?product=psuttgfa31200
Product link: https://www.newegg.com/thermaltake-toughpower-gf-a3-series-atx-atx-3-0-compatible-1200-w-80-plus-gold-certified-power-supply-black-ps-tpd-1200fnfagu-l/p/N82E16817153447'),
('psuseasonicgx750','SeaSonic CORE GX-750 ATX 3 750W','Apex product: https://bfung2.github.io/#/products?product=psuseasonicgx750
Product link: https://www.newegg.com/seasonic-usa-core-atx-3-atx-3-1-750-w-80-plus-gold-certified-power-supplies-black-gx-750/p/N82E16817151281'),
('psusilverstonesx750p','SilverStone SX750 Platinum 750W SFX','Apex product: https://bfung2.github.io/#/products?product=psusilverstonesx750p
Product link: https://www.newegg.com/silverstone-technology-sfx-750-w-80-plus-platinum-certified-power-supplies/p/1HU-00RG-000Z2'),
('psurosewillvnw750','Rosewill VNW750 750W','Apex product: https://bfung2.github.io/#/products?product=psurosewillvnw750
Product link: https://www.newegg.com/p/N82E16817182486'),
('psusamap850','SAMA P850 850W Platinum','Apex product: https://bfung2.github.io/#/products?product=psusamap850
Product link: https://www.newegg.com/sama-p-series-atx-3-1-compatible-850-w-80-plus-platinum-certified-power-supplies-p850w-black/p/1HU-02S6-00073'),
('psusamap1000white','SAMA P1000 1000W Platinum White','Apex product: https://bfung2.github.io/#/products?product=psusamap1000white
Product link: https://www.newegg.com/sama-p-series-atx-3-1-compatible-1000-w-80-plus-platinum-certified-power-supplies-p1000w-white/p/1HU-02S6-00068'),
('psufractalIon3gold1000','Fractal Design Ion 3 Gold 1000W','Apex product: https://bfung2.github.io/#/products?product=psufractalIon3gold1000
Product link: https://www.newegg.com/fractal-design-atx12v-3-1-1000-w-80-plus-gold-certified-power-supply-black-fd-p-ia3g-100/p/N82E16817580036'),
('psuantecGSK850white','ANTEC GSK850 V2 White 750W','Apex product: https://bfung2.github.io/#/products?product=psuantecGSK850white
Product link: https://www.newegg.com/p/N82E16817371154'),
('psuttgt850snow','Thermaltake Toughpower GT 850W Snow','Apex product: https://bfung2.github.io/#/products?product=psuttgt850snow
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-850-w-meet-80-plus-gold-at-115vac-input-power-supply-snow-ps-tpt-0850fnfagu-w/p/N82E16817153473'),
('psuasusrogstrix750','ASUS ROG Strix 750W Gold','Apex product: https://bfung2.github.io/#/products?product=psuasusrogstrix750
Product link: https://www.newegg.com/asus-rog-strix-atx12v-750-w-80-plus-gold-certified-power-supply-rog-strix-750g/p/N82E16817320005'),
('psuttbm3750','Thermaltake Smart BM3 750W','Apex product: https://bfung2.github.io/#/products?product=psuttbm3750
Product link: https://www.newegg.com/thermaltake-atx-3-0-compatible-750-w-meet-80-plus-bronze-at-115vac-input-power-supply-spd-750ah2clb/p/N82E16817153455'),
('psuttDockpower1000','Thermaltake Dockpower FI 1000W Gold','Apex product: https://bfung2.github.io/#/products?product=psuttDockpower1000
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-1000-w-80-plus-gold-certified-power-supply-black-tdp-1000ah3fxg/p/N82E16817153495'),
('psufractalIon3gold1000white','Fractal Design Ion 3 Gold 1000W White','Apex product: https://bfung2.github.io/#/products?product=psufractalIon3gold1000white
Product link: https://www.newegg.com/fractal-design-atx12v-3-1-1000-w-80-plus-gold-certified-power-supply-white-fd-p-ia3g-101/p/N82E16817580037'),
('psuttbm3850','Thermaltake Smart BM3 850W','Apex product: https://bfung2.github.io/#/products?product=psuttbm3850
Product link: https://www.newegg.com/thermaltake-atx-3-0-compatible-850-w-meet-80-plus-bronze-at-115vac-input-power-supply-spd-850ah2clb/p/N82E16817153454'),
('psugigabyteud1000pg5r2','GIGABYTE GP-UD1000GM PG5 Rev2.0 1000W','Apex product: https://bfung2.github.io/#/products?product=psugigabyteud1000pg5r2
Product link: https://www.newegg.com/gigabyte-atx12v-1000-w-80-plus-gold-certified-power-supply-gp-ud1000gm-pg5-rev2-0/p/N82E16817233039'),
('psuttpt850','Thermaltake Toughpower PT 850W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuttpt850
Product link: https://www.newegg.com/p/N82E16817153484'),
('psuttDockpower750','Thermaltake Dockpower FI 750W Gold','Apex product: https://bfung2.github.io/#/products?product=psuttDockpower750
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-750-w-80-plus-gold-certified-power-supply-black-dockpower-fi-750w/p/N82E16817153497'),
('psusilverstonefx500','SilverStone FX500 500W Flex ATX','Apex product: https://bfung2.github.io/#/products?product=psusilverstonefx500
Product link: https://www.newegg.com/silverstone-technology-flex-atx-500-w-80-plus-gold-certified-power-supplies-black-fx500/p/1HU-00RG-000Y9'),
('psusilverstonesx700lpt','SilverStone SX700-LPT 700W SFX-L Platinum','Apex product: https://bfung2.github.io/#/products?product=psusilverstonesx700lpt
Product link: https://www.newegg.com/silverstone-sfx-l-700w-80-plus-platinum-certified-power-supply-sx700-lpt/p/N82E16817256166'),
('psuasustuf1000gevo','ASUS TUF Gaming 1000W Gold EVO','Apex product: https://bfung2.github.io/#/products?product=psuasustuf1000gevo
Product link: https://www.newegg.com/asus-atx-3-1-atx12v-1000-w-80-plus-gold-certified-power-supply-black-tuf-gaming-1000g-evo/p/N82E16817320074'),
('psuttf31650','Thermaltake Toughpower TF3 1650W Titanium','Apex product: https://bfung2.github.io/#/products?product=psuttf31650
Product link: https://www.newegg.com/thermaltake-atx-3-1-1650-w-meet-80-plus-titanium-at-115vac-input-power-supply-black-ps-tpd-1650fnfatu-1/p/N82E16817153485'),
('psuttDockpower1200','Thermaltake Dockpower FI 1200W Gold','Apex product: https://bfung2.github.io/#/products?product=psuttDockpower1200
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-1200-w-80-plus-gold-certified-power-supply-black-tdp-1200ah3fxg/p/N82E16817153494'),
('psuttDockpower850','Thermaltake Dockpower FI 850W Gold Snow','Apex product: https://bfung2.github.io/#/products?product=psuttDockpower850
Product link: https://www.newegg.com/thermaltake-atx-3-1-compatible-850-w-80-plus-gold-certified-power-supply-snow-dockpower-fi-850w/p/N82E16817153500'),
('psusilverstoneet550b','SilverStone Essential SST-ET550-B 550W','Apex product: https://bfung2.github.io/#/products?product=psusilverstoneet550b
Product link: https://www.newegg.com/silverstone-essential-series-atx12v-v2-4-550-w-80-plus-bronze-certified-power-supply-sst-et550-b/p/N82E16817256189'),
('psuttf31300','Thermaltake Toughpower TF3 1300W Titanium','Apex product: https://bfung2.github.io/#/products?product=psuttf31300
Product link: https://www.newegg.com/p/1HU-0014-006X8'),
('psugigabyteud1000pg5v2','GIGABYTE GP-UD1000GM PG5 V2 1000W','Apex product: https://bfung2.github.io/#/products?product=psugigabyteud1000pg5v2
Product link: https://www.newegg.com/p/N82E16817233053'),
('psugigabyteud1000pg5ice','GIGABYTE GP-UD1000GM PG5 ICE 1000W White','Apex product: https://bfung2.github.io/#/products?product=psugigabyteud1000pg5ice
Product link: https://www.newegg.com/p/N82E16817233052'),
('psusilverstonehela850r','SilverStone HELA 850R Platinum 850W','Apex product: https://bfung2.github.io/#/products?product=psusilverstonehela850r
Product link: https://www.newegg.com/p/2S7-05S9-00095'),
('psusilverstoneda750r','SilverStone DA750R-GMA 750W Gold','Apex product: https://bfung2.github.io/#/products?product=psusilverstoneda750r
Product link: https://www.newegg.com/silverstone-atx-3-0-compatible-750-w-80-plus-gold-certified-power-supply-black-da750r-gma/p/N82E16817256223'),
('psusilverstoneextreme850r','SilverStone Extreme 850R Platinum 850W SFX','Apex product: https://bfung2.github.io/#/products?product=psusilverstoneextreme850r
Product link: https://www.newegg.com/silverstone-technology-sfx12v-850-w-cybenetics-platinum-cases-black-extreme-850r-platinum/p/2AM-006F-001E1'),
('psuasustuf1200p','ASUS TUF Gaming 1200W Platinum','Apex product: https://bfung2.github.io/#/products?product=psuasustuf1200p
Product link: https://www.newegg.com/asus-atx12v-1200-w-cybenetics-platinum-power-supply-black-tuf-gaming-1200p/p/N82E16817320071'),
('caseDiypcArgbN3White','DIYPC ARGB-N3-W White E-ATX Dual-Chamber Case','Apex product: https://bfung2.github.io/#/products?product=caseDiypcArgbN3White
Product link: https://www.newegg.com/diypc-e-atx-atx-case-steel-tempered-glass-cases-white-argb-n3-w/p/N82E16811353280?Item=N82E16811353280'),
('caseDiypcAtx08Wood','DIYPC DIY-ATX08-Wood ATX Mid-Tower Case','Apex product: https://bfung2.github.io/#/products?product=caseDiypcAtx08Wood
Product link: https://www.newegg.com/diypc-atx-mid-tower-steel-tempered-glass-cases-black-diy-atx08-wood/p/N82E16811353271?Item=N82E16811353271'),
('caseNzxtH6FlowBlack','NZXT H6 Flow Black Dual-Chamber Mid-Tower','Apex product: https://bfung2.github.io/#/products?product=caseNzxtH6FlowBlack
Product link: https://www.newegg.com/nzxt-mid-tower-sgcc-steel-ultra-clear-tempered-glass-dark-tinted-tempered-glass-computer-case-black-cc-h61fb-01/p/N82E16811146357?Item=N82E16811146357'),
('caseDiypcMatx06Wood','DIYPC DIY-mATX06-Wood Micro-ATX Mid-Tower','Apex product: https://bfung2.github.io/#/products?product=caseDiypcMatx06Wood
Product link: https://www.newegg.com/diypc-micro-atx-tower-steel-tempered-glass-case-black-diy-matx06-wood/p/N82E16811353273?Item=N82E16811353273'),
('caseFractalNorthXLDark','Fractal Design North XL Dark Tempered Glass Full Tower','Apex product: https://bfung2.github.io/#/products?product=caseFractalNorthXLDark
Product link: https://www.newegg.com/fractal-design-atx-full-tower-north-steel-computer-cases-charcoal-black-fd-c-nor1x-02/p/N82E16811352216?Item=N82E16811352216'),
('caseDiypcVanguardF1','DIYPC Vanguard-F1-BK ATX Full-Tower Gaming Case','Apex product: https://bfung2.github.io/#/products?product=caseDiypcVanguardF1
Product link: https://www.newegg.com/diypc-atx-full-tower-steel-tempered-glass-cases-black-vanguard-f1-bk/p/N82E16811353267?Item=N82E16811353267'),
('caseNzxtH6FlowWhite','NZXT H6 Flow White Dual-Chamber Mid-Tower','Apex product: https://bfung2.github.io/#/products?product=caseNzxtH6FlowWhite
Product link: https://www.newegg.com/nzxt-mid-tower-sgcc-steel-ultra-clear-tempered-glass-computer-case-white-cc-h61fw-01/p/N82E16811146356?Item=N82E16811146356'),
('caseFractalNorthXLMesh','Fractal Design North XL Mesh Full Tower','Apex product: https://bfung2.github.io/#/products?product=caseFractalNorthXLMesh
Product link: https://www.newegg.com/fractal-design-atx-full-tower-north-steel-computer-cases-charcoal-black-fd-c-nor1x-01/p/N82E16811352215?Item=N82E16811352215'),
('caseDiypcIdx6','DIYPC IDX6-ATX-ARGB Tempered-Glass ATX Case','Apex product: https://bfung2.github.io/#/products?product=caseDiypcIdx6'),
('caseDiypcG18Wood','DIYPC DIY-G18-WD ATX Mid-Tower Wood-Front Case','Apex product: https://bfung2.github.io/#/products?product=caseDiypcG18Wood
Product link: https://www.newegg.com/diypc-atx-mid-tower-steel-tempered-glass-case-black-diy-g18-wd/p/N82E16811353276?Item=N82E16811353276'),
('caseLianLiLancool217','Lian Li LANCOOL 217 Walnut ATX Mid-Tower','Apex product: https://bfung2.github.io/#/products?product=caseLianLiLancool217
Product link: https://www.newegg.com/lian-li-atx-mid-tower-steel-case-fans-black/p/1YF-005G-000M9?Item=1YF-005G-000M9'),
('ramcorsair32d5cl36','CORSAIR Vengeance 32GB DDR5-6000 CL36','Apex product: https://bfung2.github.io/#/products?product=ramcorsair32d5cl36
Product link: https://www.newegg.com/corsair-vengeance-32gb-ddr5-6000-cas-latency-cl36-desktop-memory-gray/p/N82E16820982114'),
('ramgskillflarex532','G.SKILL Flare X5 32GB DDR5-6000 CL36','Apex product: https://bfung2.github.io/#/products?product=ramgskillflarex532
Product link: https://www.newegg.com/g-skill-flare-x5-32gb-ddr5-6000-cas-latency-cl36-desktop-memory-black/p/N82E16820374419'),
('ramgskilltz5neo32','G.SKILL Trident Z5 Neo RGB 32GB DDR5-6000 CL36','Apex product: https://bfung2.github.io/#/products?product=ramgskilltz5neo32
Product link: https://www.newegg.com/g-skill-trident-z5-neo-rgb-series-32gb-ddr5-6000-cas-latency-cl36-desktop-memory-black/p/N82E16820374429'),
('ramcrucialpro32d4','Crucial Pro 32GB DDR4-3200 CL22','Apex product: https://bfung2.github.io/#/products?product=ramcrucialpro32d4
Product link: https://www.newegg.com/crucial-pro-32gb-ddr4-3200-cas-latency-cl22-desktop-memory-black/p/N82E16820156326'),
('casePhanteksEnthooProTG','Phanteks Enthoo Pro TG ATX Full-Tower Case','Apex product: https://bfung2.github.io/#/products?product=casePhanteksEnthooProTG
Product link: https://www.newegg.com/phanteks-atx-full-tower-enthoo-pro-brushed-plastic-steel-chassis-tempered-glass-window-computer-case-black-ph-es614ptg-bk/p/N82E16811854069'),
('caseAsusPrimeAP201Black','ASUS Prime AP201 Micro-ATX Mesh Case Black','Apex product: https://bfung2.github.io/#/products?product=caseAsusPrimeAP201Black
Product link: https://www.newegg.com/micro-atx-tower-steel-plastic-cases-black-ap201-asus-prime-case-mesh/p/2AM-0033-000F0'),
('caseThermaltakeVersaH16ARGB','Thermaltake Versa H16 TG ARGB Micro-ATX Case Black','Apex product: https://bfung2.github.io/#/products?product=caseThermaltakeVersaH16ARGB
Product link: https://www.newegg.com/thermaltake-atx-mini-tower-cases/p/2AM-000X-00343'),
('caseNZXTH5Flow2024Black','NZXT H5 Flow 2024 ATX Mid-Tower Case Black','Apex product: https://bfung2.github.io/#/products?product=caseNZXTH5Flow2024Black
Product link: https://www.newegg.com/nzxt-atx-mid-tower-h5-flow-sgcc-steel-dark-tinted-tempered-glass-case-black-cc-h52fb-01/p/N82E16811146365'),
('caseAntecC8Black','Antec C8 Dual-Chamber E-ATX Full-Tower Case Black','Apex product: https://bfung2.github.io/#/products?product=caseAntecC8Black
Product link: https://www.newegg.com/antec-e-atx-full-tower-case-steel-plastic-tempered-glass-computer-case-black-c8/p/N82E16811129306'),
('caseAntecC8ARGBBlack','Antec C8 ARGB Dual-Chamber E-ATX Full-Tower Case Black','Apex product: https://bfung2.github.io/#/products?product=caseAntecC8ARGBBlack
Product link: https://www.newegg.com/antec-e-atx-full-tower-case-steel-plastic-glass-computer-case-black-c8-argb/p/N82E16811129310'),
('caseThermaltakeView600Black','Thermaltake View 600 TG Full-Tower Case Black','Apex product: https://bfung2.github.io/#/products?product=caseThermaltakeView600Black
Product link: https://www.newegg.com/p/N82E16811133572'),
('caseFractalTorrentRGBBlack','Fractal Design Torrent RGB ATX Mid-Tower Case Black','Apex product: https://bfung2.github.io/#/products?product=caseFractalTorrentRGBBlack
Product link: https://www.newegg.com/fractal-design-atx-mid-tower-torrent-steel-tempered-glass-computer-case-black-fd-c-tor1a-04/p/N82E16811352146'),
('caseFractalPopAirBlackTG','Fractal Design Pop Air Black TG ATX Mid-Tower Case','Apex product: https://bfung2.github.io/#/products?product=caseFractalPopAirBlackTG
Product link: https://www.newegg.com/fractal-design-atx-mid-tower-pop-air-steel-tempered-glass-computer-case-black-fd-c-poa1a-02/p/N82E16811352168'),
('caseRosewillHeliumNAS','Rosewill Helium NAS ATX Mid-Tower Case','Apex product: https://bfung2.github.io/#/products?product=caseRosewillHeliumNAS
Product link: https://www.newegg.com/rosewill-atx-mid-tower-steel-plastic-computer-case-black-helium-nas/p/N82E16811147365'),
('caseRosewillHeliumNASMax','Rosewill Helium NAS Max ATX Mid-Tower Case','Apex product: https://bfung2.github.io/#/products?product=caseRosewillHeliumNASMax
Product link: https://www.newegg.com/rosewill-atx-mid-tower-steel-plastic-tempered-glass-case-black-helium-nas-max/p/N82E16811147403'),
('ssdSamsung9100Pro1TB','Samsung 9100 PRO 1TB PCIe 5.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung9100Pro1TB
Product link: https://www.newegg.com/samsung-1tb-9100-pro-nvme-2-0/p/N82E16820147902'),
('ssdSamsung9100Pro2TB','Samsung 9100 PRO 2TB PCIe 5.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung9100Pro2TB
Product link: https://www.newegg.com/samsung-2tb-9100-pro-nvme-2-0/p/N82E16820147903'),
('ssdSamsung990Pro2TB','Samsung 990 PRO 2TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung990Pro2TB
Product link: https://www.newegg.com/samsung-2tb-990-pro-nvme-2-0/p/N82E16820147861'),
('ssdTeamGroupVulcanZ1TB','Team Group T-FORCE VULCAN Z 1TB SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdTeamGroupVulcanZ1TB
Product link: https://www.newegg.com/team-group-1tb-t-force-vulcan-z-sata/p/N82E16820331833'),
('ssdTeamGroupG50EVO4TB','Team Group T-FORCE G50 EVO 4TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdTeamGroupG50EVO4TB
Product link: https://www.newegg.com/team-group-4tb-t-force-nvme/p/N82E16820985406'),
('hddSeagateBarraCuda4TB','Seagate BarraCuda 4TB 5400RPM SATA HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateBarraCuda4TB
Product link: https://www.newegg.com/seagate-barracuda-st4000dm004-4tb-for-daily-computing-5400-rpm/p/N82E16822179299'),
('hddSeagateBarraCuda8TB','Seagate BarraCuda 8TB 5400RPM SATA HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateBarraCuda8TB
Product link: https://www.newegg.com/seagate-barracuda-ne-st8000dm004-8tb-hard-drive-for-daily-computing-5400-rpm/p/N82E16822183793'),
('ssdCrucialP3101TB','Crucial P310 1TB PCIe 4.0 NVMe SSD with Heatsink','Apex product: https://bfung2.github.io/#/products?product=ssdCrucialP3101TB
Product link: https://www.newegg.com/crucial-1tb-p310-nvme-2-0/p/N82E16820156416'),
('ssdWDBlackSN71001TB','WD_BLACK SN7100 1TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdWDBlackSN71001TB
Product link: https://www.newegg.com/western-digital-1tb-sn7100-nvme/p/N82E16820250276'),
('ssdTeamGroupG501TB','Team Group T-FORCE G50 1TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdTeamGroupG501TB
Product link: https://www.newegg.com/team-group-1tb-t-force-g50-nvme-1-4/p/N82E16820985133'),
('ssdTeamGroupNV50002TB','Team Group NV5000 2TB PCIe 4.0 NVMe SSD with Heatsink','Apex product: https://bfung2.github.io/#/products?product=ssdTeamGroupNV50002TB
Product link: https://www.newegg.com/team-group-2tb-nv5000-nvme/p/N82E16820985344'),
('ssdPNYCS9001TB','PNY CS900 1TB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdPNYCS9001TB
Product link: https://www.newegg.com/pny-1tb-cs900/p/N82E16820177078'),
('ssdPatriotP210512GB','Patriot P210 512GB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdPatriotP210512GB
Product link: https://www.newegg.com/patriot-512gb-p210/p/N82E16820225231'),
('ssdSamsung870EVO500GB','Samsung 870 EVO 500GB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung870EVO500GB
Product link: https://www.newegg.com/samsung-500gb-870-evo-series-sata/p/N82E16820147792'),
('ssdSamsung870EVO1TB','Samsung 870 EVO 1TB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung870EVO1TB
Product link: https://www.newegg.com/samsung-1tb-870-evo-series-sata/p/N82E16820147793'),
('ssdSamsung870EVO2TB','Samsung 870 EVO 2TB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung870EVO2TB
Product link: https://www.newegg.com/samsung-2tb-870-evo-series-sata/p/N82E16820147794'),
('ssdSamsung870EVO4TB','Samsung 870 EVO 4TB 2.5-inch SATA SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSamsung870EVO4TB
Product link: https://www.newegg.com/samsung-4tb-870-evo-series-sata/p/N82E16820147795'),
('hddSeagateIronWolf8TB','Seagate IronWolf 8TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateIronWolf8TB
Product link: https://www.newegg.com/seagate-ironwolf-ne-st8000vn004-8tb-7200-rpm-for-nas-systems/p/N82E16822184796'),
('hddSeagateIronWolf12TB','Seagate IronWolf 12TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateIronWolf12TB
Product link: https://www.newegg.com/seagate-ironwolf-st12000vn0008-12tb/p/1JW-001N-00027'),
('hddSynologyHAT33006TB','Synology Plus Series HAT3300 6TB 5400RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddSynologyHAT33006TB
Product link: https://www.newegg.com/synology-hat3300-6t-6tb/p/N82E16822108833'),
('hddSynologyHAT331012TB','Synology Plus Series HAT3310 12TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddSynologyHAT331012TB
Product link: https://www.newegg.com/synology-hat3310-12t-12tb-for-nas-systems-7200-rpm/p/N82E16822108843'),
('hddWDRedPlus4TB','Western Digital Red Plus 4TB 5400RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPlus4TB
Product link: https://www.newegg.com/western-digital-wd40efzz-4tb-5400-rpm/p/1Z4-0002-01R24'),
('hddWDRedPlus8TB','Western Digital Red Plus 8TB 5640RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPlus8TB
Product link: https://www.newegg.com/red-plus-wd80efpx-8tb/p/1Z4-0002-01NP7'),
('hddWDRedPlus10TB','Western Digital Red Plus 10TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPlus10TB
Product link: https://www.newegg.com/red-plus-wd100efgx-10tb-hard-drive-for-nas-systems-7200-rpm/p/N82E16822234588'),
('hddWDRedPlus12TB','Western Digital Red Plus 12TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPlus12TB
Product link: https://www.newegg.com/red-plus-wd120efgx-12tb-hard-drives-for-nas-systems-7200-rpm/p/N82E16822234589'),
('hddWDBlue2TB','Western Digital Blue 2TB 7200RPM SATA Desktop HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDBlue2TB
Product link: https://www.newegg.com/blue-wd20ezbx-2tb-computer-hardware-for-daily-computing-7200-rpm/p/N82E16822234469'),
('hddSeagateBarraCuda2TB','Seagate BarraCuda 2TB 7200RPM SATA Desktop HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateBarraCuda2TB
Product link: https://www.newegg.com/seagate-barracuda-st2000dm008-2tb-for-daily-computing-7200-rpm/p/N82E16822184773'),
('hddWDRedPro16TB','Western Digital Red Pro 16TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPro16TB
Product link: https://www.newegg.com/red-pro-wd161kfgx-16tb-enterprise-nas-hard-drives-7200-rpm/p/N82E16822234429'),
('hddToshibaN300Pro16TB','Toshiba N300 Pro 16TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddToshibaN300Pro16TB
Product link: https://www.newegg.com/toshiba-n300-nas-pro-16tb-for-nas-systems-7200-rpm/p/N82E16822149846'),
('hddWDRedPro12TB','Western Digital Red Pro 12TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPro12TB
Product link: https://www.newegg.com/red-pro-wd122kfbx-12tb-enterprise-nas-hard-drives-7200-rpm/p/N82E16822234584'),
('hddWDRedPlus2TB','Western Digital Red Plus 2TB 5400RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPlus2TB
Product link: https://www.newegg.com/red-plus-wd20efpx-2tb-hard-drive-for-nas-systems-5400-rpm/p/N82E16822234546'),
('hddWDBlack8TB','Western Digital Black 8TB 7200RPM SATA Performance HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDBlack8TB
Product link: https://www.newegg.com/black-wd8002fzbx-8tb/p/N82E16822234558'),
('hddWDGold8TB','Western Digital Gold 8TB 7200RPM SATA Enterprise HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDGold8TB
Product link: https://www.newegg.com/gold-wd8005fryz-8tb-enterprise-nas-hard-drives-7200-rpm/p/N82E16822234563'),
('hddWDBlue6TB','Western Digital Blue 6TB 5400RPM SATA Desktop HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDBlue6TB
Product link: https://www.newegg.com/blue-wd60ezax-6tb-for-daily-computing-5400-rpm/p/N82E16822234535'),
('hddSeagateSkyHawkAI32TB','Seagate SkyHawk AI 32TB 7200RPM SATA Surveillance HDD','Apex product: https://bfung2.github.io/#/products?product=hddSeagateSkyHawkAI32TB
Product link: https://www.newegg.com/seagate-skyhawk-ai-st32000ve000-32tb-for-video-surveillance-7200-rpm/p/N82E16822185120'),
('hddWDRedPro20TB','Western Digital Red Pro 20TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDRedPro20TB
Product link: https://www.newegg.com/western-digital-red-pro-wd202kfgx-20tb-enterprise-nas-hard-drives-7200-rpm/p/N82E16822234583'),
('hddSynologyHAT332020TB','Synology Plus Series HAT3320 20TB 7200RPM SATA NAS HDD','Apex product: https://bfung2.github.io/#/products?product=hddSynologyHAT332020TB
Product link: https://www.newegg.com/synology-hat3320-20t-20tb-for-daily-computing-7200-rpm/p/N82E16822108854'),
('hddWDGold24TB','Western Digital Gold 24TB 7200RPM SATA Enterprise HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDGold24TB
Product link: https://www.newegg.com/gold-wd241kryz-24tb/p/N82E16822234556'),
('hddWDBlue10TB','Western Digital Blue 10TB 7200RPM SATA Desktop HDD','Apex product: https://bfung2.github.io/#/products?product=hddWDBlue10TB
Product link: https://www.newegg.com/blue-wd100eagz-10tb-for-daily-computing-7200-rpm/p/N82E16822234590'),
('ssdKingSpecOneBoomX5001TB','KingSpec OneBoom X500 1TB PCIe 5.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdKingSpecOneBoomX5001TB
Product link: https://www.newegg.com/kingspec-1tb-oneboom-nvme-2-0/p/N82E16820971003'),
('ssdWDBlackSN850X1TB','WD_BLACK SN850X 1TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdWDBlackSN850X1TB
Product link: https://www.newegg.com/western-digital-1tb-black-sn850x-nvme/p/N82E16820250243'),
('ssdSanDiskOptimusGXPRO850X1TB','SanDisk Optimus GX PRO 850X 1TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSanDiskOptimusGXPRO850X1TB
Product link: https://www.newegg.com/sandisk-1tb-nvme-1-4/p/N82E16820173706'),
('ssdSanDiskOptimusGXPRO81001TB','SanDisk Optimus GX PRO 8100 1TB PCIe 5.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSanDiskOptimusGXPRO81001TB
Product link: https://www.newegg.com/sandisk-1tb-nvme-2-0/p/N82E16820173698'),
('ssdSanDiskOptimusGXPRO81002TB','SanDisk Optimus GX PRO 8100 2TB PCIe 5.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSanDiskOptimusGXPRO81002TB
Product link: https://www.newegg.com/sandisk-2tb-nvme-2-0/p/N82E16820173697'),
('ssdSanDiskOptimusGXPRO850X2TB','SanDisk Optimus GX PRO 850X 2TB PCIe 4.0 NVMe SSD','Apex product: https://bfung2.github.io/#/products?product=ssdSanDiskOptimusGXPRO850X2TB
Product link: https://www.newegg.com/sandisk-2tb-nvme-1-4/p/N82E16820173705'),
('coolerN82E16835984015','ASRock Rock 360 Digital Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984015
Product link: https://www.newegg.com/p/N82E16835984015?SoldByNewegg=1'),
('coolerN82E16835103376','Cooler Master MasterLiquid 360 Atmos Stealth','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103376
Product link: https://www.newegg.com/p/N82E16835103376?SoldByNewegg=1'),
('cooler13C-001F-00070','be quiet! Dark Rock Pro 5','Apex product: https://bfung2.github.io/#/products?product=cooler13C-001F-00070
Product link: https://www.newegg.com/p/13C-001F-00070?SoldByNewegg=1'),
('coolerN82E16835269007','be quiet! Dark Rock 5','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269007
Product link: https://www.newegg.com/p/N82E16835269007?SoldByNewegg=1'),
('coolerN82E16835269026','be quiet! Pure Rock Pro 3','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269026
Product link: https://www.newegg.com/p/N82E16835269026?SoldByNewegg=1'),
('coolerN82E16835269025','be quiet! Pure Rock 3 LX','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269025
Product link: https://www.newegg.com/p/N82E16835269025?SoldByNewegg=1'),
('cooler13C-001F-00071','Be Quiet Dark Rock Elite TDP 280W CPU Cooler Intel AMD BK037 - Black','Apex product: https://bfung2.github.io/#/products?product=cooler13C-001F-00071
Product link: https://www.newegg.com/p/13C-001F-00071?SoldByNewegg=1'),
('cooler13C-012U-00001','Sudokoo SK700V AM5 CPU Cooler 7 Heatpipes TDP 220W Fan - Black','Apex product: https://bfung2.github.io/#/products?product=cooler13C-012U-00001
Product link: https://www.newegg.com/p/13C-012U-00001?SoldByNewegg=1'),
('cooler13C-012U-00007','Sudokoo SK620V AM5 Air Cooler Dual Tower 120mm Fan Digital Display - Black','Apex product: https://bfung2.github.io/#/products?product=cooler13C-012U-00007
Product link: https://www.newegg.com/p/13C-012U-00007?SoldByNewegg=1'),
('coolerN82E16835103370','Cooler Master Hyper 212 PRO ARGB CPU Air Cooler 120mm Fan AM5 AM4 LGA1851 1700 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103370
Product link: https://www.newegg.com/p/N82E16835103370?SoldByNewegg=1'),
('coolerN82E16835103364','Cooler Master Hyper 212 Black CPU Air Cooler 120mm Fan AMD AM5/AM4 Intel LGA 1851/1700/1200','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103364
Product link: https://www.newegg.com/p/N82E16835103364?SoldByNewegg=1'),
('coolerN82E16835103385','Cooler Master Hyper 212 3DHP CPU Air Cooler ARGB - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103385
Product link: https://www.newegg.com/p/N82E16835103385?SoldByNewegg=1'),
('coolerN82E16835269028','be quiet Pure Rock Pro 3 LX 120mm CPU Cooler ARGB - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269028
Product link: https://www.newegg.com/p/N82E16835269028?SoldByNewegg=1'),
('coolerN82E16835269027','be quiet Pure Rock Pro 3 Black 120mm CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269027
Product link: https://www.newegg.com/p/N82E16835269027?SoldByNewegg=1'),
('coolerN82E16835099046','Gamdias GD-BOREAS M2-51D HW ARGB 120mm Hydraulic CPU Air Cooler - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099046
Product link: https://www.newegg.com/p/N82E16835099046?SoldByNewegg=1'),
('coolerN82E16835106747','Thermaltake TOUGHAIR 710 CPU Cooler Intel AMD Dual Tower Fan Copper Base - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106747
Product link: https://www.newegg.com/p/N82E16835106747?SoldByNewegg=1'),
('coolerN82E16835269024','be quiet Pure Rock 3 120mm CPU Cooler Intel 1851 1700 1200 1150 1151 1155 AMD AM5 AM4 BK039 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269024
Product link: https://www.newegg.com/p/N82E16835269024?SoldByNewegg=1'),
('coolerN82E16835103384','Cooler Master Hyper 212 3DHP CPU Air Cooler Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103384
Product link: https://www.newegg.com/p/N82E16835103384?SoldByNewegg=1'),
('coolerN82E16835106779','Thermaltake ASTRIA 600 ARGB CPU Cooler 6 Copper Heat Pipes 2x120mm Fans Intel/AMD 265W TDP White CL-P139-CA12SW-A','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106779
Product link: https://www.newegg.com/p/N82E16835106779?SoldByNewegg=1'),
('coolerN82E16835106668','Thermaltake TOUGHAIR 110 CPU Cooler 120mm Fan LGA 1700 Ready - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106668
Product link: https://www.newegg.com/p/N82E16835106668?SoldByNewegg=1'),
('coolerN82E16835988018','MONTECH NX600 ARGB Dual-Tower Air Cooler Intel LGA1700 1851 AMD AM5 Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835988018
Product link: https://www.newegg.com/p/N82E16835988018?SoldByNewegg=1'),
('coolerN82E16835846080','MSI MAG COREFROZR AA13 ARGB CPU Cooler LGA 1700/1851 AM5/AM4 120mm Fan Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846080
Product link: https://www.newegg.com/p/N82E16835846080?SoldByNewegg=1'),
('coolerN82E16835607021','SAMA X30L Air Cooler for AMD AM4/AM5 Intel LGA 1700/1150/1851 - Silver','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607021
Product link: https://www.newegg.com/p/N82E16835607021?SoldByNewegg=1'),
('coolerN82E16835106666','Thermaltake TOUGHAIR 510 CPU Cooler Dual 120mm Fan LGA 1700 Ready - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106666
Product link: https://www.newegg.com/p/N82E16835106666?SoldByNewegg=1'),
('coolerN82E16835607019','SAMA X40L CPU Air Cooler ARGB Cover AMD AM4/AM5 Intel LGA Thermal Grease - Silver','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607019
Product link: https://www.newegg.com/p/N82E16835607019?SoldByNewegg=1'),
('coolerN82E16835106734','Thermaltake TOUGHAIR 710 CPU Cooler LGA 1700 1200 AM5 AM4 - Gray','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106734
Product link: https://www.newegg.com/p/N82E16835106734?SoldByNewegg=1'),
('coolerN82E16835230011','StarTech 95mm Socket T 775 CPU Cooler Fan with Heatsink - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835230011
Product link: https://www.newegg.com/p/N82E16835230011?SoldByNewegg=1'),
('coolerN82E16835230047','StarTech 95mm CPU Cooler Fan LGA1156/1155 FAN1156PWM - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835230047
Product link: https://www.newegg.com/p/N82E16835230047?SoldByNewegg=1'),
('coolerN82E16835106690','Thermaltake TOUGHAIR 510 CPU Cooler Dual 120mm Fan CL-P075-AL12RG-A - Racing Green','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106690
Product link: https://www.newegg.com/p/N82E16835106690?SoldByNewegg=1'),
('coolerN82E16835220122','Silverstone AR09-115XP 60mm CPU Cooling - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835220122
Product link: https://www.newegg.com/p/N82E16835220122?SoldByNewegg=1'),
('coolerN82E16835220139','Silverstone AR11 CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835220139
Product link: https://www.newegg.com/p/N82E16835220139?SoldByNewegg=1'),
('coolerN82E16835985001','Silverstone XE04-SP3 4U Server CPU Cooler for AMD SP6 TR4 RL-XE04-SP3B','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835985001
Product link: https://www.newegg.com/p/N82E16835985001?SoldByNewegg=1'),
('coolerN82E16835220141','SilverStone KR01 80mm CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835220141
Product link: https://www.newegg.com/p/N82E16835220141?SoldByNewegg=1'),
('coolerN82E16835607016','SAMA A40E Air Cooler AMD AM4/AM5 Intel LGA 1700/1150/1151/1200/1851 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607016
Product link: https://www.newegg.com/p/N82E16835607016?SoldByNewegg=1'),
('coolerN82E16835220030','Silverstone NT07-AM2 CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835220030
Product link: https://www.newegg.com/p/N82E16835220030?SoldByNewegg=1'),
('coolerN82E16835220123','SILVERSTONE SST-AR09-115XS 60mm CPU Cooling 2 Ball - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835220123
Product link: https://www.newegg.com/p/N82E16835220123?SoldByNewegg=1'),
('coolerN82E16835132056','Bgears b-Cooler LGA115X CPU Cooler 90mm fan','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835132056
Product link: https://www.newegg.com/p/N82E16835132056?SoldByNewegg=1'),
('cooler13C-00CA-00010','Gamdias Boreas E2-410 CPU Cooler Support LGA 1700 1151 1150 1155 1156 1200 2011 2066 AM5 AM4 - Matte Black','Apex product: https://bfung2.github.io/#/products?product=cooler13C-00CA-00010
Product link: https://www.newegg.com/p/13C-00CA-00010?SoldByNewegg=1'),
('cooler13C-012U-00006','Sudokoo SK620 AM5 Air Cooler Dual Tower CPU Cooler with 120mm Fan - White','Apex product: https://bfung2.github.io/#/products?product=cooler13C-012U-00006
Product link: https://www.newegg.com/p/13C-012U-00006?SoldByNewegg=1'),
('cooler13C-0133-00002','TRYX TURRIS 620 CPU Air Cooler 5.0 IPS Display 280W TDP Dual Tower White Intel LGA1851 AMD AM5','Apex product: https://bfung2.github.io/#/products?product=cooler13C-0133-00002
Product link: https://www.newegg.com/p/13C-0133-00002?SoldByNewegg=1'),
('cooler13C-012U-00005','Sudokoo SK620 AM5 Air Cooler 6 Heatpipes Dual Tower 120mm Fan Quiet Mount - Black','Apex product: https://bfung2.github.io/#/products?product=cooler13C-012U-00005
Product link: https://www.newegg.com/p/13C-012U-00005?SoldByNewegg=1'),
('coolerN82E16835209123','Antec Luna 360 3x120mm Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209123
Product link: https://www.newegg.com/p/N82E16835209123?SoldByNewegg=1'),
('coolerN82E16835709322','Phanteks Glacier One 360S25 SE AIO Liquid CPU Cooler 360 mm - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709322
Product link: https://www.newegg.com/p/N82E16835709322?SoldByNewegg=1'),
('coolerN82E16835128042','AORUS WATERFORCE II 360 ICE CPU Cooler 360mm Radiator ARGB Fans Intel AMD - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835128042
Product link: https://www.newegg.com/p/N82E16835128042?SoldByNewegg=1'),
('coolerN82E16835209132','Antec Ultra 360 ARGB Liquid CPU Cooler 3x120mm 2600 RPM','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209132
Product link: https://www.newegg.com/p/N82E16835209132?SoldByNewegg=1'),
('coolerN82E16835209120','Antec Skeleton 240 ARGB AIO Liquid CPU Cooler 240 mm 2 x 120 mm','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209120
Product link: https://www.newegg.com/p/N82E16835209120?SoldByNewegg=1'),
('coolerN82E16835209134','Antec Skeleton Matrix 360 360mm Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209134
Product link: https://www.newegg.com/p/N82E16835209134?SoldByNewegg=1'),
('coolerN82E16835352104','Fractal Design Lumen S24 v2 AIO CPU Cooler Intel AMD RGB Aspect 12 x2 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352104
Product link: https://www.newegg.com/p/N82E16835352104?SoldByNewegg=1'),
('cooler2YM-00BJ-00001','Sudokoo R-PTS360-BKDSMP-GAS-1 - Black','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00001
Product link: https://www.newegg.com/p/2YM-00BJ-00001?SoldByNewegg=1'),
('coolerN82E16835269031','be quiet! SILENT LOOP 3 360mm All-in-One Water Cooling - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269031
Product link: https://www.newegg.com/p/N82E16835269031?SoldByNewegg=1'),
('coolerN82E16835099037','GAMDIAS CHIONE P5-240 Liquid CPU Cooler 240mm AIO customizable LCD rotatable pump black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099037
Product link: https://www.newegg.com/p/N82E16835099037?SoldByNewegg=1'),
('coolerN82E16835846069','MSI MAG Coreliquid A13 360 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846069
Product link: https://www.newegg.com/p/N82E16835846069?SoldByNewegg=1'),
('coolerN82E16835846067','MSI MAG Coreliquid A13 240 Black AIO ARGB Cooling 240mm Radiator Dual Fans','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846067
Product link: https://www.newegg.com/p/N82E16835846067?SoldByNewegg=1'),
('coolerN82E16835846063','MSI MAG CORELIQUID I360 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846063
Product link: https://www.newegg.com/p/N82E16835846063?SoldByNewegg=1'),
('coolerN82E16835984006','ASRock AIO PRO White 360 ARGB radiator fan','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984006
Product link: https://www.newegg.com/p/N82E16835984006?SoldByNewegg=1'),
('coolerN82E16835846051','MSI MAG CoreLiquid E360 AIO CPU Cooler 360mm Radiator Triple 120mm Fans LGA 1700 AM5 Compatible - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846051
Product link: https://www.newegg.com/p/N82E16835846051?SoldByNewegg=1'),
('coolerN82E16835181505','CORSAIR iCUE LINK TITAN II 360 RX Liquid CPU Cooler System Hub Included - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181505
Product link: https://www.newegg.com/p/N82E16835181505?SoldByNewegg=1'),
('coolerN82E16835846072','MSI MAG CORELIQUID A15 360','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846072
Product link: https://www.newegg.com/p/N82E16835846072?SoldByNewegg=1'),
('coolerN82E16835099039','GAMDIAS Aura GLV2 360mm AIO Liquid CPU Cooler 3 x 120mm Fans LGA 1851/1700 AM5/AM4 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099039
Product link: https://www.newegg.com/p/N82E16835099039?SoldByNewegg=1'),
('coolerN82E16835984012','ASRock AIO Pro White 240 ARGB radiator waterblock fan','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984012
Product link: https://www.newegg.com/p/N82E16835984012?SoldByNewegg=1'),
('coolerN82E16835181530','Corsair Nautilus II 360 360mm Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181530
Product link: https://www.newegg.com/p/N82E16835181530?SoldByNewegg=1'),
('coolerN82E16835146165','KRAKEN ELITE RGB 360 AIO COOLER IPS LCD & FANS for Intel & AMD Sockets - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146165
Product link: https://www.newegg.com/p/N82E16835146165?SoldByNewegg=1'),
('coolerN82E16835984017','ASRock Rock 360 ARGB 360mm AIO Liquid CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984017
Product link: https://www.newegg.com/p/N82E16835984017?SoldByNewegg=1'),
('coolerN82E16835181507','CORSAIR iCUE LINK TITAN II 360 RX LCD AIO Liquid CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181507
Product link: https://www.newegg.com/p/N82E16835181507?SoldByNewegg=1'),
('coolerN82E16835984002','ASRock AIO Challenger 360 Digital 27mm Radiator Black Version','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984002
Product link: https://www.newegg.com/p/N82E16835984002?SoldByNewegg=1'),
('coolerN82E16835846050','MSI MAG CoreLiquid E360 AIO CPU Cooler 360mm Radiator Triple 120mm Fans LGA 1700 AM5 Compatible - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846050
Product link: https://www.newegg.com/p/N82E16835846050?SoldByNewegg=1'),
('coolerN82E16835984018','ASRock 360 White AIO Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984018
Product link: https://www.newegg.com/p/N82E16835984018?SoldByNewegg=1'),
('coolerN82E16835099045','GAMDIAS CHIONE E4 360mm V2 AIO CPU Cooler - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099045
Product link: https://www.newegg.com/p/N82E16835099045?SoldByNewegg=1'),
('coolerN82E16835200146','Rosewill FROSTMAX 240mm AIO CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835200146
Product link: https://www.newegg.com/p/N82E16835200146?SoldByNewegg=1'),
('coolerN82E16835103391','Cooler Master Atmos II Stealth 240 AIO Liquid CPU Cooler 240mm','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103391
Product link: https://www.newegg.com/p/N82E16835103391?SoldByNewegg=1'),
('coolerN82E16835101132','ASUS ROG RYUO IV 360 AIO CPU Cooler 6.67-inch 2K Curved AMOLED Display','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101132
Product link: https://www.newegg.com/p/N82E16835101132?SoldByNewegg=1'),
('coolerN82E16835146163','KRAKEN ELITE 360 AIO COOLER IPS LCD & FANS for Intel LGA 1851 1700 1200 AM5 AM4 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146163
Product link: https://www.newegg.com/p/N82E16835146163?SoldByNewegg=1'),
('coolerN82E16835846068','MSI MAG Coreliquid A13 240 White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846068
Product link: https://www.newegg.com/p/N82E16835846068?SoldByNewegg=1'),
('coolerN82E16835101120','ASUS ROG RYUJIN III 360 ARGB Extreme White Edition AIO CPU Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101120
Product link: https://www.newegg.com/p/N82E16835101120?SoldByNewegg=1'),
('coolerN82E16835984019','ASRock Rock 240 ARGB 240mm AIO Liquid CPU Cooler Intel LGA 1851 1700 AMD AM5 AM4 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984019
Product link: https://www.newegg.com/p/N82E16835984019?SoldByNewegg=1'),
('coolerN82E16835846064','MSI MAG CORELIQUID I360 WHITE','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846064
Product link: https://www.newegg.com/p/N82E16835846064?SoldByNewegg=1'),
('coolerN82E16835103322','Cooler Master Elite Liquid 240 CPU AIO Cooler White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103322
Product link: https://www.newegg.com/p/N82E16835103322?SoldByNewegg=1'),
('coolerN82E16835984016','ASRock Rock White 360 Digital 360mm AIO Liquid CPU Cooler ARGB','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984016
Product link: https://www.newegg.com/p/N82E16835984016?SoldByNewegg=1'),
('coolerN82E16835209121','Antec Skeleton 360 Liquid CPU Cooler 360mm','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209121
Product link: https://www.newegg.com/p/N82E16835209121?SoldByNewegg=1'),
('coolerN82E16835709302','Phanteks Glacier One 360M25 G2 AIO Cooler for LGA 1700 1851 1200 115x AM4 AM5 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709302
Product link: https://www.newegg.com/p/N82E16835709302?SoldByNewegg=1'),
('coolerN82E16835980001','TRYX Holo 360mm AIO','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835980001
Product link: https://www.newegg.com/p/N82E16835980001?SoldByNewegg=1'),
('coolerN82E16835181527','Corsair Nautilus II 360 Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181527
Product link: https://www.newegg.com/p/N82E16835181527?SoldByNewegg=1'),
('coolerN82E16835103392','Cooler Master Atmos II Stealth 360mm AIO Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103392
Product link: https://www.newegg.com/p/N82E16835103392?SoldByNewegg=1'),
('coolerN82E16835181523','CORSAIR NAUTILUS II 360 RS ARGB Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181523
Product link: https://www.newegg.com/p/N82E16835181523?SoldByNewegg=1'),
('coolerN82E16835101143','ASUS ROG RYUO IV SLC 360 AIO CPU Liquid Cooler 360mm - ARGB','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101143
Product link: https://www.newegg.com/p/N82E16835101143?SoldByNewegg=1'),
('coolerN82E16835846085','MSI MPG CORELIQUID P22 360 360mm CPU Liquid Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846085
Product link: https://www.newegg.com/p/N82E16835846085?SoldByNewegg=1'),
('coolerN82E16835099041','GAMDIAS CHIONE P5 360mm CPU Cooler White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099041
Product link: https://www.newegg.com/p/N82E16835099041?SoldByNewegg=1'),
('coolerN82E16835269032','be quiet SILENT LOOP 3 420mm water cooling LGA 1851 1700 1200 1150 1151 1155 AM5 AM4 TR5 TR4 BW026 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269032
Product link: https://www.newegg.com/p/N82E16835269032?SoldByNewegg=1'),
('coolerN82E16835984020','ASRock Rock White 240mm ARGB AIO Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984020
Product link: https://www.newegg.com/p/N82E16835984020?SoldByNewegg=1'),
('coolerN82E16835103382','Cooler Master Atmos II 360 AIO CPU Liquid Cooler AMD AM5/AM4 Intel LGA 1851/1700 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103382
Product link: https://www.newegg.com/p/N82E16835103382?SoldByNewegg=1'),
('coolerN82E16835984021','ASRock Rock 240 Digital 240mm AIO Liquid CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984021
Product link: https://www.newegg.com/p/N82E16835984021?SoldByNewegg=1'),
('coolerN82E16835101114','ASUS ROG STRIX LC III 360 ARGB LCD AIO CPU Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101114
Product link: https://www.newegg.com/p/N82E16835101114?SoldByNewegg=1'),
('coolerN82E16835146170','NZXT Kraken Plus 360mm AIO Liquid Cooler with LCD Static Pressure Fans - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146170
Product link: https://www.newegg.com/p/N82E16835146170?SoldByNewegg=1'),
('coolerN82E16835709307','Phanteks PH-GO420D30_DBK02 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709307
Product link: https://www.newegg.com/p/N82E16835709307?SoldByNewegg=1'),
('coolerN82E16835181528','Corsair Nautilus II 360 RS Liquid CPU Cooler AM5 AM4 LGA 1851 1700','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181528
Product link: https://www.newegg.com/p/N82E16835181528?SoldByNewegg=1'),
('coolerN82E16835181508','CORSAIR iCUE LINK TITAN II 360 RX LCD AIO Liquid CPU Cooler White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181508
Product link: https://www.newegg.com/p/N82E16835181508?SoldByNewegg=1'),
('coolerN82E16835984022','ASRock Rock White 240 Digital 240mm AIO Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984022
Product link: https://www.newegg.com/p/N82E16835984022?SoldByNewegg=1'),
('coolerN82E16835269020','be quiet! Light Loop 360mm CPU Cooler 3x Light Wings LX 120mm ARGB BW022 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269020
Product link: https://www.newegg.com/p/N82E16835269020?SoldByNewegg=1'),
('coolerN82E16835984003','ASRock AIO Steel Legend 360 LCD 27mm radiator white','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984003
Product link: https://www.newegg.com/p/N82E16835984003?SoldByNewegg=1'),
('coolerN82E16835146159','KRAKEN ELITE RGB 240 AIO COOLER IPS LCD & STATIC FANS Intel AMD Socket - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146159
Product link: https://www.newegg.com/p/N82E16835146159?SoldByNewegg=1'),
('coolerN82E16835101108','ASUS ROG Strix LC III 360 ARGB CPU Liquid Cooler 120 mm ARGB Fans - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101108
Product link: https://www.newegg.com/p/N82E16835101108?SoldByNewegg=1'),
('coolerN82E16835181529','CORSAIR NAUTILUS II 240 RS 240mm AIO CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181529
Product link: https://www.newegg.com/p/N82E16835181529?SoldByNewegg=1'),
('coolerN82E16835128050','GIGABYTE GP-GIGABYTE GAMING 360 ICE','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835128050
Product link: https://www.newegg.com/p/N82E16835128050?SoldByNewegg=1'),
('coolerN82E16835352135','Fractal Design Radius 360 360mm AIO Liquid CPU Cooler 3x 120mm Fans - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352135
Product link: https://www.newegg.com/p/N82E16835352135?SoldByNewegg=1'),
('coolerN82E16835209131','Antec Ultra 240 ARGB Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209131
Product link: https://www.newegg.com/p/N82E16835209131?SoldByNewegg=1'),
('coolerN82E16835709305','Phanteks Glacier One 360D30 AIO CPU Cooler Evolv X2 3x D-RGB Fans Intel AMD Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709305
Product link: https://www.newegg.com/p/N82E16835709305?SoldByNewegg=1'),
('coolerN82E16835099043','GAMDIAS AURA GL360 V2 WH Performance ARGB Liquid Cooler - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099043
Product link: https://www.newegg.com/p/N82E16835099043?SoldByNewegg=1'),
('coolerN82E16835101106','ASUS ROG STRIX LC III 360 ARGB WHT - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101106
Product link: https://www.newegg.com/p/N82E16835101106?SoldByNewegg=1'),
('coolerN82E16835846073','MSI MPG CORELIQUID P13 360 Black AIO Cooler 360mm Radiator 3x120mm Fans','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846073
Product link: https://www.newegg.com/p/N82E16835846073?SoldByNewegg=1'),
('coolerN82E16835984004','ASRock AIO Steel Legend Dark 360 LCD 27mm radiator black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984004
Product link: https://www.newegg.com/p/N82E16835984004?SoldByNewegg=1'),
('coolerN82E16835980002','TRYX Holo 360mm AIO 280w TDP','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835980002
Product link: https://www.newegg.com/p/N82E16835980002?SoldByNewegg=1'),
('coolerN82E16835352134','Fractal Design Radius 240 AIO CPU Liquid Cooler 240mm - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352134
Product link: https://www.newegg.com/p/N82E16835352134?SoldByNewegg=1'),
('coolerN82E16835269037','be quiet! BW027 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269037
Product link: https://www.newegg.com/p/N82E16835269037?SoldByNewegg=1'),
('coolerN82E16835209122','Antec Skeleton 360 White AIO Liquid CPU Cooler 360mm','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209122
Product link: https://www.newegg.com/p/N82E16835209122?SoldByNewegg=1'),
('coolerN82E16835181519','CORSAIR NAUTILUS II 240 RS ARGB Liquid CPU Cooler AMD AM5 AM4 Intel LGA 1954 1851 1700 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181519
Product link: https://www.newegg.com/p/N82E16835181519?SoldByNewegg=1'),
('coolerN82E16835269038','be quiet! BW028 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269038
Product link: https://www.newegg.com/p/N82E16835269038?SoldByNewegg=1'),
('coolerN82E16835200149','Rosewill FROSTMAX 360mm Gaming AIO CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835200149
Product link: https://www.newegg.com/p/N82E16835200149?SoldByNewegg=1'),
('coolerN82E16835846071','MSI MAG CORELIQUID A15 240','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846071
Product link: https://www.newegg.com/p/N82E16835846071?SoldByNewegg=1'),
('coolerN82E16835269030','be quiet SILENT LOOP 3 240mm All-in-One Water Cooling Intel LGA1851/1700/1200/1150/1151/1155 AMD AM5/AM4 BW024 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269030
Product link: https://www.newegg.com/p/N82E16835269030?SoldByNewegg=1'),
('coolerN82E16835709303','Phanteks Glacier One 360M25 G2 AIO CPU Cooler RGB Fans Intel AMD White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709303
Product link: https://www.newegg.com/p/N82E16835709303?SoldByNewegg=1'),
('coolerN82E16835352138','Fractal Design Radius 360 RGB White 360mm AIO CPU Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352138
Product link: https://www.newegg.com/p/N82E16835352138?SoldByNewegg=1'),
('coolerN82E16835846078','MSI MAG Coreliquid A12 360 AIO CPU Cooler 360mm Radiator LGA 1700 AM5 AM4 Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846078
Product link: https://www.newegg.com/p/N82E16835846078?SoldByNewegg=1'),
('coolerN82E16835101134','ASUS TUF Gaming LC III 360 ARGB AIO CPU Cooler with Triple Fans','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101134
Product link: https://www.newegg.com/p/N82E16835101134?SoldByNewegg=1'),
('coolerN82E16835099042','GAMDIAS AURA GL240 V2 240mm AIO Liquid CPU Cooler - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835099042
Product link: https://www.newegg.com/p/N82E16835099042?SoldByNewegg=1'),
('cooler2YM-002Y-00059','Lian Li Hydroshift II 360TL CPU Cooler 360mm AIO 3x120mm Fans OLED White (HS2OLDC36TW)','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-002Y-00059
Product link: https://www.newegg.com/p/2YM-002Y-00059?SoldByNewegg=1'),
('coolerN82E16835146168','NZXT Kraken Plus RGB 240mm White AIO Liquid Cooler with LCD Fan','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146168
Product link: https://www.newegg.com/p/N82E16835146168?SoldByNewegg=1'),
('cooler2YM-002Y-00052','Lian Li Hydroshift II-S 360 CL ARGB Liquid CPU Cooler 3X CL120 Fans White (HS2LCDS36CW)','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-002Y-00052
Product link: https://www.newegg.com/p/2YM-002Y-00052?SoldByNewegg=1'),
('cooler13C-0024-000D6','ASUS PRIME LC 360 ARGB LCD','Apex product: https://bfung2.github.io/#/products?product=cooler13C-0024-000D6
Product link: https://www.newegg.com/p/13C-0024-000D6?SoldByNewegg=1'),
('cooler2YM-002Y-00062','Lian Li Hydroshift II OLED 360 Liquid CPU Cooler LGA 1851/1700 AM5/4 (HS2OLDC36NB) - Black','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-002Y-00062
Product link: https://www.newegg.com/p/2YM-002Y-00062?SoldByNewegg=1'),
('cooler17Z-007W-002Z1','ASUS Prime LC 360 ARGB White Edition 360mm AIO Liquid CPU Cooler 3 x 120mm ARGB Fans - Green','Apex product: https://bfung2.github.io/#/products?product=cooler17Z-007W-002Z1
Product link: https://www.newegg.com/p/17Z-007W-002Z1?SoldByNewegg=1'),
('cooler2YM-00BJ-00009','Sudokoo ENERGLO-360 360mm AIO CPU Cooler for Intel LGA 1851 1700 1200 115X AMD AM5 AM4 - White','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00009
Product link: https://www.newegg.com/p/2YM-00BJ-00009?SoldByNewegg=1'),
('cooler2YM-00BJ-00008','Sudokoo ENERGLO 360 Liquid Cooler 3 x 120mm Black Water Cooling for Intel LGA 1851 1700 1200 115X AMD AM5 AM4','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00008
Product link: https://www.newegg.com/p/2YM-00BJ-00008?SoldByNewegg=1'),
('cooler2YM-00BJ-00003','Sudokoo NEXAURA 240 Liquid CPU Cooler Black','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00003
Product link: https://www.newegg.com/p/2YM-00BJ-00003?SoldByNewegg=1'),
('cooler2YM-00BJ-00002','Sudokoo NEXAURA 360 Liquid CPU Cooler Black','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00002
Product link: https://www.newegg.com/p/2YM-00BJ-00002?SoldByNewegg=1'),
('cooler2YM-00BJ-00007','Sudokoo ENERGLO-240 240mm AIO CPU Cooler for Intel 1851 1700 1200 115X AMD AM5 AM4 - White','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00007
Product link: https://www.newegg.com/p/2YM-00BJ-00007?SoldByNewegg=1'),
('cooler2YM-00BJ-00004','Sudokoo NEXAURA 240 WH Amazon - White','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00004
Product link: https://www.newegg.com/p/2YM-00BJ-00004?SoldByNewegg=1'),
('cooler9UB35-103-324','Cooler Master Elite Liquid 240 CPU AIO Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=cooler9UB35-103-324
Product link: https://www.newegg.com/p/9UB35-103-324?SoldByNewegg=1'),
('cooler2YM-00BJ-00005','Sudokoo NEXAURA 360  WH - White','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BJ-00005
Product link: https://www.newegg.com/p/2YM-00BJ-00005?SoldByNewegg=1'),
('cooler9UC35-103-353','COOLER MASTER MasterLiquid 240L Core ARGB - Black','Apex product: https://bfung2.github.io/#/products?product=cooler9UC35-103-353
Product link: https://www.newegg.com/p/9UC35-103-353?SoldByNewegg=1'),
('cooler9UB35-128-052','GIGABYTE GIGABYTE GAMING 240 - Black','Apex product: https://bfung2.github.io/#/products?product=cooler9UB35-128-052
Product link: https://www.newegg.com/p/9UB35-128-052?SoldByNewegg=1'),
('coolerN82E16835101095','ASUS ROG RYUJIN 240 Liquid CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101095
Product link: https://www.newegg.com/p/N82E16835101095?SoldByNewegg=1'),
('coolerN82E16835846065','MSI MAG CoreLiquid I240 AIO ARGB CPU Cooler Infinity Mirror 240mm Radiator Fans LGA AM Compatible - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846065
Product link: https://www.newegg.com/p/N82E16835846065?SoldByNewegg=1'),
('coolerN82E16835103380','COOLER MASTER MLX-D36M-A25SZ-L1 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103380
Product link: https://www.newegg.com/p/N82E16835103380?SoldByNewegg=1'),
('coolerN82E16835984001','ASRock Phantom Gaming 360 LCD 32mm Radiator 34 LCD VRM ARGB Fan Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984001
Product link: https://www.newegg.com/p/N82E16835984001?SoldByNewegg=1'),
('coolerN82E16835128054','GIGABYTE EAGLE 360 ICE AIO Liquid Cooler 360mm 3x120mm Intel AMD','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835128054
Product link: https://www.newegg.com/p/N82E16835128054?SoldByNewegg=1'),
('coolerN82E16835846077','MSI MAG Coreliquid A12 240 AIO Cooler 240mm Radiator LGA 1700 AM5 AM4 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846077
Product link: https://www.newegg.com/p/N82E16835846077?SoldByNewegg=1'),
('coolerN82E16835101115','ASUS ProArt LC 360 AIO CPU Liquid Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101115
Product link: https://www.newegg.com/p/N82E16835101115?SoldByNewegg=1'),
('coolerN82E16835269039','be quiet! BW029 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269039
Product link: https://www.newegg.com/p/N82E16835269039?SoldByNewegg=1'),
('coolerN82E16835101137','ASUS MAX 360 ARGB LCD All-in-One CPU Liquid Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101137
Product link: https://www.newegg.com/p/N82E16835101137?SoldByNewegg=1'),
('coolerN82E16835181525','CORSAIR NAUTILUS II 240 RS LCD Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181525
Product link: https://www.newegg.com/p/N82E16835181525?SoldByNewegg=1'),
('coolerN82E16835709308','Phanteks PH-GO420D30_DWT02 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709308
Product link: https://www.newegg.com/p/N82E16835709308?SoldByNewegg=1'),
('coolerN82E16835181520','CORSAIR NAUTILUS II 240 RS ARGB Liquid CPU Cooler White 240 mm','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181520
Product link: https://www.newegg.com/p/N82E16835181520?SoldByNewegg=1'),
('coolerN82E16835209133','Antec Ultra 360 ARGB White Liquid CPU Cooler 3 120mm PWM Fans Intel LGA 115X AMD AM5','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209133
Product link: https://www.newegg.com/p/N82E16835209133?SoldByNewegg=1'),
('coolerN82E16835846074','MSI MPG CORELIQUID P13 360 White AIO Liquid Cooler 360mm Radiator 3x 120mm PWM Fans LGA 1851 AM5','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846074
Product link: https://www.newegg.com/p/N82E16835846074?SoldByNewegg=1'),
('coolerN82E16835352105','Fractal Design Lumen S28 v2 AIO CPU Cooler with Aspect 14 RGB Fans - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352105
Product link: https://www.newegg.com/p/N82E16835352105?SoldByNewegg=1'),
('coolerN82E16835607007','SAMA L70 360mm Liquid CPU Cooler ARGB Mirror Effect for AMD Intel - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607007
Product link: https://www.newegg.com/p/N82E16835607007?SoldByNewegg=1'),
('coolerN82E16835607008','SAMA L70 360mm Liquid CPU Cooler ARGB Fan for AM4/AM5 LGA 1700/1150/1200 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607008
Product link: https://www.newegg.com/p/N82E16835607008?SoldByNewegg=1'),
('coolerN82E16835984011','ASRock AIO Pro 240 ARGB radiator waterblock fan black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835984011
Product link: https://www.newegg.com/p/N82E16835984011?SoldByNewegg=1'),
('coolerN82E16835846086','MSI MPG CORELIQUID P22 360 AIO CPU Liquid Cooler 360mm Radiator - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835846086
Product link: https://www.newegg.com/p/N82E16835846086?SoldByNewegg=1'),
('coolerN82E16835101099','ASUS ROG Ryujin III 240mm ARGB Liquid CPU Cooler 3.5inch LCD - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101099
Product link: https://www.newegg.com/p/N82E16835101099?SoldByNewegg=1'),
('coolerN82E16835101092','ASUS ROG RYUO III 360 Liquid CPU Cooler 90RC00I2 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101092
Product link: https://www.newegg.com/p/N82E16835101092?SoldByNewegg=1'),
('coolerN82E16835269021','be quiet! Light Loop 360mm White CPU Cooler for Overclocked Systems BW023','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269021
Product link: https://www.newegg.com/p/N82E16835269021?SoldByNewegg=1'),
('coolerN82E16835352136','Fractal Design Radius 240 RGB Black 240mm AIO CPU Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835352136
Product link: https://www.newegg.com/p/N82E16835352136?SoldByNewegg=1'),
('coolerN82E16835106812','Thermaltake ST360 CPU Liquid Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106812
Product link: https://www.newegg.com/p/N82E16835106812?SoldByNewegg=1'),
('coolerN82E16835200147','Rosewill FROSTMAX 360mm Digital ARGB AIO CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835200147
Product link: https://www.newegg.com/p/N82E16835200147?SoldByNewegg=1'),
('coolerN82E16835709306','Phanteks Glacier One 360D30 AIO CPU Cooler Evolv X2 3x D30-120 Fans Intel AMD White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835709306
Product link: https://www.newegg.com/p/N82E16835709306?SoldByNewegg=1'),
('coolerN82E16835106752','Thermaltake TH420 ARGB Sync V2 CPU Liquid Cooler 140mm 3 Fans CL-W376-PL14SW-A - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106752
Product link: https://www.newegg.com/p/N82E16835106752?SoldByNewegg=1'),
('coolerN82E16835200148','Rosewill FROSTMAX 240mm AIO CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835200148
Product link: https://www.newegg.com/p/N82E16835200148?SoldByNewegg=1'),
('coolerN82E16835101113','ASUS ROG STRIX LC III 360 ARGB LCD CPU Cooler AM5 AM4 LGA 1700 1200 115x','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101113
Product link: https://www.newegg.com/p/N82E16835101113?SoldByNewegg=1'),
('coolerN82E16835106797','Thermaltake MINECUBE 360 Ultra CPU Liquid Cooler 3x120mm Fan 360mm Radiator 4x TFT LCD','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106797
Product link: https://www.newegg.com/p/N82E16835106797?SoldByNewegg=1'),
('coolerN82E16835103383','COOLER MASTER MLX-D36M-A25SZ-VW - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103383
Product link: https://www.newegg.com/p/N82E16835103383?SoldByNewegg=1'),
('coolerN82E16835146175','NZXT Kraken Core 240 RGB AIO CPU Liquid Cooler 240mm Radiator Intel LGA 1851 1700 1200 115X AMD AM5 AM4 Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835146175
Product link: https://www.newegg.com/p/N82E16835146175?SoldByNewegg=1'),
('coolerN82E16835106766','Thermaltake TH120 V2 ARGB Snow Liquid Cooler - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106766
Product link: https://www.newegg.com/p/N82E16835106766?SoldByNewegg=1'),
('coolerN82E16835101153','ASUS LC 360 ARGB Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101153
Product link: https://www.newegg.com/p/N82E16835101153?SoldByNewegg=1'),
('coolerN82E16835101152','ASUS LC 240 ARGB 240mm Liquid CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101152
Product link: https://www.newegg.com/p/N82E16835101152?SoldByNewegg=1'),
('coolerN82E16835181526','CORSAIR NAUTILUS II 240 RS LCD Liquid CPU Cooler AM5 AM4 LGA 1851 1700','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835181526
Product link: https://www.newegg.com/p/N82E16835181526?SoldByNewegg=1'),
('coolerN82E16835106816','Thermaltake Retro 240 Ultra ARGB Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106816
Product link: https://www.newegg.com/p/N82E16835106816?SoldByNewegg=1'),
('coolerN82E16835607004','SAMA L50 360mm Liquid CPU Cooler ARGB Fans for AMD Intel - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607004
Product link: https://www.newegg.com/p/N82E16835607004?SoldByNewegg=1'),
('coolerN82E16835607006','SAMA L50 240mm Liquid CPU Cooler ARGB PWM for AMD Intel - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607006
Product link: https://www.newegg.com/p/N82E16835607006?SoldByNewegg=1'),
('coolerN82E16835269040','be quiet! BW030 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269040
Product link: https://www.newegg.com/p/N82E16835269040?SoldByNewegg=1'),
('coolerN82E16835837010','Razer Hanbo 240mm AIO Liquid Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835837010
Product link: https://www.newegg.com/p/N82E16835837010?SoldByNewegg=1'),
('coolerN82E16835103367','CoolerMaster MasterLiquid 360 AIO Cooler 360mm Ryzen AM5 AM4 Intel LGA1700 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103367
Product link: https://www.newegg.com/p/N82E16835103367?SoldByNewegg=1'),
('coolerN82E16835607009','SAMA L70 240mm Liquid CPU Cooler ARGB PWM for AMD Intel - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607009
Product link: https://www.newegg.com/p/N82E16835607009?SoldByNewegg=1'),
('coolerN82E16835269041','be quiet! BW031 - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269041
Product link: https://www.newegg.com/p/N82E16835269041?SoldByNewegg=1'),
('coolerN82E16835269054','be quiet! Light Loop IO LCD 240mm Liquid CPU Cooler - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269054
Product link: https://www.newegg.com/p/N82E16835269054?SoldByNewegg=1'),
('coolerN82E16835101138','ASUS TUF Gaming LC III 360 White CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835101138
Product link: https://www.newegg.com/p/N82E16835101138?SoldByNewegg=1'),
('coolerN82E16835269053','be quiet! Light Loop IO LCD 360mm White CPU Cooler','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835269053
Product link: https://www.newegg.com/p/N82E16835269053?SoldByNewegg=1'),
('coolerN82E16835209124','Antec Luna 360 AIO Liquid CPU Cooler 120mm White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209124
Product link: https://www.newegg.com/p/N82E16835209124?SoldByNewegg=1'),
('coolerN82E16835209135','Antec Skeleton Matrix 360 ARGB White Liquid CPU Cooler 360mm Radiator','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835209135
Product link: https://www.newegg.com/p/N82E16835209135?SoldByNewegg=1'),
('coolerN82E16835607005','SAMA L50 240mm Liquid CPU Cooler ARGB Mirror PWM for AMD/Intel - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607005
Product link: https://www.newegg.com/p/N82E16835607005?SoldByNewegg=1'),
('coolerN82E16835103371','COOLER MASTER PL360 SPR Edition - Black','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835103371
Product link: https://www.newegg.com/p/N82E16835103371?SoldByNewegg=1'),
('coolerN82E16835106761','Thermaltake TH420 V2 Liquid Cooling - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835106761
Product link: https://www.newegg.com/p/N82E16835106761?SoldByNewegg=1'),
('coolerN82E16835607010','SAMA L70 240mm Liquid CPU Cooler ARGB Mirror PWM for AM4 AM5 LGA1700 1150 1200 1851 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835607010
Product link: https://www.newegg.com/p/N82E16835607010?SoldByNewegg=1'),
('coolerN82E16835128051','GIGABYTE GAMING 240 ICE Liquid CPU Cooler 240mm 2x120mm ARGB Fans Intel LGA 1851 1700 115X 1200 AMD AM5 AM4 - White','Apex product: https://bfung2.github.io/#/products?product=coolerN82E16835128051
Product link: https://www.newegg.com/p/N82E16835128051?SoldByNewegg=1'),
('cooler2YM-002Y-00060','LIAN LI HS2OLDC36TB','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-002Y-00060
Product link: https://www.newegg.com/p/2YM-002Y-00060?SoldByNewegg=1'),
('cooler2YM-00BE-00025','TRYX Stage 360 ARGB AIO Cooler 360mm Dual 4.0 Display Modes Asetek 7th Gen LGA AMD - White','Apex product: https://bfung2.github.io/#/products?product=cooler2YM-00BE-00025
Product link: https://www.newegg.com/p/2YM-00BE-00025?SoldByNewegg=1')
) v(id,title,body) where not exists(select 1 from public.staff_notes n where n.entity_type='product' and n.entity_id=v.id);
notify pgrst,'reload schema';
commit;
