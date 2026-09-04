# shellcheck shell=bash
# Shared configuration for the fleet-orchestrator scripts. Source this file;
# do not execute it. Every project binding arrives as an environment variable,
# so the same scripts drive any repository and any agent session.

# Load an optional env file first, then apply defaults for everything the
# scripts derive from the required session and seed bindings.
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
  : "${FLEET_POLL_SECONDS:=10}"
  : "${FLEET_ACK_TIMEOUT_SECONDS:=120}"
  : "${FLEET_TEARDOWN_GRACE_SECONDS:=30}"
  : "${FLEET_STALL_SECONDS:=2700}"
  : "${FLEET_VERDICT_LANE_GLOBS:=*-review* *-rereview* *-parity*}"
  : "${FLEET_SWEEP_INSTRUCTION:=Capture; apply the event table; update fleet state.}"
  : "${FLEET_CI_POLLS:=40}"
  : "${FLEET_CI_POLL_SECONDS:=90}"
  : "${FLEET_MONITOR_STALE_SECONDS:=30}"
  : "${FLEET_CI_STALE_SECONDS:=240}"
  : "${FLEET_BOARD_STALE_SECONDS:=600}"
  : "${FLEET_VELOCITY_WINDOW_SECONDS:=3300}"
  : "${FLEET_CLOSED_PHASES:=landed superseded withdrawn complete}"
  : "${FLEET_QUEUED_PHASES:=approved approved-replay-queued landing-replay}"
  : "${FLEET_ACTIVE_PHASES:=implementing review in-review bounce}"
  : "${FLEET_BLOCKED_PHASES:=blocked parked hold}"

  case "$FLEET_POLL_SECONDS" in
    '' | 0* | *[!0-9]*)
      echo "fleet-env: FLEET_POLL_SECONDS must be a positive integer." >&2
      return 1
      ;;
  esac
  case "$FLEET_ACK_TIMEOUT_SECONDS" in
    '' | 0* | *[!0-9]*)
      echo "fleet-env: FLEET_ACK_TIMEOUT_SECONDS must be a positive integer." >&2
      return 1
      ;;
  esac
  case "$FLEET_TEARDOWN_GRACE_SECONDS" in
    '' | *[!0-9]* | 0[0-9]*)
      echo "fleet-env: FLEET_TEARDOWN_GRACE_SECONDS must be a non-negative integer." >&2
      return 1
      ;;
  esac
  case "$FLEET_STALL_SECONDS" in
    '' | 0* | *[!0-9]*)
      echo "fleet-env: FLEET_STALL_SECONDS must be a positive integer." >&2
      return 1
      ;;
  esac

  if [ -n "${FLEET_SEED:-}" ]; then
    : "${FLEET_STATE_DIR:=$FLEET_SEED/temp/fleet}"
  fi

  if [ -n "${FLEET_STATE_DIR:-}" ]; then
    : "${FLEET_CONFIG:=$FLEET_STATE_DIR/fleet.json}"
    : "${FLEET_HEARTBEAT:=$FLEET_STATE_DIR/fleet-monitor.heartbeat}"
    : "${FLEET_SWEPT:=$FLEET_STATE_DIR/fleet-monitor.swept}"
    : "${FLEET_PENDING:=$FLEET_STATE_DIR/fleet-monitor.pending}"
    : "${FLEET_DELIVERY_FAILURES:=$FLEET_STATE_DIR/fleet-monitor.delivery-failures}"
    : "${FLEET_MONITOR_LOCK_FILE:=$FLEET_STATE_DIR/fleet-monitor.lockfile}"
    : "${FLEET_LOG:=$FLEET_STATE_DIR/fleet-monitor.log}"
    : "${FLEET_CAPTURES_DIR:=$FLEET_STATE_DIR/captures}"
    : "${FLEET_CI_HEARTBEAT:=$FLEET_STATE_DIR/ci-watch.heartbeat}"
    : "${FLEET_PUSH_MARKER:=$FLEET_STATE_DIR/push-inflight.marker}"
    : "${FLEET_VELOCITY_LOG:=$FLEET_STATE_DIR/backlog-velocity.log}"
  fi

  export FLEET_COORDINATOR FLEET_SESSION FLEET_SEED FLEET_CONFIG FLEET_STATE_DIR
  export FLEET_POLL_SECONDS FLEET_ACK_TIMEOUT_SECONDS
  export FLEET_TEARDOWN_GRACE_SECONDS FLEET_STALL_SECONDS
  export FLEET_SWEEP_INSTRUCTION FLEET_VERDICT_LANE_GLOBS
  export FLEET_HEARTBEAT FLEET_SWEPT FLEET_PENDING FLEET_DELIVERY_FAILURES
  export FLEET_MONITOR_LOCK_FILE
  export FLEET_LOG FLEET_CAPTURES_DIR FLEET_CI_HEARTBEAT
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
        if ! mkdir -p "$value" 2>/dev/null || [ ! -d "$value" ] || [ ! -w "$value" ]; then
          missing="$missing  $name ('$value' is not a writable directory)\n"
        fi
        if [ -n "${FLEET_SEED:-}" ]; then
          case "$value/" in
            "$FLEET_SEED"/*)
              git -C "$FLEET_SEED" check-ignore -q -- "$value" 2>/dev/null ||
                missing="$missing  $name ('$value' is inside the seed but not gitignored; add /temp/ to .gitignore)\n"
              ;;
          esac
        fi
        if [ -z "${FLEET_CAPTURES_DIR:-}" ]; then
          missing="$missing  FLEET_CAPTURES_DIR (is unset)\n"
        elif ! mkdir -p "$FLEET_CAPTURES_DIR" 2>/dev/null ||
          [ ! -d "$FLEET_CAPTURES_DIR" ] || [ ! -w "$FLEET_CAPTURES_DIR" ]; then
          missing="$missing  FLEET_CAPTURES_DIR ('$FLEET_CAPTURES_DIR' is not a writable directory)\n"
        elif [ -n "${FLEET_SEED:-}" ]; then
          case "$FLEET_CAPTURES_DIR/" in
            "$FLEET_SEED"/*)
              git -C "$FLEET_SEED" check-ignore -q -- "$FLEET_CAPTURES_DIR" 2>/dev/null ||
                missing="$missing  FLEET_CAPTURES_DIR ('$FLEET_CAPTURES_DIR' is inside the seed but not gitignored; add /temp/ to .gitignore)\n"
              ;;
          esac
        fi
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
Defaults after FLEET_SEED is set:
  FLEET_STATE_DIR  <seed>/temp/fleet (must be gitignored)
  FLEET_CONFIG     <seed>/temp/fleet/fleet.json
See references/orchestrator-config.md for overrides and optional bindings.
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
