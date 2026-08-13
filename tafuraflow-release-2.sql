-- TafuraFlow Release 2: Floor, Service and Advanced KDS
-- Requires Release 1B. Additive migration. Safe to rerun after a partial or
-- previously completed installation; existing Release 2 objects are retained.

-- Visual floor ----------------------------------------------------------------
create table if not exists public.floor_areas (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  name text not null check(length(trim(name)) between 1 and 80),
  sort_order integer not null default 0,
  canvas_width integer not null default 1200 check(canvas_width between 600 and 2400),
  canvas_height integer not null default 720 check(canvas_height between 400 and 1600),
  background_color text not null default '#F4EBDD' check(background_color ~ '^#[0-9A-Fa-f]{6}$'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id,name)
);

insert into public.floor_areas(restaurant_id,branch_id,name,sort_order)
select b.restaurant_id,b.id,'Dining room',10 from public.restaurant_branches b
where b.is_default and not exists(select 1 from public.floor_areas a where a.branch_id=b.id);

alter table public.physical_tables add column if not exists floor_area_id uuid references public.floor_areas(id) on delete set null;
alter table public.physical_tables add column if not exists floor_x integer not null default 32 check(floor_x between 0 and 2400);
alter table public.physical_tables add column if not exists floor_y integer not null default 32 check(floor_y between 0 and 1600);
alter table public.physical_tables add column if not exists floor_width integer not null default 132 check(floor_width between 80 and 360);
alter table public.physical_tables add column if not exists floor_height integer not null default 96 check(floor_height between 72 and 280);
alter table public.physical_tables add column if not exists floor_shape text not null default 'rectangle' check(floor_shape in ('rectangle','round','booth'));

with ranked as (
  select t.id,a.id area_id,row_number() over(partition by t.branch_id order by t.label) n
  from public.physical_tables t join lateral (
    select id from public.floor_areas where branch_id=t.branch_id and active order by sort_order,id limit 1
  ) a on true where t.floor_area_id is null
)
update public.physical_tables t set floor_area_id=r.area_id,
  floor_x=32+(((r.n-1)%5)*168),floor_y=32+(floor((r.n-1)/5.0)::integer*132)
from ranked r where r.id=t.id;

create index if not exists floor_areas_branch_idx on public.floor_areas(branch_id,active,sort_order);
create index if not exists physical_tables_floor_idx on public.physical_tables(floor_area_id,floor_y,floor_x);

-- Waiter sections and immutable transfers ------------------------------------
create table if not exists public.waiter_sections (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  floor_area_id uuid references public.floor_areas(id) on delete set null,
  name text not null check(length(trim(name)) between 1 and 80),
  color text not null default '#A94732' check(color ~ '^#[0-9A-Fa-f]{6}$'),
  waiter_profile_id uuid references public.waiter_profiles(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id,name)
);
create table if not exists public.waiter_section_tables (
  section_id uuid not null references public.waiter_sections(id) on delete cascade,
  table_id uuid not null references public.physical_tables(id) on delete cascade,
  assigned_at timestamptz not null default now(),
  assigned_by uuid references public.profiles(id),
  primary key(section_id,table_id),
  unique(table_id)
);
create table if not exists public.table_transfers (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  from_table_id uuid not null references public.physical_tables(id),
  to_table_id uuid not null references public.physical_tables(id),
  from_waiter_profile_id uuid references public.waiter_profiles(id),
  to_waiter_profile_id uuid references public.waiter_profiles(id),
  reason text not null check(length(trim(reason)) between 3 and 240),
  transferred_by uuid not null references public.profiles(id),
  transferred_at timestamptz not null default now(),
  check(from_table_id<>to_table_id)
);
create index if not exists waiter_sections_branch_idx on public.waiter_sections(branch_id,active);
create index if not exists table_transfers_session_idx on public.table_transfers(session_id,transferred_at desc);

create or replace function public.apply_waiter_section_on_open() returns trigger language plpgsql security definer set search_path=public as $$
declare w public.waiter_profiles%rowtype;
begin
 if new.assigned_waiter_profile_id is not null then return new; end if;
 select p.* into w from public.waiter_section_tables st join public.waiter_sections s on s.id=st.section_id and s.active join public.waiter_profiles p on p.id=s.waiter_profile_id and p.active where st.table_id=new.table_id limit 1;
 if w.id is not null then update public.table_sessions set assigned_waiter_profile_id=w.id,assigned_waiter_name=w.full_name where id=new.id; end if;
 return new;
end $$;
drop trigger if exists session_apply_waiter_section on public.table_sessions;
create trigger session_apply_waiter_section after insert on public.table_sessions for each row execute function public.apply_waiter_section_on_open();

-- Advanced KDS ----------------------------------------------------------------
alter table public.prep_stations add column if not exists warning_minutes integer not null default 10 check(warning_minutes between 1 and 180);
alter table public.prep_stations add column if not exists overdue_minutes integer not null default 20 check(overdue_minutes between 2 and 360);
alter table public.prep_stations add column if not exists target_minutes integer not null default 15 check(target_minutes between 1 and 240);
alter table public.order_items add column if not exists kds_acknowledged_at timestamptz;
alter table public.order_items add column if not exists kds_started_at timestamptz;
alter table public.order_items add column if not exists kds_ready_at timestamptz;

create table if not exists public.kds_tickets (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  prep_station_id uuid not null references public.prep_stations(id) on delete cascade,
  status text not null default 'new' check(status in ('new','acknowledged','preparing','ready','served','cancelled')),
  priority text not null default 'normal' check(priority in ('normal','rush','vip')),
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles(id),
  started_at timestamptz,
  ready_at timestamptz,
  served_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(order_id,prep_station_id)
);
create table if not exists public.kds_ticket_events (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  ticket_id uuid not null references public.kds_tickets(id) on delete cascade,
  event_type text not null,
  from_status text,
  to_status text,
  actor_user_id uuid references public.profiles(id),
  waiter_profile_id uuid references public.waiter_profiles(id),
  detail jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create table if not exists public.waiter_ready_alerts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  ticket_id uuid not null references public.kds_tickets(id) on delete cascade,
  waiter_profile_id uuid references public.waiter_profiles(id) on delete set null,
  message text not null,
  created_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  acknowledged_by uuid references public.profiles(id),
  unique(ticket_id)
);
create index if not exists kds_tickets_station_status_idx on public.kds_tickets(prep_station_id,status,created_at);
create index if not exists kds_events_ticket_idx on public.kds_ticket_events(ticket_id,created_at);
create index if not exists waiter_ready_open_idx on public.waiter_ready_alerts(restaurant_id,waiter_profile_id,created_at) where acknowledged_at is null;

insert into public.kds_tickets(restaurant_id,branch_id,order_id,session_id,prep_station_id,status,created_at,started_at,ready_at)
select o.restaurant_id,o.branch_id,o.id,o.session_id,i.prep_station_id,
 case when bool_and(i.preparation_status='served') then 'served'
      when bool_and(i.preparation_status in ('ready','served')) then 'ready'
      when bool_or(i.preparation_status='preparing') then 'preparing' else 'new' end,
 o.created_at,
 min(case when i.preparation_status in ('preparing','ready','served') then o.created_at end),
 min(case when i.preparation_status in ('ready','served') then now() end)
from public.orders o join public.order_items i on i.order_id=o.id
where i.prep_station_id is not null and i.voided_at is null
group by o.restaurant_id,o.branch_id,o.id,o.session_id,i.prep_station_id
on conflict(order_id,prep_station_id) do nothing;

create or replace function public.ensure_kds_ticket() returns trigger language plpgsql security definer set search_path=public as $$
declare o public.orders%rowtype;
begin
  if new.prep_station_id is null then return new; end if;
  select * into o from public.orders where id=new.order_id;
  insert into public.kds_tickets(restaurant_id,branch_id,order_id,session_id,prep_station_id,created_at)
  values(o.restaurant_id,o.branch_id,o.id,o.session_id,new.prep_station_id,o.created_at)
  on conflict(order_id,prep_station_id) do nothing;
  return new;
end $$;
drop trigger if exists order_item_ensure_kds on public.order_items;
create trigger order_item_ensure_kds after insert or update of prep_station_id on public.order_items for each row execute function public.ensure_kds_ticket();

create or replace function public.sync_kds_ticket_from_items() returns trigger language plpgsql security definer set search_path=public as $$
declare new_status text;
begin
 if new.prep_station_id is null then return new; end if;
 select case when bool_and(voided_at is not null or preparation_status='served') then 'served'
             when bool_and(voided_at is not null or preparation_status in ('ready','served')) then 'ready'
             when bool_or(preparation_status='preparing') then 'preparing'
             when bool_or(preparation_status='accepted') then 'acknowledged' else 'new' end
 into new_status from public.order_items where order_id=new.order_id and prep_station_id=new.prep_station_id;
 update public.kds_tickets set status=new_status,
   acknowledged_at=case when new_status in ('acknowledged','preparing','ready','served') then coalesce(acknowledged_at,now()) else acknowledged_at end,
   started_at=case when new_status in ('preparing','ready','served') then coalesce(started_at,now()) else started_at end,
   ready_at=case when new_status in ('ready','served') then coalesce(ready_at,now()) else ready_at end,
   served_at=case when new_status='served' then coalesce(served_at,now()) else served_at end,updated_at=now()
 where order_id=new.order_id and prep_station_id=new.prep_station_id;
 return new;
end $$;
drop trigger if exists order_item_sync_kds on public.order_items;
create trigger order_item_sync_kds after update of preparation_status,voided_at on public.order_items for each row execute function public.sync_kds_ticket_from_items();

-- Secured workflow functions --------------------------------------------------
create or replace function public.save_floor_area(target_area uuid,area_name text,area_color text default '#F4EBDD') returns uuid
language plpgsql security definer set search_path=public,private as $$
declare a public.floor_areas%rowtype; rid uuid; bid uuid; result uuid;
begin
 if target_area is null then
   select m.restaurant_id into rid from public.restaurant_members m where m.user_id=auth.uid() and m.active limit 1;
   if not public.has_restaurant_text_role(rid,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
   select id into bid from public.restaurant_branches where restaurant_id=rid and is_default;
   insert into public.floor_areas(restaurant_id,branch_id,name,background_color,sort_order)
   values(rid,bid,trim(area_name),area_color,coalesce((select max(sort_order)+10 from public.floor_areas where branch_id=bid),10)) returning id into result;
 else
   select * into a from public.floor_areas where id=target_area;
   if not public.has_restaurant_text_role(a.restaurant_id,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
   update public.floor_areas set name=trim(area_name),background_color=area_color,updated_at=now() where id=target_area returning id into result;
 end if; return result;
end $$;

create or replace function public.update_table_floor_position(target_table uuid,target_area uuid,x integer,y integer,table_width integer,table_height integer,table_shape text) returns void
language plpgsql security definer set search_path=public,private as $$
declare t public.physical_tables%rowtype; a public.floor_areas%rowtype;
begin
 select * into t from public.physical_tables where id=target_table; select * into a from public.floor_areas where id=target_area;
 if t.id is null or a.id is null or t.restaurant_id<>a.restaurant_id then raise exception 'Table or floor area was not found'; end if;
 if not public.has_restaurant_text_role(t.restaurant_id,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
 update public.physical_tables set floor_area_id=target_area,floor_x=greatest(0,least(x,a.canvas_width-table_width)),floor_y=greatest(0,least(y,a.canvas_height-table_height)),floor_width=table_width,floor_height=table_height,floor_shape=table_shape where id=target_table;
end $$;

create or replace function public.save_waiter_section(target_section uuid,section_name text,section_color text,target_area uuid,target_waiter uuid,table_ids uuid[]) returns uuid
language plpgsql security definer set search_path=public,private as $$
declare rid uuid; bid uuid; sid uuid;
begin
 select restaurant_id,branch_id into rid,bid from public.floor_areas where id=target_area;
 if not public.has_restaurant_text_role(rid,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
 if target_waiter is not null and not exists(select 1 from public.waiter_profiles where id=target_waiter and restaurant_id=rid and active) then raise exception 'Choose an active waiter'; end if;
 if target_section is null then insert into public.waiter_sections(restaurant_id,branch_id,floor_area_id,name,color,waiter_profile_id) values(rid,bid,target_area,trim(section_name),section_color,target_waiter) returning id into sid;
 else update public.waiter_sections set floor_area_id=target_area,name=trim(section_name),color=section_color,waiter_profile_id=target_waiter,updated_at=now() where id=target_section and restaurant_id=rid returning id into sid; end if;
 delete from public.waiter_section_tables where section_id=sid;
 insert into public.waiter_section_tables(section_id,table_id,assigned_by) select sid,t.id,auth.uid() from public.physical_tables t where t.id=any(coalesce(table_ids,array[]::uuid[])) and t.restaurant_id=rid;
 return sid;
end $$;

create or replace function public.transfer_table_session(target_session uuid,target_table uuid,target_waiter uuid,transfer_reason text) returns void
language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; t public.physical_tables%rowtype; w public.waiter_profiles%rowtype;
begin
 select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
 select * into t from public.physical_tables where id=target_table and active for update;
 if s.id is null or t.id is null or s.restaurant_id<>t.restaurant_id or s.branch_id<>t.branch_id then raise exception 'Open session or destination table was not found'; end if;
 if not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager']) then raise exception 'Manager access is required to transfer a table'; end if;
 if exists(select 1 from public.table_sessions where table_id=target_table and status<>'closed') then raise exception 'The destination table is already open'; end if;
 if length(trim(coalesce(transfer_reason,'')))<3 then raise exception 'A transfer reason is required'; end if;
 if target_waiter is not null then select * into w from public.waiter_profiles where id=target_waiter and restaurant_id=s.restaurant_id and active; end if;
 insert into public.table_transfers(restaurant_id,branch_id,session_id,from_table_id,to_table_id,from_waiter_profile_id,to_waiter_profile_id,reason,transferred_by)
 values(s.restaurant_id,s.branch_id,s.id,s.table_id,target_table,s.assigned_waiter_profile_id,target_waiter,trim(transfer_reason),auth.uid());
 update public.table_sessions set table_id=target_table,assigned_waiter_profile_id=target_waiter,assigned_waiter_name=case when target_waiter is null then null else w.full_name end where id=s.id;
end $$;

create or replace function public.advance_kds_ticket(target_ticket uuid,next_status text) returns void
language plpgsql security definer set search_path=public,private as $$
declare k public.kds_tickets%rowtype; actor uuid; waiter uuid; target_station_group text;
begin
 select * into k from public.kds_tickets where id=target_ticket for update;
 if k.id is null or not public.has_restaurant_text_role(k.restaurant_id,array['owner','manager','kitchen','bar']) then raise exception 'Preparation-station access required'; end if;
 select p.station_group into target_station_group from public.prep_stations p where p.id=k.prep_station_id;
 if target_station_group='kitchen' and not public.has_restaurant_text_role(k.restaurant_id,array['owner','manager','kitchen']) then raise exception 'Kitchen access required'; end if;
 if target_station_group='bar' and not public.has_restaurant_text_role(k.restaurant_id,array['owner','manager','bar']) then raise exception 'Bar access required'; end if;
 if not ((k.status='new' and next_status='acknowledged') or (k.status in ('new','acknowledged') and next_status='preparing') or (k.status='preparing' and next_status='ready')) then raise exception 'That ticket cannot move to the selected status'; end if;
 actor:=private.action_user_id(k.restaurant_id); waiter:=private.current_waiter_profile(k.restaurant_id,false);
 insert into public.kds_ticket_events(restaurant_id,branch_id,ticket_id,event_type,from_status,to_status,actor_user_id,waiter_profile_id) values(k.restaurant_id,k.branch_id,k.id,'status_changed',k.status,next_status,actor,waiter);
 update public.kds_tickets set status=next_status,acknowledged_at=case when next_status in ('acknowledged','preparing') then coalesce(acknowledged_at,now()) else acknowledged_at end,acknowledged_by=case when next_status in ('acknowledged','preparing') then coalesce(acknowledged_by,actor) else acknowledged_by end,started_at=case when next_status='preparing' then coalesce(started_at,now()) else started_at end,ready_at=case when next_status='ready' then now() else ready_at end,updated_at=now() where id=k.id;
 update public.order_items set preparation_status=case next_status when 'acknowledged' then 'accepted' else next_status end,
   kds_acknowledged_at=case when next_status in ('acknowledged','preparing','ready') then coalesce(kds_acknowledged_at,now()) else kds_acknowledged_at end,
   kds_started_at=case when next_status in ('preparing','ready') then coalesce(kds_started_at,now()) else kds_started_at end,
   kds_ready_at=case when next_status='ready' then now() else kds_ready_at end
 where order_id=k.order_id and prep_station_id=k.prep_station_id and voided_at is null;
 update public.orders set status=case when exists(select 1 from public.order_items where order_id=k.order_id and voided_at is null and preparation_status='preparing') then 'preparing' when not exists(select 1 from public.order_items where order_id=k.order_id and voided_at is null and preparation_status not in ('ready','served')) then 'ready' else 'accepted' end where id=k.order_id;
 if next_status='ready' then
   insert into public.waiter_ready_alerts(restaurant_id,branch_id,session_id,ticket_id,waiter_profile_id,message)
   select k.restaurant_id,k.branch_id,k.session_id,k.id,s.assigned_waiter_profile_id,'Items are ready for '||t.label from public.table_sessions s join public.physical_tables t on t.id=s.table_id where s.id=k.session_id on conflict(ticket_id) do nothing;
 end if;
end $$;

create or replace function public.set_kds_priority(target_ticket uuid,new_priority text) returns void language plpgsql security definer set search_path=public,private as $$
declare k public.kds_tickets%rowtype;
begin select * into k from public.kds_tickets where id=target_ticket;if not public.has_restaurant_text_role(k.restaurant_id,array['owner','manager']) then raise exception 'Manager access required';end if;
 update public.kds_tickets set priority=new_priority,updated_at=now() where id=target_ticket;
 insert into public.kds_ticket_events(restaurant_id,branch_id,ticket_id,event_type,actor_user_id,detail) values(k.restaurant_id,k.branch_id,k.id,'priority_changed',auth.uid(),jsonb_build_object('priority',new_priority));end $$;

create or replace function public.acknowledge_ready_alert(target_alert uuid) returns void language plpgsql security definer set search_path=public,private as $$
declare a public.waiter_ready_alerts%rowtype;
begin select * into a from public.waiter_ready_alerts where id=target_alert;if not public.has_restaurant_text_role(a.restaurant_id,array['owner','manager','waiter']) then raise exception 'Service staff access required';end if;
 update public.waiter_ready_alerts set acknowledged_at=now(),acknowledged_by=private.action_user_id(a.restaurant_id) where id=a.id and acknowledged_at is null;end $$;

create or replace function public.can_read_ready_alert(target_restaurant uuid,target_waiter uuid) returns boolean
language sql stable security definer set search_path=public,private as $$
 select public.has_restaurant_text_role(target_restaurant,array['owner','manager']) or
   (public.has_restaurant_text_role(target_restaurant,array['waiter']) and (target_waiter is null or target_waiter=private.current_waiter_profile(target_restaurant,false)));
$$;

create or replace function public.get_release_2_service_analytics(target_branch uuid,from_date date,to_date date) returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype;
begin select * into b from public.restaurant_branches where id=target_branch;if not public.has_restaurant_text_role(b.restaurant_id,array['owner','manager']) then raise exception 'Owner or manager access required';end if;
 return jsonb_build_object(
  'summary',(select jsonb_build_object('covers',coalesce(sum(guest_count),0),'sessions',count(*),'average_table_minutes',coalesce(round(avg(extract(epoch from (coalesce(closed_at,now())-opened_at))/60)),0)) from public.table_sessions where branch_id=b.id and business_date between from_date and to_date),
  'kds',(select jsonb_build_object('tickets',count(*),'average_ack_minutes',coalesce(round(avg(extract(epoch from (acknowledged_at-created_at))/60),1),0),'average_prep_minutes',coalesce(round(avg(extract(epoch from (ready_at-coalesce(started_at,created_at)))/60),1),0),'overdue',count(*) filter(where ready_at is not null and extract(epoch from (ready_at-created_at))/60 > (select overdue_minutes from public.prep_stations where id=k.prep_station_id))) from public.kds_tickets k join public.orders o on o.id=k.order_id where k.branch_id=b.id and o.business_date between from_date and to_date),
  'requests',(select jsonb_build_object('total',count(*),'average_response_minutes',coalesce(round(avg(extract(epoch from (coalesce(acknowledged_at,resolved_at)-created_at))/60),1),0),'overdue',count(*) filter(where due_at is not null and coalesce(acknowledged_at,resolved_at,now())>due_at)) from public.customer_requests where branch_id=b.id and created_at::date between from_date and to_date),
  'stations',(select coalesce(jsonb_agg(row_data order by station_name),'[]'::jsonb) from (select p.name station_name,count(*) tickets,coalesce(round(avg(extract(epoch from (k.ready_at-coalesce(k.started_at,k.created_at)))/60),1),0) average_minutes from public.kds_tickets k join public.prep_stations p on p.id=k.prep_station_id join public.orders o on o.id=k.order_id where k.branch_id=b.id and o.business_date between from_date and to_date group by p.id,p.name) row_data),
  'waiters',(select coalesce(jsonb_agg(row_data order by tables_served desc),'[]'::jsonb) from (select coalesce(s.assigned_waiter_name,'Unassigned') waiter_name,count(*) tables_served,coalesce(sum(s.guest_count),0) covers,coalesce(round(avg(extract(epoch from (coalesce(s.closed_at,now())-s.opened_at))/60)),0) average_table_minutes from public.table_sessions s where s.branch_id=b.id and s.business_date between from_date and to_date group by s.assigned_waiter_name) row_data)
 );
end $$;

create or replace function public.get_live_floor_totals(target_restaurant uuid) returns jsonb
language plpgsql stable security definer set search_path=public,private as $$
begin
 if not public.has_restaurant_text_role(target_restaurant,array['owner','manager','waiter','cashier']) then raise exception 'Restaurant service access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('session_id',s.id,'currency',r.currency,'subtotal',x.subtotal,'discount',x.discount_total,'tax',round(greatest(x.subtotal-x.discount_total,0)*coalesce(r.tax_percent,0)/100,2),'service_charge',case when r.service_charge_value is null then 0 when r.service_charge_kind='percentage' then round(greatest(x.subtotal-x.discount_total,0)*r.service_charge_value/100,2) else r.service_charge_value end,'total',greatest(x.subtotal-x.discount_total,0)+round(greatest(x.subtotal-x.discount_total,0)*coalesce(r.tax_percent,0)/100,2)+case when r.service_charge_value is null then 0 when r.service_charge_kind='percentage' then round(greatest(x.subtotal-x.discount_total,0)*r.service_charge_value/100,2) else r.service_charge_value end))
 from public.table_sessions s join public.restaurants r on r.id=s.restaurant_id
 cross join lateral(select coalesce((select sum(i.unit_price_snapshot*i.quantity) from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null),0) subtotal,coalesce((select sum(amount_snapshot) from public.applied_discounts where session_id=s.id),0) discount_total)x
 where s.restaurant_id=target_restaurant and s.status<>'closed'),'[]'::jsonb);
end $$;

create or replace function public.get_customer_order_history(token uuid) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'order_number',o.order_number,'status',o.status,'source',o.source,'created_at',o.created_at,'rejection_reason',o.rejection_reason,'total',coalesce((select sum(oi.unit_price_snapshot*oi.quantity) from public.order_items oi where oi.order_id=o.id and oi.voided_at is null),0),'items',coalesce((select jsonb_agg(jsonb_build_object('id',oi.id,'name',oi.item_name_snapshot,'price',oi.unit_price_snapshot,'quantity',oi.quantity,'instructions',oi.special_instructions,'station',oi.prep_station_name_snapshot,'preparation_status',oi.preparation_status,'voided',oi.voided_at is not null,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',om.modifier_name_snapshot,'price_adjustment',om.price_adjustment_snapshot) order by om.id) from public.order_item_modifiers om where om.order_item_id=oi.id),'[]'::jsonb)) order by oi.id) from public.order_items oi where oi.order_id=o.id),'[]'::jsonb)) order by o.created_at desc),'[]'::jsonb)
  from public.orders o join public.table_sessions s on s.id=o.session_id join public.restaurants r on r.id=s.restaurant_id and r.active and (r.subscription_expires_at is null or r.subscription_expires_at>=current_date)
  where s.public_token=$1 and s.status in ('open','bill_requested');
$$;

-- RLS, grants, realtime --------------------------------------------------------
alter table public.floor_areas enable row level security;alter table public.waiter_sections enable row level security;alter table public.waiter_section_tables enable row level security;alter table public.table_transfers enable row level security;alter table public.kds_tickets enable row level security;alter table public.kds_ticket_events enable row level security;alter table public.waiter_ready_alerts enable row level security;
drop policy if exists floor_areas_read on public.floor_areas;
drop policy if exists waiter_sections_read on public.waiter_sections;
drop policy if exists section_tables_read on public.waiter_section_tables;
drop policy if exists transfers_read on public.table_transfers;
drop policy if exists kds_tickets_read on public.kds_tickets;
drop policy if exists kds_events_read on public.kds_ticket_events;
drop policy if exists ready_alerts_read on public.waiter_ready_alerts;
create policy floor_areas_read on public.floor_areas for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy waiter_sections_read on public.waiter_sections for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter']));
create policy section_tables_read on public.waiter_section_tables for select to authenticated using(exists(select 1 from public.waiter_sections s where s.id=section_id and public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter'])));
create policy transfers_read on public.table_transfers for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter']));
create policy kds_tickets_read on public.kds_tickets for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar']));
create policy kds_events_read on public.kds_ticket_events for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','kitchen','bar']));
create policy ready_alerts_read on public.waiter_ready_alerts for select to authenticated using(public.can_read_ready_alert(restaurant_id,waiter_profile_id));
grant select on public.floor_areas,public.waiter_sections,public.waiter_section_tables,public.table_transfers,public.kds_tickets,public.kds_ticket_events,public.waiter_ready_alerts to authenticated;
grant select on public.physical_tables,public.prep_stations to authenticated;
revoke all on function public.save_floor_area(uuid,text,text),public.update_table_floor_position(uuid,uuid,integer,integer,integer,integer,text),public.save_waiter_section(uuid,text,text,uuid,uuid,uuid[]),public.transfer_table_session(uuid,uuid,uuid,text),public.advance_kds_ticket(uuid,text),public.set_kds_priority(uuid,text),public.acknowledge_ready_alert(uuid),public.get_release_2_service_analytics(uuid,date,date),public.get_live_floor_totals(uuid) from public;
grant execute on function public.save_floor_area(uuid,text,text),public.update_table_floor_position(uuid,uuid,integer,integer,integer,integer,text),public.save_waiter_section(uuid,text,text,uuid,uuid,uuid[]),public.transfer_table_session(uuid,uuid,uuid,text),public.advance_kds_ticket(uuid,text),public.set_kds_priority(uuid,text),public.acknowledge_ready_alert(uuid),public.get_release_2_service_analytics(uuid,date,date) to authenticated;
grant execute on function public.get_live_floor_totals(uuid) to authenticated;
revoke all on function public.can_read_ready_alert(uuid,uuid) from public;
grant execute on function public.can_read_ready_alert(uuid,uuid) to authenticated;
revoke all on function public.get_customer_order_history(uuid) from public;
grant execute on function public.get_customer_order_history(uuid) to anon,authenticated;

do $$ declare n text;begin foreach n in array array['floor_areas','waiter_sections','waiter_section_tables','table_transfers','kds_tickets','kds_ticket_events','waiter_ready_alerts'] loop if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=n) then execute format('alter publication supabase_realtime add table public.%I',n);end if;end loop;end $$;

revoke all on function public.ensure_kds_ticket() from public,anon,authenticated;
revoke all on function public.sync_kds_ticket_from_items() from public,anon,authenticated;
revoke all on function public.apply_waiter_section_on_open() from public,anon,authenticated;
