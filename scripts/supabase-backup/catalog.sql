-- Regenerates, from the running catalog, the schema objects that
-- `pg_dump --schema=<user schemas>` cannot see.
--
-- Nothing here knows what application owns the database. That is the point: a
-- backup that reconstructs schema from an application's migration files is not
-- a backup, it is a dependency on a second artifact that may be missing, stale,
-- or simply wrong about what the database actually contains.

\pset tuples_only on
\pset format unaligned
-- Fully qualify generated DDL instead of relying on the reader's search_path.
set search_path = '';

\echo '-- Generated from the catalog by supabase-backup. Do not hand-edit.'
\echo ''
\echo '-- ── Extensions ──'
select format('create extension if not exists %I with schema %I;', e.extname, n.nspname)
from pg_catalog.pg_extension e
join pg_catalog.pg_namespace n on n.oid = e.extnamespace
where e.extname <> 'plpgsql'
order by e.extname;

\echo ''
\echo '-- ── App-owned triggers on platform tables ──'
-- A trigger is app-owned when the function it calls lives in a user schema.
-- Supabase's own (storage.protect_delete, cron.job_cache_invalidate, ...) call
-- functions inside their own platform schema; they already exist in any
-- project worth restoring into, so recreating them is wrong as well as noisy.
select pg_catalog.pg_get_triggerdef(t.oid) || ';'
from pg_catalog.pg_trigger t
join pg_catalog.pg_class     c  on c.oid  = t.tgrelid
join pg_catalog.pg_namespace n  on n.oid  = c.relnamespace
join pg_catalog.pg_proc      f  on f.oid  = t.tgfoid
join pg_catalog.pg_namespace fn on fn.oid = f.pronamespace
where not t.tgisinternal
  and n.nspname  = any(string_to_array(:'platform_schemas', ','))
  and fn.nspname <> all(string_to_array(:'platform_schemas', ',') ||
                        array['pg_catalog','information_schema'])
order by n.nspname, c.relname, t.tgname;

\echo ''
\echo '-- ── App-owned policies on platform tables ──'
-- Limited to auth/storage: the platform schemas that legitimately host
-- application-defined policies. Policies inside cron, realtime and friends are
-- Supabase's own.
select format(
         'create policy %I on %I.%I as %s for %s to %s%s%s;',
         p.polname, n.nspname, c.relname,
         case when p.polpermissive then 'permissive' else 'restrictive' end,
         case p.polcmd when 'r' then 'select' when 'a' then 'insert'
                       when 'w' then 'update' when 'd' then 'delete' else 'all' end,
         coalesce((select string_agg(quote_ident(rolname), ', ')
                   from pg_catalog.pg_roles where oid = any(p.polroles)), 'public'),
         coalesce(' using (' || pg_catalog.pg_get_expr(p.polqual, p.polrelid) || ')', ''),
         coalesce(' with check (' || pg_catalog.pg_get_expr(p.polwithcheck, p.polrelid) || ')', '')
       )
from pg_catalog.pg_policy p
join pg_catalog.pg_class     c on c.oid = p.polrelid
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('auth', 'storage')
order by n.nspname, c.relname, p.polname;

\echo ''
\echo '-- ── Storage buckets ──'
-- The objects inside these are archived separately, under files/<bucket>/.
select format(
         'insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) '
         'values (%L, %L, %L, %s, %s) on conflict (id) do nothing;',
         id, name, public,
         coalesce(file_size_limit::text, 'null'),
         coalesce(quote_literal(allowed_mime_types::text) || '::text[]', 'null')
       )
from storage.buckets order by id;

\echo ''
\echo '-- ── Scheduled jobs (pg_cron) ──'
-- Captured as they actually are, which is not necessarily as any migration
-- file claims. Reconciling the two is the operator''s job, not the backup''s.
select format('select cron.schedule(%L, %L, %L);', jobname, schedule, command)
from cron.job order by jobname;
