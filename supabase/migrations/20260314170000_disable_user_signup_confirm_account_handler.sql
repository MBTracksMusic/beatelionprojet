/*
  # Disable duplicate signup confirmation email handler

  Supabase Auth is the only source of signup confirmation emails.
  Remove USER_SIGNUP -> confirm_account event handler to avoid duplicate emails.
*/

BEGIN;

DELETE FROM public.event_handlers
WHERE event_type = 'USER_SIGNUP'
  AND handler_type = 'email'
  AND handler_key = 'confirm_account';

COMMIT;
