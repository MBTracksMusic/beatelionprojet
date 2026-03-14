create schema if not exists extensions;

do $$
begin
  if exists (
    select 1
    from pg_extension
    where extname = 'pg_net'
  ) then
    if not exists (
      select 1
      from pg_extension e
      join pg_namespace n on n.oid = e.extnamespace
      where e.extname = 'pg_net'
        and n.nspname = 'extensions'
    ) then
      if exists (
        select 1
        from pg_extension
        where extname = 'pg_net'
          and extrelocatable = true
      ) then
        alter extension pg_net
        set schema extensions;
      else
        raise notice 'pg_net is not relocatable on this Postgres/Supabase build; skipping SET SCHEMA.';
      end if;
    end if;
  end if;
end
$$;
