/*
  # Ensure pgcrypto extension is available

  Guarantees `gen_random_uuid()` and other pgcrypto helpers are present
  on fresh and existing Supabase databases.
*/

CREATE EXTENSION IF NOT EXISTS pgcrypto;
