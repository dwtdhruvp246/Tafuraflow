-- TafuraFlow waiter order-history repair
-- The first history policy called a private helper directly, which authenticated
-- waiter requests are intentionally not allowed to execute. This safe wrapper
-- connects the active personal or shared-PIN waiter to the table assignment.

drop function if exists public.is_current_waiter_assigned(uuid);

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

notify pgrst, 'reload schema';
