#!/usr/bin/env bats
# shellcheck disable=SC2016

load helper

setup() {
  setup_sandbox

  ENV_SCRIPT="$REPO_ROOT/skills/workflow/fleet-orchestrator/scripts/fleet-env.sh"
  STATE_DIR="$SANDBOX/state"
  CONFIG="$STATE_DIR/fleet.json"
  mkdir -p "$STATE_DIR"
  printf '{"streams":[]}\n' > "$CONFIG"
}

teardown() {
  teardown_sandbox
}

@test "explicit state and config work without a fleet seed" {
  run env -u FLEET_ENV -u FLEET_SEED -u FLEET_CAPTURES_DIR bash -u -c '
    FLEET_STATE_DIR="$1"
    FLEET_CONFIG="$2"
    . "$3"
    fleet_env_load
    fleet_env_require FLEET_STATE_DIR FLEET_CONFIG
    printf "%s\n" "$FLEET_CAPTURES_DIR"
  ' bash "$STATE_DIR" "$CONFIG" "$ENV_SCRIPT"

  [ "$status" -eq 0 ]
  [ "$output" = "$STATE_DIR/captures" ]
  [ -d "$STATE_DIR/captures" ]
}

@test "an overridden captures directory is created" {
  local captures="$SANDBOX/transcripts"

  run env -u FLEET_ENV -u FLEET_SEED bash -u -c '
    FLEET_STATE_DIR="$1"
    FLEET_CONFIG="$2"
    FLEET_CAPTURES_DIR="$3"
    . "$4"
    fleet_env_load
    fleet_env_require FLEET_STATE_DIR FLEET_CONFIG
  ' bash "$STATE_DIR" "$CONFIG" "$captures" "$ENV_SCRIPT"

  [ "$status" -eq 0 ]
  [ -d "$captures" ]
}

@test "a non-directory captures path is rejected" {
  local captures="$SANDBOX/not-a-directory"
  printf 'occupied\n' > "$captures"

  run env -u FLEET_ENV -u FLEET_SEED bash -u -c '
    FLEET_STATE_DIR="$1"
    FLEET_CONFIG="$2"
    FLEET_CAPTURES_DIR="$3"
    . "$4"
    fleet_env_load
    fleet_env_require FLEET_STATE_DIR FLEET_CONFIG
  ' bash "$STATE_DIR" "$CONFIG" "$captures" "$ENV_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"FLEET_CAPTURES_DIR ('$captures' is not a writable directory)"* ]]
}

@test "poll, acknowledgement, and stall intervals require canonical positive decimals" {
  for value in 0 00 08; do
    run env -u FLEET_ENV FLEET_POLL_SECONDS="$value" bash -c \
      'source "$1"; fleet_env_load' _ "$ENV_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FLEET_POLL_SECONDS must be a positive integer"* ]]

    run env -u FLEET_ENV FLEET_ACK_TIMEOUT_SECONDS="$value" bash -c \
      'source "$1"; fleet_env_load' _ "$ENV_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FLEET_ACK_TIMEOUT_SECONDS must be a positive integer"* ]]

    run env -u FLEET_ENV FLEET_STALL_SECONDS="$value" bash -c \
      'source "$1"; fleet_env_load' _ "$ENV_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FLEET_STALL_SECONDS must be a positive integer"* ]]
  done
}

@test "teardown grace defaults to thirty and requires a canonical non-negative decimal" {
  run env -u FLEET_ENV -u FLEET_TEARDOWN_GRACE_SECONDS bash -c \
    'source "$1"; fleet_env_load; printf "%s\n" "$FLEET_TEARDOWN_GRACE_SECONDS"' \
    _ "$ENV_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = 30 ]

  for value in 00 08 -1 invalid; do
    run env -u FLEET_ENV FLEET_TEARDOWN_GRACE_SECONDS="$value" bash -c \
      'source "$1"; fleet_env_load' _ "$ENV_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"FLEET_TEARDOWN_GRACE_SECONDS must be a non-negative integer"* ]]
  done

  run env -u FLEET_ENV FLEET_TEARDOWN_GRACE_SECONDS=0 bash -c \
    'source "$1"; fleet_env_load' _ "$ENV_SCRIPT"
  [ "$status" -eq 0 ]
}

@test "an in-seed runtime directory must be gitignored" {
  local seed="$SANDBOX/seed" fleet_dir="$SANDBOX/seed/temp/fleet"
  mkdir -p "$fleet_dir"
  git -C "$seed" init -q
  printf '{"streams":[]}\n' > "$fleet_dir/fleet.json"

  run env -u FLEET_ENV -u FLEET_CAPTURES_DIR bash -u -c '
    FLEET_SEED="$1"
    FLEET_STATE_DIR="$2"
    FLEET_CONFIG="$2/fleet.json"
    . "$3"
    fleet_env_load
    fleet_env_require FLEET_STATE_DIR FLEET_CONFIG
  ' bash "$seed" "$fleet_dir" "$ENV_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"inside the seed but not gitignored"* ]]
}

@test "an overridden in-seed captures directory must be gitignored" {
  local seed="$SANDBOX/seed" captures="$SANDBOX/seed/captures"
  mkdir -p "$seed"
  git -C "$seed" init -q

  run env -u FLEET_ENV bash -u -c '
    FLEET_SEED="$1"
    FLEET_STATE_DIR="$2"
    FLEET_CONFIG="$3"
    FLEET_CAPTURES_DIR="$4"
    . "$5"
    fleet_env_load
    fleet_env_require FLEET_STATE_DIR FLEET_CONFIG
  ' bash "$seed" "$STATE_DIR" "$CONFIG" "$captures" "$ENV_SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"FLEET_CAPTURES_DIR ('$captures' is inside the seed but not gitignored"* ]]
}
