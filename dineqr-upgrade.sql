-- DineQR upgrade: private invitation links, owner phone, company controls and owner payments.
-- Run this after the original DineQR database SQL. This upgrade is safe to run again when a newer website package asks you to repair permissions/functions.

alter table public.profiles add column if not exists phone text;
alter table public.staff_invitations add column if not exists phone text;
alter table public.staff_invitations add column if not exists invite_token uuid default gen_random_uuid();
alter table public.menu_items add column if not exists image_url text;
update public.staff_invitations set invite_token=gen_random_uuid() where invite_token is null;
alter table public.staff_invitations alter column invite_token set not null;
create unique index if not exists staff_invitations_token_unique on public.staff_invitations(invite_token);

create table if not exists public.owner_payments (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  payment_date date not null default current_date,
  method public.payment_method not null,
  notes text,
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists owner_payments_restaurant_date_idx on public.owner_payments(restaurant_id,payment_date desc);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare invite public.staff_invitations%rowtype; supplied_token text;
begin
  insert into public.profiles(id,email,full_name,phone)
  values(new.id,lower(coalesce(new.email,'')),coalesce(new.raw_user_meta_data->>'full_name',''),nullif(trim(new.raw_user_meta_data->>'phone'),''))
  on conflict(id) do update set email=excluded.email,full_name=coalesce(nullif(excluded.full_name,''),public.profiles.full_name),phone=coalesce(excluded.phone,public.profiles.phone);
  supplied_token:=new.raw_user_meta_data->>'invitation_token';
  if supplied_token is not null and supplied_token ~* '^[0-9a-f-]{36}$' then
    select * into invite from public.staff_invitations
    where invite_token=supplied_token::uuid and lower(email)=lower(new.email) and accepted_at is null and expires_at>now()
    limit 1;
  end if;
  if invite.id is not null then
    insert into public.restaurant_members(restaurant_id,user_id,role)
    values(invite.restaurant_id,new.id,invite.role)
    on conflict(restaurant_id,user_id) do update set role=excluded.role,active=true;
    update public.staff_invitations set accepted_at=now() where id=invite.id;
  end if;
  return new;
end;
$$;

create or replace function public.get_public_invitation(token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('company_name',r.name,'full_name',i.full_name,'email',i.email,'phone',i.phone,'role',i.role,'expires_at',i.expires_at)
  from public.staff_invitations i join public.restaurants r on r.id=i.restaurant_id
  where i.invite_token=token and i.accepted_at is null and i.expires_at>now() and r.active;
$$;

create or replace function public.get_public_session(token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; table_label text; result jsonb;
begin
  select * into s from public.table_sessions where public_token=token and status in ('open','bill_requested');
  if not found then return null; end if;
  select * into r from public.restaurants where id=s.restaurant_id and active;
  if not found then return null; end if;
  select label into table_label from public.physical_tables where id=s.table_id;
  select jsonb_build_object(
    'session_id',s.id,'session_status',s.status,'restaurant_id',r.id,'restaurant_name',r.name,'currency',r.currency,
    'tax_percent',r.tax_percent,'service_charge_kind',r.service_charge_kind,'service_charge_value',r.service_charge_value,'table_label',table_label,
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'sort_order',c.sort_order) order by c.sort_order,c.name) from public.menu_categories c where c.restaurant_id=r.id and c.active),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'category_id',i.category_id,'name',i.name,'description',i.description,'price',i.price,'image_url',i.image_url,'sort_order',i.sort_order) order by i.sort_order,i.name) from public.menu_items i where i.restaurant_id=r.id and i.available),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

drop function if exists public.create_restaurant_company(text,text,text);
create or replace function public.create_restaurant_company(company_name text,owner_name text,owner_email text,owner_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid; token uuid; base_slug text; final_slug text; suffix int:=1;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if length(trim(company_name))<2 then raise exception 'Company name is required'; end if;
  if exists(select 1 from public.profiles where lower(email)=lower(trim(owner_email))) then raise exception 'This owner email already has an account'; end if;
  base_slug:=public.make_slug(company_name);final_slug:=base_slug;
  while exists(select 1 from public.restaurants where slug=final_slug) loop suffix:=suffix+1;final_slug:=base_slug||'-'||suffix;end loop;
  insert into public.restaurants(name,slug,created_by) values(trim(company_name),final_slug,auth.uid()) returning id into rid;
  insert into public.staff_invitations(restaurant_id,email,full_name,phone,role,invited_by)
  values(rid,lower(trim(owner_email)),trim(owner_name),nullif(trim(owner_phone),''),'owner',auth.uid()) returning invite_token into token;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details)
  values(rid,auth.uid(),'restaurant.created','restaurant',rid,jsonb_build_object('owner_email',lower(trim(owner_email))));
  return jsonb_build_object('restaurant_id',rid,'invite_token',token,'owner_email',lower(trim(owner_email)));
end;
$$;

create or replace function public.admin_set_restaurant_status(target_restaurant uuid,new_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  update public.restaurants set active=new_active where id=target_restaurant;
  if not found then raise exception 'Restaurant company not found'; end if;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details)
  values(target_restaurant,auth.uid(),case when new_active then 'restaurant.activated' else 'restaurant.suspended' end,'restaurant',target_restaurant,jsonb_build_object('active',new_active));
end;
$$;

drop function if exists public.invite_staff(uuid,text,text,public.app_role);
create or replace function public.invite_staff(target_restaurant uuid,staff_name text,staff_email text,staff_role public.app_role) returns jsonb
language plpgsql security definer set search_path = public as $$
declare invite_id uuid; token uuid;
begin
  if staff_role in ('super_admin','owner') then raise exception 'Invalid staff role'; end if;
  if not public.has_restaurant_role(target_restaurant,array['owner','manager']::public.app_role[]) then raise exception 'Owner or manager access required'; end if;
  if staff_role='manager' and not public.has_restaurant_role(target_restaurant,array['owner']::public.app_role[]) then raise exception 'Only the owner can invite a manager'; end if;
  if exists(select 1 from public.profiles where lower(email)=lower(trim(staff_email))) then raise exception 'This email already has an account'; end if;
  insert into public.staff_invitations(restaurant_id,email,full_name,role,invited_by)
  values(target_restaurant,lower(trim(staff_email)),trim(staff_name),staff_role,auth.uid()) returning id,invite_token into invite_id,token;
  return jsonb_build_object('invitation_id',invite_id,'invite_token',token,'email',lower(trim(staff_email)));
end;
$$;

alter table public.owner_payments enable row level security;
drop policy if exists restaurants_admin_update on public.restaurants;
create policy restaurants_admin_update on public.restaurants for update using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists restaurants_admin_delete on public.restaurants;
create policy restaurants_admin_delete on public.restaurants for delete using(public.is_super_admin());
drop policy if exists owner_payments_admin on public.owner_payments;
create policy owner_payments_admin on public.owner_payments for all using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists invitations_admin_update on public.staff_invitations;
create policy invitations_admin_update on public.staff_invitations for update using(public.is_super_admin()) with check(public.is_super_admin());
drop policy if exists members_owner_manage on public.restaurant_members;
create policy members_owner_manage on public.restaurant_members for update
using(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]) or (role not in ('owner','manager') and public.has_restaurant_role(restaurant_id,array['manager']::public.app_role[])))
with check(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]) or (role not in ('owner','manager') and public.has_restaurant_role(restaurant_id,array['manager']::public.app_role[])));

revoke all on function public.get_public_invitation(uuid) from public;
revoke all on function public.create_restaurant_company(text,text,text,text) from public;
revoke all on function public.invite_staff(uuid,text,text,public.app_role) from public;
revoke all on function public.admin_set_restaurant_status(uuid,boolean) from public;
grant execute on function public.get_public_invitation(uuid) to anon,authenticated;
grant execute on function public.create_restaurant_company(text,text,text,text) to authenticated;
grant execute on function public.invite_staff(uuid,text,text,public.app_role) to authenticated;
grant execute on function public.admin_set_restaurant_status(uuid,boolean) to authenticated;
grant select,insert,update,delete on public.owner_payments to authenticated;
grant select,insert,update,delete on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.physical_tables,public.table_sessions,public.menu_categories,public.menu_items,public.orders,public.order_items,public.discounts,public.applied_discounts,public.customer_requests,public.payments,public.audit_logs to authenticated;
grant select on public.receipts to authenticated;
revoke update on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.customer_requests from authenticated;
grant update(full_name,phone) on public.profiles to authenticated;
grant update(name,tax_percent,service_charge_kind,service_charge_value) on public.restaurants to authenticated;
grant update(active) on public.restaurant_members to authenticated;
grant update(phone) on public.staff_invitations to authenticated;
grant update(status,acknowledged_by,acknowledged_at,resolved_by,resolved_at) on public.customer_requests to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('menu-images','menu-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists dineqr_menu_images_public_read on storage.objects;
create policy dineqr_menu_images_public_read on storage.objects for select using(bucket_id='menu-images');
drop policy if exists dineqr_menu_images_staff_insert on storage.objects;
create policy dineqr_menu_images_staff_insert on storage.objects for insert to authenticated with check(bucket_id='menu-images' and exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager')));
drop policy if exists dineqr_menu_images_staff_update on storage.objects;
create policy dineqr_menu_images_staff_update on storage.objects for update to authenticated using(bucket_id='menu-images' and exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager'))) with check(bucket_id='menu-images' and exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager')));
drop policy if exists dineqr_menu_images_staff_delete on storage.objects;
create policy dineqr_menu_images_staff_delete on storage.objects for delete to authenticated using(bucket_id='menu-images' and exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager')));
