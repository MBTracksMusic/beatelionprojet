/*
  # get_occupied_product_ids — product occupancy pre-check for the battle UI

  Context:
  - battle_product_locks materializes one row per product currently engaged in
    an occupied battle (pending_acceptance, awaiting_admin, active, voting). See
    20260530143000_battle_product_occupied_locks.sql.
  - That table is service_role only, so the producer creation UI cannot read it
    to grey out beats that are already engaged. Producers only discovered the
    conflict at submit time, via the raw BATTLE_PRODUCT_ALREADY_OCCUPIED error.

  This RPC exposes a narrow read: given a set of product ids the caller already
  knows about (its own beats + the selected opponent's beats), it returns the
  subset that is currently occupied. It never reveals the global occupied set,
  so it cannot enumerate other producers' engagements.

  The AFTER-INSERT trigger sync_battle_product_locks remains the real guard;
  this is purely a UX pre-check.

  Convention: SECURITY DEFINER body lives in `private` (not REST-exposed); a
  thin SECURITY INVOKER wrapper in `public` is the PostgREST entrypoint, mirror-
  ing rpc_create_battle / respond_to_battle.
*/

BEGIN;

CREATE OR REPLACE FUNCTION private.get_occupied_product_ids(p_product_ids uuid[])
RETURNS uuid[]
LANGUAGE sql
SECURITY DEFINER
STABLE
SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT COALESCE(array_agg(DISTINCT l.product_id), ARRAY[]::uuid[])
  FROM public.battle_product_locks l
  WHERE l.product_id = ANY(COALESCE(p_product_ids, ARRAY[]::uuid[]));
$function$;

REVOKE ALL ON FUNCTION private.get_occupied_product_ids(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.get_occupied_product_ids(uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION private.get_occupied_product_ids(uuid[]) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_occupied_product_ids(p_product_ids uuid[])
RETURNS uuid[]
LANGUAGE sql
STABLE
SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
  SELECT private.get_occupied_product_ids(p_product_ids);
$function$;

REVOKE ALL ON FUNCTION public.get_occupied_product_ids(uuid[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_occupied_product_ids(uuid[]) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_occupied_product_ids(uuid[]) TO authenticated, service_role;

COMMIT;
