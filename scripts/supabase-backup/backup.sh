#!/bin/sh
# supabase-backup — capture one Supabase project into a single timestamped
# tarball: every user schema with its data and privileges, the auth identity
# tables, the schema objects pg_dump cannot see, and every storage object.
#
#   backup.sh <project>        reads /etc/supabase-backup/<project>.conf
#
# Exits non-zero, and writes nothing, if the result would be incomplete. A
# backup set that quietly degrades is worse than one that fails loudly.
set -eu

PROJECT="${1:?usage: backup.sh <project>}"
CONF_DIR="${CONF_DIR:-/etc/supabase-backup}"
LIB_DIR="${LIB_DIR:-/opt/supabase-backup}"
CONF="${CONF_DIR}/${PROJECT}.conf"

# Debian's psql/pg_dump are Perl wrappers that emit a wall of locale warnings
# under an ungenerated LANG, which some consoles hand us. Pin it.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

[ -f "$CONF" ] || { echo "no such project config: $CONF" >&2; exit 2; }
# shellcheck disable=SC1090
. "$CONF"

: "${DATABASE_URL:?set DATABASE_URL in $CONF}"
: "${SUPABASE_URL:?set SUPABASE_URL in $CONF}"
: "${SUPABASE_SERVICE_KEY:?set SUPABASE_SERVICE_KEY in $CONF}"

OUT="${BACKUP_DIR:-/var/backups/supabase/$PROJECT}"
KEEP_DAYS="${KEEP_DAYS:-30}"
PAGE="${PAGE_SIZE:-100}"

# Schemas Supabase owns. Their contents are recreated by the platform, not by
# us; we only capture app-owned objects that happen to live inside them.
PLATFORM_SCHEMAS="${PLATFORM_SCHEMAS:-auth,storage,realtime,vault,cron,extensions,graphql,graphql_public,pgsodium,pgsodium_masks,net,supabase_functions,supabase_migrations,pgbouncer,_analytics,_realtime}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${PROJECT}-${STAMP}"
WORK="${OUT}/.work-${STAMP}"
ARCHIVE="${OUT}/${NAME}.tar.gz"

log()  { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '%s  ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

cleanup() { rm -rf "$WORK" "${ARCHIVE}.partial"; }
trap cleanup EXIT INT TERM

psql_q() { psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

mkdir -p "$WORK/files"
log "backup ${NAME} starting"

# ── 1. Which schemas belong to the application ─────────────────────────────
log "discovering user schemas"
SCHEMAS="$(psql_q "select nspname from pg_namespace
                   where nspname <> all(string_to_array('${PLATFORM_SCHEMAS}', ','))
                     and nspname not in ('pg_catalog','information_schema')
                     and nspname not like 'pg\\_%'
                   order by nspname")" || fail "could not list schemas - check DATABASE_URL"
[ -n "$SCHEMAS" ] || fail "no user schemas found - refusing to write an empty backup"

SCHEMA_ARGS=""
for s in $SCHEMAS; do SCHEMA_ARGS="$SCHEMA_ARGS --schema=$s"; done
log "schemas: $(echo "$SCHEMAS" | tr '\n' ' ')"

# ── 2. Dump them, with privileges ──────────────────────────────────────────
# NOT --no-privileges. GRANT/REVOKE are schema, not decoration: column-level
# grants are a normal way to make a column unwritable, and dropping them
# restores a database that is missing a control it was relying on. The roles
# involved (anon, authenticated, service_role) exist in every Supabase project,
# so keeping privileges costs no portability. --no-owner is enough.
log "dumping schema and data"
# shellcheck disable=SC2086
pg_dump "$DATABASE_URL" $SCHEMA_ARGS --no-owner --file="$WORK/schema.sql" \
  || fail "pg_dump failed"

TABLES="$(grep -cE '^CREATE TABLE ' "$WORK/schema.sql" || true)"
GRANTS="$(grep -cE '^(GRANT|REVOKE)' "$WORK/schema.sql" || true)"
[ "$TABLES" -gt 0 ] || fail "dump contains no tables"
# A Supabase user schema always carries non-default ACLs, so zero privilege
# statements means they were stripped rather than genuinely absent.
[ "$GRANTS" -gt 0 ] || fail "dump contains no GRANT/REVOKE - privileges were not captured"
log "captured ${TABLES} table(s), ${GRANTS} privilege statement(s)"

# ── 3. Auth identity tables ────────────────────────────────────────────────
# Data only; Supabase owns the auth schema's DDL. identities matters as much as
# users: without it, restored accounts exist but cannot sign in.
log "dumping auth.users + auth.identities"
pg_dump "$DATABASE_URL" --table=auth.users --table=auth.identities \
  --data-only --no-owner --file="$WORK/auth.sql" \
  || fail "pg_dump of auth tables failed (does this role have auth schema access?)"

# ── 4. What pg_dump cannot see ─────────────────────────────────────────────
log "capturing catalog-derived objects"
# -q matters: without it psql writes its own chatter ("SET", "Output format is
# unaligned.") into the file, and neither is valid SQL when replayed.
psql "$DATABASE_URL" -q -v ON_ERROR_STOP=1 \
     -v platform_schemas="$PLATFORM_SCHEMAS" \
     -f "$LIB_DIR/catalog.sql" > "$WORK/non-public.sql" \
  || fail "catalog introspection failed"

# ── 5. Storage ─────────────────────────────────────────────────────────────
BUCKETS="$(psql_q "select id from storage.buckets order by id")" || fail "could not list buckets"

storage_list() {  # $1 bucket, $2 prefix, $3 offset
  curl -fsS --max-time 60 \
    -X POST "${SUPABASE_URL%/}/storage/v1/object/list/$1" \
    -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
    -H "apikey: ${SUPABASE_SERVICE_KEY}" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg p "$2" --argjson o "$3" --argjson l "$PAGE" \
          '{prefix:$p, limit:$l, offset:$o, sortBy:{column:"name",order:"asc"}}')"
}

# Iterative, over a queue file. Deliberately not recursive: POSIX sh has no
# local variables, so a recursive walk overwrites its caller's prefix and
# silently skips entire subtrees while still reporting success.
walk_bucket() {
  bucket="$1"
  printf '\n' > "$WORK/queue"
  qline=0
  while : ; do
    qline=$((qline + 1))
    [ "$qline" -gt "$(wc -l < "$WORK/queue")" ] && break
    prefix="$(sed -n "${qline}p" "$WORK/queue")"
    offset=0
    while : ; do
      page="$(storage_list "$bucket" "$prefix" "$offset")" \
        || fail "storage list failed at '${bucket}/${prefix}'"
      count="$(printf '%s' "$page" | jq 'length')"
      [ "$count" -eq 0 ] && break
      printf '%s' "$page" | jq -r --arg p "$prefix" \
        '.[] | select(.id == null) | select(.name != ".emptyFolderPlaceholder")
             | (if $p == "" then .name else $p + "/" + .name end)' >> "$WORK/queue"
      printf '%s' "$page" | jq -r --arg p "$prefix" \
        '.[] | select(.id != null) | select(.name != ".emptyFolderPlaceholder")
             | (if $p == "" then .name else $p + "/" + .name end)' >> "$WORK/found"
      offset=$((offset + count))
      [ "$count" -lt "$PAGE" ] && break
    done
  done
}

: > "$WORK/filelist.txt"
TOTAL_OBJ=0
for b in $BUCKETS; do
  log "bucket '${b}': walking"
  : > "$WORK/found"
  walk_bucket "$b"

  # The database is the authoritative inventory. Comparing the walk against
  # storage.objects is what catches a walk that skipped a subtree - the walk's
  # own output cannot reveal what it never looked at.
  psql_q "select name from storage.objects where bucket_id = '${b}' order by name" \
    > "$WORK/expected" || fail "could not read storage.objects for '${b}'"
  sort -o "$WORK/found" "$WORK/found"
  sort -o "$WORK/expected" "$WORK/expected"
  if ! MISSING="$(comm -13 "$WORK/found" "$WORK/expected")" || [ -n "$MISSING" ]; then
    printf '%s\n' "$MISSING" | head -10 | sed 's/^/    missing: /' >&2
    fail "bucket '${b}': storage.objects lists objects the walk did not find"
  fi

  N=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    dest="$WORK/files/$b/$path"
    mkdir -p "$(dirname "$dest")"
    curl -fsS --max-time 300 \
      "${SUPABASE_URL%/}/storage/v1/object/${b}/${path}" \
      -H "Authorization: Bearer ${SUPABASE_SERVICE_KEY}" \
      -H "apikey: ${SUPABASE_SERVICE_KEY}" \
      -o "$dest" || fail "download failed: ${b}/${path}"
    [ -s "$dest" ] || fail "downloaded zero bytes: ${b}/${path}"
    printf '%s/%s\n' "$b" "$path" >> "$WORK/filelist.txt"
    N=$((N + 1))
  done < "$WORK/found"
  log "bucket '${b}': ${N} object(s), matching storage.objects"
  TOTAL_OBJ=$((TOTAL_OBJ + N))
done

# ── 6. Manifest and checksums ──────────────────────────────────────────────
rm -f "$WORK/queue" "$WORK/found" "$WORK/expected"

# Row counts come from the archive's own COPY blocks, not from the source: a
# restore should be checked against what the archive actually holds.
awk '
  /^COPY [^ ]+ /{ t=$2; b=1; n=0; next }
  b && $0 == "\\." { printf "%s\t%d\n", t, n; b=0; next }
  b { n++ }
' "$WORK/schema.sql" "$WORK/auth.sql" > "$WORK/.rows"

ROWS_JSON="$(jq -R -s 'split("\n") | map(select(length>0) | split("\t") | {(.[0]): (.[1]|tonumber)}) | add // {}' < "$WORK/.rows")"

jq -nc \
  --arg project "$PROJECT" \
  --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg schemas "$(echo "$SCHEMAS" | tr '\n' ' ' | sed 's/ $//')" \
  --arg buckets "$(echo "$BUCKETS" | tr '\n' ' ' | sed 's/ $//')" \
  --argjson objects "$TOTAL_OBJ" \
  --arg pg "$(pg_dump --version | awk '{print $3}')" \
  --argjson rows "$ROWS_JSON" \
  '{project:$project, created_utc:$created,
    schemas:($schemas|split(" ")), buckets:($buckets|split(" ")),
    storage_objects:$objects, pg_dump_version:$pg, rows:$rows}' \
  > "$WORK/manifest.json" || fail "manifest generation failed"
rm -f "$WORK/.rows"

( cd "$WORK" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )

# ── 7. Archive and prune ───────────────────────────────────────────────────
mkdir -p "$OUT"
# Write under a temp name and rename. Rename is atomic within a filesystem, so
# a filesystem snapshot taken mid-run sees a whole archive or none of it, never
# a truncated one that still looks like a valid tarball.
tar -czf "${ARCHIVE}.partial" -C "$WORK" . || fail "archive failed"
mv -f "${ARCHIVE}.partial" "$ARCHIVE"       || fail "could not finalise archive"
log "wrote ${ARCHIVE} ($(du -h "$ARCHIVE" | awk '{print $1}'))"

if [ "$KEEP_DAYS" -gt 0 ]; then
  PRUNED="$(find "$OUT" -maxdepth 1 -name "${PROJECT}-*.tar.gz" -mtime "+${KEEP_DAYS}" -print -delete | wc -l | tr -d ' ')"
  [ "$PRUNED" -gt 0 ] && log "pruned ${PRUNED} archive(s) older than ${KEEP_DAYS}d"
fi

log "backup ${NAME} complete"
