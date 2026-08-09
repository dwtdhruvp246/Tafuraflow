-- TafuraFlow: waiter-specific fulfilled order history
-- Waiters may see every live order needed for service, but once an order is
-- served or rejected they may only see it when they were assigned to that
-- order's table session. Owners, managers, kitchen, bar and cashier retain
-- their existing restaurant-wide visibility.

create or replace function private.is_current_waiter_assigned(target_session uuid) returns boolean
language plpgsql stable security definer set search_path=pg_catalog,private,public as $$
declare rid uuid;assigned_waiter uuid;current_waiter uuid;
begin
  select restaurant_id,assigned_waiter_profile_id into rid,assigned_waiter
  from public.table_sessions where id=target_session;
  if not found or assigned_waiter is null then return false;end if;
  if not public.has_restaurant_text_role(rid,array['waiter']) then return false;end if;
  current_waiter:=private.current_waiter_profile(rid,false);
  return current_waiter is not null and current_waiter=assigned_waiter;
end; $$;

revoke all on function private.is_current_waiter_assigned(uuid) from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.is_current_waiter_assigned(uuid) to authenticated;

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders
for select to authenticated
using (
  public.has_restaurant_text_role(restaurant_id,array['owner','manager','kitchen','bar','cashier'])
  or (
    public.has_restaurant_text_role(restaurant_id,array['waiter'])
    and (
      status not in ('served','rejected')
      or private.is_current_waiter_assigned(orders.session_id)
    )
  )
);

-- Child records inherit the order visibility above. These policies prevent a
-- waiter from retrieving another waiter's fulfilled order details directly.
drop policy if exists order_items_read on public.order_items;
create policy order_items_read on public.order_items
for select to authenticated
using (exists(select 1 from public.orders visible_order where visible_order.id=order_items.order_id));

drop policy if exists order_item_modifiers_read on public.order_item_modifiers;
create policy order_item_modifiers_read on public.order_item_modifiers
for select to authenticated
using (exists(select 1 from public.order_items visible_item where visible_item.id=order_item_modifiers.order_item_id));

drop policy if exists order_events_read on public.order_events;
create policy order_events_read on public.order_events
for select to authenticated
using (exists(select 1 from public.orders visible_order where visible_order.id=order_events.order_id));

drop policy if exists item_events_read on public.order_item_events;
create policy item_events_read on public.order_item_events
for select to authenticated
using (
  exists (
    select 1
    from public.order_items visible_item
    where visible_item.id=order_item_events.order_item_id
  )
);

notify pgrst, 'reload schema';
