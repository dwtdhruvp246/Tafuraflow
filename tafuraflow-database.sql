-- TafuraFlow complete Supabase schema
-- Run this file ONCE in a new Supabase project's SQL Editor.
-- After creating your first account, promote it at the bottom of this file.

create extension if not exists pgcrypto;

create type public.app_role as enum ('super_admin', 'owner', 'manager', 'waiter', 'kitchen', 'bar', 'cashier');
create type public.session_status as enum ('open', 'bill_requested', 'closed');
create type public.order_status as enum ('pending', 'accepted', 'preparing', 'ready', 'served', 'rejected');
create type public.request_type as enum ('waiter', 'bill');
create type public.request_status as enum ('open', 'acknowledged', 'resolved');
create type public.charge_kind as enum ('percentage', 'fixed');
create type public.payment_method as enum ('cash', 'card', 'bank_transfer', 'other');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  phone text,
  platform_role public.app_role check (platform_role is null or platform_role = 'super_admin'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index profiles_email_unique on public.profiles(lower(email));

create table public.restaurants (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 2 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  currency text not null default 'USD' check (currency = 'USD'),
  tax_percent numeric(6,3),
  service_charge_kind public.charge_kind,
  service_charge_value numeric(12,2),
  menu_theme text not null default 'warm' check (menu_theme in ('warm','modern','natural')),
  menu_accent_color text not null default '#9A4632' check (menu_accent_color ~ '^#[0-9A-Fa-f]{6}$'),
  menu_layout text not null default 'rows' check (menu_layout in ('rows','compact','cards')),
  menu_tagline text check (menu_tagline is null or length(menu_tagline) <= 160),
  menu_logo_url text,
  menu_hero_url text,
  menu_show_images boolean not null default true,
  menu_font_style text not null default 'editorial' check (menu_font_style in ('editorial','modern','classic','friendly')),
  menu_header_style text not null default 'light' check (menu_header_style in ('light','accent','dark')),
  menu_category_style text not null default 'pills' check (menu_category_style in ('pills','underline','blocks')),
  menu_card_style text not null default 'soft' check (menu_card_style in ('soft','outline','minimal')),
  menu_image_shape text not null default 'rounded' check (menu_image_shape in ('rounded','square','circle')),
  menu_hero_style text not null default 'split' check (menu_hero_style in ('split','centered','banner')),
  menu_background_style text not null default 'cream' check (menu_background_style in ('cream','white','natural','paper')),
  menu_show_hero boolean not null default true,
  menu_show_descriptions boolean not null default true,
  menu_address text,
  menu_phone text,
  menu_hours text,
  menu_social_url text,
  menu_design_changed_at timestamptz,
  menu_design_draft jsonb not null default '{}'::jsonb,
  menu_design_published jsonb not null default '{}'::jsonb,
  menu_design_template text not null default 'modern-restaurant',
  menu_design_draft_updated_at timestamptz,
  menu_design_draft_updated_by uuid references public.profiles(id),
  subscription_expires_at date,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (tax_percent is null or tax_percent between 0 and 100),
  check (service_charge_value is null or service_charge_value >= 0),
  check (service_charge_kind <> 'percentage' or service_charge_value <= 100)
);

create table public.restaurant_members (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.app_role not null check (role <> 'super_admin'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, user_id)
);

create table public.staff_invitations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  email text not null,
  full_name text not null,
  phone text,
  invite_token uuid not null unique default gen_random_uuid(),
  role public.app_role not null check (role <> 'super_admin'),
  invited_by uuid not null references public.profiles(id),
  accepted_at timestamptz,
  expires_at timestamptz not null default (now() + interval '14 days'),
  created_at timestamptz not null default now()
);
create unique index one_pending_invitation on public.staff_invitations(restaurant_id, lower(email)) where accepted_at is null;

create table public.physical_tables (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 50),
  seats integer not null default 2 check (seats between 1 and 100),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (restaurant_id, label)
);

create table public.table_sessions (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  table_id uuid not null references public.physical_tables(id),
  public_token uuid not null unique default gen_random_uuid(),
  status public.session_status not null default 'open',
  opened_by uuid not null references public.profiles(id),
  assigned_waiter_id uuid references public.profiles(id),
  assigned_waiter_name text,
  opened_at timestamptz not null default now(),
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  subtotal_snapshot numeric(12,2),
  discount_snapshot numeric(12,2),
  tax_snapshot numeric(12,2),
  service_snapshot numeric(12,2),
  total_snapshot numeric(12,2),
  check ((status = 'closed' and closed_at is not null) or (status <> 'closed' and closed_at is null))
);
create unique index one_active_session_per_table on public.table_sessions(table_id) where status <> 'closed';
create index sessions_restaurant_status_idx on public.table_sessions(restaurant_id, status);

create table public.menu_categories (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  sort_order integer not null default 0,
  preparation_area text not null default 'kitchen' check (preparation_area in ('kitchen','bar')),
  active boolean not null default true,
  unique (restaurant_id, name)
);

create table public.menu_items (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  category_id uuid references public.menu_categories(id) on delete set null,
  name text not null check (length(trim(name)) between 1 and 120),
  description text not null default '',
  price numeric(12,2) not null check (price >= 0),
  image_url text,
  available boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index menu_items_restaurant_idx on public.menu_items(restaurant_id, category_id, available);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  order_number bigint generated always as identity unique,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id),
  status public.order_status not null default 'pending',
  accepted_by uuid references public.profiles(id),
  accepted_at timestamptz,
  rejected_by uuid references public.profiles(id),
  rejected_at timestamptz,
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index orders_restaurant_status_idx on public.orders(restaurant_id, status, created_at desc);
create index orders_session_idx on public.orders(session_id, created_at);

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  menu_item_id uuid references public.menu_items(id) on delete set null,
  item_name_snapshot text not null,
  unit_price_snapshot numeric(12,2) not null check (unit_price_snapshot >= 0),
  quantity integer not null check (quantity between 1 and 100),
  special_instructions text,
  preparation_area text not null default 'kitchen' check (preparation_area in ('kitchen','bar')),
  preparation_status text not null default 'pending' check (preparation_status in ('pending','accepted','preparing','ready','served','rejected')),
  voided_at timestamptz,
  voided_by uuid references public.profiles(id),
  void_reason text,
  check ((voided_at is null and void_reason is null) or (voided_at is not null and length(trim(void_reason)) > 0))
);
create index order_items_order_idx on public.order_items(order_id);

create table public.discounts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null,
  kind public.charge_kind not null,
  value numeric(12,2) not null check (value >= 0),
  active boolean not null default true,
  usage_limit integer check (usage_limit is null or usage_limit > 0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (kind <> 'percentage' or value <= 100)
);

create table public.applied_discounts (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  discount_id uuid references public.discounts(id) on delete set null,
  name_snapshot text not null,
  amount_snapshot numeric(12,2) not null check (amount_snapshot >= 0),
  applied_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create unique index one_discount_per_session on public.applied_discounts(session_id, discount_id) where discount_id is not null;

create table public.customer_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  type public.request_type not null,
  status public.request_status not null default 'open',
  acknowledged_by uuid references public.profiles(id),
  acknowledged_at timestamptz,
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create index requests_restaurant_status_idx on public.customer_requests(restaurant_id, status, created_at desc);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  session_id uuid not null unique references public.table_sessions(id),
  method public.payment_method not null,
  amount numeric(12,2) not null check (amount >= 0),
  recorded_by uuid not null references public.profiles(id),
  recorded_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  restaurant_id uuid references public.restaurants(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index audit_restaurant_created_idx on public.audit_logs(restaurant_id, created_at desc);

create table public.owner_payments (
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

create table public.menu_design_versions (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  version_number integer not null,
  template_key text not null,
  config jsonb not null,
  published_by uuid not null references public.profiles(id),
  published_at timestamptz not null default now(),
  unique(restaurant_id,version_number)
);
create index owner_payments_restaurant_date_idx on public.owner_payments(restaurant_id,payment_date desc);

create or replace function public.set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;
create trigger profiles_updated before update on public.profiles for each row execute function public.set_updated_at();
create trigger restaurants_updated before update on public.restaurants for each row execute function public.set_updated_at();
create trigger members_updated before update on public.restaurant_members for each row execute function public.set_updated_at();
create trigger menu_items_updated before update on public.menu_items for each row execute function public.set_updated_at();
create trigger orders_updated before update on public.orders for each row execute function public.set_updated_at();

create or replace function public.is_super_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where id = auth.uid() and platform_role = 'super_admin');
$$;

create or replace function public.has_restaurant_role(target uuid, allowed public.app_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_super_admin() or exists(
    select 1 from public.restaurant_members m join public.restaurants r on r.id=m.restaurant_id
    where m.restaurant_id = target and m.user_id = auth.uid() and m.active and m.role = any(allowed)
      and r.active and (r.subscription_expires_at is null or r.subscription_expires_at >= current_date)
  );
$$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare invite public.staff_invitations%rowtype; supplied_token text;
begin
  insert into public.profiles(id, email, full_name, phone)
  values(new.id, lower(coalesce(new.email, '')), coalesce(new.raw_user_meta_data->>'full_name', ''),nullif(trim(new.raw_user_meta_data->>'phone'),''))
  on conflict(id) do update set email = excluded.email, full_name = coalesce(nullif(excluded.full_name,''), public.profiles.full_name),phone=coalesce(excluded.phone,public.profiles.phone);

  supplied_token:=new.raw_user_meta_data->>'invitation_token';
  if supplied_token is not null and supplied_token ~* '^[0-9a-f-]{36}$' then
    select * into invite from public.staff_invitations
    where invite_token=supplied_token::uuid and lower(email)=lower(new.email) and accepted_at is null and expires_at > now()
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
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

insert into public.profiles(id,email,full_name)
select id,lower(coalesce(email,'')),coalesce(raw_user_meta_data->>'full_name','') from auth.users
on conflict(id) do nothing;

create or replace function public.get_my_context() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'profile', jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'platform_role',p.platform_role),
    'membership', case when m.id is null then null else jsonb_build_object('id',m.id,'restaurant_id',m.restaurant_id,'role',m.role,'active',m.active) end,
    'restaurant', case when r.id is null then null else to_jsonb(r) end
  )
  from public.profiles p
  left join lateral (select * from public.restaurant_members where user_id=p.id and active order by created_at limit 1) m on true
  left join public.restaurants r on r.id=m.restaurant_id
  where p.id=auth.uid();
$$;

create or replace function public.make_slug(value text) returns text language sql immutable as $$
  select trim(both '-' from regexp_replace(lower(value),'[^a-z0-9]+','-','g'));
$$;

create or replace function public.get_public_invitation(token uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('company_name',r.name,'full_name',i.full_name,'email',i.email,'phone',i.phone,'role',i.role,'expires_at',i.expires_at)
  from public.staff_invitations i join public.restaurants r on r.id=i.restaurant_id
  where i.invite_token=token and i.accepted_at is null and i.expires_at>now() and r.active;
$$;

create or replace function public.create_restaurant_company(company_name text, owner_name text, owner_email text, owner_phone text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare rid uuid; token uuid; base_slug text; final_slug text; suffix int := 1;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if length(trim(company_name)) < 2 then raise exception 'Company name is required'; end if;
  if exists(select 1 from public.profiles where lower(email)=lower(trim(owner_email))) then raise exception 'This owner email already has an account'; end if;
  base_slug := public.make_slug(company_name); final_slug := base_slug;
  while exists(select 1 from public.restaurants where slug=final_slug) loop suffix:=suffix+1; final_slug:=base_slug||'-'||suffix; end loop;
  insert into public.restaurants(name,slug,created_by) values(trim(company_name),final_slug,auth.uid()) returning id into rid;
  insert into public.staff_invitations(restaurant_id,email,full_name,phone,role,invited_by)
  values(rid,lower(trim(owner_email)),trim(owner_name),nullif(trim(owner_phone),''),'owner',auth.uid()) returning invite_token into token;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details)
  values(rid,auth.uid(),'restaurant.created','restaurant',rid,jsonb_build_object('owner_email',lower(trim(owner_email))));
  return jsonb_build_object('restaurant_id',rid,'invite_token',token,'owner_email',lower(trim(owner_email)));
end;
$$;

create or replace function public.admin_set_restaurant_status(target_restaurant uuid, new_active boolean) returns void
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

create or replace function public.admin_update_menu_appearance(target_restaurant uuid, appearance jsonb) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare restaurant_row public.restaurants%rowtype; changed_at timestamptz;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into restaurant_row from public.restaurants where id=target_restaurant for update;
  if not found then raise exception 'Restaurant company not found'; end if;
  if coalesce(appearance->>'menu_accent_color','#9A4632') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'Please choose a valid menu accent color'; end if;
  update public.restaurants set
    menu_theme=coalesce(appearance->>'menu_theme','warm'),
    menu_accent_color=upper(coalesce(appearance->>'menu_accent_color','#9A4632')),
    menu_layout=coalesce(appearance->>'menu_layout','rows'),
    menu_tagline=nullif(trim(appearance->>'menu_tagline'),''),
    menu_logo_url=nullif(trim(appearance->>'menu_logo_url'),''),
    menu_hero_url=nullif(trim(appearance->>'menu_hero_url'),''),
    menu_show_images=coalesce((appearance->>'menu_show_images')::boolean,true),
    menu_font_style=coalesce(appearance->>'menu_font_style','editorial'),
    menu_header_style=coalesce(appearance->>'menu_header_style','light'),
    menu_category_style=coalesce(appearance->>'menu_category_style','pills'),
    menu_card_style=coalesce(appearance->>'menu_card_style','soft'),
    menu_image_shape=coalesce(appearance->>'menu_image_shape','rounded'),
    menu_hero_style=coalesce(appearance->>'menu_hero_style','split'),
    menu_background_style=coalesce(appearance->>'menu_background_style','cream'),
    menu_show_hero=coalesce((appearance->>'menu_show_hero')::boolean,true),
    menu_show_descriptions=coalesce((appearance->>'menu_show_descriptions')::boolean,true),
    menu_address=nullif(trim(appearance->>'menu_address'),''),
    menu_phone=nullif(trim(appearance->>'menu_phone'),''),
    menu_hours=nullif(trim(appearance->>'menu_hours'),''),
    menu_social_url=nullif(trim(appearance->>'menu_social_url'),''),
    menu_design_changed_at=now()
  where id=target_restaurant returning menu_design_changed_at into changed_at;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details)
  values(target_restaurant,auth.uid(),'restaurant.menu_design_changed','restaurant',target_restaurant,jsonb_build_object('changed_at',changed_at));
  return changed_at;
end;
$$;

create or replace function public.admin_get_menu_design(target_restaurant uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r public.restaurants%rowtype;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into r from public.restaurants where id=target_restaurant;
  if not found then raise exception 'Restaurant company not found'; end if;
  return jsonb_build_object(
    'restaurant_id',r.id,'restaurant_name',r.name,'template',r.menu_design_template,
    'draft',r.menu_design_draft,'published',r.menu_design_published,
    'draft_updated_at',r.menu_design_draft_updated_at,'last_published_at',r.menu_design_changed_at,
    'next_publish_at',null,
    'can_publish',true,
    'versions',coalesce((select jsonb_agg(jsonb_build_object('id',v.id,'version_number',v.version_number,'template',v.template_key,'published_at',v.published_at,'published_by',p.full_name) order by v.version_number desc) from public.menu_design_versions v left join public.profiles p on p.id=v.published_by where v.restaurant_id=r.id),'[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_save_menu_design_draft(target_restaurant uuid, design jsonb, template_key text) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare saved_at timestamptz;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  if jsonb_typeof(design)<>'object' or pg_column_size(design)>250000 then raise exception 'Menu design is invalid or too large'; end if;
  update public.restaurants set menu_design_draft=design,menu_design_template=coalesce(nullif(trim(template_key),''),'custom'),menu_design_draft_updated_at=now(),menu_design_draft_updated_by=auth.uid()
  where id=target_restaurant returning menu_design_draft_updated_at into saved_at;
  if not found then raise exception 'Restaurant company not found'; end if;
  return saved_at;
end;
$$;

create or replace function public.admin_publish_menu_design(target_restaurant uuid, allow_override boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.restaurants%rowtype; version_no integer; published_at timestamptz;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into r from public.restaurants where id=target_restaurant for update;
  if not found then raise exception 'Restaurant company not found'; end if;
  if r.menu_design_draft='{}'::jsonb then raise exception 'Save a menu design draft before publishing'; end if;
  select coalesce(max(version_number),0)+1 into version_no from public.menu_design_versions where restaurant_id=target_restaurant;
  update public.restaurants set menu_design_published=r.menu_design_draft,menu_design_changed_at=now() where id=target_restaurant returning menu_design_changed_at into published_at;
  insert into public.menu_design_versions(restaurant_id,version_number,template_key,config,published_by,published_at)
  values(target_restaurant,version_no,r.menu_design_template,r.menu_design_draft,auth.uid(),published_at);
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details)
  values(target_restaurant,auth.uid(),'restaurant.menu_design_published','restaurant',target_restaurant,jsonb_build_object('version',version_no));
  return jsonb_build_object('published_at',published_at,'version_number',version_no,'next_publish_at',null);
end;
$$;

create or replace function public.admin_restore_menu_design_version(target_restaurant uuid, target_version uuid) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare v public.menu_design_versions%rowtype; saved_at timestamptz;
begin
  if not public.is_super_admin() then raise exception 'Super Admin access required'; end if;
  select * into v from public.menu_design_versions where id=target_version and restaurant_id=target_restaurant;
  if not found then raise exception 'Menu design version not found'; end if;
  update public.restaurants set menu_design_draft=v.config,menu_design_template=v.template_key,menu_design_draft_updated_at=now(),menu_design_draft_updated_by=auth.uid()
  where id=target_restaurant returning menu_design_draft_updated_at into saved_at;
  return saved_at;
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

create or replace function public.invite_staff(target_restaurant uuid, staff_name text, staff_email text, staff_phone text, staff_role public.app_role) returns jsonb
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

create or replace function public.edit_restaurant_staff(target_restaurant uuid, target_user uuid, staff_name text, staff_phone text, staff_role public.app_role) returns void
language plpgsql security definer set search_path = public as $$
declare member_row public.restaurant_members%rowtype;
begin
  if not public.has_restaurant_role(target_restaurant,array['owner']::public.app_role[]) then raise exception 'Owner access required'; end if;
  if staff_role in ('super_admin','owner') then raise exception 'Invalid staff role'; end if;
  if length(trim(staff_name))<2 then raise exception 'Staff name is required'; end if;
  select * into member_row from public.restaurant_members where restaurant_id=target_restaurant and user_id=target_user for update;
  if not found or member_row.role='owner' then raise exception 'Staff member not found'; end if;
  update public.profiles set full_name=trim(staff_name),phone=nullif(trim(staff_phone),'') where id=target_user;
  update public.restaurant_members set role=staff_role where id=member_row.id;
end;
$$;

create or replace function public.edit_staff_invitation(target_invitation uuid, staff_name text, staff_phone text, staff_role public.app_role) returns void
language plpgsql security definer set search_path = public as $$
declare invitation_row public.staff_invitations%rowtype;
begin
  select * into invitation_row from public.staff_invitations where id=target_invitation and accepted_at is null for update;
  if not found then raise exception 'Pending staff invitation not found'; end if;
  if not public.has_restaurant_role(invitation_row.restaurant_id,array['owner']::public.app_role[]) then raise exception 'Owner access required'; end if;
  if staff_role in ('super_admin','owner') then raise exception 'Invalid staff role'; end if;
  if length(trim(staff_name))<2 then raise exception 'Staff name is required'; end if;
  update public.staff_invitations set full_name=trim(staff_name),phone=nullif(trim(staff_phone),''),role=staff_role where id=target_invitation;
end;
$$;

create or replace function public.open_table_session(target_table uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare tbl public.physical_tables%rowtype; session_row public.table_sessions%rowtype; opener_waiter_name text;
begin
  select * into tbl from public.physical_tables where id=target_table and active;
  if not found then raise exception 'Table not found'; end if;
  if not public.has_restaurant_role(tbl.restaurant_id,array['owner','manager','waiter']::public.app_role[]) then raise exception 'Not allowed'; end if;
  if exists(select 1 from public.table_sessions where table_id=target_table and status<>'closed') then raise exception 'Table is already open'; end if;
  select p.full_name into opener_waiter_name from public.restaurant_members m join public.profiles p on p.id=m.user_id
  where m.restaurant_id=tbl.restaurant_id and m.user_id=auth.uid() and m.role='waiter' and m.active;
  insert into public.table_sessions(restaurant_id,table_id,opened_by,assigned_waiter_id,assigned_waiter_name)
  values(tbl.restaurant_id,tbl.id,auth.uid(),case when opener_waiter_name is null then null else auth.uid() end,opener_waiter_name) returning * into session_row;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id) values(tbl.restaurant_id,auth.uid(),'table.opened','table_session',session_row.id);
  return jsonb_build_object('session_id',session_row.id,'public_token',session_row.public_token,'table_label',tbl.label,'assigned_waiter_name',session_row.assigned_waiter_name);
end;
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
    'menu_font_style',r.menu_font_style,'menu_header_style',r.menu_header_style,'menu_category_style',r.menu_category_style,'menu_card_style',r.menu_card_style,'menu_image_shape',r.menu_image_shape,'menu_hero_style',r.menu_hero_style,'menu_background_style',r.menu_background_style,'menu_show_hero',r.menu_show_hero,'menu_show_descriptions',r.menu_show_descriptions,'menu_address',r.menu_address,'menu_phone',r.menu_phone,'menu_hours',r.menu_hours,'menu_social_url',r.menu_social_url,'menu_design',r.menu_design_published,'menu_design_template',r.menu_design_template,
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

create or replace function public.place_customer_order(token uuid, items jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.table_sessions%rowtype; order_id uuid; entry jsonb; item public.menu_items%rowtype; qty int; total numeric:=0; prep_area text;
begin
  select * into s from public.table_sessions where public_token=token and status='open' for update;
  if not found then raise exception 'This table session is closed'; end if;
  if jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 then raise exception 'The cart is empty'; end if;
  insert into public.orders(restaurant_id,session_id) values(s.restaurant_id,s.id) returning id into order_id;
  for entry in select * from jsonb_array_elements(items) loop
    qty:=coalesce((entry->>'quantity')::int,0);
    if qty<1 or qty>50 then raise exception 'Invalid quantity'; end if;
    select * into item from public.menu_items where id=(entry->>'menu_item_id')::uuid and restaurant_id=s.restaurant_id and available;
    if not found then raise exception 'A menu item is unavailable'; end if;
    select coalesce(c.preparation_area,'kitchen') into prep_area from public.menu_categories c where c.id=item.category_id;
    prep_area:=coalesce(prep_area,'kitchen');
    insert into public.order_items(order_id,menu_item_id,item_name_snapshot,unit_price_snapshot,quantity,special_instructions,preparation_area)
    values(order_id,item.id,item.name,item.price,qty,nullif(trim(entry->>'instructions'),''),prep_area);
    total:=total+(item.price*qty);
  end loop;
  return jsonb_build_object('order_id',order_id,'total',total,'status','pending');
end;
$$;

create or replace function public.create_customer_request(token uuid, request_kind public.request_type) returns uuid
language plpgsql security definer set search_path = public as $$
declare s public.table_sessions%rowtype; request_id uuid;
begin
  select * into s from public.table_sessions where public_token=token and status in ('open','bill_requested');
  if not found then raise exception 'This table session is closed'; end if;
  if exists(select 1 from public.customer_requests where session_id=s.id and type=request_kind and status='open') then
    select id into request_id from public.customer_requests where session_id=s.id and type=request_kind and status='open' order by created_at desc limit 1;
    return request_id;
  end if;
  insert into public.customer_requests(restaurant_id,session_id,type) values(s.restaurant_id,s.id,request_kind) returning id into request_id;
  if request_kind='bill' then update public.table_sessions set status='bill_requested' where id=s.id; end if;
  return request_id;
end;
$$;

create or replace function public.resolve_customer_request(target_request uuid) returns void
language plpgsql security definer set search_path = public as $$
declare request_row public.customer_requests%rowtype;
begin
  select * into request_row from public.customer_requests where id=target_request for update;
  if not found then raise exception 'Guest request not found'; end if;
  if not public.has_restaurant_role(request_row.restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]) then raise exception 'Not allowed'; end if;
  update public.customer_requests set status='resolved',acknowledged_by=coalesce(acknowledged_by,auth.uid()),acknowledged_at=coalesce(acknowledged_at,now()),resolved_by=auth.uid(),resolved_at=now() where id=target_request;
  if request_row.type='bill' then update public.table_sessions set status='open' where id=request_row.session_id and status='bill_requested'; end if;
end;
$$;

create or replace function public.set_order_status(target_order uuid, next_status public.order_status, reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare current_order public.orders%rowtype;
begin
  select * into current_order from public.orders where id=target_order for update;
  if not found then raise exception 'Order not found'; end if;
  if not public.has_restaurant_role(current_order.restaurant_id,array['owner','manager','waiter','kitchen','bar']::public.app_role[]) then raise exception 'Not allowed'; end if;
  if (current_order.status='pending' or next_status='served') and not public.has_restaurant_role(current_order.restaurant_id,array['owner','manager','waiter']::public.app_role[]) then raise exception 'Service staff access required'; end if;
  if next_status='rejected' and current_order.status='pending' then
    update public.orders set status='rejected',rejected_by=auth.uid(),rejected_at=now(),rejection_reason=nullif(trim(reason),'') where id=target_order;
    update public.order_items set preparation_status='rejected' where order_id=target_order and voided_at is null;
  elsif next_status='accepted' and current_order.status='pending' then
    update public.orders set status='accepted',accepted_by=auth.uid(),accepted_at=now() where id=target_order;
    update public.order_items set preparation_status='accepted' where order_id=target_order and voided_at is null;
  elsif next_status='preparing' and current_order.status='accepted' then update public.orders set status='preparing' where id=target_order;
  elsif next_status='ready' and current_order.status='preparing' then update public.orders set status='ready' where id=target_order;
  elsif next_status='served' and current_order.status='ready' then update public.orders set status='served' where id=target_order; update public.order_items set preparation_status='served' where order_id=target_order and voided_at is null;
  else raise exception 'Invalid order status change'; end if;
end;
$$;

create or replace function public.set_station_order_status(target_order uuid, station text, next_status text) returns void
language plpgsql security definer set search_path = public as $$
declare current_order public.orders%rowtype; current_station_status text; all_ready boolean;
begin
  if station not in ('kitchen','bar') or next_status not in ('preparing','ready') then raise exception 'Invalid preparation status'; end if;
  select * into current_order from public.orders where id=target_order for update;
  if not found then raise exception 'Order not found'; end if;
  if station='kitchen' and not public.has_restaurant_role(current_order.restaurant_id,array['owner','manager','kitchen']::public.app_role[]) then raise exception 'Kitchen access required'; end if;
  if station='bar' and not public.has_restaurant_role(current_order.restaurant_id,array['owner','manager','bar']::public.app_role[]) then raise exception 'Bar access required'; end if;
  if current_order.status not in ('accepted','preparing') then raise exception 'This order is not ready for preparation'; end if;
  select min(preparation_status) into current_station_status from public.order_items where order_id=target_order and preparation_area=station and voided_at is null;
  if current_station_status is null then raise exception 'No items for this preparation area'; end if;
  if next_status='preparing' and current_station_status<>'accepted' then raise exception 'Items have already started'; end if;
  if next_status='ready' and exists(select 1 from public.order_items where order_id=target_order and preparation_area=station and voided_at is null and preparation_status<>'preparing') then raise exception 'Start preparing these items first'; end if;
  update public.order_items set preparation_status=next_status where order_id=target_order and preparation_area=station and voided_at is null;
  select not exists(select 1 from public.order_items where order_id=target_order and voided_at is null and preparation_status<>'ready') into all_ready;
  update public.orders set status=case when all_ready then 'ready'::public.order_status else 'preparing'::public.order_status end where id=target_order;
end;
$$;

create or replace function public.void_order_item(target_item uuid, reason text) returns void
language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if length(trim(reason))<3 then raise exception 'A void reason is required'; end if;
  select o.restaurant_id into rid from public.order_items i join public.orders o on o.id=i.order_id where i.id=target_item;
  if not public.has_restaurant_role(rid,array['owner','manager','waiter']::public.app_role[]) then raise exception 'Not allowed'; end if;
  update public.order_items set voided_at=now(),voided_by=auth.uid(),void_reason=trim(reason) where id=target_item and voided_at is null;
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

create or replace function public.close_table_session(target_session uuid, method public.payment_method) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; subtotal numeric; discount_total numeric; taxable numeric; tax_total numeric; service_total numeric; final_total numeric;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found then raise exception 'Open session not found'; end if;
  if not public.has_restaurant_role(s.restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]) then raise exception 'Owner, manager, waiter or cashier access required'; end if;
  if exists(select 1 from public.orders where session_id=s.id and status='pending') then raise exception 'Resolve pending orders before closing the table'; end if;
  select * into r from public.restaurants where id=s.restaurant_id;
  select coalesce(sum(i.unit_price_snapshot*i.quantity),0) into subtotal from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  select coalesce(sum(amount_snapshot),0) into discount_total from public.applied_discounts where session_id=s.id;
  taxable:=greatest(subtotal-discount_total,0);
  tax_total:=round(taxable*coalesce(r.tax_percent,0)/100,2);
  service_total:=case when r.service_charge_value is null then 0 when r.service_charge_kind='percentage' then round(taxable*r.service_charge_value/100,2) else r.service_charge_value end;
  final_total:=taxable+tax_total+service_total;
  insert into public.payments(restaurant_id,session_id,method,amount,recorded_by) values(s.restaurant_id,s.id,method,final_total,auth.uid());
  update public.table_sessions set status='closed',closed_by=auth.uid(),closed_at=now(),subtotal_snapshot=subtotal,discount_snapshot=discount_total,tax_snapshot=tax_total,service_snapshot=service_total,total_snapshot=final_total where id=s.id;
  update public.customer_requests set status='resolved',resolved_by=auth.uid(),resolved_at=now() where session_id=s.id and status<>'resolved';
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details) values(s.restaurant_id,auth.uid(),'table.closed','table_session',s.id,jsonb_build_object('total',final_total,'payment_method',method));
  return jsonb_build_object(
    'session_id',s.id,
    'items',coalesce((select jsonb_agg(jsonb_build_object('name',i.item_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_snapshot) order by o.created_at,i.id) from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null),'[]'::jsonb),
    'subtotal',subtotal,'discount',discount_total,'tax',tax_total,'tax_configured',r.tax_percent is not null,'service_charge',service_total,'service_configured',r.service_charge_value is not null,'total',final_total,'payment_method',method
  );
end;
$$;

create view public.receipts with (security_invoker=true) as
select s.id,s.restaurant_id,s.table_id,t.label as table_label,s.opened_at,s.closed_at,s.subtotal_snapshot,s.discount_snapshot,s.tax_snapshot,s.service_snapshot,s.total_snapshot,p.method as payment_method,p.recorded_at,s.assigned_waiter_id,s.assigned_waiter_name
from public.table_sessions s join public.physical_tables t on t.id=s.table_id left join public.payments p on p.session_id=s.id where s.status='closed';

alter table public.profiles enable row level security;
alter table public.restaurants enable row level security;
alter table public.restaurant_members enable row level security;
alter table public.staff_invitations enable row level security;
alter table public.physical_tables enable row level security;
alter table public.table_sessions enable row level security;
alter table public.menu_categories enable row level security;
alter table public.menu_items enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.discounts enable row level security;
alter table public.applied_discounts enable row level security;
alter table public.customer_requests enable row level security;
alter table public.payments enable row level security;
alter table public.audit_logs enable row level security;
alter table public.owner_payments enable row level security;
alter table public.menu_design_versions enable row level security;

create policy profiles_read on public.profiles for select using(id=auth.uid() or public.is_super_admin() or exists(select 1 from public.restaurant_members mine join public.restaurant_members theirs on theirs.restaurant_id=mine.restaurant_id where mine.user_id=auth.uid() and theirs.user_id=profiles.id and mine.active));
create policy profiles_self_update on public.profiles for update using(id=auth.uid()) with check(id=auth.uid());
create policy restaurants_read on public.restaurants for select using(public.is_super_admin() or public.has_restaurant_role(id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy restaurants_owner_update on public.restaurants for update using(public.has_restaurant_role(id,array['owner']::public.app_role[]));
create policy restaurants_admin_update on public.restaurants for update using(public.is_super_admin()) with check(public.is_super_admin());
create policy restaurants_admin_delete on public.restaurants for delete using(public.is_super_admin());
create policy members_read on public.restaurant_members for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy members_owner_manage on public.restaurant_members for update
using(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]) or (role not in ('owner','manager') and public.has_restaurant_role(restaurant_id,array['manager']::public.app_role[])))
with check(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]) or (role not in ('owner','manager') and public.has_restaurant_role(restaurant_id,array['manager']::public.app_role[])));
create policy invitations_read on public.staff_invitations for select using(public.is_super_admin() or public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[]));
create policy invitations_admin_update on public.staff_invitations for update using(public.is_super_admin()) with check(public.is_super_admin());
create policy tables_read on public.physical_tables for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy tables_insert on public.physical_tables for insert with check(public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[]));
create policy tables_owner_update on public.physical_tables for update using(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[])) with check(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]));
create policy tables_owner_delete on public.physical_tables for delete using(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]));
create policy sessions_read on public.table_sessions for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy categories_read on public.menu_categories for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy categories_manage on public.menu_categories for all using(public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[])) with check(public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[]));
create policy items_read on public.menu_items for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy items_manage on public.menu_items for all using(public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[])) with check(public.has_restaurant_role(restaurant_id,array['owner','manager']::public.app_role[]));
create policy orders_read on public.orders for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[]));
create policy order_items_read on public.order_items for select using(exists(select 1 from public.orders o where o.id=order_id and public.has_restaurant_role(o.restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']::public.app_role[])));
create policy discounts_read on public.discounts for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]));
create policy discounts_manage on public.discounts for all using(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[])) with check(public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]));
create policy applied_discounts_read on public.applied_discounts for select using(exists(select 1 from public.table_sessions s where s.id=session_id and public.has_restaurant_role(s.restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[])));
create policy requests_read on public.customer_requests for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]));
create policy requests_update on public.customer_requests for update using(public.has_restaurant_role(restaurant_id,array['owner','manager','waiter','cashier']::public.app_role[]));
create policy payments_read on public.payments for select using(public.has_restaurant_role(restaurant_id,array['owner','manager','cashier']::public.app_role[]));
create policy audit_read on public.audit_logs for select using(public.is_super_admin() or public.has_restaurant_role(restaurant_id,array['owner']::public.app_role[]));
create policy owner_payments_admin on public.owner_payments for all using(public.is_super_admin()) with check(public.is_super_admin());
create policy menu_design_versions_admin on public.menu_design_versions for all using(public.is_super_admin()) with check(public.is_super_admin());

-- Browser access is still controlled by every row-level security policy above.
-- Anonymous guests use only the three token-protected functions below.
revoke all on all tables in schema public from anon;
grant select,insert,update,delete on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.physical_tables,public.table_sessions,public.menu_categories,public.menu_items,public.orders,public.order_items,public.discounts,public.applied_discounts,public.customer_requests,public.payments,public.audit_logs,public.owner_payments,public.menu_design_versions to authenticated;
grant select on public.receipts to authenticated;
revoke update on public.profiles,public.restaurants,public.restaurant_members,public.staff_invitations,public.customer_requests from authenticated;
grant update(full_name,phone) on public.profiles to authenticated;
grant update(tax_percent,service_charge_kind,service_charge_value) on public.restaurants to authenticated;
grant update(active) on public.restaurant_members to authenticated;
grant update(phone) on public.staff_invitations to authenticated;
grant update(status,acknowledged_by,acknowledged_at,resolved_by,resolved_at) on public.customer_requests to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('menu-images','menu-images',true,5242880,array['image/jpeg','image/png','image/webp','image/gif'])
on conflict(id) do update set public=true,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy dineqr_menu_images_public_read on storage.objects for select using(bucket_id='menu-images');
create policy dineqr_menu_images_staff_insert on storage.objects for insert to authenticated with check(bucket_id='menu-images' and (public.is_super_admin() or exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager'))));
create policy dineqr_menu_images_staff_update on storage.objects for update to authenticated using(bucket_id='menu-images' and (public.is_super_admin() or exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager')))) with check(bucket_id='menu-images' and (public.is_super_admin() or exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager'))));
create policy dineqr_menu_images_staff_delete on storage.objects for delete to authenticated using(bucket_id='menu-images' and (public.is_super_admin() or exists(select 1 from public.restaurant_members m where m.user_id=auth.uid() and m.active and m.restaurant_id::text=(storage.foldername(name))[1] and m.role in ('owner','manager'))));

revoke all on function public.get_public_session(uuid) from public;
revoke all on function public.get_customer_order_history(uuid) from public;
revoke all on function public.place_customer_order(uuid,jsonb) from public;
revoke all on function public.create_customer_request(uuid,public.request_type) from public;
revoke all on function public.resolve_customer_request(uuid) from public;
revoke all on function public.get_public_invitation(uuid) from public;
revoke all on function public.get_my_context() from public;
revoke all on function public.create_restaurant_company(text,text,text,text) from public;
revoke all on function public.admin_set_restaurant_status(uuid,boolean) from public;
revoke all on function public.admin_update_restaurant_company(uuid,text,text,text,date) from public;
revoke all on function public.admin_update_menu_appearance(uuid,jsonb) from public;
revoke all on function public.admin_get_menu_design(uuid) from public;
revoke all on function public.admin_save_menu_design_draft(uuid,jsonb,text) from public;
revoke all on function public.admin_publish_menu_design(uuid,boolean) from public;
revoke all on function public.admin_restore_menu_design_version(uuid,uuid) from public;
revoke all on function public.admin_set_restaurant_expiry(uuid,date) from public;
revoke all on function public.assign_waiter_to_session(uuid,uuid) from public;
revoke all on function public.invite_staff(uuid,text,text,text,public.app_role) from public;
revoke all on function public.edit_restaurant_staff(uuid,uuid,text,text,public.app_role) from public;
revoke all on function public.edit_staff_invitation(uuid,text,text,public.app_role) from public;
revoke all on function public.open_table_session(uuid) from public;
revoke all on function public.set_order_status(uuid,public.order_status,text) from public;
revoke all on function public.set_station_order_status(uuid,text,text) from public;
revoke all on function public.void_order_item(uuid,text) from public;
revoke all on function public.apply_discount_to_session(uuid,uuid) from public;
revoke all on function public.close_table_session(uuid,public.payment_method) from public;
grant execute on function public.get_public_session(uuid) to anon,authenticated;
grant execute on function public.get_customer_order_history(uuid) to anon,authenticated;
grant execute on function public.place_customer_order(uuid,jsonb) to anon,authenticated;
grant execute on function public.create_customer_request(uuid,public.request_type) to anon,authenticated;
grant execute on function public.resolve_customer_request(uuid) to authenticated;
grant execute on function public.get_public_invitation(uuid) to anon,authenticated;
grant execute on function public.get_my_context() to authenticated;
grant execute on function public.create_restaurant_company(text,text,text,text) to authenticated;
grant execute on function public.admin_set_restaurant_status(uuid,boolean) to authenticated;
grant execute on function public.admin_update_restaurant_company(uuid,text,text,text,date) to authenticated;
grant execute on function public.admin_update_menu_appearance(uuid,jsonb) to authenticated;
grant execute on function public.admin_get_menu_design(uuid) to authenticated;
grant execute on function public.admin_save_menu_design_draft(uuid,jsonb,text) to authenticated;
grant execute on function public.admin_publish_menu_design(uuid,boolean) to authenticated;
grant execute on function public.admin_restore_menu_design_version(uuid,uuid) to authenticated;
grant execute on function public.admin_set_restaurant_expiry(uuid,date) to authenticated;
grant execute on function public.assign_waiter_to_session(uuid,uuid) to authenticated;
grant execute on function public.invite_staff(uuid,text,text,text,public.app_role) to authenticated;
grant execute on function public.edit_restaurant_staff(uuid,uuid,text,text,public.app_role) to authenticated;
grant execute on function public.edit_staff_invitation(uuid,text,text,public.app_role) to authenticated;
grant execute on function public.open_table_session(uuid) to authenticated;
grant execute on function public.set_order_status(uuid,public.order_status,text) to authenticated;
grant execute on function public.set_station_order_status(uuid,text,text) to authenticated;
grant execute on function public.void_order_item(uuid,text) to authenticated;
grant execute on function public.apply_discount_to_session(uuid,uuid) to authenticated;
grant execute on function public.close_table_session(uuid,public.payment_method) to authenticated;

do $$
declare realtime_table text;
begin
  foreach realtime_table in array array[
    'profiles','restaurants','restaurant_members','staff_invitations','physical_tables','table_sessions',
    'menu_categories','menu_items','orders','order_items','discounts','applied_discounts',
    'customer_requests','payments','owner_payments'
  ] loop
    if not exists(
      select 1 from pg_publication_tables
      where pubname='supabase_realtime' and schemaname='public' and tablename=realtime_table
    ) then
      execute format('alter publication supabase_realtime add table public.%I',realtime_table);
    end if;
  end loop;
end $$;

-- IMPORTANT FIRST-TIME SETUP
-- 1. Run this whole file.
-- 2. Create your own account on signup.html.
-- 3. Return to SQL Editor and run the line below after replacing the email:
-- update public.profiles set platform_role='super_admin' where lower(email)=lower('YOUR-EMAIL@example.com');
