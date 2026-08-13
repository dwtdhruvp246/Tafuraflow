-- TafuraFlow Release 3
-- Business-day close, cash reconciliation, staff shifts, manager approvals,
-- split bills, and management reports.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Permissions and stronger business-day records
-- ---------------------------------------------------------------------------

insert into public.permission_definitions(permission_key,label,description,sensitive) values
('shift.manage','Manage staff shifts','Schedule staff, review attendance and maintain shift notes',true),
('cash.manage','Manage cash shifts','Open tills, record movements and reconcile counted cash',true),
('bill.split','Split table bills','Create and settle item or equal-share split bills',true),
('report.view','View management reports','View detailed sales, cash, labour, discount and void reports',true),
('task.manage','Manage shift tasks','Create and complete restaurant operating tasks',false)
on conflict(permission_key) do update set label=excluded.label,description=excluded.description,sensitive=excluded.sensitive;

insert into public.role_permissions(permission_key,role,allowed)
select p.permission_key,r.role,
  case
    when r.role='owner' then true
    when r.role='manager' then true
    when r.role='cashier' and p.permission_key in ('cash.manage','bill.split','task.manage') then true
    when r.role='waiter' and p.permission_key in ('bill.split','task.manage') then true
    else false
  end
from (values('shift.manage'),('cash.manage'),('bill.split'),('report.view'),('task.manage')) p(permission_key)
cross join (values('owner'),('manager'),('waiter'),('kitchen'),('bar'),('cashier')) r(role)
on conflict(permission_key,role) do update set allowed=excluded.allowed;

alter table public.business_days add column if not exists locked_at timestamptz;
alter table public.business_days add column if not exists locked_by uuid references public.profiles(id);
alter table public.business_days add column if not exists gross_sales numeric(14,2) not null default 0;
alter table public.business_days add column if not exists payment_total numeric(14,2) not null default 0;
alter table public.business_days add column if not exists cash_expected numeric(14,2) not null default 0;
alter table public.business_days add column if not exists cash_actual numeric(14,2) not null default 0;
alter table public.business_days add column if not exists cash_variance numeric(14,2) not null default 0;
alter table public.business_days add column if not exists close_summary jsonb not null default '{}'::jsonb;

-- A closed day cannot silently reopen when a new table is opened after cutoff.
create or replace function public.set_session_business_context() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare day_row public.business_days%rowtype;
begin
  if new.branch_id is null then
    select id into new.branch_id from public.restaurant_branches
    where restaurant_id=new.restaurant_id and is_default and active limit 1;
  end if;
  if new.branch_id is null then raise exception 'No active branch is configured for this restaurant'; end if;
  new.business_date:=coalesce(new.business_date,public.branch_business_date(new.branch_id,coalesce(new.opened_at,now())));
  select * into day_row from public.business_days where branch_id=new.branch_id and business_date=new.business_date;
  if found and day_row.status='closed' then
    raise exception 'This business day is closed. A manager must reopen it before another table can be opened';
  end if;
  insert into public.business_days(restaurant_id,branch_id,business_date,opened_by)
  values(new.restaurant_id,new.branch_id,new.business_date,new.opened_by)
  on conflict(branch_id,business_date) do nothing;
  return new;
end; $$;

-- ---------------------------------------------------------------------------
-- Cashier shifts and immutable cash movement records
-- ---------------------------------------------------------------------------

create table public.cashier_shifts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  business_day_id uuid not null references public.business_days(id) on delete restrict,
  cashier_user_id uuid not null references public.profiles(id),
  status text not null default 'open' check(status in ('open','reconciled')),
  opening_float numeric(14,2) not null default 0 check(opening_float>=0),
  expected_cash numeric(14,2) not null default 0,
  counted_cash numeric(14,2),
  variance numeric(14,2),
  opened_at timestamptz not null default now(),
  opened_by uuid not null references public.profiles(id),
  reconciled_at timestamptz,
  reconciled_by uuid references public.profiles(id),
  reconciliation_note text,
  created_at timestamptz not null default now()
);
create unique index cashier_one_open_shift_per_user on public.cashier_shifts(branch_id,cashier_user_id) where status='open';
create index cashier_shifts_day_idx on public.cashier_shifts(business_day_id,opened_at);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  business_day_id uuid not null references public.business_days(id) on delete restrict,
  cashier_shift_id uuid not null references public.cashier_shifts(id) on delete restrict,
  movement_type text not null check(movement_type in ('cash_in','paid_out','refund','adjustment')),
  amount numeric(14,2) not null check(amount>0),
  direction smallint not null check(direction in (-1,1)),
  reason text not null check(length(trim(reason))>=3),
  reference text,
  recorded_by uuid not null references public.profiles(id),
  recorded_at timestamptz not null default now()
);
create index cash_movements_shift_idx on public.cash_movements(cashier_shift_id,recorded_at);

alter table public.payments add column if not exists cashier_shift_id uuid references public.cashier_shifts(id);
create index if not exists payments_cashier_shift_idx on public.payments(cashier_shift_id,recorded_at);

create or replace function public.open_cashier_shift(target_branch uuid,opening_float_amount numeric default 0)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype; d public.business_days%rowtype; shift_id uuid; actor uuid;
begin
  select * into b from public.restaurant_branches where id=target_branch and active;
  if not found then raise exception 'Active branch not found'; end if;
  if not private.has_restaurant_permission(b.restaurant_id,'cash.manage') then raise exception 'You do not have permission to manage cash shifts'; end if;
  if coalesce(opening_float_amount,0)<0 then raise exception 'Opening float cannot be negative'; end if;
  actor:=private.action_user_id(b.restaurant_id);
  insert into public.business_days(restaurant_id,branch_id,business_date,opened_by)
  values(b.restaurant_id,b.id,public.branch_business_date(b.id,now()),actor)
  on conflict(branch_id,business_date) do nothing;
  select * into d from public.business_days where branch_id=b.id and business_date=public.branch_business_date(b.id,now());
  if d.status='closed' then raise exception 'This business day is already closed'; end if;
  insert into public.cashier_shifts(restaurant_id,branch_id,business_day_id,cashier_user_id,opening_float,opened_by)
  values(b.restaurant_id,b.id,d.id,actor,coalesce(opening_float_amount,0),actor) returning id into shift_id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details)
  values(b.restaurant_id,b.id,actor,'cashier_shift.opened','cashier_shift',shift_id,jsonb_build_object('opening_float',coalesce(opening_float_amount,0),'business_date',d.business_date));
  return shift_id;
exception when unique_violation then raise exception 'You already have an open cash shift for this branch';
end; $$;

create or replace function public.add_cash_movement(target_shift uuid,movement_kind text,movement_amount numeric,movement_reason text,movement_reference text default null)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare s public.cashier_shifts%rowtype; movement_id uuid; actor uuid; direction_value smallint;
begin
  select * into s from public.cashier_shifts where id=target_shift and status='open' for update;
  if not found then raise exception 'Open cash shift not found'; end if;
  if not private.has_restaurant_permission(s.restaurant_id,'cash.manage') then raise exception 'You do not have permission to record cash movements'; end if;
  if movement_kind not in ('cash_in','paid_out','refund','adjustment') then raise exception 'Choose a valid cash movement'; end if;
  if coalesce(movement_amount,0)=0 or (movement_kind<>'adjustment' and movement_amount<0) then raise exception 'Enter a valid cash amount'; end if;
  if length(trim(coalesce(movement_reason,'')))<3 then raise exception 'Enter a reason for this cash movement'; end if;
  direction_value:=case when movement_kind='cash_in' then 1 when movement_kind in ('paid_out','refund') then -1 else case when movement_amount<0 then -1 else 1 end end;
  actor:=private.action_user_id(s.restaurant_id);
  insert into public.cash_movements(restaurant_id,branch_id,business_day_id,cashier_shift_id,movement_type,amount,direction,reason,reference,recorded_by)
  values(s.restaurant_id,s.branch_id,s.business_day_id,s.id,movement_kind,abs(movement_amount),direction_value,trim(movement_reason),nullif(trim(movement_reference),''),actor)
  returning id into movement_id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details)
  values(s.restaurant_id,s.branch_id,actor,'cash.movement_recorded','cash_movement',movement_id,jsonb_build_object('type',movement_kind,'amount',abs(movement_amount),'direction',direction_value,'reason',trim(movement_reason)));
  return movement_id;
end; $$;

create or replace function public.reconcile_cashier_shift(target_shift uuid,counted_amount numeric,reconciliation_notes text default null)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare s public.cashier_shifts%rowtype; cash_sales numeric; movements numeric; expected numeric; difference numeric; actor uuid;
begin
  select * into s from public.cashier_shifts where id=target_shift and status='open' for update;
  if not found then raise exception 'Open cash shift not found'; end if;
  if not private.has_restaurant_permission(s.restaurant_id,'cash.manage') then raise exception 'You do not have permission to reconcile cash'; end if;
  if counted_amount is null or counted_amount<0 then raise exception 'Enter the counted cash amount'; end if;
  select coalesce(sum(coalesce(p.allocated_amount,p.amount)),0) into cash_sales
  from public.payments p join public.restaurant_payment_methods m on m.branch_id=p.branch_id and m.method_code=p.method_code
  where p.cashier_shift_id=s.id and p.status='recorded' and m.category='cash';
  select coalesce(sum(amount*direction),0) into movements from public.cash_movements where cashier_shift_id=s.id;
  expected:=round(s.opening_float+cash_sales+movements,2); difference:=round(counted_amount-expected,2); actor:=private.action_user_id(s.restaurant_id);
  update public.cashier_shifts set status='reconciled',expected_cash=expected,counted_cash=counted_amount,variance=difference,reconciled_at=now(),reconciled_by=actor,reconciliation_note=nullif(trim(reconciliation_notes),'') where id=s.id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details)
  values(s.restaurant_id,s.branch_id,actor,'cashier_shift.reconciled','cashier_shift',s.id,jsonb_build_object('opening_float',s.opening_float,'cash_sales',cash_sales,'movements',movements,'expected_cash',expected,'counted_cash',counted_amount,'variance',difference));
  return jsonb_build_object('shift_id',s.id,'opening_float',s.opening_float,'cash_sales',cash_sales,'movements',movements,'expected_cash',expected,'counted_cash',counted_amount,'variance',difference);
end; $$;

-- Automatically link any browser-recorded payment to that user's current till.
create or replace function public.attach_payment_cashier_shift() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.cashier_shift_id is null and new.recorded_by is not null then
    select s.id into new.cashier_shift_id from public.cashier_shifts s
    where s.branch_id=new.branch_id and s.cashier_user_id=new.recorded_by and s.status='open'
    order by s.opened_at desc limit 1;
  end if;
  return new;
end; $$;
drop trigger if exists payments_attach_cashier_shift on public.payments;
create trigger payments_attach_cashier_shift before insert on public.payments for each row execute function public.attach_payment_cashier_shift();

-- ---------------------------------------------------------------------------
-- Staff scheduling, attendance, tasks, and manager logbook
-- ---------------------------------------------------------------------------

create table public.staff_shifts (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  staff_user_id uuid references public.profiles(id) on delete set null,
  waiter_profile_id uuid references public.waiter_profiles(id) on delete set null,
  staff_name_snapshot text not null,
  role_snapshot text not null,
  scheduled_start timestamptz not null,
  scheduled_end timestamptz not null,
  clocked_in_at timestamptz,
  clocked_out_at timestamptz,
  status text not null default 'scheduled' check(status in ('scheduled','clocked_in','completed','missed','cancelled')),
  break_minutes integer not null default 0 check(break_minutes between 0 and 1440),
  notes text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(scheduled_end>scheduled_start),
  check(staff_user_id is not null or waiter_profile_id is not null)
);
create index staff_shifts_branch_start_idx on public.staff_shifts(branch_id,scheduled_start);
create trigger staff_shifts_updated before update on public.staff_shifts for each row execute function public.set_updated_at();

create table public.staff_tasks (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  title text not null check(length(trim(title)) between 2 and 160),
  details text,
  assigned_user_id uuid references public.profiles(id) on delete set null,
  assigned_waiter_profile_id uuid references public.waiter_profiles(id) on delete set null,
  due_at timestamptz,
  priority text not null default 'normal' check(priority in ('low','normal','high','urgent')),
  status text not null default 'open' check(status in ('open','completed','cancelled')),
  created_by uuid not null references public.profiles(id),
  completed_by uuid references public.profiles(id),
  completed_at timestamptz,
  created_at timestamptz not null default now()
);
create index staff_tasks_branch_status_idx on public.staff_tasks(branch_id,status,due_at);

create table public.manager_log_entries (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  business_day_id uuid references public.business_days(id) on delete set null,
  category text not null check(category in ('service','staff','maintenance','cash','security','other')),
  note text not null check(length(trim(note))>=3),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create index manager_log_branch_idx on public.manager_log_entries(branch_id,created_at desc);

create or replace function public.create_staff_shift(target_branch uuid,target_user uuid,target_waiter uuid,shift_role text,starts_at timestamptz,ends_at timestamptz,shift_notes text default null)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype; actor uuid; name_value text; shift_id uuid;
begin
  select * into b from public.restaurant_branches where id=target_branch and active;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'shift.manage') then raise exception 'You do not have permission to schedule staff'; end if;
  if starts_at is null or ends_at is null or ends_at<=starts_at then raise exception 'Choose a valid shift start and end'; end if;
  if target_user is not null then select coalesce(nullif(trim(full_name),''),email) into name_value from public.profiles where id=target_user; end if;
  if name_value is null and target_waiter is not null then select full_name into name_value from public.waiter_profiles where id=target_waiter and restaurant_id=b.restaurant_id; end if;
  if name_value is null then raise exception 'Choose a valid staff member'; end if;
  actor:=private.action_user_id(b.restaurant_id);
  insert into public.staff_shifts(restaurant_id,branch_id,staff_user_id,waiter_profile_id,staff_name_snapshot,role_snapshot,scheduled_start,scheduled_end,notes,created_by)
  values(b.restaurant_id,b.id,target_user,target_waiter,name_value,trim(shift_role),starts_at,ends_at,nullif(trim(shift_notes),''),actor) returning id into shift_id;
  return shift_id;
end; $$;

create or replace function public.clock_staff_shift(target_shift uuid,clock_action text,break_minutes_value integer default 0)
returns void language plpgsql security definer set search_path=public,private as $$
declare s public.staff_shifts%rowtype; actor uuid; waiter uuid;
begin
  select * into s from public.staff_shifts where id=target_shift for update;
  if not found then raise exception 'Staff shift not found'; end if;
  actor:=private.action_user_id(s.restaurant_id); waiter:=private.current_waiter_profile(s.restaurant_id,true);
  if not private.has_restaurant_permission(s.restaurant_id,'shift.manage') and not (s.staff_user_id=actor or s.waiter_profile_id=waiter) then raise exception 'You can only clock your own shift'; end if;
  if clock_action='in' then
    if s.status<>'scheduled' then raise exception 'This shift cannot be clocked in'; end if;
    update public.staff_shifts set status='clocked_in',clocked_in_at=now() where id=s.id;
  elsif clock_action='out' then
    if s.status<>'clocked_in' then raise exception 'Clock in before clocking out'; end if;
    update public.staff_shifts set status='completed',clocked_out_at=now(),break_minutes=greatest(coalesce(break_minutes_value,0),0) where id=s.id;
  else raise exception 'Choose clock in or clock out'; end if;
end; $$;

create or replace function public.create_staff_task(target_branch uuid,task_title text,task_details text,target_user uuid,target_waiter uuid,due_time timestamptz,task_priority text default 'normal')
returns uuid language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype; task_id uuid;
begin
  select * into b from public.restaurant_branches where id=target_branch and active;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'task.manage') then raise exception 'You do not have permission to create shift tasks'; end if;
  if length(trim(coalesce(task_title,'')))<2 then raise exception 'Enter a task title'; end if;
  if task_priority not in ('low','normal','high','urgent') then raise exception 'Choose a valid task priority'; end if;
  insert into public.staff_tasks(restaurant_id,branch_id,title,details,assigned_user_id,assigned_waiter_profile_id,due_at,priority,created_by)
  values(b.restaurant_id,b.id,trim(task_title),nullif(trim(task_details),''),target_user,target_waiter,due_time,task_priority,private.action_user_id(b.restaurant_id)) returning id into task_id;
  return task_id;
end; $$;

create or replace function public.set_staff_task_status(target_task uuid,new_status text)
returns void language plpgsql security definer set search_path=public,private as $$
declare t public.staff_tasks%rowtype; actor uuid; waiter uuid;
begin
  select * into t from public.staff_tasks where id=target_task for update;
  if not found then raise exception 'Shift task not found'; end if;
  actor:=private.action_user_id(t.restaurant_id); waiter:=private.current_waiter_profile(t.restaurant_id,true);
  if new_status not in ('open','completed','cancelled') then raise exception 'Choose a valid task status'; end if;
  if not private.has_restaurant_permission(t.restaurant_id,'task.manage') and not (t.assigned_user_id=actor or t.assigned_waiter_profile_id=waiter) then raise exception 'You can only update your assigned tasks'; end if;
  update public.staff_tasks set status=new_status,completed_by=case when new_status='completed' then actor else null end,completed_at=case when new_status='completed' then now() else null end where id=t.id;
end; $$;

create or replace function public.add_manager_log_entry(target_branch uuid,entry_category text,entry_note text)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype; d uuid; entry_id uuid;
begin
  select * into b from public.restaurant_branches where id=target_branch and active;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'shift.manage') then raise exception 'Manager access is required for the logbook'; end if;
  if entry_category not in ('service','staff','maintenance','cash','security','other') then raise exception 'Choose a valid logbook category'; end if;
  if length(trim(coalesce(entry_note,'')))<3 then raise exception 'Enter a logbook note'; end if;
  select id into d from public.business_days where branch_id=b.id and status='open' order by business_date desc limit 1;
  insert into public.manager_log_entries(restaurant_id,branch_id,business_day_id,category,note,created_by)
  values(b.restaurant_id,b.id,d,entry_category,trim(entry_note),private.action_user_id(b.restaurant_id)) returning id into entry_id;
  return entry_id;
end; $$;

-- ---------------------------------------------------------------------------
-- Manager approval rules and expanded request types
-- ---------------------------------------------------------------------------

alter table public.approval_requests drop constraint if exists approval_requests_request_type_check;
alter table public.approval_requests add constraint approval_requests_request_type_check
check(request_type in ('discount','void','payment_correction','receipt_correction','business_day_reopen','cash_adjustment','refund'));

create table public.approval_rules (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  action_type text not null check(action_type in ('discount','void','refund','cash_adjustment')),
  threshold_amount numeric(14,2),
  threshold_percent numeric(6,3),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  updated_at timestamptz not null default now(),
  unique(branch_id,action_type),
  check(threshold_amount is null or threshold_amount>=0),
  check(threshold_percent is null or threshold_percent between 0 and 100)
);
create trigger approval_rules_updated before update on public.approval_rules for each row execute function public.set_updated_at();

create or replace function public.save_approval_rule(target_branch uuid,action_kind text,amount_threshold numeric,percent_threshold numeric,rule_active boolean default true)
returns uuid language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype; rule_id uuid;
begin
  select * into b from public.restaurant_branches where id=target_branch and active;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'approval.review') then raise exception 'Manager approval access is required'; end if;
  if action_kind not in ('discount','void','refund','cash_adjustment') then raise exception 'Choose a valid approval action'; end if;
  insert into public.approval_rules(restaurant_id,branch_id,action_type,threshold_amount,threshold_percent,active,created_by)
  values(b.restaurant_id,b.id,action_kind,amount_threshold,percent_threshold,rule_active,private.action_user_id(b.restaurant_id))
  on conflict(branch_id,action_type) do update set threshold_amount=excluded.threshold_amount,threshold_percent=excluded.threshold_percent,active=excluded.active,updated_at=now()
  returning id into rule_id;
  return rule_id;
end; $$;

create or replace function public.create_approval_request(target_restaurant uuid,target_branch uuid,request_kind text,entity_kind text,target_entity uuid,request_reason text,request_payload jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path=public,private as $$
declare request_id uuid; action_user uuid; waiter_id uuid;
begin
  if not public.has_restaurant_text_role(target_restaurant,array['owner','manager','waiter','kitchen','bar','cashier']) then raise exception 'Restaurant staff access is required'; end if;
  if request_kind not in ('discount','void','payment_correction','receipt_correction','business_day_reopen','cash_adjustment','refund') then raise exception 'Choose a valid approval request type'; end if;
  if length(trim(coalesce(request_reason,'')))<3 then raise exception 'Enter a reason for this approval request'; end if;
  if not exists(select 1 from public.restaurant_branches where id=target_branch and restaurant_id=target_restaurant and active) then raise exception 'Active branch not found'; end if;
  action_user:=private.action_user_id(target_restaurant); waiter_id:=private.current_waiter_profile(target_restaurant,true);
  insert into public.approval_requests(restaurant_id,branch_id,request_type,entity_type,entity_id,requested_by,requested_by_waiter_profile_id,reason,requested_payload)
  values(target_restaurant,target_branch,request_kind,trim(entity_kind),target_entity,action_user,waiter_id,trim(request_reason),coalesce(request_payload,'{}'::jsonb)) returning id into request_id;
  return request_id;
end; $$;

create or replace function public.review_approval_request(target_request uuid,decision text,decision_reason text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare request_row public.approval_requests%rowtype; actor uuid;
begin
  if decision not in ('approved','rejected') then raise exception 'Choose approved or rejected'; end if;
  select * into request_row from public.approval_requests where id=target_request and status='pending' for update;
  if not found then raise exception 'Pending approval request not found'; end if;
  if not private.has_restaurant_permission(request_row.restaurant_id,'approval.review') then raise exception 'You do not have permission to review approvals'; end if;
  if decision='rejected' and length(trim(coalesce(decision_reason,'')))<3 then raise exception 'Enter a reason for rejecting this request'; end if;
  actor:=private.action_user_id(request_row.restaurant_id);
  update public.approval_requests set status=decision,reviewed_by=actor,review_reason=nullif(trim(decision_reason),''),reviewed_at=now() where id=request_row.id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details)
  values(request_row.restaurant_id,request_row.branch_id,actor,'approval.'||decision,'approval_request',request_row.id,jsonb_build_object('request_type',request_row.request_type,'requested_by',request_row.requested_by,'decision_reason',nullif(trim(decision_reason),'')));
end; $$;

-- ---------------------------------------------------------------------------
-- Split-bill allocations layered over the existing one master bill per table
-- ---------------------------------------------------------------------------

create table public.bill_splits (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  bill_id uuid not null references public.bills(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  split_number integer not null,
  label text not null,
  split_type text not null check(split_type in ('equal','items')),
  subtotal numeric(14,2) not null default 0,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  service_total numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  balance numeric(14,2) not null default 0,
  status text not null default 'open' check(status in ('open','paid','cancelled')),
  paid_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(bill_id,split_number),
  check(total>=0 and balance>=0)
);
create index bill_splits_session_idx on public.bill_splits(session_id,status,split_number);

create table public.bill_split_lines (
  id uuid primary key default gen_random_uuid(),
  bill_split_id uuid not null references public.bill_splits(id) on delete cascade,
  order_item_id uuid not null references public.order_items(id) on delete restrict,
  description text not null,
  quantity numeric(12,3) not null,
  allocation_amount numeric(14,2) not null check(allocation_amount>=0),
  created_at timestamptz not null default now(),
  unique(bill_split_id,order_item_id)
);

alter table public.payments add column if not exists bill_split_id uuid references public.bill_splits(id);
create index if not exists payments_bill_split_idx on public.payments(bill_split_id,recorded_at);

create or replace function public.create_bill_split_plan(target_session uuid,split_mode text,equal_split_count integer default null,item_assignments jsonb default '[]'::jsonb)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; preview jsonb; master_bill uuid; actor uuid; n integer; i integer; per_total numeric; remainder numeric; split_id uuid; assignment jsonb; item_subtotal numeric; overall_subtotal numeric; assigned_count integer; assignment_count integer; eligible_count integer; invalid_count integer;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found then raise exception 'Open table session not found'; end if;
  if not private.has_restaurant_permission(s.restaurant_id,'bill.split') or
     (public.has_restaurant_text_role(s.restaurant_id,array['waiter']) and not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','cashier']) and not private.is_current_waiter_assigned(s.id))
  then raise exception 'You do not have permission to split this table bill'; end if;
  if exists(select 1 from public.bill_splits where session_id=s.id and status='paid') then raise exception 'A paid split bill cannot be replaced'; end if;
  preview:=public.get_session_bill_preview(s.id); select * into r from public.restaurants where id=s.restaurant_id; actor:=private.action_user_id(s.restaurant_id);
  insert into public.bills(restaurant_id,branch_id,session_id,business_date,status,currency,subtotal,discount_total,tax_total,service_total,total,balance,issued_at,issued_by)
  values(s.restaurant_id,s.branch_id,s.id,s.business_date,'issued',r.currency,(preview->>'subtotal')::numeric,(preview->>'discount')::numeric,(preview->>'tax')::numeric,(preview->>'service_charge')::numeric,(preview->>'total')::numeric,(preview->>'total')::numeric,now(),actor)
  on conflict(session_id) do update set status='issued',subtotal=excluded.subtotal,discount_total=excluded.discount_total,tax_total=excluded.tax_total,service_total=excluded.service_total,total=excluded.total,balance=excluded.total,issued_at=now(),issued_by=actor
  returning id into master_bill;
  delete from public.bill_lines where bill_id=master_bill;
  insert into public.bill_lines(bill_id,order_item_id,line_type,description,quantity,unit_amount,line_total,metadata)
  select master_bill,oi.id,'item',oi.item_name_snapshot,oi.quantity,oi.unit_price_snapshot,round(oi.quantity*oi.unit_price_snapshot,2),jsonb_build_object('order_id',o.id,'station',oi.prep_station_name_snapshot)
  from public.orders o join public.order_items oi on oi.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and oi.voided_at is null;
  delete from public.bill_splits where session_id=s.id;
  overall_subtotal:=(preview->>'subtotal')::numeric;
  if split_mode='equal' then
    n:=coalesce(equal_split_count,0); if n<2 or n>20 then raise exception 'Choose between 2 and 20 equal bills'; end if;
    per_total:=round((preview->>'total')::numeric/n,2); remainder:=(preview->>'total')::numeric;
    for i in 1..n loop
      insert into public.bill_splits(restaurant_id,branch_id,bill_id,session_id,split_number,label,split_type,subtotal,discount_total,tax_total,service_total,total,balance,created_by)
      values(s.restaurant_id,s.branch_id,master_bill,s.id,i,'Guest '||i,'equal',round((preview->>'subtotal')::numeric/n,2),round((preview->>'discount')::numeric/n,2),round((preview->>'tax')::numeric/n,2),round((preview->>'service_charge')::numeric/n,2),case when i=n then remainder else per_total end,case when i=n then remainder else per_total end,actor);
      remainder:=remainder-per_total;
    end loop;
  elsif split_mode='items' then
    if jsonb_typeof(item_assignments)<>'array' or jsonb_array_length(item_assignments)<2 then raise exception 'Create at least two item bills'; end if;
    select count(*) into eligible_count from public.orders o join public.order_items oi on oi.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and oi.voided_at is null;
    select count(distinct (x.value)::uuid),count(*) into assigned_count,assignment_count from jsonb_array_elements(item_assignments) a cross join lateral jsonb_array_elements_text(coalesce(a->'item_ids','[]'::jsonb)) x;
    select count(*) into invalid_count from jsonb_array_elements(item_assignments) a cross join lateral jsonb_array_elements_text(coalesce(a->'item_ids','[]'::jsonb)) x
    where not exists(select 1 from public.order_items oi join public.orders o on o.id=oi.order_id where oi.id=(x.value)::uuid and o.session_id=s.id and o.status not in ('pending','rejected') and oi.voided_at is null);
    if assigned_count<>eligible_count or assignment_count<>eligible_count or invalid_count>0 then raise exception 'Assign every billable item to exactly one guest'; end if;
    i:=0;
    for assignment in select value from jsonb_array_elements(item_assignments) loop
      i:=i+1;
      select coalesce(sum(oi.quantity*oi.unit_price_snapshot),0) into item_subtotal
      from jsonb_array_elements_text(coalesce(assignment->'item_ids','[]'::jsonb)) x
      join public.order_items oi on oi.id=(x.value)::uuid join public.orders o on o.id=oi.order_id
      where o.session_id=s.id and oi.voided_at is null;
      if item_subtotal<=0 then raise exception 'Each guest bill must contain at least one item'; end if;
      insert into public.bill_splits(restaurant_id,branch_id,bill_id,session_id,split_number,label,split_type,subtotal,discount_total,tax_total,service_total,total,balance,created_by)
      values(s.restaurant_id,s.branch_id,master_bill,s.id,i,coalesce(nullif(trim(assignment->>'label'),''),'Guest '||i),'items',item_subtotal,round((preview->>'discount')::numeric*item_subtotal/nullif(overall_subtotal,0),2),round((preview->>'tax')::numeric*item_subtotal/nullif(overall_subtotal,0),2),round((preview->>'service_charge')::numeric*item_subtotal/nullif(overall_subtotal,0),2),round((preview->>'total')::numeric*item_subtotal/nullif(overall_subtotal,0),2),round((preview->>'total')::numeric*item_subtotal/nullif(overall_subtotal,0),2),actor)
      returning id into split_id;
      insert into public.bill_split_lines(bill_split_id,order_item_id,description,quantity,allocation_amount)
      select split_id,oi.id,oi.item_name_snapshot,oi.quantity,round(oi.quantity*oi.unit_price_snapshot,2)
      from jsonb_array_elements_text(coalesce(assignment->'item_ids','[]'::jsonb)) x join public.order_items oi on oi.id=(x.value)::uuid;
    end loop;
    -- Put any rounding difference on the final split so the plan equals the master bill.
    update public.bill_splits bs set total=bs.total+d.diff,balance=bs.balance+d.diff
    from (select (preview->>'total')::numeric-coalesce(sum(total),0) diff from public.bill_splits where bill_id=master_bill) d
    where bs.bill_id=master_bill and bs.split_number=i and d.diff<>0;
  else raise exception 'Choose equal split or split by item'; end if;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details)
  values(s.restaurant_id,s.branch_id,actor,'bill.split_created','bill',master_bill,jsonb_build_object('session_id',s.id,'mode',split_mode,'split_count',(select count(*) from public.bill_splits where bill_id=master_bill)));
  return jsonb_build_object('bill_id',master_bill,'session_id',s.id,'currency',r.currency,'total',(preview->>'total')::numeric,'splits',(select jsonb_agg(to_jsonb(x) order by x.split_number) from public.bill_splits x where x.bill_id=master_bill));
end; $$;

create or replace function public.record_split_payment(target_split uuid,payment_method_code text,payment_currency text default 'USD',payment_reference text default null,tendered_amount numeric default null,exchange_rate_to_bill numeric default null,idempotency_key uuid default null)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare sp public.bill_splits%rowtype; s public.table_sessions%rowtype; r public.restaurants%rowtype; pm public.restaurant_payment_methods%rowtype; actor uuid; waiter uuid; rate numeric; tendered numeric; converted numeric; payment_id uuid; legacy_method public.payment_method; shift_id uuid; remaining_count integer;
begin
  select * into sp from public.bill_splits where id=target_split and status='open' for update;
  if not found then
    if idempotency_key is not null then select p.id into payment_id from public.payments p where p.bill_split_id=target_split and p.idempotency_key=$7; end if;
    if payment_id is not null then return jsonb_build_object('payment_id',payment_id,'duplicate',true); end if;
    raise exception 'Open split bill not found';
  end if;
  select * into s from public.table_sessions where id=sp.session_id and status<>'closed' for update;
  if not found then raise exception 'Open table session not found'; end if;
  if not private.has_restaurant_permission(sp.restaurant_id,'payment.record') or
     (public.has_restaurant_text_role(sp.restaurant_id,array['waiter']) and not public.has_restaurant_text_role(sp.restaurant_id,array['owner','manager','cashier']) and not private.is_current_waiter_assigned(sp.session_id))
  then raise exception 'You do not have permission to record this table payment'; end if;
  select * into pm from public.restaurant_payment_methods where branch_id=sp.branch_id and method_code=$2 and active;
  if not found then raise exception 'Choose an active payment method'; end if;
  payment_currency:=upper(coalesce(payment_currency,'USD')); if not payment_currency=any(pm.accepted_currencies) then raise exception 'This payment method does not accept the selected currency'; end if;
  if pm.requires_reference and length(trim(coalesce(payment_reference,'')))<2 then raise exception 'Enter the payment reference'; end if;
  select * into r from public.restaurants where id=sp.restaurant_id;
  rate:=case when payment_currency=r.currency then 1 else coalesce(exchange_rate_to_bill,(select rate_to_base from public.branch_currencies where branch_id=sp.branch_id and currency_code=payment_currency)) end;
  tendered:=coalesce(tendered_amount,case when payment_currency=r.currency then sp.balance else null end);
  if rate is null or rate<=0 or tendered is null or tendered<0 then raise exception 'Enter a valid amount and exchange rate'; end if;
  converted:=round(tendered*rate,2); if abs(converted-sp.balance)>0.02 then raise exception 'The amount received must match this split bill balance'; end if;
  actor:=private.action_user_id(sp.restaurant_id); waiter:=private.current_waiter_profile(sp.restaurant_id,true);
  select id into shift_id from public.cashier_shifts where branch_id=sp.branch_id and cashier_user_id=actor and status='open' order by opened_at desc limit 1;
  legacy_method:=case pm.category when 'cash' then 'cash'::public.payment_method when 'card' then 'card'::public.payment_method when 'bank' then 'bank_transfer'::public.payment_method else 'other'::public.payment_method end;
  insert into public.payments(restaurant_id,branch_id,session_id,business_date,bill_id,bill_split_id,cashier_shift_id,method,method_code,currency,amount,tendered_amount,exchange_rate_to_bill,allocated_amount,reference,idempotency_key,recorded_by,recorded_by_waiter_profile_id)
  values(sp.restaurant_id,sp.branch_id,sp.session_id,s.business_date,sp.bill_id,sp.id,shift_id,legacy_method,pm.method_code,payment_currency,sp.balance,tendered,rate,sp.balance,nullif(trim(payment_reference),''),idempotency_key,actor,waiter) returning id into payment_id;
  insert into public.payment_allocations(payment_id,bill_id,amount) values(payment_id,sp.bill_id,sp.balance);
  update public.bill_splits set status='paid',balance=0,paid_at=now() where id=sp.id;
  select count(*) into remaining_count from public.bill_splits where bill_id=sp.bill_id and status='open';
  update public.bills set balance=(select coalesce(sum(balance),0) from public.bill_splits where bill_id=sp.bill_id),status=case when remaining_count=0 then 'paid' else 'partially_paid' end,paid_at=case when remaining_count=0 then now() else null end where id=sp.bill_id;
  if remaining_count=0 then
    update public.table_sessions set status='closed',closed_by=actor,closed_by_waiter_profile_id=waiter,closed_at=now(),subtotal_snapshot=(select subtotal from public.bills where id=sp.bill_id),discount_snapshot=(select discount_total from public.bills where id=sp.bill_id),tax_snapshot=(select tax_total from public.bills where id=sp.bill_id),service_snapshot=(select service_total from public.bills where id=sp.bill_id),total_snapshot=(select total from public.bills where id=sp.bill_id) where id=s.id;
    update public.customer_requests set status='resolved',resolved_by=actor,resolved_by_waiter_profile_id=waiter,resolved_at=now() where session_id=s.id and status<>'resolved';
  end if;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,waiter_profile_id,action,entity_type,entity_id,details)
  values(sp.restaurant_id,sp.branch_id,actor,waiter,'bill.split_paid','bill_split',sp.id,jsonb_build_object('payment_id',payment_id,'method',pm.method_code,'currency',payment_currency,'amount',sp.balance,'table_closed',remaining_count=0));
  return jsonb_build_object('split_id',sp.id,'payment_id',payment_id,'bill_id',sp.bill_id,'amount',sp.balance,'currency',r.currency,'payment_method',pm.display_name,'remaining_splits',remaining_count,'table_closed',remaining_count=0,'duplicate',false);
end; $$;

create or replace function public.cancel_bill_split_plan(target_session uuid)
returns void language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; b uuid;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found or not private.has_restaurant_permission(s.restaurant_id,'bill.split') or
     (public.has_restaurant_text_role(s.restaurant_id,array['waiter']) and not public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','cashier']) and not private.is_current_waiter_assigned(s.id))
  then raise exception 'You do not have permission to cancel this split bill'; end if;
  if exists(select 1 from public.bill_splits where session_id=s.id and status='paid') then raise exception 'A split plan with recorded payments cannot be cancelled'; end if;
  select bill_id into b from public.bill_splits where session_id=s.id limit 1;
  delete from public.bill_splits where session_id=s.id;
  if b is not null then delete from public.bills where id=b; end if;
end; $$;

-- ---------------------------------------------------------------------------
-- Controlled business-day close and advanced report snapshot
-- ---------------------------------------------------------------------------

create or replace function public.close_business_day(target_business_day uuid,closing_note text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare d public.business_days%rowtype; sales numeric; paid numeric; expected numeric; actual numeric; variance_value numeric; actor uuid; summary jsonb;
begin
  select * into d from public.business_days where id=target_business_day and status='open' for update;
  if not found then raise exception 'Open business day not found'; end if;
  if not private.has_restaurant_permission(d.restaurant_id,'business_day.close') then raise exception 'You do not have permission to close the business day'; end if;
  if exists(select 1 from public.table_sessions where branch_id=d.branch_id and business_date=d.business_date and status<>'closed') then raise exception 'Close all tables for this business date first'; end if;
  if exists(select 1 from public.cashier_shifts where business_day_id=d.id and status='open') then raise exception 'Reconcile every open cash shift before closing the business day'; end if;
  select coalesce(sum(total),0) into sales from public.bills where branch_id=d.branch_id and business_date=d.business_date and status='paid';
  select coalesce(sum(coalesce(allocated_amount,amount)),0) into paid from public.payments where branch_id=d.branch_id and business_date=d.business_date and status='recorded';
  select coalesce(sum(expected_cash),0),coalesce(sum(counted_cash),0),coalesce(sum(variance),0) into expected,actual,variance_value from public.cashier_shifts where business_day_id=d.id and status='reconciled';
  summary:=jsonb_build_object('gross_sales',sales,'payment_total',paid,'cash_expected',expected,'cash_actual',actual,'cash_variance',variance_value,'payments_by_method',coalesce((select jsonb_agg(x) from (select coalesce(method_code,method::text) method,sum(coalesce(allocated_amount,amount)) amount,count(*) transactions from public.payments where branch_id=d.branch_id and business_date=d.business_date and status='recorded' group by coalesce(method_code,method::text) order by 1) x),'[]'::jsonb),'cashier_shifts',coalesce((select jsonb_agg(jsonb_build_object('id',id,'cashier_user_id',cashier_user_id,'expected_cash',expected_cash,'counted_cash',counted_cash,'variance',variance)) from public.cashier_shifts where business_day_id=d.id),'[]'::jsonb));
  actor:=private.action_user_id(d.restaurant_id);
  update public.business_days set status='closed',closed_at=now(),closed_by=actor,locked_at=now(),locked_by=actor,close_note=nullif(trim(closing_note),''),gross_sales=sales,payment_total=paid,cash_expected=expected,cash_actual=actual,cash_variance=variance_value,close_summary=summary where id=d.id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details) values(d.restaurant_id,d.branch_id,actor,'business_day.closed','business_day',d.id,summary||jsonb_build_object('business_date',d.business_date,'note',nullif(trim(closing_note),'')));
end; $$;

create or replace function public.get_release_3_reports(target_branch uuid,date_from date,date_to date)
returns jsonb language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype;
begin
  select * into b from public.restaurant_branches where id=target_branch;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'report.view') then raise exception 'You do not have permission to view management reports'; end if;
  if date_from is null or date_to is null or date_to<date_from or date_to-date_from>366 then raise exception 'Choose a report period of up to 366 days'; end if;
  return jsonb_build_object(
    'summary',jsonb_build_object(
      'gross_sales',coalesce((select sum(total) from public.bills where branch_id=b.id and business_date between date_from and date_to and status='paid'),0),
      'payments',coalesce((select sum(coalesce(allocated_amount,amount)) from public.payments where branch_id=b.id and business_date between date_from and date_to and status='recorded'),0),
      'transactions',(select count(*) from public.payments where branch_id=b.id and business_date between date_from and date_to and status='recorded'),
      'average_bill',coalesce((select avg(total) from public.bills where branch_id=b.id and business_date between date_from and date_to and status='paid'),0),
      'discounts',coalesce((select sum(discount_total) from public.bills where branch_id=b.id and business_date between date_from and date_to and status='paid'),0),
      'voids',(select count(*) from public.order_items oi join public.orders o on o.id=oi.order_id where o.branch_id=b.id and o.business_date between date_from and date_to and oi.voided_at is not null),
      'cash_variance',coalesce((select sum(variance) from public.cashier_shifts cs join public.business_days d on d.id=cs.business_day_id where cs.branch_id=b.id and d.business_date between date_from and date_to and cs.status='reconciled'),0),
      'labour_hours',coalesce((select sum(extract(epoch from (clocked_out_at-clocked_in_at))/3600-break_minutes/60.0) from public.staff_shifts where branch_id=b.id and clocked_in_at is not null and clocked_out_at is not null and (scheduled_start at time zone 'UTC')::date between date_from and date_to),0)
    ),
    'payment_methods',coalesce((select jsonb_agg(x) from (select coalesce(p.method_code,p.method::text) label,sum(coalesce(p.allocated_amount,p.amount)) amount,count(*) transactions from public.payments p where p.branch_id=b.id and p.business_date between date_from and date_to and p.status='recorded' group by 1 order by 2 desc) x),'[]'::jsonb),
    'daily_sales',coalesce((select jsonb_agg(x order by x.business_date) from (select business_date,sum(total) sales,count(*) bills from public.bills where branch_id=b.id and business_date between date_from and date_to and status='paid' group by business_date) x),'[]'::jsonb),
    'hourly_sales',coalesce((select jsonb_agg(x order by x.hour) from (select extract(hour from p.recorded_at at time zone b.timezone)::integer hour,sum(coalesce(p.allocated_amount,p.amount)) sales,count(*) transactions from public.payments p where p.branch_id=b.id and p.business_date between date_from and date_to and p.status='recorded' group by 1) x),'[]'::jsonb),
    'top_items',coalesce((select jsonb_agg(x) from (select oi.item_name_snapshot label,sum(oi.quantity) quantity,sum(oi.quantity*oi.unit_price_snapshot) sales from public.order_items oi join public.orders o on o.id=oi.order_id where o.branch_id=b.id and o.business_date between date_from and date_to and oi.voided_at is null and o.status not in ('pending','rejected') group by oi.item_name_snapshot order by sales desc limit 25) x),'[]'::jsonb),
    'table_sales',coalesce((select jsonb_agg(x) from (select t.label,sum(bl.total) sales,count(*) bills from public.bills bl join public.table_sessions s on s.id=bl.session_id join public.physical_tables t on t.id=s.table_id where bl.branch_id=b.id and bl.business_date between date_from and date_to and bl.status='paid' group by t.label order by sales desc) x),'[]'::jsonb),
    'waiter_sales',coalesce((select jsonb_agg(x) from (select coalesce(s.assigned_waiter_name,'Unassigned') label,sum(bl.total) sales,count(*) bills from public.bills bl join public.table_sessions s on s.id=bl.session_id where bl.branch_id=b.id and bl.business_date between date_from and date_to and bl.status='paid' group by coalesce(s.assigned_waiter_name,'Unassigned') order by sales desc) x),'[]'::jsonb),
    'discounts',coalesce((select jsonb_agg(x) from (select ad.name_snapshot label,count(*) uses,sum(ad.amount_snapshot) amount from public.applied_discounts ad join public.table_sessions s on s.id=ad.session_id where s.branch_id=b.id and s.business_date between date_from and date_to group by ad.name_snapshot order by amount desc) x),'[]'::jsonb),
    'voids',coalesce((select jsonb_agg(x) from (select oi.item_name_snapshot label,count(*) quantity,sum(oi.quantity*oi.unit_price_snapshot) value,coalesce(oi.void_reason,'No reason') reason from public.order_items oi join public.orders o on o.id=oi.order_id where o.branch_id=b.id and o.business_date between date_from and date_to and oi.voided_at is not null group by oi.item_name_snapshot,coalesce(oi.void_reason,'No reason') order by value desc) x),'[]'::jsonb),
    'cash_shifts',coalesce((select jsonb_agg(x) from (select cs.id,p.full_name cashier,d.business_date,cs.opening_float,cs.expected_cash,cs.counted_cash,cs.variance,cs.status from public.cashier_shifts cs join public.business_days d on d.id=cs.business_day_id left join public.profiles p on p.id=cs.cashier_user_id where cs.branch_id=b.id and d.business_date between date_from and date_to order by cs.opened_at desc) x),'[]'::jsonb),
    'staff_attendance',coalesce((select jsonb_agg(x) from (select staff_name_snapshot,role_snapshot,scheduled_start,scheduled_end,clocked_in_at,clocked_out_at,break_minutes,status from public.staff_shifts where branch_id=b.id and (scheduled_start at time zone b.timezone)::date between date_from and date_to order by scheduled_start desc) x),'[]'::jsonb)
  );
end; $$;

-- ---------------------------------------------------------------------------
-- RLS, Data API grants, function privileges, and Realtime
-- ---------------------------------------------------------------------------

alter table public.cashier_shifts enable row level security;
alter table public.cash_movements enable row level security;
alter table public.staff_shifts enable row level security;
alter table public.staff_tasks enable row level security;
alter table public.manager_log_entries enable row level security;
alter table public.approval_rules enable row level security;
alter table public.bill_splits enable row level security;
alter table public.bill_split_lines enable row level security;

create policy cashier_shifts_read on public.cashier_shifts for select to authenticated using(private.has_restaurant_permission(restaurant_id,'cash.manage') or private.has_restaurant_permission(restaurant_id,'report.view'));
create policy cash_movements_read on public.cash_movements for select to authenticated using(private.has_restaurant_permission(restaurant_id,'cash.manage') or private.has_restaurant_permission(restaurant_id,'report.view'));
create policy staff_shifts_read on public.staff_shifts for select to authenticated using(private.has_restaurant_permission(restaurant_id,'shift.manage') or staff_user_id=private.action_user_id(restaurant_id) or waiter_profile_id=private.current_waiter_profile(restaurant_id,true));
create policy staff_tasks_read on public.staff_tasks for select to authenticated using(private.has_restaurant_permission(restaurant_id,'task.manage') or assigned_user_id=private.action_user_id(restaurant_id) or assigned_waiter_profile_id=private.current_waiter_profile(restaurant_id,true));
create policy manager_log_read on public.manager_log_entries for select to authenticated using(private.has_restaurant_permission(restaurant_id,'shift.manage'));
create policy approval_rules_read on public.approval_rules for select to authenticated using(private.has_restaurant_permission(restaurant_id,'approval.review'));
drop policy if exists approvals_read on public.approval_requests;
create policy approvals_read on public.approval_requests for select to authenticated using(
  public.has_restaurant_text_role(restaurant_id,array['owner','manager']) or
  requested_by_waiter_profile_id=private.current_waiter_profile(restaurant_id,true) or
  (requested_by_waiter_profile_id is null and requested_by=auth.uid())
);
create policy bill_splits_read on public.bill_splits for select to authenticated using(
  private.has_restaurant_permission(restaurant_id,'payment.view') or
  public.has_restaurant_text_role(restaurant_id,array['owner','manager','cashier']) or
  (public.has_restaurant_text_role(restaurant_id,array['waiter']) and private.is_current_waiter_assigned(session_id))
);
create policy bill_split_lines_read on public.bill_split_lines for select to authenticated using(exists(
  select 1 from public.bill_splits s where s.id=bill_split_lines.bill_split_id and (
    private.has_restaurant_permission(s.restaurant_id,'payment.view') or
    public.has_restaurant_text_role(s.restaurant_id,array['owner','manager','cashier']) or
    (public.has_restaurant_text_role(s.restaurant_id,array['waiter']) and private.is_current_waiter_assigned(s.session_id))
  )
));

grant select on public.cashier_shifts,public.cash_movements,public.staff_shifts,public.staff_tasks,public.manager_log_entries,public.approval_rules,public.bill_splits,public.bill_split_lines to authenticated;

revoke all on function public.open_cashier_shift(uuid,numeric) from public;
revoke all on function public.add_cash_movement(uuid,text,numeric,text,text) from public;
revoke all on function public.reconcile_cashier_shift(uuid,numeric,text) from public;
revoke all on function public.create_staff_shift(uuid,uuid,uuid,text,timestamptz,timestamptz,text) from public;
revoke all on function public.clock_staff_shift(uuid,text,integer) from public;
revoke all on function public.create_staff_task(uuid,text,text,uuid,uuid,timestamptz,text) from public;
revoke all on function public.set_staff_task_status(uuid,text) from public;
revoke all on function public.add_manager_log_entry(uuid,text,text) from public;
revoke all on function public.save_approval_rule(uuid,text,numeric,numeric,boolean) from public;
revoke all on function public.create_bill_split_plan(uuid,text,integer,jsonb) from public;
revoke all on function public.record_split_payment(uuid,text,text,text,numeric,numeric,uuid) from public;
revoke all on function public.cancel_bill_split_plan(uuid) from public;
revoke all on function public.get_release_3_reports(uuid,date,date) from public;
grant execute on function public.open_cashier_shift(uuid,numeric),public.add_cash_movement(uuid,text,numeric,text,text),public.reconcile_cashier_shift(uuid,numeric,text),public.create_staff_shift(uuid,uuid,uuid,text,timestamptz,timestamptz,text),public.clock_staff_shift(uuid,text,integer),public.create_staff_task(uuid,text,text,uuid,uuid,timestamptz,text),public.set_staff_task_status(uuid,text),public.add_manager_log_entry(uuid,text,text),public.save_approval_rule(uuid,text,numeric,numeric,boolean),public.create_bill_split_plan(uuid,text,integer,jsonb),public.record_split_payment(uuid,text,text,text,numeric,numeric,uuid),public.cancel_bill_split_plan(uuid),public.get_release_3_reports(uuid,date,date) to authenticated;

revoke all on function public.attach_payment_cashier_shift() from public;

do $$ begin alter publication supabase_realtime add table public.cashier_shifts; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.cash_movements; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.staff_shifts; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.staff_tasks; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.manager_log_entries; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.approval_requests; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.bill_splits; exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
