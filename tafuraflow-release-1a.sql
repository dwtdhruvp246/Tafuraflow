-- TafuraFlow Release 1A: Menu and Service Foundations
-- Run after 20260718190000_invites_company_billing.sql.
-- Additive and safe to run once on an existing TafuraFlow database.

create table public.prep_stations (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  station_key text not null check (station_key ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  station_group text not null check (station_group in ('kitchen','bar')),
  color text not null default '#9A4632' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  sort_order integer not null default 0,
  active boolean not null default true,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(restaurant_id,station_key),
  unique(restaurant_id,name)
);

insert into public.prep_stations(restaurant_id,name,station_key,station_group,color,sort_order,is_default)
select id,'Kitchen','kitchen','kitchen','#A34A32',10,true from public.restaurants
on conflict(restaurant_id,station_key) do nothing;

insert into public.prep_stations(restaurant_id,name,station_key,station_group,color,sort_order,is_default)
select id,'Bar','bar','bar','#456A74',20,true from public.restaurants
on conflict(restaurant_id,station_key) do nothing;

create or replace function public.create_default_prep_stations() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  insert into public.prep_stations(restaurant_id,name,station_key,station_group,color,sort_order,is_default)
  values(new.id,'Kitchen','kitchen','kitchen','#A34A32',10,true),(new.id,'Bar','bar','bar','#456A74',20,true)
  on conflict(restaurant_id,station_key) do nothing;
  return new;
end; $$;

drop trigger if exists create_default_prep_stations_trigger on public.restaurants;
create trigger create_default_prep_stations_trigger after insert on public.restaurants for each row execute function public.create_default_prep_stations();

alter table public.menu_categories add column prep_station_id uuid references public.prep_stations(id) on delete set null;
alter table public.menu_items add column prep_station_id uuid references public.prep_stations(id) on delete set null;
alter table public.menu_items add column availability_status text not null default 'available';
alter table public.menu_items add column snoozed_until timestamptz;
alter table public.menu_items add column quantity_available integer;
alter table public.menu_items add constraint menu_items_availability_status_check check(availability_status in ('available','sold_out','snoozed'));
alter table public.menu_items add constraint menu_items_quantity_available_check check(quantity_available is null or quantity_available>=0);

update public.menu_categories c set prep_station_id=s.id
from public.prep_stations s
where s.restaurant_id=c.restaurant_id and s.station_key=c.preparation_area and c.prep_station_id is null;

create or replace function public.sync_category_prep_station() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.prep_station_id is null or (tg_op='UPDATE' and old.preparation_area is distinct from new.preparation_area) then
    select id into new.prep_station_id from public.prep_stations where restaurant_id=new.restaurant_id and station_key=new.preparation_area limit 1;
  end if;
  return new;
end; $$;

drop trigger if exists sync_category_prep_station_trigger on public.menu_categories;
create trigger sync_category_prep_station_trigger before insert or update on public.menu_categories for each row execute function public.sync_category_prep_station();

create or replace function public.validate_menu_station_route() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.prep_station_id is not null and not exists(select 1 from public.prep_stations s where s.id=new.prep_station_id and s.restaurant_id=new.restaurant_id) then
    raise exception 'Preparation station must belong to this restaurant';
  end if;
  return new;
end; $$;

drop trigger if exists validate_category_station_route_trigger on public.menu_categories;
create trigger validate_category_station_route_trigger before insert or update on public.menu_categories for each row execute function public.validate_menu_station_route();
drop trigger if exists validate_item_station_route_trigger on public.menu_items;
create trigger validate_item_station_route_trigger before insert or update on public.menu_items for each row execute function public.validate_menu_station_route();

create table public.modifier_groups (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  description text,
  required boolean not null default false,
  min_selections integer not null default 0 check(min_selections>=0),
  max_selections integer not null default 1 check(max_selections between 1 and 20),
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(restaurant_id,name),
  check(min_selections<=max_selections),
  check(not required or min_selections>=1)
);

create table public.modifiers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  group_id uuid not null references public.modifier_groups(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  price_adjustment numeric(12,2) not null default 0,
  sort_order integer not null default 0,
  available boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(group_id,name)
);

create table public.menu_item_modifier_groups (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  modifier_group_id uuid not null references public.modifier_groups(id) on delete cascade,
  sort_order integer not null default 0,
  primary key(menu_item_id,modifier_group_id)
);

alter table public.table_sessions add column guest_count integer;
alter table public.table_sessions add constraint table_sessions_guest_count_check check(guest_count is null or guest_count between 1 and 100);
alter table public.orders add column source text not null default 'customer';
alter table public.orders add column client_request_id uuid;
alter table public.orders add constraint orders_source_check check(source in ('customer','staff'));
create unique index orders_session_client_request_unique on public.orders(session_id,client_request_id) where client_request_id is not null;

alter table public.order_items add column prep_station_id uuid references public.prep_stations(id) on delete set null;
alter table public.order_items add column prep_station_name_snapshot text;

update public.order_items i set prep_station_id=s.id,prep_station_name_snapshot=s.name
from public.orders o,public.prep_stations s
where o.id=i.order_id and s.restaurant_id=o.restaurant_id and s.station_key=i.preparation_area and i.prep_station_id is null;

create table public.order_item_modifiers (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null references public.order_items(id) on delete cascade,
  modifier_id uuid references public.modifiers(id) on delete set null,
  modifier_name_snapshot text not null,
  price_adjustment_snapshot numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

alter table public.customer_requests alter column type type text using type::text;
alter table public.customer_requests add column note text;
alter table public.customer_requests add column due_at timestamptz;
alter table public.customer_requests add constraint customer_requests_type_check check(type in ('waiter','bill','water','cutlery','condiments','clear_table','other'));
alter table public.customer_requests add constraint customer_requests_note_check check(note is null or length(note)<=240);

create table public.table_session_events (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_type text not null default 'system' check(actor_type in ('customer','staff','system')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.order_events (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_type text not null default 'system' check(actor_type in ('customer','staff','system')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.order_item_events (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  order_item_id uuid not null references public.order_items(id) on delete cascade,
  event_type text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  actor_type text not null default 'system' check(actor_type in ('customer','staff','system')),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index prep_stations_restaurant_order_idx on public.prep_stations(restaurant_id,sort_order);
create index modifier_groups_restaurant_order_idx on public.modifier_groups(restaurant_id,sort_order);
create index modifiers_group_order_idx on public.modifiers(group_id,sort_order);
create index order_item_modifiers_item_idx on public.order_item_modifiers(order_item_id);
create index customer_requests_session_created_idx on public.customer_requests(session_id,created_at desc);
create index session_events_session_time_idx on public.table_session_events(session_id,created_at);
create index order_events_order_time_idx on public.order_events(order_id,created_at);
create index item_events_item_time_idx on public.order_item_events(order_item_id,created_at);

create or replace function public.capture_table_session_event() returns trigger
language plpgsql security definer set search_path=public as $$
declare kind text; detail jsonb;
begin
  if tg_op='INSERT' then kind:='session.opened'; detail:=jsonb_build_object('status',new.status,'guest_count',new.guest_count,'assigned_waiter_id',new.assigned_waiter_id);
  elsif old.status is distinct from new.status then kind:='session.status_changed'; detail:=jsonb_build_object('from',old.status,'to',new.status);
  elsif old.assigned_waiter_id is distinct from new.assigned_waiter_id then kind:='session.waiter_assigned'; detail:=jsonb_build_object('from',old.assigned_waiter_id,'to',new.assigned_waiter_id,'waiter_name',new.assigned_waiter_name);
  elsif old.guest_count is distinct from new.guest_count then kind:='session.guest_count_changed'; detail:=jsonb_build_object('from',old.guest_count,'to',new.guest_count);
  else return new; end if;
  insert into public.table_session_events(restaurant_id,session_id,event_type,actor_id,actor_type,details)
  values(new.restaurant_id,new.id,kind,auth.uid(),case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

create or replace function public.capture_order_event() returns trigger
language plpgsql security definer set search_path=public as $$
declare kind text; detail jsonb;
begin
  if tg_op='INSERT' then kind:='order.submitted'; detail:=jsonb_build_object('status',new.status,'source',new.source);
  elsif old.status is distinct from new.status then
    kind:='order.status_changed'; detail:=jsonb_build_object('from',old.status,'to',new.status,'reason',new.rejection_reason);
    if new.status='rejected' and old.status<>'rejected' then
      update public.menu_items mi set quantity_available=mi.quantity_available+stock.quantity,availability_status=case when mi.availability_status='sold_out' then 'available' else mi.availability_status end
      from (select menu_item_id,sum(quantity)::integer as quantity from public.order_items where order_id=new.id and voided_at is null and menu_item_id is not null group by menu_item_id) stock
      where mi.id=stock.menu_item_id and mi.quantity_available is not null;
    end if;
  else return new; end if;
  insert into public.order_events(restaurant_id,order_id,event_type,actor_id,actor_type,details)
  values(new.restaurant_id,new.id,kind,auth.uid(),case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

create or replace function public.capture_order_item_event() returns trigger
language plpgsql security definer set search_path=public as $$
declare rid uuid; kind text; detail jsonb;
begin
  select restaurant_id into rid from public.orders where id=new.order_id;
  if tg_op='INSERT' then kind:='item.created'; detail:=jsonb_build_object('status',new.preparation_status,'station',new.prep_station_name_snapshot,'quantity',new.quantity);
  elsif old.voided_at is null and new.voided_at is not null then
    kind:='item.voided'; detail:=jsonb_build_object('reason',new.void_reason);
    if new.menu_item_id is not null and not exists(select 1 from public.orders where id=new.order_id and status='rejected') then
      update public.menu_items set quantity_available=quantity_available+new.quantity,availability_status=case when availability_status='sold_out' then 'available' else availability_status end where id=new.menu_item_id and quantity_available is not null;
    end if;
  elsif old.preparation_status is distinct from new.preparation_status then kind:='item.status_changed'; detail:=jsonb_build_object('from',old.preparation_status,'to',new.preparation_status,'station',new.prep_station_name_snapshot);
  else return new; end if;
  insert into public.order_item_events(restaurant_id,order_item_id,event_type,actor_id,actor_type,details)
  values(rid,new.id,kind,auth.uid(),case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

drop trigger if exists capture_table_session_event_trigger on public.table_sessions;
create trigger capture_table_session_event_trigger after insert or update on public.table_sessions for each row execute function public.capture_table_session_event();
drop trigger if exists capture_order_event_trigger on public.orders;
create trigger capture_order_event_trigger after insert or update on public.orders for each row execute function public.capture_order_event();
drop trigger if exists capture_order_item_event_trigger on public.order_items;
create trigger capture_order_item_event_trigger after insert or update on public.order_items for each row execute function public.capture_order_item_event();

create or replace function public.open_table_session_v2(target_table uuid, guests integer default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare tbl public.physical_tables%rowtype; session_row public.table_sessions%rowtype; opener_waiter_name text;
begin
  select * into tbl from public.physical_tables where id=target_table and active;
  if not found then raise exception 'Table not found'; end if;
  if not public.has_restaurant_text_role(tbl.restaurant_id,array['owner','manager','waiter']) then raise exception 'Not allowed'; end if;
  if guests is not null and (guests<1 or guests>tbl.seats) then raise exception 'Guest count must be between 1 and the table capacity'; end if;
  if exists(select 1 from public.table_sessions where table_id=target_table and status<>'closed') then raise exception 'Table is already open'; end if;
  select p.full_name into opener_waiter_name from public.restaurant_members m join public.profiles p on p.id=m.user_id
  where m.restaurant_id=tbl.restaurant_id and m.user_id=auth.uid() and m.role='waiter' and m.active;
  insert into public.table_sessions(restaurant_id,table_id,opened_by,assigned_waiter_id,assigned_waiter_name,guest_count)
  values(tbl.restaurant_id,tbl.id,auth.uid(),case when opener_waiter_name is null then null else auth.uid() end,opener_waiter_name,guests) returning * into session_row;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details) values(tbl.restaurant_id,auth.uid(),'table.opened','table_session',session_row.id,jsonb_build_object('guest_count',guests));
  return jsonb_build_object('session_id',session_row.id,'public_token',session_row.public_token,'table_label',tbl.label,'assigned_waiter_name',session_row.assigned_waiter_name,'guest_count',guests);
end; $$;

create or replace function public.get_public_session(token uuid) returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; table_label text; result jsonb;
begin
  select * into s from public.table_sessions where public_token=token and status in ('open','bill_requested');
  if not found then return null; end if;
  select * into r from public.restaurants where id=s.restaurant_id and active and (subscription_expires_at is null or subscription_expires_at>=current_date);
  if not found then return null; end if;
  select label into table_label from public.physical_tables where id=s.table_id;
  select jsonb_build_object(
    'session_id',s.id,'session_status',s.status,'restaurant_id',r.id,'restaurant_name',r.name,'currency',r.currency,'guest_count',s.guest_count,
    'tax_percent',r.tax_percent,'service_charge_kind',r.service_charge_kind,'service_charge_value',r.service_charge_value,'table_label',table_label,
    'menu_theme',r.menu_theme,'menu_accent_color',r.menu_accent_color,'menu_layout',r.menu_layout,'menu_tagline',r.menu_tagline,'menu_logo_url',r.menu_logo_url,'menu_hero_url',r.menu_hero_url,'menu_show_images',r.menu_show_images,
    'menu_font_style',r.menu_font_style,'menu_header_style',r.menu_header_style,'menu_category_style',r.menu_category_style,'menu_card_style',r.menu_card_style,'menu_image_shape',r.menu_image_shape,'menu_hero_style',r.menu_hero_style,'menu_background_style',r.menu_background_style,'menu_show_hero',r.menu_show_hero,'menu_show_descriptions',r.menu_show_descriptions,'menu_address',r.menu_address,'menu_phone',r.menu_phone,'menu_hours',r.menu_hours,'menu_social_url',r.menu_social_url,'menu_design',r.menu_design_published,'menu_design_template',r.menu_design_template,
    'categories',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'name',c.name,'sort_order',c.sort_order) order by c.sort_order,c.name) from public.menu_categories c where c.restaurant_id=r.id and c.active),'[]'::jsonb),
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'id',i.id,'category_id',i.category_id,'name',i.name,'description',i.description,'price',i.price,'image_url',i.image_url,'sort_order',i.sort_order,
      'quantity_available',i.quantity_available,'station_name',coalesce(si.name,sc.name,'Kitchen'),
      'modifier_groups',coalesce((select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name,'description',g.description,'required',g.required,'min_selections',g.min_selections,'max_selections',g.max_selections,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'price_adjustment',m.price_adjustment) order by m.sort_order,m.name) from public.modifiers m where m.group_id=g.id and m.available),'[]'::jsonb)) order by link.sort_order,g.sort_order,g.name) from public.menu_item_modifier_groups link join public.modifier_groups g on g.id=link.modifier_group_id and g.active where link.menu_item_id=i.id),'[]'::jsonb)
    ) order by i.sort_order,i.name) from public.menu_items i left join public.menu_categories c on c.id=i.category_id left join public.prep_stations si on si.id=i.prep_station_id left join public.prep_stations sc on sc.id=c.prep_station_id where i.restaurant_id=r.id and i.available and i.availability_status<>'sold_out' and (i.availability_status<>'snoozed' or i.snoozed_until<=now()) and (i.quantity_available is null or i.quantity_available>0)),'[]'::jsonb),
    'orders',coalesce((select jsonb_agg(jsonb_build_object('id',o.id,'order_number',o.order_number,'status',o.status,'source',o.source,'created_at',o.created_at,'rejection_reason',o.rejection_reason,'total',coalesce((select sum(oi.unit_price_snapshot*oi.quantity) from public.order_items oi where oi.order_id=o.id and oi.voided_at is null),0),'items',coalesce((select jsonb_agg(jsonb_build_object('id',oi.id,'name',oi.item_name_snapshot,'price',oi.unit_price_snapshot,'quantity',oi.quantity,'instructions',oi.special_instructions,'station',oi.prep_station_name_snapshot,'voided',oi.voided_at is not null,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',om.modifier_name_snapshot,'price_adjustment',om.price_adjustment_snapshot) order by om.id) from public.order_item_modifiers om where om.order_item_id=oi.id),'[]'::jsonb)) order by oi.id) from public.order_items oi where oi.order_id=o.id),'[]'::jsonb)) order by o.created_at desc) from public.orders o where o.session_id=s.id),'[]'::jsonb)
  ) into result;
  return result;
end; $$;

create or replace function public.get_customer_order_history(token uuid) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number',o.order_number,'status',o.status,'source',o.source,'created_at',o.created_at,'rejection_reason',o.rejection_reason,'total',coalesce((select sum(oi.unit_price_snapshot*oi.quantity) from public.order_items oi where oi.order_id=o.id and oi.voided_at is null),0),'items',coalesce((select jsonb_agg(jsonb_build_object('id',oi.id,'name',oi.item_name_snapshot,'price',oi.unit_price_snapshot,'quantity',oi.quantity,'instructions',oi.special_instructions,'station',oi.prep_station_name_snapshot,'voided',oi.voided_at is not null,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',om.modifier_name_snapshot,'price_adjustment',om.price_adjustment_snapshot) order by om.id) from public.order_item_modifiers om where om.order_item_id=oi.id),'[]'::jsonb)) order by oi.id) from public.order_items oi where oi.order_id=o.id),'[]'::jsonb)) order by o.created_at desc),'[]'::jsonb)
  from public.orders o join public.table_sessions s on s.id=o.session_id join public.restaurants r on r.id=s.restaurant_id and r.active and (r.subscription_expires_at is null or r.subscription_expires_at>=current_date)
  where s.public_token=$1 and s.status in ('open','bill_requested');
$$;

create or replace function public.place_customer_order_v2(token uuid, items jsonb, idempotency_key uuid, requested_source text default 'customer') returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.table_sessions%rowtype; order_id uuid; existing_order public.orders%rowtype; entry jsonb; item public.menu_items%rowtype; qty int; total numeric:=0; station public.prep_stations%rowtype; order_item_id uuid; selected_ids uuid[]; selected_count int; linked_count int; group_row public.modifier_groups%rowtype; modifier_total numeric; selected_modifier record; actual_source text:='customer'; total_quantity int:=0;
begin
  select * into s from public.table_sessions where public_token=token and status='open' for update;
  if not found then raise exception 'This table session is closed'; end if;
  if idempotency_key is null then raise exception 'A request identifier is required'; end if;
  select * into existing_order from public.orders where session_id=s.id and client_request_id=idempotency_key;
  if found then return jsonb_build_object('order_id',existing_order.id,'total',coalesce((select sum(unit_price_snapshot*quantity) from public.order_items where order_id=existing_order.id and voided_at is null),0),'status',existing_order.status,'duplicate',true); end if;
  if (select count(*) from public.orders where session_id=s.id and created_at>now()-interval '1 minute')>=6 then raise exception 'Too many orders were sent. Please wait a minute and try again'; end if;
  if jsonb_typeof(items)<>'array' or jsonb_array_length(items)=0 or jsonb_array_length(items)>30 then raise exception 'The cart is empty or contains too many lines'; end if;
  if requested_source='staff' and auth.uid() is not null and public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter']) then actual_source:='staff'; end if;
  insert into public.orders(restaurant_id,session_id,source,client_request_id) values(s.restaurant_id,s.id,actual_source,idempotency_key) returning id into order_id;
  for entry in select * from jsonb_array_elements(items) loop
    qty:=coalesce((entry->>'quantity')::int,0); total_quantity:=total_quantity+qty;
    if qty<1 or qty>50 or total_quantity>100 then raise exception 'Please choose a valid item quantity'; end if;
    select * into item from public.menu_items where id=(entry->>'menu_item_id')::uuid and restaurant_id=s.restaurant_id and available and availability_status<>'sold_out' and (availability_status<>'snoozed' or snoozed_until<=now()) for update;
    if not found or (item.quantity_available is not null and item.quantity_available<qty) then raise exception 'A menu item is unavailable or has insufficient quantity'; end if;
    select coalesce(array_agg(value::uuid),'{}'::uuid[]) into selected_ids from jsonb_array_elements_text(coalesce(entry->'modifiers','[]'::jsonb));
    select count(*) into linked_count from public.modifiers m join public.modifier_groups g on g.id=m.group_id and g.active join public.menu_item_modifier_groups l on l.modifier_group_id=g.id and l.menu_item_id=item.id where m.id=any(selected_ids) and m.available and m.restaurant_id=s.restaurant_id;
    if linked_count<>coalesce(array_length(selected_ids,1),0) then raise exception 'One of the selected options is unavailable'; end if;
    for group_row in select g.* from public.menu_item_modifier_groups l join public.modifier_groups g on g.id=l.modifier_group_id and g.active where l.menu_item_id=item.id loop
      select count(*) into selected_count from public.modifiers m where m.group_id=group_row.id and m.id=any(selected_ids);
      if selected_count<group_row.min_selections or selected_count>group_row.max_selections then raise exception 'Please complete the % options',group_row.name; end if;
    end loop;
    select coalesce(sum(price_adjustment),0) into modifier_total from public.modifiers where id=any(selected_ids);
    if item.price+modifier_total<0 then raise exception 'Selected options cannot make an item price negative'; end if;
    select ps.* into station
    from public.menu_items mi
    left join public.menu_categories c on c.id=mi.category_id
    join public.prep_stations ps on ps.id=coalesce(mi.prep_station_id,c.prep_station_id,(select d.id from public.prep_stations d where d.restaurant_id=mi.restaurant_id and d.station_key='kitchen' limit 1))
    where mi.id=item.id;
    if station.id is null then select * into station from public.prep_stations where restaurant_id=s.restaurant_id and station_key='kitchen'; end if;
    insert into public.order_items(order_id,menu_item_id,item_name_snapshot,unit_price_snapshot,quantity,special_instructions,preparation_area,prep_station_id,prep_station_name_snapshot)
    values(order_id,item.id,item.name,item.price+modifier_total,qty,nullif(trim(entry->>'instructions'),''),coalesce(station.station_group,'kitchen'),station.id,coalesce(station.name,'Kitchen')) returning id into order_item_id;
    for selected_modifier in select * from public.modifiers where id=any(selected_ids) loop
      insert into public.order_item_modifiers(order_item_id,modifier_id,modifier_name_snapshot,price_adjustment_snapshot) values(order_item_id,selected_modifier.id,selected_modifier.name,selected_modifier.price_adjustment);
    end loop;
    if item.quantity_available is not null then update public.menu_items set quantity_available=quantity_available-qty,availability_status=case when quantity_available-qty=0 then 'sold_out' else availability_status end where id=item.id; end if;
    total:=total+((item.price+modifier_total)*qty);
  end loop;
  return jsonb_build_object('order_id',order_id,'total',total,'status','pending','duplicate',false);
exception when others then
  raise;
end; $$;

create or replace function public.place_customer_order(token uuid,items jsonb) returns jsonb
language sql security definer set search_path=public as $$ select public.place_customer_order_v2($1,$2,gen_random_uuid(),'customer'); $$;

create or replace function public.create_customer_request_v2(token uuid,request_kind text,request_note text default null) returns uuid
language plpgsql security definer set search_path=public as $$
declare s public.table_sessions%rowtype; request_id uuid; allowed text[]:=array['waiter','bill','water','cutlery','condiments','clear_table','other'];
begin
  if not request_kind=any(allowed) then raise exception 'Please choose a valid service request'; end if;
  if request_kind='other' and length(trim(coalesce(request_note,'')))<3 then raise exception 'Please tell the waiter what you need'; end if;
  select * into s from public.table_sessions where public_token=token and status in ('open','bill_requested');
  if not found then raise exception 'This table session is closed'; end if;
  if (select count(*) from public.customer_requests where session_id=s.id and created_at>now()-interval '5 minutes')>=8 then raise exception 'Too many requests were sent. Please wait a moment'; end if;
  select id into request_id from public.customer_requests where session_id=s.id and type=request_kind and status='open' order by created_at desc limit 1;
  if request_id is not null then return request_id; end if;
  insert into public.customer_requests(restaurant_id,session_id,type,note,due_at) values(s.restaurant_id,s.id,request_kind,nullif(trim(request_note),''),now()+interval '3 minutes') returning id into request_id;
  if request_kind='bill' then update public.table_sessions set status='bill_requested' where id=s.id; end if;
  return request_id;
end; $$;

create or replace function public.create_customer_request(token uuid,request_kind public.request_type) returns uuid
language sql security definer set search_path=public as $$ select public.create_customer_request_v2($1,$2::text,null); $$;

create or replace function public.set_station_order_status_v2(target_order uuid,target_station uuid,next_status text) returns void
language plpgsql security definer set search_path=public as $$
declare current_order public.orders%rowtype; station public.prep_stations%rowtype; current_station_status text; all_ready boolean;
begin
  if next_status not in ('preparing','ready') then raise exception 'Invalid preparation status'; end if;
  select * into current_order from public.orders where id=target_order for update;
  select * into station from public.prep_stations where id=target_station and restaurant_id=current_order.restaurant_id and active;
  if current_order.id is null or station.id is null then raise exception 'Order or preparation station not found'; end if;
  if not public.has_restaurant_text_role(current_order.restaurant_id,array['owner','manager',station.station_group]) then raise exception 'Preparation-station access required'; end if;
  if current_order.status not in ('accepted','preparing') then raise exception 'This order is not ready for preparation'; end if;
  select min(preparation_status) into current_station_status from public.order_items where order_id=target_order and prep_station_id=target_station and voided_at is null;
  if current_station_status is null then raise exception 'No items for this preparation station'; end if;
  if next_status='preparing' and current_station_status<>'accepted' then raise exception 'Items have already started'; end if;
  if next_status='ready' and exists(select 1 from public.order_items where order_id=target_order and prep_station_id=target_station and voided_at is null and preparation_status<>'preparing') then raise exception 'Start preparing these items first'; end if;
  update public.order_items set preparation_status=next_status where order_id=target_order and prep_station_id=target_station and voided_at is null;
  select not exists(select 1 from public.order_items where order_id=target_order and voided_at is null and preparation_status<>'ready') into all_ready;
  update public.orders set status=case when all_ready then 'ready'::public.order_status else 'preparing'::public.order_status end where id=target_order;
end; $$;

create or replace function public.set_menu_item_availability(target_item uuid,new_status text,snooze_until timestamptz default null,remaining_quantity integer default null) returns void
language plpgsql security definer set search_path=public as $$
declare item public.menu_items%rowtype;
begin
  select * into item from public.menu_items where id=target_item;
  if not found then raise exception 'Menu item not found'; end if;
  if not public.has_restaurant_text_role(item.restaurant_id,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
  if new_status not in ('available','sold_out','snoozed') then raise exception 'Please choose a valid availability status'; end if;
  if new_status='snoozed' and (snooze_until is null or snooze_until<=now()) then raise exception 'Choose a future snooze time'; end if;
  if remaining_quantity is not null and remaining_quantity<0 then raise exception 'Remaining quantity cannot be negative'; end if;
  update public.menu_items set available=true,availability_status=new_status,snoozed_until=case when new_status='snoozed' then snooze_until else null end,quantity_available=remaining_quantity where id=target_item;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details) values(item.restaurant_id,auth.uid(),'menu.availability_changed','menu_item',item.id,jsonb_build_object('status',new_status,'snoozed_until',snooze_until,'quantity_available',remaining_quantity));
end; $$;

-- Keep modifier choices visible on the final receipt. The item snapshot already
-- includes the modifier price, so this only enriches the immutable receipt data.
create or replace function public.close_table_session(target_session uuid,method public.payment_method) returns jsonb
language plpgsql security definer set search_path=public as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; subtotal numeric; discount_total numeric; taxable numeric; tax_total numeric; service_total numeric; final_total numeric;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found then raise exception 'Open session not found'; end if;
  if not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter','cashier']) then raise exception 'Owner, manager, waiter or cashier access required'; end if;
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
    'items',coalesce((select jsonb_agg(jsonb_build_object(
      'name',i.item_name_snapshot,
      'quantity',i.quantity,
      'unit_price',i.unit_price_snapshot,
      'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',m.modifier_name_snapshot,'price_adjustment',m.price_adjustment_snapshot) order by m.id) from public.order_item_modifiers m where m.order_item_id=i.id),'[]'::jsonb)
    ) order by o.created_at,i.id) from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null),'[]'::jsonb),
    'subtotal',subtotal,'discount',discount_total,'tax',tax_total,'tax_configured',r.tax_percent is not null,'service_charge',service_total,'service_configured',r.service_charge_value is not null,'total',final_total,'payment_method',method
  );
end; $$;

alter table public.prep_stations enable row level security;
alter table public.modifier_groups enable row level security;
alter table public.modifiers enable row level security;
alter table public.menu_item_modifier_groups enable row level security;
alter table public.order_item_modifiers enable row level security;
alter table public.table_session_events enable row level security;
alter table public.order_events enable row level security;
alter table public.order_item_events enable row level security;

create policy prep_stations_read on public.prep_stations for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy prep_stations_manage on public.prep_stations for all to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager'])) with check(public.has_restaurant_text_role(restaurant_id,array['owner','manager']));
create policy modifier_groups_read on public.modifier_groups for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy modifier_groups_manage on public.modifier_groups for all to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager'])) with check(public.has_restaurant_text_role(restaurant_id,array['owner','manager']));
create policy modifiers_read on public.modifiers for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy modifiers_manage on public.modifiers for all to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager'])) with check(public.has_restaurant_text_role(restaurant_id,array['owner','manager']) and exists(select 1 from public.modifier_groups g where g.id=group_id and g.restaurant_id=modifiers.restaurant_id));
create policy item_modifier_links_read on public.menu_item_modifier_groups for select to authenticated using(exists(select 1 from public.menu_items i where i.id=menu_item_id and public.has_restaurant_text_role(i.restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier'])));
create policy item_modifier_links_manage on public.menu_item_modifier_groups for all to authenticated using(exists(select 1 from public.menu_items i where i.id=menu_item_id and public.has_restaurant_text_role(i.restaurant_id,array['owner','manager']))) with check(exists(select 1 from public.menu_items i join public.modifier_groups g on g.restaurant_id=i.restaurant_id where i.id=menu_item_id and g.id=modifier_group_id and public.has_restaurant_text_role(i.restaurant_id,array['owner','manager'])));
create policy order_item_modifiers_read on public.order_item_modifiers for select to authenticated using(exists(select 1 from public.order_items i join public.orders o on o.id=i.order_id where i.id=order_item_id and public.has_restaurant_text_role(o.restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier'])));
create policy session_events_read on public.table_session_events for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy order_events_read on public.order_events for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy item_events_read on public.order_item_events for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));

grant select,insert,update,delete on public.prep_stations,public.modifier_groups,public.modifiers,public.menu_item_modifier_groups to authenticated;
grant select on public.order_item_modifiers,public.table_session_events,public.order_events,public.order_item_events to authenticated;

revoke all on function public.open_table_session_v2(uuid,integer) from public;
revoke all on function public.get_public_session(uuid) from public;
revoke all on function public.get_customer_order_history(uuid) from public;
revoke all on function public.place_customer_order_v2(uuid,jsonb,uuid,text) from public;
revoke all on function public.place_customer_order(uuid,jsonb) from public;
revoke all on function public.create_customer_request_v2(uuid,text,text) from public;
revoke all on function public.create_customer_request(uuid,public.request_type) from public;
revoke all on function public.set_station_order_status_v2(uuid,uuid,text) from public;
revoke all on function public.set_menu_item_availability(uuid,text,timestamptz,integer) from public;
revoke all on function public.close_table_session(uuid,public.payment_method) from public;
revoke all on function public.create_default_prep_stations() from public;
revoke all on function public.sync_category_prep_station() from public;
revoke all on function public.validate_menu_station_route() from public;
revoke all on function public.capture_table_session_event() from public;
revoke all on function public.capture_order_event() from public;
revoke all on function public.capture_order_item_event() from public;
grant execute on function public.open_table_session_v2(uuid,integer) to authenticated;
grant execute on function public.get_public_session(uuid),public.get_customer_order_history(uuid) to anon,authenticated;
grant execute on function public.place_customer_order_v2(uuid,jsonb,uuid,text),public.place_customer_order(uuid,jsonb) to anon,authenticated;
grant execute on function public.create_customer_request_v2(uuid,text,text),public.create_customer_request(uuid,public.request_type) to anon,authenticated;
grant execute on function public.set_station_order_status_v2(uuid,uuid,text),public.set_menu_item_availability(uuid,text,timestamptz,integer) to authenticated;
grant execute on function public.close_table_session(uuid,public.payment_method) to authenticated;

do $$
declare table_name text;
begin
  foreach table_name in array array['prep_stations','modifier_groups','modifiers','menu_item_modifier_groups','order_item_modifiers','table_session_events','order_events','order_item_events'] loop
    if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=table_name) then
      execute format('alter publication supabase_realtime add table public.%I',table_name);
    end if;
  end loop;
end $$;
