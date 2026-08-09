-- TafuraFlow Release 1A.1 hotfix
-- Supabase installs pgcrypto functions in the extensions schema. The original
-- hardened function search paths did not include that schema, so PIN creation
-- could fail even though the Release 1A.1 RPCs were installed successfully.

alter function private.current_waiter_profile(uuid,boolean)
  set search_path=pg_catalog,private,extensions,public;
alter function public.start_waiter_terminal_session(uuid,text)
  set search_path=pg_catalog,private,extensions,public;
alter function public.end_waiter_terminal_session(uuid)
  set search_path=pg_catalog,private,extensions,public;
alter function public.create_tablet_waiter(text,text,text)
  set search_path=pg_catalog,private,extensions,public;
alter function public.set_waiter_pin(uuid,text)
  set search_path=pg_catalog,private,extensions,public;

notify pgrst, 'reload schema';
