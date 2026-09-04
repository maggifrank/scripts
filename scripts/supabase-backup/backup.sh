#!/bin/sh
# supabase-backup — capture one Supabase project into a single timestamped
# tarball: every user schema with its data and privileges, the auth identity
# tables, the schema objects pg_dump cannot see, and every storage object.
#
#   backup.sh <project>        reads /etc/supabase-backup/<project>.conf
#
# If the project has an age recipients file, the tarball is encrypted to those
# public keys and written as <name>.tar.gz.age, with a small plaintext sidecar
# so the archive can still be inventoried and checked for damage by something
# that holds no key. See "Encryption" below.
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

# ── Encryption ─────────────────────────────────────────────────────────────
# Recipients are age public keys. They live in their own directory, not in
# $CONF, because they are not secret and the two audiences differ: $CONF holds
# a service key and a database password and is readable by root alone, while
# the web console has to be able to read the recipient list to show what a
# project is encrypted to.
#
# The identity that opens these archives is deliberately NOT on this host.
# Encrypting to a key the backup host also holds protects a stolen disk and
# nothing else; keeping the private half elsewhere means a host that is fully
# compromised still yields no data. That is the whole point, and it is why
# nothing here can decrypt what it just wrote.
#
# A non-empty recipients file is the only switch: present means encrypt, absent
# means do not. There is no third state to get out of sync with reality.
KEYS_DIR="${KEYS_DIR:-/etc/supabase-backup-keys}"
RECIPIENTS_FILE="${RECIPIENTS_FILE:-${KEYS_DIR}/${PROJECT}.recipients}"
AGE_BIN="${AGE_BIN:-age}"

ENCRYPT=0
RECIPIENT_COUNT=0
if [ -f "$RECIPIENTS_FILE" ] && grep -qE '^[^#[:space:]]' "$RECIPIENTS_FILE" 2>/dev/null; then
  ENCRYPT=1
  RECIPIENT_COUNT="$(grep -cE '^[^#[:space:]]' "$RECIPIENTS_FILE")"
fi

# Schemas Supabase owns. Their contents are recreated by the platform, not by
# us; we only capture app-owned objects that happen to live inside them.
PLATFORM_SCHEMAS="${PLATFORM_SCHEMAS:-auth,storage,realtime,vault,cron,extensions,graphql,graphql_public,pgsodium,pgsodium_masks,net,supabase_functions,supabase_migrations,pgbouncer,_analytics,_realtime}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="${PROJECT}-${STAMP}"
WORK="${OUT}/.work-${STAMP}"
ARCHIVE="${OUT}/${NAME}.tar.gz"
[ "$ENCRYPT" -eq 1 ] && ARCHIVE="${ARCHIVE}.age"
# Written beside an encrypted archive only. Everything a reader can learn from
# a plaintext archive by opening it, they cannot learn from an encrypted one -
# including whether it is damaged. The sidecar carries the ciphertext's digest
# so that question stays answerable without a key.
META="${OUT}/${NAME}.meta.json"
# tar's exit status, smuggled out of a pipeline. Deliberately outside $WORK,
# which is what gets archived.
TAR_RC="${OUT}/.tar-rc-${STAMP}"

log()  { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { printf '%s  ERROR: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; exit 1; }

cleanup() { rm -rf "$WORK" "${ARCHIVE}.partial" "${META}.partial" "$TAR_RC"; }
trap cleanup EXIT INT TERM

psql_q() { psql "$DATABASE_URL" -Atq -v ON_ERROR_STOP=1 -c "$1"; }

mkdir -p "$WORK/files"
log "backup ${NAME} starting"

# ── 0. Encryption preflight ────────────────────────────────────────────────
# Everything here is checked before the first pg_dump. A recipients file that
# age cannot parse is a run that dumps a whole project and then cannot write
# it, and finding that out at 04:00 is finding it out too late.
if [ "$ENCRYPT" -eq 1 ]; then
  command -v "$AGE_BIN" >/dev/null 2>&1 || fail \
    "${RECIPIENTS_FILE} asks for encryption but ${AGE_BIN} is not installed. Install age (apt-get install age), or remove that file to go back to writing archives in the clear."
  if ! printf '' | "$AGE_BIN" -R "$RECIPIENTS_FILE" >/dev/null 2>"$WORK/.age-check"; then
    sed 's/^/    /' "$WORK/.age-check" >&2
    fail "age rejected ${RECIPIENTS_FILE} (see above) - no archive was written"
  fi
  rm -f "$WORK/.age-check"
  log "encrypting to ${RECIPIENT_COUNT} recipient(s) from ${RECIPIENTS_FILE}"
elif [ -n "$(find "$OUT" -maxdepth 1 -name "${PROJECT}-*.tar.gz.age" -print -quit 2>/dev/null)" ] \
     && [ "${ALLOW_PLAINTEXT:-0}" != "1" ]; then
  # Encryption that can turn itself off by a file going missing is not
  # encryption. A deleted recipients file looks exactly like one that was never
  # there, so the archives already on disk are what gets asked instead.
  fail "this project has encrypted archives, but ${RECIPIENTS_FILE} is missing or empty. Refusing to write a plaintext archive alongside them - put the recipients back, or set ALLOW_PLAINTEXT=1 in ${CONF} to say the downgrade is deliberate."
fi

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
if [ "$ENCRYPT" -eq 1 ]; then
  # tar's exit status has to be caught by hand. This is /bin/sh, which has no
  # pipefail, and a tar that dies partway still feeds age a clean stream: the
  # result is a valid age file wrapped around half a tarball, which nothing
  # downstream can tell from a good one until someone needs it.
  rm -f "$TAR_RC"
  { tar -czf - -C "$WORK" . ; echo $? > "$TAR_RC"; } \
    | "$AGE_BIN" -R "$RECIPIENTS_FILE" -o "${ARCHIVE}.partial" \
    || fail "age failed to encrypt the archive"
  [ "$(cat "$TAR_RC" 2>/dev/null)" = "0" ] || fail "archive failed"
  rm -f "$TAR_RC"

  # The sidecar. Two things a key-holder does not need and a key-less reader
  # cannot get any other way: the digest of the ciphertext, so damage is still
  # detectable, and the manifest, so the archive can still be inventoried.
  # SIDECAR_MANIFEST=0 withholds the manifest for a host where even the schema
  # and bucket names are worth keeping back; the console then says so plainly
  # rather than showing an archive it knows nothing about.
  CIPHER_SHA="$(sha256sum "${ARCHIVE}.partial" | awk '{print $1}')"
  CIPHER_BYTES="$(wc -c < "${ARCHIVE}.partial" | tr -d ' ')"
  if [ "${SIDECAR_MANIFEST:-1}" = "1" ]; then
    MANIFEST_ARG="$(cat "$WORK/manifest.json")"
  else
    MANIFEST_ARG="null"
  fi
  jq -n \
    --arg archive "$(basename "$ARCHIVE")" \
    --arg project "$PROJECT" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sha256 "$CIPHER_SHA" \
    --argjson bytes "$CIPHER_BYTES" \
    --argjson recipients "$(grep -E '^[^#[:space:]]' "$RECIPIENTS_FILE" \
                            | jq -R -s 'split("\n") | map(select(length>0))')" \
    --argjson manifest "$MANIFEST_ARG" \
    '{archive:$archive, project:$project, created_utc:$created,
      encryption:{tool:"age", recipients:$recipients},
      sha256:$sha256, bytes:$bytes, manifest:$manifest}' \
    > "${META}.partial" || fail "sidecar generation failed"

  # Sidecar into place first. An archive that exists without its sidecar cannot
  # be checked for damage; a sidecar without its archive is invisible to
  # everything that lists archives, and is tidied up below.
  mv -f "${META}.partial" "$META"       || fail "could not finalise the sidecar"
  mv -f "${ARCHIVE}.partial" "$ARCHIVE" || fail "could not finalise archive"
  log "wrote ${ARCHIVE} ($(du -h "$ARCHIVE" | awk '{print $1}')), encrypted to ${RECIPIENT_COUNT} recipient(s)"
  log "this host cannot read it back - restoring needs the matching identity"
else
  tar -czf "${ARCHIVE}.partial" -C "$WORK" . || fail "archive failed"
  mv -f "${ARCHIVE}.partial" "$ARCHIVE"      || fail "could not finalise archive"
  log "wrote ${ARCHIVE} ($(du -h "$ARCHIVE" | awk '{print $1}'))"
fi

if [ "$KEEP_DAYS" -gt 0 ]; then
  PRUNED="$(find "$OUT" -maxdepth 1 \
                 \( -name "${PROJECT}-*.tar.gz" -o -name "${PROJECT}-*.tar.gz.age" \) \
                 -mtime "+${KEEP_DAYS}" -print -delete | wc -l | tr -d ' ')"
  [ "$PRUNED" -gt 0 ] && log "pruned ${PRUNED} archive(s) older than ${KEEP_DAYS}d"
fi

# A sidecar means nothing without the archive it describes. This clears the
# ones whose archive was just pruned, and any left by a run that died between
# the two renames above. Not inside the KEEP_DAYS check: it is tidying, not
# pruning, and a host with pruning switched off still should not accumulate
# metadata for archives that are gone.
find "$OUT" -maxdepth 1 -name "${PROJECT}-*.meta.json" 2>/dev/null | while IFS= read -r m; do
  base="${m%.meta.json}"
  [ -f "${base}.tar.gz.age" ] || [ -f "${base}.tar.gz" ] || rm -f "$m"
done

log "backup ${NAME} complete"
