-- DineQR upgrade: private invitation links, owner phone, company controls and owner payments.
-- Run this after the original DineQR database SQL. This upgrade is safe to run again when a newer website package asks you to repair permissions/functions.

alter table public.profiles add column if not exists phone text;
alter table public.staff_invitations add column if not exists phone text;
alter table public.staff_invitations add column if not exists invite_token uuid default gen_random_uuid();
alter table public.menu_items add column if not exists image_url text;
alter table public.restaurants add column if not exists menu_theme text not null default 'warm';
alter table public.restaurants add column if not exists menu_accent_color text not null default '#9A4632';
alter table public.restaurants add column if not exists menu_layout text not null default 'rows';
alter table public.restaurants add column if not exists menu_tagline text;
alter table public.restaurants add column if not exists menu_logo_url text;
alter table public.restaurants add column if not exists menu_hero_url text;
alter table public.restaurants add column if not exists menu_show_images boolean not null default true;
alter table public.restaurants add column if not exists menu_font_style text not null default 'editorial';
alter table public.restaurants add column if not exists menu_header_style text not null default 'light';
alter table public.restaurants add column if not exists menu_category_style text not null default 'pills';
alter table public.restaurants add column if not exists menu_card_style text not null default 'soft';
alter table public.restaurants add column if not exists menu_image_shape text not null default 'rounded';
alter table public.restaurants add column if not exists menu_hero_style text not null default 'split';
alter table public.restaurants add column if not exists menu_background_style text not null default 'cream';
alter table public.restaurants add column if not exists menu_show_hero boolean not null default true;
alter table public.restaurants add column if not exists menu_show_descriptions boolean not null default true;
alter table public.restaurants add column if not exists menu_address text;
alter table public.restaurants add column if not exists menu_phone text;
alter table public.restaurants add column if not exists menu_hours text;
alter table public.restaurants add column if not exists menu_social_url text;
alter table public.restaurants add column if not exists subscription_expires_at date;
alter table public.table_sessions add column if not exists assigned_waiter_id uuid references public.profiles(id);
alter table public.table_sessions add column if not exists assigned_waiter_name text;
alter table public.discounts add column if not exists usage_limit integer;
do $$ begin
  alter table public.restaurants add constraint restaurants_menu_theme_check check (menu_theme in ('warm','modern','natural'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.restaurants add constraint restaurants_menu_accent_check check (menu_accent_color ~ '^#[0-9A-Fa-f]{6}$');
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.restaurants add constraint restaurants_menu_layout_check check (menu_layout in ('rows','compact','cards'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.restaurants add constraint restaurants_menu_tagline_check check (menu_tagline is null or length(menu_tagline) <= 160);
exception when duplicate_object then null; end $$;
do $$ begin
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_font_style_check') then alter table public.restaurants add constraint restaurants_menu_font_style_check check(menu_font_style in ('editorial','modern','classic','friendly')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_header_style_check') then alter table public.restaurants add constraint restaurants_menu_header_style_check check(menu_header_style in ('light','accent','dark')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_category_style_check') then alter table public.restaurants add constraint restaurants_menu_category_style_check check(menu_category_style in ('pills','underline','blocks')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_card_style_check') then alter table public.restaurants add constraint restaurants_menu_card_style_check check(menu_card_style in ('soft','outline','minimal')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_image_shape_check') then alter table public.restaurants add constraint restaurants_menu_image_shape_check check(menu_image_shape in ('rounded','square','circle')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_hero_style_check') then alter table public.restaurants add constraint restaurants_menu_hero_style_check check(menu_hero_style in ('split','centered','banner')); end if;
  if not exists(select 1 from pg_constraint where conname='restaurants_menu_background_style_check') then alter table public.restaurants add constraint restaurants_menu_background_style_check check(menu_background_style in ('cream','white','natural','paper')); end if;
  if not exists(select 1 from pg_constraint where conname='discounts_usage_limit_check') then alter table public.discounts add constraint discounts_usage_limit_check check(usage_limit is null or usage_limit>0); end if;
end $$;
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
  access_expires_on date,
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.owner_payments add column if not exists access_expires_on date;
create index if not exists owner_payments_restaurant_date_idx on public.owner_payments(restaurant_id,payment_date desc);

create or replace function public.has_restaurant_role(target uuid, allowed public.app_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super_admin() or exists(
    select 1 from public.restaurant_members m join public.restaurants r on r.id=m.restaurant_id
    where m.restaurant_id=target and m.user_id=auth.uid() and m.active and m.role=any(allowed)
      and r.active and (r.subscription_expires_at is null or r.subscription_expires_at>=current_date)
  );
$$;

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
    update public.profiles set full_name=invite.full_name,phone=coalesce(invite.phone,phone) where id=new.id;
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
  select * into r from public.restaurants where id=s.restaurant_id and active and (subscription_expires_at is null or subscription_expires_at>=current_date);
  if not found then return null; end if;
  select label into table_label from public.physical_tables where id=s.table_id;
  select jsonb_build_object(
    'session_id',s.id,'session_status',s.status,'restaurant_id',r.id,'restaurant_name',r.name,'currency',r.currency,
    'tax_percent',r.tax_percent,'service_charge_kind',r.service_charge_kind,'service_charge_value',r.service_charge_value,'table_label',table_label,
    'menu_theme',r.menu_theme,'menu_accent_color',r.menu_accent_color,'menu_layout',r.menu_layout,'menu_tagline',r.menu_tagline,'menu_logo_url',r.menu_logo_url,'menu_hero_url',r.menu_hero_url,'menu_show_images',r.menu_show_images,
    'menu_font_style',r.menu_font_style,'menu_header_style',r.menu_header_style,'menu_category_style',r.menu_category_style,'menu_card_style',r.menu_card_style,'menu_image_shape',r.menu_image_shape,'menu_hero_style',r.menu_hero_style,'menu_background_style',r.menu_background_style,'menu_show_hero',r.menu_show_hero,'menu_show_descriptions',r.menu_show_descriptions,'menu_address',r.menu_address,'menu_phone',r.menu_phone,'menu_hours',r.menu_hours,'menu_social_url',r.menu_social_url,
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'sort_order',c.sort_order) order by c.sort_order,c.name) from public.menu_categories c where c.restaurant_id=r.id and c.active),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'category_id',i.category_id,'name',i.name,'description',i.description,'price',i.price,'image_url',i.image_url,'sort_order',i.sort_order) order by i.sort_order,i.name) from public.menu_items i where i.restaurant_id=r.id and i.available),'[]'::jsonb),
    'orders',coalesce((select jsonb_agg(jsonb_build_object(
      'id',o.id,'order_number',o.order_number,'status',o.status,'created_at',o.created_at,'rejection_reason',o.rejection_reason,
      'total',coalesce((select sum(oi.unit_price_snapshot*oi.quantity) from public.order_items oi where oi.order_id=o.id and oi.voided_at is null),0),
      'items',coalesce((select jsonb_agg(jsonb_build_object('id',oi.id,'name',oi.item_name_snapshot,'price',oi.unit_price_snapshot,'quantity',oi.quantity,'instructions',oi.special_instructions,'voided',oi.voided_at is not null) order by oi.id) from public.order_items oi where oi.order_id=o.id),'[]'::jsonb)
    ) order by o.created_at desc) from public.orders o where o.session_id=s.id),'[]'::jsonb)
  ) into result;
  return result;
end;
$$;

create or replace function public.get_customer_order_history(token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',o.id,'order_number',o.order_number,'status',o.status,'created_at',o.created_at,'rejection_reason',o.rejection_reason,
    'total',coalesce((select sum(oi.unit_price_snapshot*oi.quantity) from public.order_items oi where oi.order_id=o.id and oi.voided_at is null),0),
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',oi.id,'name',oi.item_name_snapshot,'price',oi.unit_price_snapshot,'quantity',oi.quantity,'instructions',oi.special_instructions,'voided',oi.voided_at is not null) order by oi.id) from public.order_items oi where oi.order_id=o.id),'[]'::jsonb)
  ) order by o.created_at desc),'[]'::jsonb)
  from public.orders o
  join public.table_sessions s on s.id=o.session_id
  join public.restaurants r on r.id=s.restaurant_id and r.active and (r.subscription_expires_at is null or r.subscription_expires_at>=current_date)
  where s.public_token=$1 and s.status in ('open','bill_requested');
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

create or replace function public.admin_update_restaurant_company(target_restaurant uuid, company_name text, owner_name text, owner_phone text, expiry_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if length(trim(company_name))<2 or length(trim(owner_name))<2 then raise exception 'Company and owner names are required'; end if;
  update public.restaurants set name=trim(company_name),subscription_expires_at=expiry_date where id=target_restaurant;
  if not found then raise exception 'Restaurant company not found'; end if;
  update public.staff_invitations set full_name=trim(owner_name),phone=nullif(trim(owner_phone),'') where restaurant_id=target_restaurant and role='owner';
  update public.profiles p set full_name=trim(owner_name),phone=nullif(trim(owner_phone),'')
  from public.restaurant_members m where m.user_id=p.id and m.restaurant_id=target_restaurant and m.role='owner';
end;
$$;

create or replace function public.admin_set_restaurant_expiry(target_restaurant uuid, expiry_date date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  update public.restaurants set subscription_expires_at=expiry_date where id=target_restaurant;
  if not found then raise exception 'Restaurant company not found'; end if;
end;
$$;

create or replace function public.assign_waiter_to_session(target_session uuid, target_waiter uuid) returns void
language plpgsql security definer set search_path = public as $$
declare session_row public.table_sessions%rowtype; waiter_name text;
begin
  select * into session_row from public.table_sessions where id=target_session and status<>'closed';
  if not found then raise exception 'Open session not found'; end if;
  if not public.has_restaurant_role(session_row.restaurant_id,array['owner','manager']::public.app_role[]) then raise exception 'Owner or manager access required'; end if;
  select p.full_name into waiter_name from public.restaurant_members m join public.profiles p on p.id=m.user_id
  where m.restaurant_id=session_row.restaurant_id and m.user_id=target_waiter and m.role='waiter' and m.active;
  if waiter_name is null then raise exception 'Active waiter not found'; end if;
  update public.table_sessions set assigned_waiter_id=target_waiter,assigned_waiter_name=waiter_name where id=target_session;
end;
$$;

create or replace function public.apply_discount_to_session(target_session uuid, target_discount uuid) returns numeric
language plpgsql security definer set search_path = public as $$
declare s public.table_sessions%rowtype; d public.discounts%rowtype; subtotal numeric; amount numeric; used_count integer;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed';
  select * into d from public.discounts where id=target_discount and restaurant_id=s.restaurant_id and active;
  if d.id is null then raise exception 'Discount is unavailable'; end if;
  if not public.has_restaurant_role(s.restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]) then raise exception 'Not allowed'; end if;
  select count(*) into used_count from public.applied_discounts where discount_id=d.id;
  if d.usage_limit is not null and used_count>=d.usage_limit and not exists(select 1 from public.applied_discounts where session_id=s.id and discount_id=d.id) then raise exception 'Discount usage limit reached'; end if;
  select coalesce(sum(i.unit_price_snapshot*i.quantity),0) into subtotal from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  amount:=case when d.kind='percentage' then round(subtotal*d.value/100,2) else least(d.value,subtotal) end;
  insert into public.applied_discounts(session_id,discount_id,name_snapshot,amount_snapshot,applied_by)
  values(s.id,d.id,d.name,amount,auth.uid())
  on conflict(session_id,discount_id) where discount_id is not null
  do update set name_snapshot=excluded.name_snapshot,amount_snapshot=excluded.amount_snapshot,applied_by=excluded.applied_by,created_at=now();
  return amount;
end;
$$;

drop function if exists public.invite_staff(uuid,text,text,public.app_role);
drop function if exists public.invite_staff(uuid,text,text,text,public.app_role);
create or replace function public.invite_staff(target_restaurant uuid,staff_name text,staff_email text,staff_phone text,staff_role public.app_role) returns jsonb
language plpgsql security definer set search_path = public as $$
declare invite_id uuid; token uuid;
begin
  if staff_role in ('super_admin','owner') then raise exception 'Invalid staff role'; end if;
  if not public.has_restaurant_role(target_restaurant,array['owner','manager']::public.app_role[]) then raise exception 'Owner or manager access required'; end if;
  if staff_role='manager' and not public.has_restaurant_role(target_restaurant,array['owner']::public.app_role[]) then raise exception 'Only the owner can invite a manager'; end if;
  if exists(select 1 from public.profiles where lower(email)=lower(trim(staff_email))) then raise exception 'This email already has an account'; end if;
  insert into public.staff_invitations(restaurant_id,email,full_name,phone,role,invited_by)
  values(target_restaurant,lower(trim(staff_email)),trim(staff_name),nullif(trim(staff_phone),''),staff_role,auth.uid()) returning id,invite_token into invite_id,token;
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

create or replace view public.receipts with (security_invoker=true) as
select s.id,s.restaurant_id,s.table_id,t.label as table_label,s.opened_at,s.closed_at,s.subtotal_snapshot,s.discount_snapshot,s.tax_snapshot,s.service_snapshot,s.total_snapshot,p.method as payment_method,p.recorded_at,s.assigned_waiter_id,s.assigned_waiter_name
from public.table_sessions s join public.physical_tables t on t.id=s.table_id left join public.payments p on p.session_id=s.id where s.status='closed';

revoke all on function public.get_public_invitation(uuid) from public;
revoke all on function public.get_customer_order_history(uuid) from public;
revoke all on function public.create_restaurant_company(text,text,text,text) from public;
revoke all on function public.invite_staff(uuid,text,text,text,public.app_role) from public;
revoke all on function public.admin_set_restaurant_status(uuid,boolean) from public;
revoke all on function public.admin_update_restaurant_company(uuid,text,text,text,date) from public;
revoke all on function public.admin_set_restaurant_expiry(uuid,date) from public;
revoke all on function public.assign_waiter_to_session(uuid,uuid) from public;
grant execute on function public.get_public_invitation(uuid) to anon,authenticated;
grant execute on function public.get_customer_order_history(uuid) to anon,authenticated;
grant execute on function public.create_restaurant_company(text,text,text,text) to authenticated;
grant execute on function public.invite_staff(uuid,text,text,text,public.app_role) to authenticated;
grant execute on function public.admin_set_restaurant_status(uuid,boolean) to authenticated;
grant execute on function public.admin_update_restaurant_company(uuid,text,text,text,date) to authenticated;
grant execute on function public.admin_set_restaurant_expiry(uuid,date) to authenticated;
grant execute on function public.assign_waiter_to_session(uuid,uuid) to authenticated;
grant select,insert,update,delete on public.owner_payments to authenticated;
grant select,insert,update,delete on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.physical_tables,public.table_sessions,public.menu_categories,public.menu_items,public.orders,public.order_items,public.discounts,public.applied_discounts,public.customer_requests,public.payments,public.audit_logs to authenticated;
grant select on public.receipts to authenticated;
revoke update on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.customer_requests from authenticated;
grant update(full_name,phone) on public.profiles to authenticated;
grant update(tax_percent,service_charge_kind,service_charge_value,menu_theme,menu_accent_color,menu_layout,menu_tagline,menu_logo_url,menu_hero_url,menu_show_images,menu_font_style,menu_header_style,menu_category_style,menu_card_style,menu_image_shape,menu_hero_style,menu_background_style,menu_show_hero,menu_show_descriptions,menu_address,menu_phone,menu_hours,menu_social_url) on public.restaurants to authenticated;
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
