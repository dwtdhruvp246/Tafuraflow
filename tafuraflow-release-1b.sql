-- TafuraFlow Release 1B: Business and Payment Foundations
-- Requires Release 1A, Release 1A.1, waiter-history repairs, and direct routing.

-- ---------------------------------------------------------------------------
-- Branches, currencies, and business dates
-- ---------------------------------------------------------------------------

create table public.restaurant_branches (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  name text not null check (length(trim(name)) between 2 and 120),
  code text not null check (code ~ '^[A-Z0-9_-]{2,20}$'),
  timezone text not null default 'Africa/Harare',
  business_day_cutoff time not null default '04:00',
  base_currency text not null default 'USD' check (base_currency in ('USD','ZWG')),
  is_default boolean not null default false,
  active boolean not null default true,
  address text,
  phone text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (restaurant_id, code)
);
create unique index restaurant_one_default_branch_idx on public.restaurant_branches(restaurant_id) where is_default;

insert into public.restaurant_branches(restaurant_id,name,code,is_default)
select r.id, r.name || ' Main', 'MAIN', true
from public.restaurants r
where not exists(select 1 from public.restaurant_branches b where b.restaurant_id=r.id);

create table public.branch_currencies (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  currency_code text not null check (currency_code in ('USD','ZWG')),
  enabled boolean not null default false,
  is_base boolean not null default false,
  rate_to_base numeric(18,8) not null default 1 check (rate_to_base > 0),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now(),
  unique(branch_id,currency_code)
);
create unique index branch_one_base_currency_idx on public.branch_currencies(branch_id) where is_base;

insert into public.branch_currencies(restaurant_id,branch_id,currency_code,enabled,is_base,rate_to_base)
select b.restaurant_id,b.id,'USD',true,true,1 from public.restaurant_branches b
on conflict(branch_id,currency_code) do nothing;
insert into public.branch_currencies(restaurant_id,branch_id,currency_code,enabled,is_base,rate_to_base)
select b.restaurant_id,b.id,'ZWG',false,false,1 from public.restaurant_branches b
on conflict(branch_id,currency_code) do nothing;

create table public.business_days (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  business_date date not null,
  status text not null default 'open' check(status in ('open','closed')),
  opened_at timestamptz not null default now(),
  opened_by uuid references public.profiles(id),
  closed_at timestamptz,
  closed_by uuid references public.profiles(id),
  close_note text,
  created_at timestamptz not null default now(),
  unique(branch_id,business_date),
  check((status='open' and closed_at is null) or (status='closed' and closed_at is not null))
);

create or replace function public.branch_business_date(target_branch uuid, moment timestamptz default now())
returns date language sql stable set search_path=public as $$
  select ((moment at time zone b.timezone) - (b.business_day_cutoff - time '00:00'))::date
  from public.restaurant_branches b where b.id=target_branch;
$$;

-- ---------------------------------------------------------------------------
-- Backfill branch-ready operational records
-- ---------------------------------------------------------------------------

alter table public.physical_tables add column branch_id uuid references public.restaurant_branches(id);
alter table public.table_sessions add column branch_id uuid references public.restaurant_branches(id);
alter table public.table_sessions add column business_date date;
alter table public.menu_categories add column branch_id uuid references public.restaurant_branches(id);
alter table public.menu_items add column branch_id uuid references public.restaurant_branches(id);
alter table public.prep_stations add column branch_id uuid references public.restaurant_branches(id);
alter table public.orders add column branch_id uuid references public.restaurant_branches(id);
alter table public.orders add column business_date date;
alter table public.discounts add column branch_id uuid references public.restaurant_branches(id);
alter table public.customer_requests add column branch_id uuid references public.restaurant_branches(id);
alter table public.payments add column branch_id uuid references public.restaurant_branches(id);
alter table public.payments add column business_date date;
alter table public.audit_logs add column branch_id uuid references public.restaurant_branches(id);
alter table public.waiter_profiles add column branch_id uuid references public.restaurant_branches(id);

update public.physical_tables x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.table_sessions x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.menu_categories x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.menu_items x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.prep_stations x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.orders x set branch_id=s.branch_id from public.table_sessions s where s.id=x.session_id and x.branch_id is null;
update public.discounts x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.customer_requests x set branch_id=s.branch_id from public.table_sessions s where s.id=x.session_id and x.branch_id is null;
update public.payments x set branch_id=s.branch_id from public.table_sessions s where s.id=x.session_id and x.branch_id is null;
update public.audit_logs x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;
update public.waiter_profiles x set branch_id=b.id from public.restaurant_branches b where b.restaurant_id=x.restaurant_id and b.is_default and x.branch_id is null;

update public.table_sessions s set business_date=public.branch_business_date(s.branch_id,s.opened_at) where business_date is null;
update public.orders o set business_date=s.business_date from public.table_sessions s where s.id=o.session_id and o.business_date is null;
update public.payments p set business_date=s.business_date from public.table_sessions s where s.id=p.session_id and p.business_date is null;

alter table public.physical_tables alter column branch_id set not null;
alter table public.table_sessions alter column branch_id set not null;
alter table public.table_sessions alter column business_date set not null;
alter table public.menu_categories alter column branch_id set not null;
alter table public.menu_items alter column branch_id set not null;
alter table public.prep_stations alter column branch_id set not null;
alter table public.orders alter column branch_id set not null;
alter table public.orders alter column business_date set not null;
alter table public.discounts alter column branch_id set not null;
alter table public.customer_requests alter column branch_id set not null;
alter table public.payments alter column branch_id set not null;
alter table public.payments alter column business_date set not null;
alter table public.waiter_profiles alter column branch_id set not null;

create index physical_tables_branch_idx on public.physical_tables(branch_id,active,label);
create index sessions_branch_business_date_idx on public.table_sessions(branch_id,business_date,status);
create index orders_branch_business_date_idx on public.orders(branch_id,business_date,created_at desc);
create index payments_branch_business_date_idx on public.payments(branch_id,business_date,recorded_at desc);
create index audit_branch_created_idx on public.audit_logs(branch_id,created_at desc);

insert into public.business_days(restaurant_id,branch_id,business_date,status,opened_at,closed_at)
select s.restaurant_id,s.branch_id,s.business_date,
       case when bool_or(s.status<>'closed') then 'open' else 'closed' end,
       min(s.opened_at),
       case when bool_or(s.status<>'closed') then null else max(s.closed_at) end
from public.table_sessions s
group by s.restaurant_id,s.branch_id,s.business_date
on conflict(branch_id,business_date) do nothing;

create or replace function public.set_default_branch_context() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.branch_id is null then
    select id into new.branch_id from public.restaurant_branches where restaurant_id=new.restaurant_id and is_default and active limit 1;
  end if;
  if new.branch_id is null then raise exception 'No active branch is configured for this restaurant'; end if;
  return new;
end; $$;

create or replace function public.set_session_business_context() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.branch_id is null then select id into new.branch_id from public.restaurant_branches where restaurant_id=new.restaurant_id and is_default and active limit 1; end if;
  new.business_date:=coalesce(new.business_date,public.branch_business_date(new.branch_id,coalesce(new.opened_at,now())));
  insert into public.business_days(restaurant_id,branch_id,business_date,opened_by)
  values(new.restaurant_id,new.branch_id,new.business_date,new.opened_by)
  on conflict(branch_id,business_date) do nothing;
  return new;
end; $$;

create or replace function public.set_order_business_context() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  select s.branch_id,s.business_date into new.branch_id,new.business_date from public.table_sessions s where s.id=new.session_id;
  if new.branch_id is null then raise exception 'Order table session has no branch'; end if;
  return new;
end; $$;

create or replace function public.set_payment_business_context() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  select s.branch_id,s.business_date into new.branch_id,new.business_date from public.table_sessions s where s.id=new.session_id;
  if new.branch_id is null then raise exception 'Payment table session has no branch'; end if;
  return new;
end; $$;

create or replace function public.set_request_branch_context() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  select s.branch_id into new.branch_id from public.table_sessions s where s.id=new.session_id;
  if new.branch_id is null then raise exception 'Service request table session has no branch'; end if;
  return new;
end; $$;

create trigger branches_updated before update on public.restaurant_branches for each row execute function public.set_updated_at();
create trigger branch_currencies_updated before update on public.branch_currencies for each row execute function public.set_updated_at();
create trigger tables_branch_context before insert on public.physical_tables for each row execute function public.set_default_branch_context();
create trigger categories_branch_context before insert on public.menu_categories for each row execute function public.set_default_branch_context();
create trigger items_branch_context before insert on public.menu_items for each row execute function public.set_default_branch_context();
create trigger stations_branch_context before insert on public.prep_stations for each row execute function public.set_default_branch_context();
create trigger discounts_branch_context before insert on public.discounts for each row execute function public.set_default_branch_context();
create trigger waiter_profiles_branch_context before insert on public.waiter_profiles for each row execute function public.set_default_branch_context();
create trigger sessions_business_context before insert on public.table_sessions for each row execute function public.set_session_business_context();
create trigger orders_business_context before insert on public.orders for each row execute function public.set_order_business_context();
create trigger payments_business_context before insert on public.payments for each row execute function public.set_payment_business_context();

-- ---------------------------------------------------------------------------
-- Permission and approval foundations
-- ---------------------------------------------------------------------------

create table public.permission_definitions (
  permission_key text primary key,
  label text not null,
  description text not null,
  sensitive boolean not null default false
);
create table public.role_permissions (
  permission_key text not null references public.permission_definitions(permission_key) on delete cascade,
  role text not null check(role in ('owner','manager','waiter','kitchen','bar','cashier')),
  allowed boolean not null default false,
  primary key(permission_key,role)
);
create table public.staff_permission_overrides (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid references public.restaurant_branches(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  permission_key text not null references public.permission_definitions(permission_key) on delete cascade,
  allowed boolean not null,
  reason text not null check(length(trim(reason))>=3),
  granted_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique(restaurant_id,branch_id,user_id,permission_key)
);

insert into public.permission_definitions(permission_key,label,description,sensitive) values
('branch.view','View business setup','View branches, business dates, currencies and payment methods',false),
('branch.configure','Configure business setup','Change timezone, cutoff, currencies and payment methods',true),
('business_day.close','Close business day','Close a business date after all tables are closed',true),
('payment.record','Record payments','Record a final offline restaurant payment',true),
('payment.view','View payments','View restaurant receipts and payment details',true),
('discount.apply','Apply discounts','Apply configured discounts to a table bill',true),
('void.item','Void order items','Void an item with a required reason',true),
('approval.review','Review approvals','Approve or reject controlled requests',true),
('security.view','View security alerts','Review suspicious public activity',true)
on conflict(permission_key) do nothing;

insert into public.role_permissions(permission_key,role,allowed)
select d.permission_key,r.role,
  case
    when r.role='owner' then true
    when r.role='manager' and d.permission_key in ('branch.view','business_day.close','payment.record','payment.view','discount.apply','void.item','approval.review','security.view') then true
    when r.role='waiter' and d.permission_key in ('payment.record','discount.apply','void.item') then true
    when r.role='cashier' and d.permission_key in ('branch.view','payment.record','payment.view') then true
    when r.role in ('kitchen','bar') and d.permission_key='void.item' then true
    else false end
from public.permission_definitions d cross join (values('owner'),('manager'),('waiter'),('kitchen'),('bar'),('cashier')) r(role)
on conflict(permission_key,role) do update set allowed=excluded.allowed;

create or replace function private.has_restaurant_permission(target_restaurant uuid,target_permission text)
returns boolean language sql stable security definer set search_path=public,private as $$
  select coalesce(
    (select o.allowed from public.staff_permission_overrides o
     where o.restaurant_id=target_restaurant and o.user_id=auth.uid() and o.permission_key=target_permission
     order by (o.branch_id is not null) desc limit 1),
    exists(
      select 1 from public.role_permissions rp
      where rp.permission_key=target_permission and rp.allowed and (
        (rp.role='owner' and public.has_restaurant_text_role(target_restaurant,array['owner'])) or
        (rp.role='manager' and public.has_restaurant_text_role(target_restaurant,array['manager'])) or
        (rp.role='waiter' and public.has_restaurant_text_role(target_restaurant,array['waiter'])) or
        (rp.role='kitchen' and public.has_restaurant_text_role(target_restaurant,array['kitchen'])) or
        (rp.role='bar' and public.has_restaurant_text_role(target_restaurant,array['bar'])) or
        (rp.role='cashier' and public.has_restaurant_text_role(target_restaurant,array['cashier']))
      )
    ),false);
$$;

create table public.approval_requests (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  request_type text not null check(request_type in ('discount','void','payment_correction','receipt_correction','business_day_reopen')),
  entity_type text not null,
  entity_id uuid,
  requested_by uuid not null references public.profiles(id),
  requested_by_waiter_profile_id uuid references public.waiter_profiles(id),
  reason text not null check(length(trim(reason))>=3),
  requested_payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
  reviewed_by uuid references public.profiles(id),
  review_reason text,
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
create index approval_requests_branch_status_idx on public.approval_requests(branch_id,status,created_at desc);

-- ---------------------------------------------------------------------------
-- Zimbabwe payment methods, bills, and allocations
-- ---------------------------------------------------------------------------

create table public.restaurant_payment_methods (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  method_code text not null check(method_code ~ '^[a-z0-9_]{2,40}$'),
  display_name text not null,
  category text not null check(category in ('cash','card','mobile_money','bank','other')),
  accepted_currencies text[] not null default array['USD']::text[],
  requires_reference boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(branch_id,method_code),
  check(accepted_currencies <@ array['USD','ZWG']::text[])
);

insert into public.restaurant_payment_methods(restaurant_id,branch_id,method_code,display_name,category,accepted_currencies,requires_reference,sort_order)
select b.restaurant_id,b.id,v.code,v.label,v.category,v.currencies,v.reference,v.sort_order
from public.restaurant_branches b cross join (values
  ('cash_usd','Cash — USD','cash',array['USD']::text[],false,10),
  ('cash_zwg','Cash — ZiG','cash',array['ZWG']::text[],false,20),
  ('card','Card','card',array['USD','ZWG']::text[],true,30),
  ('ecocash','EcoCash','mobile_money',array['USD','ZWG']::text[],true,40),
  ('innbucks','InnBucks','mobile_money',array['USD']::text[],true,50),
  ('zipit','ZIPIT','bank',array['USD','ZWG']::text[],true,60),
  ('bank_transfer','Bank transfer','bank',array['USD','ZWG']::text[],true,70),
  ('other','Other','other',array['USD','ZWG']::text[],true,80)
) v(code,label,category,currencies,reference,sort_order)
on conflict(branch_id,method_code) do nothing;

create trigger restaurant_payment_methods_updated before update on public.restaurant_payment_methods for each row execute function public.set_updated_at();

create table public.bills (
  id uuid primary key default gen_random_uuid(),
  bill_number bigint generated always as identity unique,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id),
  session_id uuid not null unique references public.table_sessions(id),
  business_date date not null,
  status text not null default 'draft' check(status in ('draft','issued','partially_paid','paid','voided')),
  currency text not null check(currency in ('USD','ZWG')),
  subtotal numeric(14,2) not null default 0,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  service_total numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  balance numeric(14,2) not null default 0,
  issued_at timestamptz,
  issued_by uuid references public.profiles(id),
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(subtotal>=0 and discount_total>=0 and tax_total>=0 and service_total>=0 and total>=0 and balance>=0)
);
create index bills_branch_business_date_idx on public.bills(branch_id,business_date,created_at desc);
create trigger bills_updated before update on public.bills for each row execute function public.set_updated_at();

create table public.bill_lines (
  id uuid primary key default gen_random_uuid(),
  bill_id uuid not null references public.bills(id) on delete cascade,
  order_item_id uuid references public.order_items(id) on delete set null,
  line_type text not null default 'item' check(line_type in ('item','discount','tax','service','adjustment')),
  description text not null,
  quantity numeric(12,3) not null default 1,
  unit_amount numeric(14,2) not null,
  line_total numeric(14,2) not null,
  tax_category_snapshot text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index bill_lines_bill_idx on public.bill_lines(bill_id,id);

alter table public.payments drop constraint if exists payments_session_id_key;
alter table public.payments add column bill_id uuid references public.bills(id);
alter table public.payments add column method_code text;
alter table public.payments add column currency text check(currency in ('USD','ZWG'));
alter table public.payments add column tendered_amount numeric(14,2) check(tendered_amount>=0);
alter table public.payments add column exchange_rate_to_bill numeric(18,8) check(exchange_rate_to_bill>0);
alter table public.payments add column allocated_amount numeric(14,2) check(allocated_amount>=0);
alter table public.payments add column reference text;
alter table public.payments add column idempotency_key uuid;
alter table public.payments add column status text not null default 'recorded' check(status in ('recorded','voided','corrected'));
alter table public.payments add column corrected_payment_id uuid references public.payments(id);
alter table public.payments add column correction_reason text;
create unique index payments_idempotency_idx on public.payments(session_id,idempotency_key) where idempotency_key is not null;
create index payments_bill_idx on public.payments(bill_id,recorded_at);

insert into public.bills(restaurant_id,branch_id,session_id,business_date,status,currency,subtotal,discount_total,tax_total,service_total,total,balance,issued_at,issued_by,paid_at)
select s.restaurant_id,s.branch_id,s.id,s.business_date,'paid',r.currency,
       coalesce(s.subtotal_snapshot,0),coalesce(s.discount_snapshot,0),coalesce(s.tax_snapshot,0),coalesce(s.service_snapshot,0),coalesce(s.total_snapshot,0),0,s.closed_at,s.closed_by,s.closed_at
from public.table_sessions s join public.restaurants r on r.id=s.restaurant_id
where s.status='closed'
on conflict(session_id) do nothing;

insert into public.bill_lines(bill_id,order_item_id,line_type,description,quantity,unit_amount,line_total,metadata)
select b.id,oi.id,'item',oi.item_name_snapshot,oi.quantity,oi.unit_price_snapshot,oi.quantity*oi.unit_price_snapshot,
       jsonb_build_object('order_id',o.id,'voided',oi.voided_at is not null)
from public.bills b join public.orders o on o.session_id=b.session_id join public.order_items oi on oi.order_id=o.id
where o.status not in ('pending','rejected') and oi.voided_at is null
and not exists(select 1 from public.bill_lines bl where bl.bill_id=b.id and bl.order_item_id=oi.id);

update public.payments p set
  bill_id=b.id,
  method_code=case p.method when 'cash' then 'cash_usd' when 'card' then 'card' when 'bank_transfer' then 'bank_transfer' else 'other' end,
  currency=coalesce(p.currency,'USD'),
  tendered_amount=coalesce(p.tendered_amount,p.amount),
  exchange_rate_to_bill=coalesce(p.exchange_rate_to_bill,1),
  allocated_amount=coalesce(p.allocated_amount,p.amount)
from public.bills b where b.session_id=p.session_id;

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments(id) on delete restrict,
  bill_id uuid not null references public.bills(id) on delete restrict,
  amount numeric(14,2) not null check(amount>0),
  created_at timestamptz not null default now(),
  unique(payment_id,bill_id)
);
create index payment_allocations_bill_idx on public.payment_allocations(bill_id);
insert into public.payment_allocations(payment_id,bill_id,amount)
select p.id,p.bill_id,coalesce(p.allocated_amount,p.amount) from public.payments p
where p.bill_id is not null and coalesce(p.allocated_amount,p.amount)>0
on conflict(payment_id,bill_id) do nothing;

-- ---------------------------------------------------------------------------
-- Security activity and immutable financial events
-- ---------------------------------------------------------------------------

create table public.branch_rate_limits (
  branch_id uuid primary key references public.restaurant_branches(id) on delete cascade,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  customer_orders_per_minute integer not null default 6 check(customer_orders_per_minute between 1 and 60),
  customer_requests_per_minute integer not null default 8 check(customer_requests_per_minute between 1 and 60),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);
insert into public.branch_rate_limits(branch_id,restaurant_id)
select id,restaurant_id from public.restaurant_branches on conflict(branch_id) do nothing;

create table public.public_api_activity (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  session_id uuid not null references public.table_sessions(id) on delete cascade,
  activity_kind text not null check(activity_kind in ('order','request')),
  entity_id uuid not null,
  created_at timestamptz not null default now()
);
create index public_activity_session_time_idx on public.public_api_activity(session_id,activity_kind,created_at desc);

create table public.suspicious_activity_events (
  id uuid primary key default gen_random_uuid(),
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  session_id uuid references public.table_sessions(id) on delete cascade,
  event_kind text not null,
  severity text not null default 'warning' check(severity in ('info','warning','critical')),
  details jsonb not null default '{}'::jsonb,
  status text not null default 'open' check(status in ('open','reviewed','dismissed')),
  reviewed_by uuid references public.profiles(id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);
create index suspicious_activity_branch_status_idx on public.suspicious_activity_events(branch_id,status,created_at desc);

create or replace function public.enforce_public_order_rate() returns trigger
language plpgsql security definer set search_path=public as $$
declare allowed_count integer;
begin
  if new.source::text<>'customer' then return new; end if;
  select customer_orders_per_minute into allowed_count from public.branch_rate_limits where branch_id=new.branch_id;
  if (select count(*) from public.orders where session_id=new.session_id and source::text='customer' and created_at>now()-interval '1 minute')>=coalesce(allowed_count,6) then
    raise exception 'Too many orders were sent. Please wait a minute and try again';
  end if;
  return new;
end; $$;

create or replace function public.enforce_public_request_rate() returns trigger
language plpgsql security definer set search_path=public as $$
declare allowed_count integer;
begin
  select customer_requests_per_minute into allowed_count from public.branch_rate_limits where branch_id=new.branch_id;
  if (select count(*) from public.customer_requests where session_id=new.session_id and created_at>now()-interval '1 minute')>=coalesce(allowed_count,8) then
    raise exception 'Too many requests were sent. Please wait a minute and try again';
  end if;
  return new;
end; $$;

create or replace function public.capture_public_activity() returns trigger
language plpgsql security definer set search_path=public as $$
declare kind text; recent_count integer; warning_level integer;
begin
  if tg_table_name='orders' and new.source::text<>'customer' then return new; end if;
  kind:=case when tg_table_name='orders' then 'order' else 'request' end;
  insert into public.public_api_activity(restaurant_id,branch_id,session_id,activity_kind,entity_id)
  values(new.restaurant_id,new.branch_id,new.session_id,kind,new.id);
  select count(*) into recent_count from public.public_api_activity where session_id=new.session_id and activity_kind=kind and created_at>now()-interval '2 minutes';
  select case when kind='order' then customer_orders_per_minute else customer_requests_per_minute end into warning_level from public.branch_rate_limits where branch_id=new.branch_id;
  if recent_count>=greatest(coalesce(warning_level,6)-1,2) and not exists(
    select 1 from public.suspicious_activity_events where session_id=new.session_id and event_kind='high_'||kind||'_volume' and created_at>now()-interval '5 minutes'
  ) then
    insert into public.suspicious_activity_events(restaurant_id,branch_id,session_id,event_kind,details)
    values(new.restaurant_id,new.branch_id,new.session_id,'high_'||kind||'_volume',jsonb_build_object('count',recent_count,'window_minutes',2));
  end if;
  return new;
end; $$;

create trigger orders_public_rate before insert on public.orders for each row execute function public.enforce_public_order_rate();
create trigger requests_branch_context before insert on public.customer_requests for each row execute function public.set_request_branch_context();
create trigger requests_public_rate before insert on public.customer_requests for each row execute function public.enforce_public_request_rate();
create trigger orders_public_activity after insert on public.orders for each row execute function public.capture_public_activity();
create trigger requests_public_activity after insert on public.customer_requests for each row execute function public.capture_public_activity();

create table public.financial_events (
  id bigint generated always as identity primary key,
  restaurant_id uuid not null references public.restaurants(id) on delete cascade,
  branch_id uuid not null references public.restaurant_branches(id) on delete cascade,
  event_type text not null,
  entity_type text not null,
  entity_id uuid not null,
  actor_id uuid references public.profiles(id),
  waiter_profile_id uuid references public.waiter_profiles(id),
  before_data jsonb,
  after_data jsonb,
  reason text,
  created_at timestamptz not null default now()
);
create index financial_events_branch_created_idx on public.financial_events(branch_id,created_at desc);

create or replace function public.capture_financial_event() returns trigger
language plpgsql security definer set search_path=public,private as $$
declare row_data jsonb; rid uuid; bid uuid; entity uuid; event_name text;
begin
  row_data:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
  if tg_table_name='payment_allocations' then
    select b.restaurant_id,b.branch_id into rid,bid from public.bills b where b.id=(row_data->>'bill_id')::uuid;
  else rid:=(row_data->>'restaurant_id')::uuid;bid:=(row_data->>'branch_id')::uuid;end if;
  entity:=(row_data->>'id')::uuid;event_name:=tg_table_name||'.'||lower(tg_op);
  insert into public.financial_events(restaurant_id,branch_id,event_type,entity_type,entity_id,actor_id,waiter_profile_id,before_data,after_data,reason)
  values(rid,bid,event_name,tg_table_name,entity,private.action_user_id(rid),private.current_waiter_profile(rid,false),case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,coalesce(row_data->>'correction_reason',row_data->>'reason',row_data->>'review_reason'));
  if tg_op='DELETE' then return old; end if;
  return new;
end; $$;

create trigger bills_financial_event after insert or update on public.bills for each row execute function public.capture_financial_event();
create trigger payments_financial_event after insert or update on public.payments for each row execute function public.capture_financial_event();
create trigger allocations_financial_event after insert or update on public.payment_allocations for each row execute function public.capture_financial_event();
create trigger approvals_financial_event after insert or update on public.approval_requests for each row execute function public.capture_financial_event();

-- ---------------------------------------------------------------------------
-- Release 1B secure functions
-- ---------------------------------------------------------------------------

create or replace function public.get_session_bill_preview(target_session uuid) returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; subtotal numeric; discount_total numeric; taxable numeric; tax_total numeric; service_total numeric; final_total numeric;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed';
  if not found then raise exception 'Open table session not found'; end if;
  if not private.has_restaurant_permission(s.restaurant_id,'payment.record') then raise exception 'You do not have permission to record this payment'; end if;
  select * into r from public.restaurants where id=s.restaurant_id;
  select coalesce(sum(i.unit_price_snapshot*i.quantity),0) into subtotal from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  select coalesce(sum(amount_snapshot),0) into discount_total from public.applied_discounts where session_id=s.id;
  taxable:=greatest(subtotal-discount_total,0);
  tax_total:=round(taxable*coalesce(r.tax_percent,0)/100,2);
  service_total:=case when r.service_charge_value is null then 0 when r.service_charge_kind='percentage' then round(taxable*r.service_charge_value/100,2) else r.service_charge_value end;
  final_total:=taxable+tax_total+service_total;
  return jsonb_build_object('session_id',s.id,'branch_id',s.branch_id,'business_date',s.business_date,'currency',r.currency,'subtotal',subtotal,'discount',discount_total,'tax',tax_total,'tax_configured',r.tax_percent is not null,'service_charge',service_total,'service_configured',r.service_charge_value is not null,'total',final_total);
end; $$;

create or replace function public.close_table_session_v2(target_session uuid,payment_method_code text,payment_currency text default 'USD',payment_reference text default null,tendered_amount numeric default null,exchange_rate_to_bill numeric default null,idempotency_key uuid default null) returns jsonb
language plpgsql security definer set search_path=public,private as $$
declare s public.table_sessions%rowtype; r public.restaurants%rowtype; preview jsonb; pm public.restaurant_payment_methods%rowtype; final_total numeric; converted numeric; rate numeric; tendered numeric; bill_id uuid; payment_id uuid; waiter_id uuid; action_user uuid; legacy_method public.payment_method; existing_payment public.payments%rowtype;
begin
  select * into s from public.table_sessions where id=target_session and status<>'closed' for update;
  if not found then
    if idempotency_key is not null then select * into existing_payment from public.payments where session_id=target_session and payments.idempotency_key=$7; end if;
    if existing_payment.id is not null then return jsonb_build_object('session_id',target_session,'payment_id',existing_payment.id,'duplicate',true); end if;
    raise exception 'Open table session not found';
  end if;
  if not private.has_restaurant_permission(s.restaurant_id,'payment.record') then raise exception 'You do not have permission to record this payment'; end if;
  select * into pm from public.restaurant_payment_methods where branch_id=s.branch_id and method_code=$2 and active;
  if not found then raise exception 'Choose an active payment method'; end if;
  payment_currency:=upper(coalesce(payment_currency,'USD'));
  if not payment_currency=any(pm.accepted_currencies) then raise exception 'This payment method does not accept the selected currency'; end if;
  if not exists(select 1 from public.branch_currencies where branch_id=s.branch_id and currency_code=payment_currency and enabled) then raise exception 'The selected currency is not enabled for this branch'; end if;
  if pm.requires_reference and length(trim(coalesce(payment_reference,'')))<2 then raise exception 'Enter the payment reference'; end if;
  preview:=public.get_session_bill_preview(s.id);final_total:=(preview->>'total')::numeric;
  select * into r from public.restaurants where id=s.restaurant_id;
  rate:=case when payment_currency=r.currency then 1 else coalesce(exchange_rate_to_bill,(select rate_to_base from public.branch_currencies where branch_id=s.branch_id and currency_code=payment_currency)) end;
  if rate is null or rate<=0 then raise exception 'Enter a valid exchange rate'; end if;
  tendered:=coalesce(tendered_amount,case when payment_currency=r.currency then final_total else null end);
  if tendered is null or tendered<0 then raise exception 'Enter the amount received'; end if;
  converted:=round(tendered*rate,2);
  if abs(converted-final_total)>0.02 then raise exception 'The amount received does not match the final bill total'; end if;
  waiter_id:=private.current_waiter_profile(s.restaurant_id,true);action_user:=private.action_user_id(s.restaurant_id);
  insert into public.bills(restaurant_id,branch_id,session_id,business_date,status,currency,subtotal,discount_total,tax_total,service_total,total,balance,issued_at,issued_by,paid_at)
  values(s.restaurant_id,s.branch_id,s.id,s.business_date,'paid',r.currency,(preview->>'subtotal')::numeric,(preview->>'discount')::numeric,(preview->>'tax')::numeric,(preview->>'service_charge')::numeric,final_total,0,now(),action_user,now()) returning id into bill_id;
  insert into public.bill_lines(bill_id,order_item_id,line_type,description,quantity,unit_amount,line_total,metadata)
  select bill_id,i.id,'item',i.item_name_snapshot,i.quantity,i.unit_price_snapshot,i.quantity*i.unit_price_snapshot,jsonb_build_object('order_id',o.id,'station',i.prep_station_name_snapshot)
  from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null;
  legacy_method:=case pm.category when 'cash' then 'cash'::public.payment_method when 'card' then 'card'::public.payment_method when 'bank' then 'bank_transfer'::public.payment_method else 'other'::public.payment_method end;
  insert into public.payments(restaurant_id,branch_id,session_id,business_date,bill_id,method,method_code,currency,amount,tendered_amount,exchange_rate_to_bill,allocated_amount,reference,idempotency_key,recorded_by,recorded_by_waiter_profile_id)
  values(s.restaurant_id,s.branch_id,s.id,s.business_date,bill_id,legacy_method,pm.method_code,payment_currency,final_total,tendered,rate,final_total,nullif(trim(payment_reference),''),idempotency_key,action_user,waiter_id) returning id into payment_id;
  insert into public.payment_allocations(payment_id,bill_id,amount) values(payment_id,bill_id,final_total);
  update public.table_sessions set status='closed',closed_by=action_user,closed_by_waiter_profile_id=waiter_id,closed_at=now(),subtotal_snapshot=(preview->>'subtotal')::numeric,discount_snapshot=(preview->>'discount')::numeric,tax_snapshot=(preview->>'tax')::numeric,service_snapshot=(preview->>'service_charge')::numeric,total_snapshot=final_total where id=s.id;
  update public.customer_requests set status='resolved',resolved_by=action_user,resolved_by_waiter_profile_id=waiter_id,resolved_at=now() where session_id=s.id and status<>'resolved';
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,waiter_profile_id,action,entity_type,entity_id,details) values(s.restaurant_id,s.branch_id,action_user,waiter_id,'table.closed','table_session',s.id,jsonb_build_object('bill_id',bill_id,'payment_id',payment_id,'total',final_total,'method',pm.method_code,'currency',payment_currency,'reference',nullif(trim(payment_reference),''),'business_date',s.business_date));
  return preview||jsonb_build_object('bill_id',bill_id,'payment_id',payment_id,'payment_method',pm.display_name,'payment_method_code',pm.method_code,'payment_currency',payment_currency,'payment_reference',nullif(trim(payment_reference),''),'tendered_amount',tendered,'exchange_rate_to_bill',rate,'items',coalesce((select jsonb_agg(jsonb_build_object('name',i.item_name_snapshot,'quantity',i.quantity,'unit_price',i.unit_price_snapshot,'modifiers',coalesce((select jsonb_agg(jsonb_build_object('name',m.modifier_name_snapshot,'price_adjustment',m.price_adjustment_snapshot) order by m.id) from public.order_item_modifiers m where m.order_item_id=i.id),'[]'::jsonb)) order by o.created_at,i.id) from public.orders o join public.order_items i on i.order_id=o.id where o.session_id=s.id and o.status not in ('pending','rejected') and i.voided_at is null),'[]'::jsonb),'duplicate',false);
end; $$;

create or replace function public.update_branch_business_settings(target_branch uuid,branch_name text,branch_timezone text,day_cutoff time,branch_address text default null,branch_phone text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare b public.restaurant_branches%rowtype;
begin
  select * into b from public.restaurant_branches where id=target_branch;
  if not found or not private.has_restaurant_permission(b.restaurant_id,'branch.configure') then raise exception 'Owner access is required to change business settings'; end if;
  if branch_timezone not in ('Africa/Harare','Africa/Johannesburg','Africa/Maputo','UTC') then raise exception 'Choose a supported timezone'; end if;
  update public.restaurant_branches set name=trim(branch_name),timezone=branch_timezone,business_day_cutoff=day_cutoff,address=nullif(trim(branch_address),''),phone=nullif(trim(branch_phone),'') where id=b.id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details) values(b.restaurant_id,b.id,auth.uid(),'branch.settings_updated','restaurant_branch',b.id,jsonb_build_object('timezone',branch_timezone,'business_day_cutoff',day_cutoff));
end; $$;

create or replace function public.create_approval_request(target_restaurant uuid,target_branch uuid,request_kind text,entity_kind text,target_entity uuid,request_reason text,request_payload jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path=public,private as $$
declare request_id uuid; action_user uuid; waiter_id uuid;
begin
  if not public.has_restaurant_text_role(target_restaurant,array['owner','manager','waiter','kitchen','bar','cashier']) then raise exception 'Restaurant staff access is required'; end if;
  if request_kind not in ('discount','void','payment_correction','receipt_correction','business_day_reopen') then raise exception 'Choose a valid approval request type'; end if;
  if length(trim(coalesce(request_reason,'')))<3 then raise exception 'Enter a reason for this approval request'; end if;
  if not exists(select 1 from public.restaurant_branches where id=target_branch and restaurant_id=target_restaurant and active) then raise exception 'Active branch not found'; end if;
  action_user:=private.action_user_id(target_restaurant);waiter_id:=private.current_waiter_profile(target_restaurant,true);
  insert into public.approval_requests(restaurant_id,branch_id,request_type,entity_type,entity_id,requested_by,requested_by_waiter_profile_id,reason,requested_payload)
  values(target_restaurant,target_branch,request_kind,trim(entity_kind),target_entity,action_user,waiter_id,trim(request_reason),coalesce(request_payload,'{}'::jsonb)) returning id into request_id;
  return request_id;
end; $$;

create or replace function public.review_approval_request(target_request uuid,decision text,decision_reason text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare request_row public.approval_requests%rowtype;
begin
  if decision not in ('approved','rejected') then raise exception 'Choose approved or rejected'; end if;
  select * into request_row from public.approval_requests where id=target_request and status='pending' for update;
  if not found then raise exception 'Pending approval request not found'; end if;
  if not private.has_restaurant_permission(request_row.restaurant_id,'approval.review') then raise exception 'You do not have permission to review approvals'; end if;
  if decision='rejected' and length(trim(coalesce(decision_reason,'')))<3 then raise exception 'Enter a reason for rejecting this request'; end if;
  update public.approval_requests set status=decision,reviewed_by=private.action_user_id(request_row.restaurant_id),review_reason=nullif(trim(decision_reason),''),reviewed_at=now() where id=request_row.id;
end; $$;

create or replace function public.update_branch_currency(target_currency uuid,new_enabled boolean,new_rate_to_base numeric) returns void
language plpgsql security definer set search_path=public,private as $$
declare c public.branch_currencies%rowtype;
begin
  select * into c from public.branch_currencies where id=target_currency;
  if not found or not private.has_restaurant_permission(c.restaurant_id,'branch.configure') then raise exception 'Owner access is required to change currencies'; end if;
  if c.is_base and not new_enabled then raise exception 'The base currency cannot be disabled'; end if;
  if new_rate_to_base<=0 then raise exception 'Enter a valid rate'; end if;
  update public.branch_currencies set enabled=new_enabled,rate_to_base=case when is_base then 1 else new_rate_to_base end,updated_by=auth.uid() where id=c.id;
end; $$;

create or replace function public.update_restaurant_payment_method(target_method uuid,new_active boolean,new_requires_reference boolean) returns void
language plpgsql security definer set search_path=public,private as $$
declare m public.restaurant_payment_methods%rowtype;
begin
  select * into m from public.restaurant_payment_methods where id=target_method;
  if not found or not private.has_restaurant_permission(m.restaurant_id,'branch.configure') then raise exception 'Owner access is required to change payment methods'; end if;
  update public.restaurant_payment_methods set active=new_active,requires_reference=new_requires_reference where id=m.id;
end; $$;

create or replace function public.close_business_day(target_business_day uuid,closing_note text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare d public.business_days%rowtype;
begin
  select * into d from public.business_days where id=target_business_day and status='open' for update;
  if not found then raise exception 'Open business day not found'; end if;
  if not private.has_restaurant_permission(d.restaurant_id,'business_day.close') then raise exception 'You do not have permission to close the business day'; end if;
  if exists(select 1 from public.table_sessions where branch_id=d.branch_id and business_date=d.business_date and status<>'closed') then raise exception 'Close all tables for this business date first'; end if;
  update public.business_days set status='closed',closed_at=now(),closed_by=private.action_user_id(d.restaurant_id),close_note=nullif(trim(closing_note),'') where id=d.id;
  insert into public.audit_logs(restaurant_id,branch_id,actor_id,action,entity_type,entity_id,details) values(d.restaurant_id,d.branch_id,private.action_user_id(d.restaurant_id),'business_day.closed','business_day',d.id,jsonb_build_object('business_date',d.business_date,'note',nullif(trim(closing_note),'')));
end; $$;

create or replace function public.review_suspicious_activity(target_event uuid,new_status text,review_note text default null) returns void
language plpgsql security definer set search_path=public,private as $$
declare e public.suspicious_activity_events%rowtype;
begin
  if new_status not in ('reviewed','dismissed') then raise exception 'Choose reviewed or dismissed'; end if;
  select * into e from public.suspicious_activity_events where id=target_event;
  if not found or not private.has_restaurant_permission(e.restaurant_id,'security.view') then raise exception 'You do not have permission to review security activity'; end if;
  update public.suspicious_activity_events set status=new_status,reviewed_by=private.action_user_id(e.restaurant_id),reviewed_at=now(),review_note=nullif(trim(review_note),'') where id=e.id;
end; $$;

-- ---------------------------------------------------------------------------
-- Receipt compatibility view
-- ---------------------------------------------------------------------------

create or replace view public.receipts with (security_invoker=true) as
select s.id,s.restaurant_id,s.table_id,t.label as table_label,s.opened_at,s.closed_at,s.subtotal_snapshot,s.discount_snapshot,s.tax_snapshot,s.service_snapshot,s.total_snapshot,p.method as payment_method,p.recorded_at,s.assigned_waiter_id,s.assigned_waiter_name,
       s.branch_id,s.business_date,b.bill_number,b.id as bill_id,p.method_code as payment_method_code,pm.display_name as payment_method_name,p.currency as payment_currency,p.tendered_amount,p.exchange_rate_to_bill,p.reference as payment_reference
from public.table_sessions s
join public.physical_tables t on t.id=s.table_id
left join public.bills b on b.session_id=s.id
left join lateral(select p1.* from public.payments p1 where p1.session_id=s.id and p1.status='recorded' order by p1.recorded_at limit 1) p on true
left join public.restaurant_payment_methods pm on pm.branch_id=s.branch_id and pm.method_code=p.method_code
where s.status='closed';

-- ---------------------------------------------------------------------------
-- RLS, explicit Data API grants, function privileges, and Realtime
-- ---------------------------------------------------------------------------

alter table public.restaurant_branches enable row level security;
alter table public.branch_currencies enable row level security;
alter table public.business_days enable row level security;
alter table public.permission_definitions enable row level security;
alter table public.role_permissions enable row level security;
alter table public.staff_permission_overrides enable row level security;
alter table public.approval_requests enable row level security;
alter table public.restaurant_payment_methods enable row level security;
alter table public.bills enable row level security;
alter table public.bill_lines enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.branch_rate_limits enable row level security;
alter table public.public_api_activity enable row level security;
alter table public.suspicious_activity_events enable row level security;
alter table public.financial_events enable row level security;

create policy branches_read on public.restaurant_branches for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','kitchen','bar','cashier']));
create policy currencies_read on public.branch_currencies for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','cashier']));
create policy business_days_read on public.business_days for select to authenticated using(private.has_restaurant_permission(restaurant_id,'branch.view'));
create policy permission_definitions_read on public.permission_definitions for select to authenticated using(true);
create policy role_permissions_read on public.role_permissions for select to authenticated using(true);
create policy permission_overrides_read on public.staff_permission_overrides for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner']));
create policy approvals_read on public.approval_requests for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager']) or requested_by=auth.uid());
create policy payment_methods_read on public.restaurant_payment_methods for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager','waiter','cashier']));
create policy bills_read on public.bills for select to authenticated using(private.has_restaurant_permission(restaurant_id,'payment.view'));
create policy bill_lines_read on public.bill_lines for select to authenticated using(exists(select 1 from public.bills b where b.id=bill_lines.bill_id and private.has_restaurant_permission(b.restaurant_id,'payment.view')));
create policy payment_allocations_read on public.payment_allocations for select to authenticated using(exists(select 1 from public.bills b where b.id=payment_allocations.bill_id and private.has_restaurant_permission(b.restaurant_id,'payment.view')));
create policy rate_limits_read on public.branch_rate_limits for select to authenticated using(public.has_restaurant_text_role(restaurant_id,array['owner','manager']));
create policy suspicious_activity_read on public.suspicious_activity_events for select to authenticated using(private.has_restaurant_permission(restaurant_id,'security.view'));
create policy financial_events_read on public.financial_events for select to authenticated using(private.has_restaurant_permission(restaurant_id,'payment.view'));

grant select on public.restaurant_branches,public.branch_currencies,public.business_days,public.permission_definitions,public.role_permissions,public.staff_permission_overrides,public.approval_requests,public.restaurant_payment_methods,public.bills,public.bill_lines,public.payment_allocations,public.branch_rate_limits,public.suspicious_activity_events,public.financial_events to authenticated;
revoke all on public.public_api_activity from anon,authenticated;

revoke all on function private.has_restaurant_permission(uuid,text) from public;
grant execute on function private.has_restaurant_permission(uuid,text) to authenticated;
revoke all on function public.branch_business_date(uuid,timestamptz) from public;
grant execute on function public.branch_business_date(uuid,timestamptz) to authenticated;
revoke all on function public.get_session_bill_preview(uuid) from public;
revoke all on function public.close_table_session_v2(uuid,text,text,text,numeric,numeric,uuid) from public;
revoke all on function public.update_branch_business_settings(uuid,text,text,time,text,text) from public;
revoke all on function public.create_approval_request(uuid,uuid,text,text,uuid,text,jsonb) from public;
revoke all on function public.review_approval_request(uuid,text,text) from public;
revoke all on function public.update_branch_currency(uuid,boolean,numeric) from public;
revoke all on function public.update_restaurant_payment_method(uuid,boolean,boolean) from public;
revoke all on function public.close_business_day(uuid,text) from public;
revoke all on function public.review_suspicious_activity(uuid,text,text) from public;
grant execute on function public.get_session_bill_preview(uuid),public.close_table_session_v2(uuid,text,text,text,numeric,numeric,uuid),public.update_branch_business_settings(uuid,text,text,time,text,text),public.create_approval_request(uuid,uuid,text,text,uuid,text,jsonb),public.review_approval_request(uuid,text,text),public.update_branch_currency(uuid,boolean,numeric),public.update_restaurant_payment_method(uuid,boolean,boolean),public.close_business_day(uuid,text),public.review_suspicious_activity(uuid,text,text) to authenticated;

revoke all on function public.set_default_branch_context() from public;
revoke all on function public.set_session_business_context() from public;
revoke all on function public.set_order_business_context() from public;
revoke all on function public.set_payment_business_context() from public;
revoke all on function public.set_request_branch_context() from public;
revoke all on function public.enforce_public_order_rate() from public;
revoke all on function public.enforce_public_request_rate() from public;
revoke all on function public.capture_public_activity() from public;
revoke all on function public.capture_financial_event() from public;

do $$ begin
  alter publication supabase_realtime add table public.restaurant_branches;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.branch_currencies;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.business_days;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.restaurant_payment_methods;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.bills;
exception when duplicate_object then null; end $$;
do $$ begin
  alter publication supabase_realtime add table public.suspicious_activity_events;
exception when duplicate_object then null; end $$;

notify pgrst, 'reload schema';
