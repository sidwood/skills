#!/bin/bash
# Runs the full Playwright e2e suite of one checkout, one worker, against a
# scratch database and a Redis database of its own, then cleans up.
#
#   .atomic/fleet/e2e-check.sh <checkout path> [playwright arguments...]
#
# With no further arguments it runs the whole suite. Anything after the
# checkout path is passed to Playwright, so a single spec can be run under
# the same lock and scratch database:
#   .atomic/fleet/e2e-check.sh <checkout> test/journeys/04-brief-edit-stale.spec.ts
#
# Exit 0 only when the suite passes with no failed or flaky test. The last
# line printed is always the counts:
#   e2e-check: passed=465 failed=0 flaky=0 skipped=6 exit=0 log=<path>
#
# What it guarantees
# - Database: creates casefilecrafter-e2e-check-<checkout>-<pid>, migrates and
#   seeds it, points the API, the worker and the e2e helpers at it, and drops
#   it afterwards. It never uses casefilecrafter-local.
# - Slots: up to E2E_CHECK_SLOTS runs go at once on this machine (default 3;
#   a checkout from before the mock web server's own ports takes slot 1 only).
#   Each takes a slot, and a slot has a port block and a Redis database of its
#   own. The suite has taken its ports from the environment since the
#   per-checkout ports landed (apps/e2e/test/support/e2e-ports.ts), so the
#   script sets E2E_PORT_BLOCK for the run: slot 1 uses 30010 to 30013 and
#   Redis database 8, slot 2 uses 30020 to 30023 and database 9, slot 3 uses
#   30030 to 30033 and database 12. It waits for a free slot and for the
#   slot's four ports, and never reuses another checkout's servers. The slot's
#   Redis database is flushed afterwards. (Reviews use database 14, the
#   suite's default is 15, database 10 is someone else's.)
# - Checkout: no tracked file is touched. If the checkout's untracked
#   apps/e2e/.env pins E2E_DB_NAME or E2E_REDIS_URL (the Playwright config
#   loads that file over the shell environment), the two lines are swapped
#   for the scratch values during the run and the file is restored on exit.
#
# Tunables: E2E_CHECK_WAIT_SECONDS (default 1200) is how long to wait for a
# slot and its ports; E2E_CHECK_SLOTS (1 to 3, default 3) is how many runs go
# at once.

set -u

PORTS=""
REDIS_DB=""
# Up to three at a time. A checkout whose mock web server still scans the
# shared 3310-3399 range (before its ports joined the checkout's block) may
# only take slot 1, so two such runs never race for 3310.
SLOTS="${E2E_CHECK_SLOTS:-3}"
SLOT_BLOCKS="30010 30020 30030"
SLOT_REDIS="8 9 12"
WAIT_SECONDS="${E2E_CHECK_WAIT_SECONDS:-1200}"
LOCK_BASE="${TMPDIR:-/tmp}/casefilecrafter-e2e-check.slot"
LOCK_DIR=""
LOG_DIR="${TMPDIR:-/tmp}/casefilecrafter-e2e-check"

say() { echo "e2e-check: $*" >&2; }

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
  say "usage: $0 <checkout path> [playwright arguments...]"
  echo "e2e-check: passed=0 failed=0 flaky=0 skipped=0 exit=2 log=none"
  exit 2
fi

CHECKOUT="$(cd "$1" && pwd)"
shift
NAME="$(basename "$CHECKOUT")"
E2E_ENV="$CHECKOUT/apps/e2e/.env"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$NAME-$(date +%Y%m%d-%H%M%S).log"

DB=""
HAVE_LOCK=0
ENV_BACKUP=""
PASSED=0 FAILED=0 FLAKY=0 SKIPPED=0
STATUS=2

listeners() {
  local port
  for port in $PORTS; do
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null
  done
}

# shellcheck disable=SC2317  # Called only by the trap.
cleanup() {
  trap - EXIT INT TERM
  # Stop any server of this checkout that outlived the run.
  local pid cwd
  for pid in $(listeners); do
    cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    case "$cwd" in "$CHECKOUT"/*) kill "$pid" 2>/dev/null ;; esac
  done
  if [ -n "$ENV_BACKUP" ] && [ -f "$ENV_BACKUP" ]; then
    mv -f "$ENV_BACKUP" "$E2E_ENV"
  fi
  if [ "$HAVE_LOCK" = 1 ]; then
    docker exec redis redis-cli -n "$REDIS_DB" flushdb >/dev/null 2>&1
  fi
  if [ -n "$DB" ]; then
    docker exec postgres psql -U admin -q \
      -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" >/dev/null 2>&1 ||
      say "could not drop $DB; drop it by hand"
  fi
  [ "$HAVE_LOCK" = 1 ] && rm -rf "$LOCK_DIR"
  echo "e2e-check: passed=$PASSED failed=$FAILED flaky=$FLAKY skipped=$SKIPPED exit=$STATUS log=$LOG"
  exit "$STATUS"
}
trap cleanup EXIT
trap 'say "interrupted"; STATUS=130; exit 130' INT TERM

fail() { say "$*"; STATUS=2; exit 2; }

[ -f "$CHECKOUT/apps/e2e/playwright.config.ts" ] || fail "$CHECKOUT is not a casefilecrafter checkout"
[ -d "$CHECKOUT/node_modules" ] || fail "$CHECKOUT has no node_modules; run pnpm install there"
[ -f "$CHECKOUT/.env" ] || fail "$CHECKOUT has no .env"
grep -q '^E2E_USER_EMAIL=.' "$E2E_ENV" 2>/dev/null || fail "$E2E_ENV does not set E2E_USER_EMAIL"

# A few runs at a time on this machine: take the first free slot.
case "$SLOTS" in 1 | 2 | 3) ;; *) SLOTS=3 ;; esac
BLOCK_PORTS=8
if ! grep -q 'MOCK_WEB_PORT_COUNT' "$CHECKOUT/apps/e2e/test/support/e2e-ports.ts" 2>/dev/null; then
  SLOTS=1
  BLOCK_PORTS=4
  say "this checkout's mock web server predates its own ports: slot 1 only"
fi
deadline=$(($(date +%s) + WAIT_SECONDS))
SLOT=0
while [ "$SLOT" = 0 ]; do
  n=1
  while [ "$n" -le "$SLOTS" ]; do
    dir="$LOCK_BASE.$n"
    if mkdir "$dir" 2>/dev/null; then
      SLOT="$n"
      break
    fi
    holder="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      say "removing a stale lock on slot $n left by pid $holder"
      rm -rf "$dir"
      continue
    fi
    n=$((n + 1))
  done
  [ "$SLOT" != 0 ] && break
  [ "$(date +%s)" -lt "$deadline" ] || fail "all $SLOTS e2e-check slots are still held after ${WAIT_SECONDS}s"
  sleep 5
done
LOCK_DIR="$LOCK_BASE.$SLOT"
HAVE_LOCK=1
echo $$ >"$LOCK_DIR/pid"
BLOCK="$(echo "$SLOT_BLOCKS" | cut -d' ' -f"$SLOT")"
REDIS_DB="$(echo "$SLOT_REDIS" | cut -d' ' -f"$SLOT")"
PORTS="$(seq "$BLOCK" $((BLOCK + BLOCK_PORTS - 1)) | tr '\n' ' ')"

waited=0
while [ -n "$(listeners)" ]; do
  if [ "$waited" = 0 ]; then
    say "waiting for ports $PORTS; held by:"
    for pid in $(listeners); do
      say "  pid $pid in $(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
    done
    waited=1
  fi
  [ "$(date +%s)" -lt "$deadline" ] || fail "ports $PORTS still in use after ${WAIT_SECONDS}s"
  sleep 5
done

# Scratch database, named after the checkout and this process.
suffix="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-28)"
DB="casefilecrafter-e2e-check-$suffix-$$"
[ "$DB" != "casefilecrafter-local" ] || fail "refusing to use casefilecrafter-local"
URL="$(cd "$CHECKOUT" && DB="$DB" node -e "
const { parseEnv } = require('node:util')
const env = parseEnv(require('node:fs').readFileSync('.env', 'utf8'))
const url = new URL(env.POSTGRES_URL)
url.pathname = '/' + process.env.DB
process.stdout.write(url.toString())")" || fail "could not read POSTGRES_URL from $CHECKOUT/.env"
REDIS="redis://localhost:6379/$REDIS_DB"

say "checkout $CHECKOUT at $(git -C "$CHECKOUT" rev-parse --short HEAD 2>/dev/null)"
say "slot $SLOT: ports $PORTS, database $DB, Redis database $REDIS_DB, log $LOG"

docker exec postgres psql -U admin -q -c "CREATE DATABASE \"$DB\"" >>"$LOG" 2>&1 || fail "could not create $DB"
docker exec redis redis-cli -n "$REDIS_DB" flushdb >/dev/null 2>&1 || fail "Redis is not reachable"

# The Playwright config loads apps/e2e/.env over the shell environment, so a
# pinned database or Redis there would win. Swap those lines for this run.
if grep -Eq '^(E2E_DB_NAME|E2E_REDIS_URL|E2E_PORT_BLOCK|E2E_WEB_PORT|E2E_API_PORT|E2E_MAIL_PORT|E2E_MODEL_PORT|E2E_MOCK_WEB_PORT|BASE_URL)=' "$E2E_ENV"; then
  ENV_BACKUP="$E2E_ENV.e2e-check-backup-$$"
  cp -p "$E2E_ENV" "$ENV_BACKUP" || fail "could not back up $E2E_ENV"
  {
    grep -Ev '^(E2E_DB_NAME|E2E_REDIS_URL|E2E_PORT_BLOCK|E2E_WEB_PORT|E2E_API_PORT|E2E_MAIL_PORT|E2E_MODEL_PORT|E2E_MOCK_WEB_PORT|BASE_URL)=' "$ENV_BACKUP"
    echo "E2E_DB_NAME=$DB"
    echo "E2E_REDIS_URL=$REDIS"
    echo "E2E_PORT_BLOCK=$BLOCK"
  } >"$E2E_ENV"
fi

export POSTGRES_URL="$URL" E2E_DB_NAME="$DB" E2E_REDIS_URL="$REDIS" E2E_PORT_BLOCK="$BLOCK"
unset CI BASE_URL E2E_WEB_PORT E2E_API_PORT E2E_MAIL_PORT E2E_MODEL_PORT E2E_MOCK_WEB_PORT

step() {
  local label="$1"
  shift
  say "$label"
  (cd "$CHECKOUT" && "$@") >>"$LOG" 2>&1 || fail "$label failed; see $LOG"
}

step "applying migrations" pnpm db:local:up
step "seeding reference data" pnpm db:seed
step "seeding the e2e user" pnpm --filter @casefilecrafter/e2e seed
rm -f "$CHECKOUT/apps/e2e/test/support/.auth/user.json"

say "running the e2e suite (one worker)"
started=$(date +%s)
(cd "$CHECKOUT" && pnpm --filter @casefilecrafter/e2e test "$@") >>"$LOG" 2>&1
run_exit=$?
say "suite finished in $(($(date +%s) - started))s with exit $run_exit"

count() {
  sed -n "s/^ *\([0-9][0-9]*\) $1.*/\1/p" "$LOG" | tail -1
}
PASSED="$(count passed)"
FAILED="$(count failed)"
FLAKY="$(count flaky)"
SKIPPED="$(count skipped)"
PASSED="${PASSED:-0}" FAILED="${FAILED:-0}" FLAKY="${FLAKY:-0}" SKIPPED="${SKIPPED:-0}"

if [ "$FAILED" != 0 ] || [ "$FLAKY" != 0 ]; then
  say "failed or flaky tests:"
  grep -E '^ +[0-9]+\) \[' "$LOG" | sort -u | cut -c1-200 >&2
fi

if [ "$run_exit" = 0 ] && [ "$FAILED" = 0 ] && [ "$FLAKY" = 0 ] && [ "$PASSED" != 0 ]; then
  STATUS=0
else
  STATUS=1
  [ "$PASSED" = 0 ] && [ "$FAILED" = 0 ] && say "no test ran; see $LOG"
fi
exit "$STATUS"
