# shellcheck shell=bash
# Shared configuration for the fleet-orchestrator scripts. Source this file;
# do not execute it. Every project binding arrives as an environment variable,
# so the same scripts drive any repository and any agent session.

# Load an optional env file first, then apply defaults for everything the
# scripts derive from the four required bindings.
fleet_env_load() {
  local env_file="${FLEET_ENV:-}"

  if [ -n "$env_file" ]; then
    if [ ! -f "$env_file" ]; then
      echo "fleet-env: FLEET_ENV '$env_file' does not exist." >&2
      return 1
    fi
    set -a
    # shellcheck source=/dev/null
    . "$env_file"
    set +a
  fi

  : "${FLEET_COORDINATOR:=coordinator}"
  : "${FLEET_POLL_SECONDS:=60}"
  : "${FLEET_STALL_SECONDS:=2700}"
  : "${FLEET_IDLE_SECONDS:=300}"
  : "${FLEET_PULSE_INTERVAL_SECONDS:=600}"
  : "${FLEET_VERDICT_LANE_GLOBS:=*-review* *-rereview* *-parity*}"
  : "${FLEET_SWEEP_INSTRUCTION:=Capture before teardown, apply your event table, and update the fleet config and the board in the same turn.}"
  : "${FLEET_CI_POLLS:=40}"
  : "${FLEET_CI_POLL_SECONDS:=90}"
  : "${FLEET_MONITOR_STALE_SECONDS:=180}"
  : "${FLEET_CI_STALE_SECONDS:=240}"
  : "${FLEET_BOARD_STALE_SECONDS:=600}"
  : "${FLEET_VELOCITY_WINDOW_SECONDS:=3300}"
  : "${FLEET_CLOSED_PHASES:=landed superseded withdrawn complete}"
  : "${FLEET_QUEUED_PHASES:=approved approved-replay-queued landing-replay ready review-ready}"
  : "${FLEET_ACTIVE_PHASES:=implementing review in-review bounce verdict-pending}"
  : "${FLEET_BLOCKED_PHASES:=blocked parked hold}"

  if [ -n "${FLEET_STATE_DIR:-}" ]; then
    : "${FLEET_HEARTBEAT:=$FLEET_STATE_DIR/fleet-monitor.heartbeat}"
    : "${FLEET_SWEPT:=$FLEET_STATE_DIR/fleet-monitor.swept}"
    : "${FLEET_LOG:=$FLEET_STATE_DIR/fleet-monitor.log}"
    : "${FLEET_CI_HEARTBEAT:=$FLEET_STATE_DIR/ci-watch.heartbeat}"
    : "${FLEET_PUSH_MARKER:=$FLEET_STATE_DIR/push-inflight.marker}"
    : "${FLEET_VELOCITY_LOG:=$FLEET_STATE_DIR/backlog-velocity.log}"
  fi

  export FLEET_COORDINATOR FLEET_SESSION FLEET_SEED FLEET_CONFIG FLEET_STATE_DIR
  export FLEET_HEARTBEAT FLEET_SWEPT FLEET_LOG FLEET_CI_HEARTBEAT
  export FLEET_PUSH_MARKER FLEET_VELOCITY_LOG FLEET_VELOCITY_WINDOW_SECONDS
  export FLEET_CLOSED_PHASES FLEET_QUEUED_PHASES FLEET_ACTIVE_PHASES
  export FLEET_BLOCKED_PHASES
}

# Report every missing or unusable binding at once, with the fix, and fail.
# A monitor that starts against half a configuration is worse than one that
# refuses to start.
fleet_env_require() {
  local missing="" name value

  for name in "$@"; do
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
      missing="$missing  $name\n"
      continue
    fi
    case "$name" in
      FLEET_SEED)
        [ -d "$value/.git" ] || missing="$missing  $name ('$value' is not a git repository)\n"
        ;;
      FLEET_CONFIG)
        [ -f "$value" ] || missing="$missing  $name ('$value' does not exist)\n"
        ;;
      FLEET_STATE_DIR)
        mkdir -p "$value" 2>/dev/null ||
          missing="$missing  $name ('$value' is not creatable)\n"
        ;;
    esac
  done

  if [ -n "$missing" ]; then
    echo "fleet-env: unusable configuration:" >&2
    printf '%b' "$missing" >&2
    cat >&2 <<'EOF'
Set them in the environment, or point FLEET_ENV at a file that does:
  FLEET_SESSION    agent session name the fleet runs in
  FLEET_SEED       absolute path to the seed repository
  FLEET_CONFIG     absolute path to the fleet config (fleet.json)
  FLEET_STATE_DIR  absolute path for heartbeats, ledgers, and logs
See references/orchestrator-config.md for the optional bindings.
EOF
    return 1
  fi
}

# True when a lane name matches one of the verdict-bearing lane globs, whose
# settles need a judgment call and therefore an orchestrator wake.
fleet_is_verdict_lane() {
  local lane="$1" glob
  # Deliberate word splitting: the binding is a space-separated glob list.
  # shellcheck disable=SC2086
  set -- $FLEET_VERDICT_LANE_GLOBS
  for glob in "$@"; do
    # shellcheck disable=SC2254
    case "$lane" in
      $glob) return 0 ;;
    esac
  done
  return 1
}
