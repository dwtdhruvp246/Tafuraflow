-- TafuraFlow direct order routing
-- Customer and staff-assisted orders no longer wait for waiter approval.
-- The existing order RPC still validates the table session, menu items,
-- quantities, modifiers and stock. These triggers only advance the initial
-- workflow state so each item appears at its configured preparation station.

create or replace function public.auto_accept_new_order()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.status = 'pending' then
    new.status := 'accepted';
    new.accepted_at := coalesce(new.accepted_at, now());
  end if;
  return new;
end;
$$;

create or replace function public.auto_accept_new_order_item()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.preparation_status = 'pending'
     and exists (
       select 1
       from public.orders o
       where o.id = new.order_id
         and o.status in ('accepted', 'preparing', 'ready')
     ) then
    new.preparation_status := 'accepted';
  end if;
  return new;
end;
$$;

drop trigger if exists auto_accept_new_order_before_insert on public.orders;
create trigger auto_accept_new_order_before_insert
before insert on public.orders
for each row execute function public.auto_accept_new_order();

drop trigger if exists auto_accept_new_order_item_before_insert on public.order_items;
create trigger auto_accept_new_order_item_before_insert
before insert on public.order_items
for each row execute function public.auto_accept_new_order_item();

-- Release any orders that were still waiting when this upgrade was installed.
update public.orders
set status = 'accepted',
    accepted_at = coalesce(accepted_at, now())
where status = 'pending';

update public.order_items oi
set preparation_status = 'accepted'
from public.orders o
where o.id = oi.order_id
  and o.status in ('accepted', 'preparing', 'ready')
  and oi.preparation_status = 'pending'
  and oi.voided_at is null;

revoke all on function public.auto_accept_new_order() from public;
revoke all on function public.auto_accept_new_order_item() from public;

notify pgrst, 'reload schema';
