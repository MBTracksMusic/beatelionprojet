-- Drop the single-column event_type index because it is left-prefix covered by
-- event_bus_event_aggregate_idx (event_type, aggregate_id).

BEGIN;

DROP INDEX IF EXISTS public.event_bus_event_type_idx;

COMMIT;
