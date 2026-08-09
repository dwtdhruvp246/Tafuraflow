-- TafuraFlow Release 1A.1: Shared Waiter Mode
-- Run once after 20260808205304_release_1a_menu_service_foundations.sql.

create schema if not exists private;
revoke all on schema private from public,anon,authenticated;

alter table public.restaurant_members add column is_shared_waiter_device boolean not null default false;

create table public.waiter_profiles (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  linked_user_id uuid references public.profiles(id) on delete set null,
  full_name text not null check(length(trim(full_name)) between 1 and 100),
  phone text,
  active boolean not null default true,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(restaurant_id,id)
);
create unique index waiter_profiles_linked_user_unique on public.waiter_profiles(restaurant_id,linked_user_id) where linked_user_id is not null;
create index waiter_profiles_restaurant_active_idx on public.waiter_profiles(restaurant_id,active,full_name);
create trigger waiter_profiles_updated before update on public.waiter_profiles for each row execute function public.set_updated_at();

insert into public.waiter_profiles(restaurant_id,linked_user_id,full_name,phone,active,created_by)
select m.restaurant_id,m.user_id,coalesce(nullif(trim(p.full_name),''),p.email),p.phone,m.active,m.user_id
from public.restaurant_members m join public.profiles p on p.id=m.user_id
where m.role='waiter'
on conflict(restaurant_id,linked_user_id) where linked_user_id is not null do update
set full_name=excluded.full_name,phone=excluded.phone,active=excluded.active;

create table private.waiter_pin_credentials (
  waiter_profile_id uuid primary key references public.waiter_profiles(id) on delete cascade,
  pin_hash text not null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create table private.waiter_terminal_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash bytea not null unique,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  device_user_id uuid not null references public.profiles(id) on delete cascade,
  waiter_profile_id uuid not null references public.waiter_profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null,
  ended_at timestamptz
);
create index waiter_terminal_sessions_lookup_idx on private.waiter_terminal_sessions(device_user_id,restaurant_id,expires_at) where ended_at is null;

create table private.waiter_device_attempts (
  device_user_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null default now(),
  failed_attempts integer not null default 0,
  locked_until timestamptz
);

alter table public.table_sessions add column opened_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.table_sessions add column assigned_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.table_sessions add column closed_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.orders add column placed_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.orders add column placed_by_waiter_name text;
alter table public.orders add column accepted_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.orders add column rejected_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.orders add column served_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.order_items add column voided_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.customer_requests add column resolved_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.payments add column recorded_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.applied_discounts add column applied_by_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.audit_logs add column waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.table_session_events add column waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.order_events add column waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;
alter table public.order_item_events add column waiter_profile_id uuid references public.waiter_profiles(id) on delete set null;

update public.table_sessions s set assigned_waiter_profile_id=w.id
from public.waiter_profiles w
where w.restaurant_id=s.restaurant_id and w.linked_user_id=s.assigned_waiter_id and s.assigned_waiter_profile_id is null;

create or replace function private.request_waiter_token() returns text
language plpgsql stable set search_path='' as $$
declare headers jsonb; raw text;
begin
  begin headers:=coalesce(current_setting('request.headers',true),'{}')::jsonb; exception when others then headers:='{}'::jsonb; end;
  raw:=nullif(headers->>'x-tafuraflow-waiter-token','');
  if raw is not null and raw!~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then return null; end if;
  return raw;
end; $$;

create or replace function private.current_waiter_profile(target_restaurant uuid,enforce_device boolean default true) returns uuid
language plpgsql stable security definer set search_path=pg_catalog,private,extensions,public as $$
declare member public.restaurant_members%rowtype; token text; waiter_id uuid;
begin
  select * into member from public.restaurant_members where restaurant_id=target_restaurant and user_id=auth.uid() and active limit 1;
  if not found then return null; end if;
  if member.is_shared_waiter_device then
    token:=private.request_waiter_token();
    if token is not null then
      select s.waiter_profile_id into waiter_id
      from private.waiter_terminal_sessions s join public.waiter_profiles w on w.id=s.waiter_profile_id and w.active
      where s.device_user_id=auth.uid() and s.restaurant_id=target_restaurant and s.token_hash=digest(token,'sha256')
        and s.ended_at is null and s.expires_at>now();
      if waiter_id is not null then return waiter_id;end if;
    end if;
    if enforce_device then raise exception 'Choose your waiter name and enter your PIN to continue'; end if;
    return null;
  end if;
  if member.role='waiter' then
    select id into waiter_id from public.waiter_profiles where restaurant_id=target_restaurant and linked_user_id=auth.uid() and active;
  end if;
  return waiter_id;
end; $$;

create or replace function private.action_user_id(target_restaurant uuid) returns uuid
language plpgsql stable security definer set search_path=public,private as $$
declare waiter_id uuid; linked_id uuid;
begin
  waiter_id:=private.current_waiter_profile(target_restaurant,true);
  if waiter_id is not null then select linked_user_id into linked_id from public.waiter_profiles where id=waiter_id; end if;
  return coalesce(linked_id,auth.uid());
end; $$;

-- A shared device has no restaurant data access until a waiter PIN session is active.
-- This function is already used by the existing RLS policies and operational RPCs.
create or replace function public.has_restaurant_text_role(target uuid,allowed text[]) returns boolean
language plpgsql stable security definer set search_path=public,private as $$
declare member public.restaurant_members%rowtype;
begin
  if public.is_super_admin() then return true;end if;
  select m.* into member from public.restaurant_members m join public.restaurants r on r.id=m.restaurant_id
  where m.restaurant_id=target and m.user_id=auth.uid() and m.active and m.role::text=any(allowed)
    and r.active and (r.subscription_expires_at is null or r.subscription_expires_at>=current_date);
  if not found then return false;end if;
  if member.is_shared_waiter_device then return private.current_waiter_profile(target,false) is not null;end if;
  return true;
end; $$;

create or replace function public.list_waiters_for_terminal() returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,extensions,public as $$
declare rid uuid;
begin
  select restaurant_id into rid from public.restaurant_members where user_id=auth.uid() and active and role='waiter' and is_shared_waiter_device;
  if rid is null then raise exception 'This account is not configured as a shared waiter tablet'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'full_name',w.full_name,'initials',upper(left(regexp_replace(w.full_name,'(^|\s)(\S)\S*','\2','g'),2))) order by w.full_name)
    from public.waiter_profiles w join private.waiter_pin_credentials c on c.waiter_profile_id=w.id
    where w.restaurant_id=rid and w.active and not exists(select 1 from public.restaurant_members m where m.restaurant_id=rid and m.user_id=w.linked_user_id and m.is_shared_waiter_device)), '[]'::jsonb);
end; $$;

create or replace function public.start_waiter_terminal_session(target_waiter uuid,pin text) returns jsonb
language plpgsql security definer set search_path=pg_catalog,private,extensions,public as $$
declare member public.restaurant_members%rowtype; waiter public.waiter_profiles%rowtype; credential private.waiter_pin_credentials%rowtype; attempt private.waiter_device_attempts%rowtype; raw_token uuid; expiry timestamptz;
begin
  select * into member from public.restaurant_members where user_id=auth.uid() and active and role='waiter' and is_shared_waiter_device;
  if not found then raise exception 'This account is not configured as a shared waiter tablet'; end if;
  select * into waiter from public.waiter_profiles where id=target_waiter and restaurant_id=member.restaurant_id and active;
  if not found then return jsonb_build_object('ok',false,'message','This waiter is no longer available on this tablet.'); end if;
  if exists(select 1 from public.restaurant_members m where m.restaurant_id=member.restaurant_id and m.user_id=waiter.linked_user_id and m.is_shared_waiter_device) then return jsonb_build_object('ok',false,'message','Please choose a waiter, not the tablet account.'); end if;
  insert into private.waiter_device_attempts(device_user_id) values(auth.uid()) on conflict(device_user_id) do nothing;
  select * into attempt from private.waiter_device_attempts where device_user_id=auth.uid() for update;
  if attempt.window_started_at<now()-interval '15 minutes' then update private.waiter_device_attempts set window_started_at=now(),failed_attempts=0,locked_until=null where device_user_id=auth.uid();attempt.failed_attempts:=0;attempt.locked_until:=null; end if;
  if attempt.locked_until>now() then return jsonb_build_object('ok',false,'message','This tablet is temporarily locked after too many incorrect PINs. Try again in 15 minutes.','locked',true); end if;
  select * into credential from private.waiter_pin_credentials where waiter_profile_id=waiter.id for update;
  if not found then return jsonb_build_object('ok',false,'message','A PIN has not been set for this waiter. Ask the owner to set one.'); end if;
  if credential.locked_until>now() then return jsonb_build_object('ok',false,'message','This waiter PIN is temporarily locked. Try again in 15 minutes.','locked',true); end if;
  if credential.locked_until is not null then
    update private.waiter_pin_credentials set failed_attempts=0,locked_until=null,updated_at=now() where waiter_profile_id=waiter.id;
    credential.failed_attempts:=0;credential.locked_until:=null;
  end if;
  if pin is null or pin!~ '^[0-9]{4}$' or coalesce(credential.pin_hash<>crypt(pin,credential.pin_hash),true) then
    update private.waiter_pin_credentials set failed_attempts=failed_attempts+1,locked_until=case when failed_attempts+1>=5 then now()+interval '15 minutes' else null end,updated_at=now() where waiter_profile_id=waiter.id;
    update private.waiter_device_attempts set failed_attempts=failed_attempts+1,locked_until=case when failed_attempts+1>=20 then now()+interval '15 minutes' else null end where device_user_id=auth.uid();
    return jsonb_build_object('ok',false,'message',case when credential.failed_attempts+1>=5 then 'This waiter PIN is temporarily locked. Try again in 15 minutes.' else 'That PIN is incorrect. '||(5-(credential.failed_attempts+1))||' attempts remaining.' end);
  end if;
  update private.waiter_pin_credentials set failed_attempts=0,locked_until=null,updated_at=now() where waiter_profile_id=waiter.id;
  update private.waiter_device_attempts set failed_attempts=0,locked_until=null,window_started_at=now() where device_user_id=auth.uid();
  update private.waiter_terminal_sessions set ended_at=now() where device_user_id=auth.uid() and ended_at is null;
  raw_token:=gen_random_uuid();expiry:=now()+interval '12 hours';
  insert into private.waiter_terminal_sessions(token_hash,restaurant_id,device_user_id,waiter_profile_id,expires_at) values(digest(raw_token::text,'sha256'),member.restaurant_id,auth.uid(),waiter.id,expiry);
  insert into public.audit_logs(restaurant_id,actor_id,waiter_profile_id,action,entity_type,entity_id,details) values(member.restaurant_id,auth.uid(),waiter.id,'waiter.terminal_started','waiter_profile',waiter.id,jsonb_build_object('expires_at',expiry));
  return jsonb_build_object('ok',true,'token',raw_token,'waiter_id',waiter.id,'waiter_name',waiter.full_name,'expires_at',expiry);
end; $$;

create or replace function public.end_waiter_terminal_session(token uuid) returns void
language plpgsql security definer set search_path=pg_catalog,private,extensions,public as $$
declare ended_waiter uuid; rid uuid;
begin
  update private.waiter_terminal_sessions set ended_at=now() where device_user_id=auth.uid() and token_hash=digest(token::text,'sha256') and ended_at is null returning waiter_profile_id,restaurant_id into ended_waiter,rid;
  if ended_waiter is not null then insert into public.audit_logs(restaurant_id,actor_id,waiter_profile_id,action,entity_type,entity_id) values(rid,auth.uid(),ended_waiter,'waiter.terminal_ended','waiter_profile',ended_waiter); end if;
end; $$;

create or replace function public.create_tablet_waiter(staff_name text,staff_phone text,pin text) returns uuid
language plpgsql security definer set search_path=pg_catalog,private,extensions,public as $$
declare rid uuid; waiter_id uuid;
begin
  select restaurant_id into rid from public.restaurant_members where user_id=auth.uid() and active and role='owner';
  if rid is null then raise exception 'Owner access required'; end if;
  if length(trim(staff_name))<1 then raise exception 'Waiter name is required'; end if;
  if pin is null or pin!~ '^[0-9]{4}$' then raise exception 'The waiter PIN must contain exactly 4 numbers'; end if;
  insert into public.waiter_profiles(restaurant_id,full_name,phone,created_by) values(rid,trim(staff_name),nullif(trim(staff_phone),''),auth.uid()) returning id into waiter_id;
  insert into private.waiter_pin_credentials(waiter_profile_id,pin_hash) values(waiter_id,crypt(pin,gen_salt('bf',10)));
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id) values(rid,auth.uid(),'waiter.created_for_tablet','waiter_profile',waiter_id);
  return waiter_id;
end; $$;

create or replace function public.update_tablet_waiter(target_waiter uuid,staff_name text,staff_phone text,new_active boolean) returns void
language plpgsql security definer set search_path=public,private as $$
declare waiter public.waiter_profiles%rowtype;
begin
  select * into waiter from public.waiter_profiles where id=target_waiter;
  if not found then raise exception 'Waiter not found'; end if;
  if not public.has_restaurant_text_role(waiter.restaurant_id,array['owner']) then raise exception 'Owner access required'; end if;
  if length(trim(staff_name))<1 then raise exception 'Waiter name is required'; end if;
  update public.waiter_profiles set full_name=trim(staff_name),phone=nullif(trim(staff_phone),''),active=new_active where id=target_waiter;
  if not new_active then update private.waiter_terminal_sessions set ended_at=now() where waiter_profile_id=target_waiter and ended_at is null; end if;
end; $$;

create or replace function public.set_waiter_pin(target_waiter uuid,new_pin text) returns void
language plpgsql security definer set search_path=pg_catalog,private,extensions,public as $$
declare waiter public.waiter_profiles%rowtype;
begin
  select * into waiter from public.waiter_profiles where id=target_waiter;
  if not found then raise exception 'Waiter not found'; end if;
  if not public.has_restaurant_text_role(waiter.restaurant_id,array['owner']) then raise exception 'Owner access required'; end if;
  if new_pin is null or new_pin!~ '^[0-9]{4}$' then raise exception 'The waiter PIN must contain exactly 4 numbers'; end if;
  insert into private.waiter_pin_credentials(waiter_profile_id,pin_hash,failed_attempts,locked_until,updated_at) values(target_waiter,crypt(new_pin,gen_salt('bf',10)),0,null,now())
  on conflict(waiter_profile_id) do update set pin_hash=excluded.pin_hash,failed_attempts=0,locked_until=null,updated_at=now();
  update private.waiter_terminal_sessions set ended_at=now() where waiter_profile_id=target_waiter and ended_at is null;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id) values(waiter.restaurant_id,auth.uid(),'waiter.pin_reset','waiter_profile',waiter.id);
end; $$;

create or replace function public.set_shared_waiter_device(target_member uuid,enabled boolean) returns void
language plpgsql security definer set search_path=public,private as $$
declare member public.restaurant_members%rowtype;
begin
  select * into member from public.restaurant_members where id=target_member for update;
  if not found then raise exception 'Staff account not found'; end if;
  if not public.has_restaurant_text_role(member.restaurant_id,array['owner']) then raise exception 'Owner access required'; end if;
  if member.role<>'waiter' then raise exception 'Only a waiter account can be used as a shared tablet'; end if;
  update public.restaurant_members set is_shared_waiter_device=enabled where id=member.id;
  update public.waiter_profiles set active=case when enabled then false else member.active end where restaurant_id=member.restaurant_id and linked_user_id=member.user_id;
  update private.waiter_terminal_sessions set ended_at=now() where device_user_id=member.user_id and ended_at is null;
  insert into public.audit_logs(restaurant_id,actor_id,action,entity_type,entity_id,details) values(member.restaurant_id,auth.uid(),case when enabled then 'waiter.device_enabled' else 'waiter.device_disabled' end,'restaurant_member',member.id,jsonb_build_object('enabled',enabled));
end; $$;

create or replace function public.get_waiter_management() returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare rid uuid;
begin
  select restaurant_id into rid from public.restaurant_members where user_id=auth.uid() and active and role in ('owner','manager');
  if rid is null then raise exception 'Owner or manager access required'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',w.id,'full_name',w.full_name,'phone',w.phone,'active',w.active,'linked_user_id',w.linked_user_id,'pin_configured',c.waiter_profile_id is not null,'is_device_account',coalesce(m.is_shared_waiter_device,false)) order by w.full_name)
    from public.waiter_profiles w left join private.waiter_pin_credentials c on c.waiter_profile_id=w.id left join public.restaurant_members m on m.restaurant_id=w.restaurant_id and m.user_id=w.linked_user_id where w.restaurant_id=rid), '[]'::jsonb);
end; $$;

create or replace function public.sync_waiter_profile_from_member() returns trigger
language plpgsql security definer set search_path=public as $$
declare p public.profiles%rowtype;
begin
  select * into p from public.profiles where id=new.user_id;
  if new.role='waiter' then
    insert into public.waiter_profiles(restaurant_id,linked_user_id,full_name,phone,active,created_by) values(new.restaurant_id,new.user_id,coalesce(nullif(trim(p.full_name),''),p.email),p.phone,new.active and not new.is_shared_waiter_device,new.user_id)
    on conflict(restaurant_id,linked_user_id) where linked_user_id is not null do update set full_name=excluded.full_name,phone=excluded.phone,active=excluded.active;
  else update public.waiter_profiles set active=false where restaurant_id=new.restaurant_id and linked_user_id=new.user_id; end if;
  return new;
end; $$;
drop trigger if exists sync_waiter_profile_from_member_trigger on public.restaurant_members;
create trigger sync_waiter_profile_from_member_trigger after insert or update of role,active,is_shared_waiter_device on public.restaurant_members for each row execute function public.sync_waiter_profile_from_member();

create or replace function public.sync_waiter_profile_from_profile() returns trigger
language plpgsql security definer set search_path=public as $$
begin update public.waiter_profiles set full_name=coalesce(nullif(trim(new.full_name),''),new.email),phone=new.phone where linked_user_id=new.id;return new;end; $$;
drop trigger if exists sync_waiter_profile_from_profile_trigger on public.profiles;
create trigger sync_waiter_profile_from_profile_trigger after update of full_name,phone on public.profiles for each row execute function public.sync_waiter_profile_from_profile();

create or replace function public.get_my_context() returns jsonb
language sql security definer set search_path=public,private as $$
  select jsonb_build_object(
    'profile',jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'platform_role',p.platform_role),
    'membership',case when m.id is null then null else jsonb_build_object('id',m.id,'restaurant_id',m.restaurant_id,'role',m.role,'active',m.active,'is_shared_waiter_device',m.is_shared_waiter_device) end,
    'restaurant',case when r.id is null then null else to_jsonb(r) end,
    'waiter_operator',case when waiter_op.id is null then null else jsonb_build_object('id',waiter_op.id,'full_name',waiter_op.full_name,'phone',waiter_op.phone) end
  )
  from public.profiles p
  left join lateral(select * from public.restaurant_members where user_id=p.id and active order by created_at limit 1)m on true
  left join public.restaurants r on r.id=m.restaurant_id
  left join lateral(select w.* from public.waiter_profiles w where w.id=private.current_waiter_profile(m.restaurant_id,false))waiter_op on true
  where p.id=auth.uid();
$$;

create or replace function public.assign_waiter_to_session(target_session uuid,target_waiter uuid) returns void
language plpgsql security definer set search_path=public,private as $$
declare session_row public.table_sessions%rowtype; waiter public.waiter_profiles%rowtype;
begin
  select * into session_row from public.table_sessions where id=target_session and status<>'closed';
  if not found then raise exception 'Open session not found'; end if;
  if not public.has_restaurant_text_role(session_row.restaurant_id,array['owner','manager']) then raise exception 'Owner or manager access required'; end if;
  select * into waiter from public.waiter_profiles where restaurant_id=session_row.restaurant_id and active and (id=target_waiter or linked_user_id=target_waiter) limit 1;
  if not found then raise exception 'Active waiter not found'; end if;
  update public.table_sessions set assigned_waiter_profile_id=waiter.id,assigned_waiter_id=waiter.linked_user_id,assigned_waiter_name=waiter.full_name where id=target_session;
end; $$;

create or replace function public.open_table_session_v2(target_table uuid,guests integer default null) returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare tbl public.physical_tables%rowtype; session_row public.table_sessions%rowtype; waiter public.waiter_profiles%rowtype; action_user uuid;
begin
  select * into tbl from public.physical_tables where id=target_table and active;
  if not found then raise exception 'Table not found'; end if;
  if not public.has_restaurant_text_role(tbl.restaurant_id,array['owner','manager','waiter']) then raise exception 'Not allowed'; end if;
  if guests is not null and (guests<1 or guests>tbl.seats) then raise exception 'Guest count must be between 1 and the table capacity'; end if;
  if exists(select 1 from public.table_sessions where table_id=target_table and status<>'closed') then raise exception 'Table is already open'; end if;
  select * into waiter from public.waiter_profiles where id=private.current_waiter_profile(tbl.restaurant_id,true);
  action_user:=private.action_user_id(tbl.restaurant_id);
  insert into public.table_sessions(restaurant_id,table_id,opened_by,opened_by_waiter_profile_id,assigned_waiter_id,assigned_waiter_profile_id,assigned_waiter_name,guest_count)
  values(tbl.restaurant_id,tbl.id,action_user,waiter.id,waiter.linked_user_id,waiter.id,waiter.full_name,guests) returning * into session_row;
  insert into public.audit_logs(restaurant_id,actor_id,waiter_profile_id,action,entity_type,entity_id,details) values(tbl.restaurant_id,action_user,waiter.id,'table.opened','table_session',session_row.id,jsonb_build_object('guest_count',guests));
  return jsonb_build_object('session_id',session_row.id,'public_token',session_row.public_token,'table_label',tbl.label,'assigned_waiter_name',session_row.assigned_waiter_name,'guest_count',guests);
end; $$;

create or replace function public.open_table_session(target_table uuid) returns jsonb
language sql security definer set search_path=public as $$ select public.open_table_session_v2($1,null); $$;

create or replace function public.attribute_staff_order() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare waiter public.waiter_profiles%rowtype;
begin
  if new.source='staff' then
    select * into waiter from public.waiter_profiles where id=private.current_waiter_profile(new.restaurant_id,true);
    new.placed_by_waiter_profile_id:=waiter.id;
    new.placed_by_waiter_name:=waiter.full_name;
  end if;
  return new;
end; $$;
drop trigger if exists attribute_staff_order_trigger on public.orders;
create trigger attribute_staff_order_trigger before insert on public.orders for each row execute function public.attribute_staff_order();

create or replace function public.set_order_status(target_order uuid,next_status public.order_status,reason text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare current_order public.orders%rowtype; waiter_id uuid; action_user uuid;
begin
  select * into current_order from public.orders where id=target_order for update;
  if not found then raise exception 'Order not found'; end if;
  if not public.has_restaurant_text_role(current_order.restaurant_id,array['owner','manager','waiter','kitchen','bar']) then raise exception 'Not allowed'; end if;
  if (current_order.status='pending' or next_status='served') and not public.has_restaurant_text_role(current_order.restaurant_id,array['owner','manager','waiter']) then raise exception 'Service staff access required'; end if;
  waiter_id:=private.current_waiter_profile(current_order.restaurant_id,true);action_user:=private.action_user_id(current_order.restaurant_id);
  if next_status='rejected' and current_order.status='pending' then
    if length(trim(coalesce(reason,'')))<3 then raise exception 'A rejection reason is required'; end if;
    update public.orders set status='rejected',rejected_by=action_user,rejected_by_waiter_profile_id=waiter_id,rejected_at=now(),rejection_reason=trim(reason) where id=target_order;
    update public.order_items set preparation_status='rejected' where order_id=target_order and voided_at is null;
  elsif next_status='accepted' and current_order.status='pending' then
    update public.orders set status='accepted',accepted_by=action_user,accepted_by_waiter_profile_id=waiter_id,accepted_at=now() where id=target_order;
    update public.order_items set preparation_status='accepted' where order_id=target_order and voided_at is null;
  elsif next_status='preparing' and current_order.status='accepted' then update public.orders set status='preparing' where id=target_order;
  elsif next_status='ready' and current_order.status='preparing' then update public.orders set status='ready' where id=target_order;
  elsif next_status='served' and current_order.status='ready' then
    update public.orders set status='served',served_by_waiter_profile_id=waiter_id where id=target_order;
    update public.order_items set preparation_status='served' where order_id=target_order and voided_at is null;
  else raise exception 'Invalid order status change'; end if;
end; $$;

create or replace function public.void_order_item(target_item uuid,reason text) returns void
language plpgsql security definer set search_path=public,private as $$
declare rid uuid; waiter_id uuid; action_user uuid;
begin
  if length(trim(reason))<3 then raise exception 'A void reason is required'; end if;
  select o.restaurant_id into rid from public.order_items i join public.orders o on o.id=i.order_id where i.id=target_item;
  if not public.has_restaurant_text_role(rid,array['owner','manager','waiter']) then raise exception 'Not allowed'; end if;
  waiter_id:=private.current_waiter_profile(rid,true);action_user:=private.action_user_id(rid);
  update public.order_items set voided_at=now(),voided_by=action_user,voided_by_waiter_profile_id=waiter_id,void_reason=trim(reason) where id=target_item and voided_at is null;
end; $$;

create or replace function public.resolve_customer_request(target_request uuid) returns void
language plpgsql security definer set search_path=public,private as $$
declare request_row public.customer_requests%rowtype; waiter_id uuid; action_user uuid;
begin
  select * into request_row from public.customer_requests where id=target_request for update;
  if not found then raise exception 'Guest request not found'; end if;
  if not public.has_restaurant_text_role(request_row.restaurant_id,array['owner','manager','waiter','cashier']) then raise exception 'Not allowed'; end if;
  waiter_id:=private.current_waiter_profile(request_row.restaurant_id,true);action_user:=private.action_user_id(request_row.restaurant_id);
  update public.customer_requests set status='resolved',acknowledged_by=coalesce(acknowledged_by,action_user),acknowledged_at=coalesce(acknowledged_at,now()),resolved_by=action_user,resolved_by_waiter_profile_id=waiter_id,resolved_at=now() where id=target_request;
  if request_row.type='bill' then update public.table_sessions set status='open' where id=request_row.session_id and status='bill_requested'; end if;
end; $$;

create or replace function public.apply_discount_to_session(target_session uuid,target_discount uuid) returns numeric
language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; d public.discounts%rowtype; subtotal numeric; amount numeric; used_count integer; waiter_id uuid; action_user uuid;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed';
  select * into d from public.discounts where id=target_discount and restaurant_id=s.restaurant_id and active;
  if d.id is null then raise exception 'Discount is unavailable'; end if;
  if not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter','cashier']) then raise exception 'Not allowed'; end if;
  waiter_id:=private.current_waiter_profile(s.restaurant_id,true);action_user:=private.action_user_id(s.restaurant_id);
  select count(*) into used_count from public.applied_discounts where discount_id=d.id;
  if d.usage_limit is not null and used_count>=d.usage_limit and not exists(select 1 from public.applied_discounts where session_id=s.id and discount_id=d.id) then raise exception 'Discount usage limit reached'; end if;
  select coalesce(sum(i.unit_price_snapshot*i.quantity),0) into subtotal from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  amount:=case when d.kind='percentage' then round(subtotal*d.value/100,2) else least(d.value,subtotal) end;
  insert into public.applied_discounts(session_id,discount_id,name_snapshot,amount_snapshot,applied_by,applied_by_waiter_profile_id)
  values(s.id,d.id,d.name,amount,action_user,waiter_id)
  on conflict(session_id,discount_id) where discount_id is not null do update set name_snapshot=excluded.name_snapshot,amount_snapshot=excluded.amount_snapshot,applied_by=excluded.applied_by,applied_by_waiter_profile_id=excluded.applied_by_waiter_profile_id,created_at=now();
  return amount;
end; $$;

create or replace function public.close_table_session(target_session uuid,method public.payment_method) returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; subtotal numeric; discount_total numeric; taxable numeric; tax_total numeric; service_total numeric; final_total numeric; waiter_id uuid; action_user uuid;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found then raise exception 'Open session not found'; end if;
  if not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter','cashier']) then raise exception 'Owner, manager, waiter or cashier access required'; end if;
  if exists(select 1 from public.orders where session_id=s.id and status='pending') then raise exception 'Resolve pending orders before closing the table'; end if;
  waiter_id:=private.current_waiter_profile(s.restaurant_id,true);action_user:=private.action_user_id(s.restaurant_id);
  select * into r from public.restaurants where id=s.restaurant_id;
  select coalesce(sum(i.unit_price_snapshot*i.quantity),0) into subtotal from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  select coalesce(sum(amount_snapshot),0) into discount_total from public.applied_discounts where session_id=s.id;
  taxable:=greatest(subtotal-discount_total,0);
  tax_total:=round(taxable*coalesce(r.tax_percent,0)/100,2);
  service_total:=case when r.service_charge_value is null then 0 when r.service_charge_kind='percentage' then round(taxable*r.service_charge_value/100,2) else r.service_charge_value end;
  final_total:=taxable+tax_total+service_total;
  insert into public.payments(restaurant_id,session_id,method,amount,recorded_by,recorded_by_waiter_profile_id) values(s.restaurant_id,s.id,method,final_total,action_user,waiter_id);
  update public.table_sessions set status='closed',closed_by=action_user,closed_by_waiter_profile_id=waiter_id,closed_at=now(),subtotal_snapshot=subtotal,discount_snapshot=discount_total,tax_snapshot=tax_total,service_snapshot=service_total,total_snapshot=final_total where id=s.id;
  update public.customer_requests set status='resolved',resolved_by=action_user,resolved_by_waiter_profile_id=waiter_id,resolved_at=now() where session_id=s.id and status<>'resolved';
  insert into public.audit_logs(restaurant_id,actor_id,waiter_profile_id,action,entity_type,entity_id,details) values(s.restaurant_id,action_user,waiter_id,'table.closed','table_session',s.id,jsonb_build_object('total',final_total,'payment_method',method));
  return jsonb_build_object(
    'session_id',s.id,
    'items',coalesce((select jsonb_agg(jsonb_build_object('name',i.item_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_snapshot,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',m.modifier_name_snapshot,'price_adjustment',m.price_adjustment_snapshot) order by m.id) from public.order_item_modifiers m where m.order_item_id=i.id),'[]'::jsonb)) order by o.created_at,i.id) from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null),'[]'::jsonb),
    'subtotal',subtotal,'discount',discount_total,'tax',tax_total,'tax_configured',r.tax_percent is not null,'service_charge',service_total,'service_configured',r.service_charge_value is not null,'total',final_total,'payment_method',method
  );
end; $$;

create or replace function public.capture_table_session_event() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare kind text; detail jsonb; waiter_id uuid;
begin
  if tg_op='INSERT' then kind:='session.opened';detail:=jsonb_build_object('status',new.status,'guest_count',new.guest_count,'assigned_waiter_id',new.assigned_waiter_profile_id);waiter_id:=new.opened_by_waiter_profile_id;
  elsif old.status is distinct from new.status then kind:='session.status_changed';detail:=jsonb_build_object('from',old.status,'to',new.status);waiter_id:=coalesce(new.closed_by_waiter_profile_id,private.current_waiter_profile(new.restaurant_id,false));
  elsif old.assigned_waiter_profile_id is distinct from new.assigned_waiter_profile_id then kind:='session.waiter_assigned';detail:=jsonb_build_object('from',old.assigned_waiter_profile_id,'to',new.assigned_waiter_profile_id,'waiter_name',new.assigned_waiter_name);waiter_id:=private.current_waiter_profile(new.restaurant_id,false);
  elsif old.guest_count is distinct from new.guest_count then kind:='session.guest_count_changed';detail:=jsonb_build_object('from',old.guest_count,'to',new.guest_count);waiter_id:=private.current_waiter_profile(new.restaurant_id,false);
  else return new;end if;
  insert into public.table_session_events(restaurant_id,session_id,event_type,actor_id,waiter_profile_id,actor_type,details) values(new.restaurant_id,new.id,kind,auth.uid(),waiter_id,case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

create or replace function public.capture_order_event() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare kind text; detail jsonb; waiter_id uuid;
begin
  if tg_op='INSERT' then kind:='order.submitted';detail:=jsonb_build_object('status',new.status,'source',new.source);waiter_id:=new.placed_by_waiter_profile_id;
  elsif old.status is distinct from new.status then
    kind:='order.status_changed';detail:=jsonb_build_object('from',old.status,'to',new.status,'reason',new.rejection_reason);waiter_id:=coalesce(new.accepted_by_waiter_profile_id,new.rejected_by_waiter_profile_id,new.served_by_waiter_profile_id,private.current_waiter_profile(new.restaurant_id,false));
    if new.status='rejected' and old.status<>'rejected' then update public.menu_items mi set quantity_available=mi.quantity_available+stock.quantity,availability_status=case when mi.availability_status='sold_out' then 'available' else mi.availability_status end from(select menu_item_id,sum(quantity)::integer quantity from public.order_items where order_id=new.id and voided_at is null and menu_item_id is not null group by menu_item_id)stock where mi.id=stock.menu_item_id and mi.quantity_available is not null;end if;
  else return new;end if;
  insert into public.order_events(restaurant_id,order_id,event_type,actor_id,waiter_profile_id,actor_type,details) values(new.restaurant_id,new.id,kind,auth.uid(),waiter_id,case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

create or replace function public.capture_order_item_event() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare rid uuid; kind text; detail jsonb; waiter_id uuid;
begin
  select restaurant_id into rid from public.orders where id=new.order_id;
  if tg_op='INSERT' then kind:='item.created';detail:=jsonb_build_object('status',new.preparation_status,'station',new.prep_station_name_snapshot,'quantity',new.quantity);waiter_id:=private.current_waiter_profile(rid,false);
  elsif old.voided_at is null and new.voided_at is not null then
    kind:='item.voided';detail:=jsonb_build_object('reason',new.void_reason);waiter_id:=new.voided_by_waiter_profile_id;
    if new.menu_item_id is not null and not exists(select 1 from public.orders where id=new.order_id and status='rejected') then update public.menu_items set quantity_available=quantity_available+new.quantity,availability_status=case when availability_status='sold_out' then 'available' else availability_status end where id=new.menu_item_id and quantity_available is not null;end if;
  elsif old.preparation_status is distinct from new.preparation_status then kind:='item.status_changed';detail:=jsonb_build_object('from',old.preparation_status,'to',new.preparation_status,'station',new.prep_station_name_snapshot);waiter_id:=private.current_waiter_profile(rid,false);
  else return new;end if;
  insert into public.order_item_events(restaurant_id,order_item_id,event_type,actor_id,waiter_profile_id,actor_type,details) values(rid,new.id,kind,auth.uid(),waiter_id,case when auth.uid() is null then 'customer' else 'staff' end,detail);
  return new;
end; $$;

alter table public.waiter_profiles enable row level security;
create policy waiter_profiles_read on public.waiter_profiles for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager']));
grant select on public.waiter_profiles to authenticated;

-- Replace legacy enum-based read policies so a shared device cannot read restaurant
-- data until a waiter has entered a valid PIN. This also applies company suspension
-- and subscription expiry consistently to every staff role.
drop policy if exists restaurants_read on public.restaurants;
create policy restaurants_read on public.restaurants for select to authenticated using(public.is_super_admin() or public.has_restaurant_text_role(id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists members_read on public.restaurant_members;
create policy members_read on public.restaurant_members for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists tables_read on public.physical_tables;
create policy tables_read on public.physical_tables for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists sessions_read on public.table_sessions;
create policy sessions_read on public.table_sessions for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists categories_read on public.menu_categories;
create policy categories_read on public.menu_categories for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists items_read on public.menu_items;
create policy items_read on public.menu_items for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items for select to authenticated using(exists(select 1 from public.orders o where o.id=order_id and public.has_restaurant_text_role(o.restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier'])));
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','cashier']));
drop policy if exists audit_read on public.audit_logs;
create policy audit_read on public.audit_logs for select to authenticated using(public.is_super_admin() or public.has_restaurant_text_role(restaurant_id,array['owner']));

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using(
  id=auth.uid() or public.is_super_admin() or exists(
    select 1 from public.restaurant_members mine join public.restaurant_members theirs on theirs.restaurant_id=mine.restaurant_id
    where mine.user_id=auth.uid() and theirs.user_id=profiles.id and mine.active
      and public.has_restaurant_text_role(mine.restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier'])
  )
);
drop policy if exists discounts_read on public.discounts;
create policy discounts_read on public.discounts for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','cashier']));
drop policy if exists applied_discounts_read on public.applied_discounts;
create policy applied_discounts_read on public.applied_discounts for select to authenticated using(exists(select 1 from public.table_sessions s where s.id=session_id and public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','waiter','cashier'])));
drop policy if exists requests_read on public.customer_requests;
create policy requests_read on public.customer_requests for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','cashier']));
drop policy if exists requests_update on public.customer_requests;
create policy requests_update on public.customer_requests for update to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','cashier'])) with check(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','cashier']));

revoke all on function public.list_waiters_for_terminal() from public;
revoke all on function public.start_waiter_terminal_session(uuid,text) from public;
revoke all on function public.end_waiter_terminal_session(uuid) from public;
revoke all on function public.create_tablet_waiter(text,text,text) from public;
revoke all on function public.update_tablet_waiter(uuid,text,text,boolean) from public;
revoke all on function public.set_waiter_pin(uuid,text) from public;
revoke all on function public.set_shared_waiter_device(uuid,boolean) from public;
revoke all on function public.get_waiter_management() from public;
revoke all on function public.get_my_context() from public;
revoke all on function public.assign_waiter_to_session(uuid,uuid) from public;
revoke all on function public.open_table_session_v2(uuid,integer) from public;
revoke all on function public.open_table_session(uuid) from public;
revoke all on function public.set_order_status(uuid,public.order_status,text) from public;
revoke all on function public.void_order_item(uuid,text) from public;
revoke all on function public.resolve_customer_request(uuid) from public;
revoke all on function public.apply_discount_to_session(uuid,uuid) from public;
revoke all on function public.close_table_session(uuid,public.payment_method) from public;
revoke all on function public.sync_waiter_profile_from_member() from public;
revoke all on function public.sync_waiter_profile_from_profile() from public;
revoke all on function public.attribute_staff_order() from public;
revoke all on function public.capture_table_session_event() from public;
revoke all on function public.capture_order_event() from public;
revoke all on function public.capture_order_item_event() from public;
revoke all on function public.has_restaurant_text_role(uuid,text[]) from public;
revoke all on function private.request_waiter_token() from public;
revoke all on function private.current_waiter_profile(uuid,boolean) from public;
revoke all on function private.action_user_id(uuid) from public;
grant execute on function public.list_waiters_for_terminal(),public.start_waiter_terminal_session(uuid,text),public.end_waiter_terminal_session(uuid) to authenticated;
grant execute on function public.create_tablet_waiter(text,text,text),public.update_tablet_waiter(uuid,text,text,boolean),public.set_waiter_pin(uuid,text),public.set_shared_waiter_device(uuid,boolean),public.get_waiter_management() to authenticated;
grant execute on function public.get_my_context(),public.assign_waiter_to_session(uuid,uuid),public.open_table_session_v2(uuid,integer),public.open_table_session(uuid),public.set_order_status(uuid,public.order_status,text),public.void_order_item(uuid,text),public.resolve_customer_request(uuid),public.apply_discount_to_session(uuid,uuid),public.close_table_session(uuid,public.payment_method) to authenticated;
grant execute on function public.has_restaurant_text_role(uuid,text[]) to authenticated;

do $$ begin
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='waiter_profiles') then alter publication supabase_realtime add table public.waiter_profiles;end if;
end $$;
