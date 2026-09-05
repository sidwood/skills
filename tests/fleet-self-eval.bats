#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox

  SELF_EVAL="$REPO_ROOT/skills/workflow/fleet-orchestrator/scripts/self-eval.sh"
  SEED="$SANDBOX/seed"
  STATE_DIR="$SEED/temp/fleet"
  FLEET_FILE="$STATE_DIR/fleet.json"
  PENDING_FILE="$STATE_DIR/fleet-monitor.pending"
  SWEPT_FILE="$STATE_DIR/fleet-monitor.swept"
  HERDR_INVENTORY="$SANDBOX/herdr-inventory.json"
  FAKE_BIN="$SANDBOX/bin"

  mkdir -p "$SEED" "$STATE_DIR" "$FAKE_BIN"
  git -C "$SEED" init -q
  printf '/temp/\n' > "$SEED/.gitignore"
  git -C "$SEED" add .gitignore
  git -C "$SEED" \
    -c user.name='Fleet Self-Eval Test' \
    -c user.email='fleet-self-eval@example.test' \
    commit -qm 'Ignore fleet runtime state'

  printf '{"workspace":"w1","streams":[]}\n' > "$FLEET_FILE"
  : > "$PENDING_FILE"
  : > "$SWEPT_FILE"
  date +%s > "$STATE_DIR/fleet-monitor.heartbeat"
  write_fake_commands
  write_idle_inventory
}

teardown() {
  teardown_sandbox
}

write_fake_commands() {
  cat > "$FAKE_BIN/herdr" <<'HERDR'
#!/usr/bin/env bash
python3 - "$HERDR_INVENTORY" "${FLEET_WORKSPACE:-w1}" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as source:
    inventory = json.load(source)
for agent in inventory.get("result", {}).get("agents", []):
    if "workspace_id" not in agent:
        agent["workspace_id"] = sys.argv[2]
json.dump(inventory, sys.stdout)
sys.stdout.write("\n")
PYTHON
HERDR
  cat > "$FAKE_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '[]\n'
GH
  chmod +x "$FAKE_BIN/herdr" "$FAKE_BIN/gh"
}

write_idle_inventory() {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3},
  {"name":"ticket-impl","agent_status":"idle","state_change_seq":8}
]}}
JSON
}

invoke_self_eval() {
  run env \
    -u FLEET_ENV \
    -u FLEET_PENDING \
    -u FLEET_SWEPT \
    -u FLEET_HEARTBEAT \
    -u FLEET_SESSION \
    -u FLEET_WORKSPACE \
    -u FLEET_VELOCITY_LOG \
    "PATH=$FAKE_BIN:$PATH" \
    FLEET_WORKSPACE=w1 \
    FLEET_COORDINATOR=coordinator \
    "FLEET_SEED=$SEED" \
    "FLEET_STATE_DIR=$STATE_DIR" \
    "FLEET_CONFIG=$FLEET_FILE" \
    "HERDR_INVENTORY=$HERDR_INVENTORY" \
    bash "$SELF_EVAL"
}

sync_recipe_catalog() {
  python3 \
    "$REPO_ROOT/skills/workflow/fleet-coordinator/scripts/fleet.py" \
    --config "$FLEET_FILE" recipes sync >/dev/null
}

@test "default Herdr session reports the configured project workspace" {
  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"workspace w1 in default session"* ]]
  [[ "$output" != *"WORKSPACE-DRIFT"* ]]
}

@test "workspace mismatch is a topology alarm" {
  printf '{"workspace":"w2","streams":[]}\n' > "$FLEET_FILE"

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSPACE-DRIFT:"* ]]
  [[ "$output" == *"'w2' != FLEET_WORKSPACE 'w1'"* ]]
}

@test "missing workspace is a topology alarm" {
  printf '{"streams":[]}\n' > "$FLEET_FILE"

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSPACE-DRIFT: fleet.json workspace is missing or invalid"* ]]
}

@test "non-string session is a topology alarm" {
  printf '{"workspace":"w1","session":false,"streams":[]}\n' > "$FLEET_FILE"

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"WORKSPACE-DRIFT: fleet.json session must be a string"* ]]
}

@test "conflicting agent workspace identities fail lane inventory" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"worker","workspace_id":"w1","pane_id":"w2:p9","agent_status":"working","state_change_seq":3}
]}}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"LANE-READ-FAILED agent workspace identities conflict"* ]]
}

@test "missing canonical Cursor Grok recipe reports recipe drift" {
  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"RECIPE-DRIFT:"* ]]
  [[ "$output" == *"missing recipe grok-xhigh-cursor"* ]]
}

@test "capacity hold without replacement is an orchestrator alarm" {
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"TICKET",
  "phase":"hold",
  "agents":{"impl":{"name":"ticket-impl","dispatchState":"resolved"}},
  "events":[{
    "eventId":"ticket-impl@9",
    "agent":"ticket-impl",
    "kind":"resolved-invalid-output",
    "resolutionClass":"capacity",
    "role":"impl",
    "usagePool":"grok-native"
  }]
}]}
JSON
  sync_recipe_catalog

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"recipe catalog: current"* ]]
  [[ "$output" == *"CAPACITY-STALL: TICKET"* ]]
}

@test "pending event handles a lane after its state sequence advances" {
  local sent_at pending_line
  sent_at=$(($(date +%s) - 12))
  printf 'ticket-impl@7\tticket-impl\tdone\t%s\t2\tcoordinator\n' "$sent_at" \
    > "$PENDING_FILE"

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"settled-unswept=0: none"* ]]
  pending_line="$(printf '%s\n' "$output" | awk '/^pending-delivery=/')"
  [[ "$pending_line" == *"ticket-impl@7[coordinator,age="* ]]
  [[ "$pending_line" == *"s,attempts=2]" ]]
}

@test "local swept entry alone cannot hide an unacknowledged lane" {
  printf 'ticket-impl@7\n' > "$SWEPT_FILE"

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"settled-unswept=1: ticket-impl@8"* ]]
  [[ "$output" == *"pending-delivery=0: none"* ]]
}

@test "durable fleet event handles a lane after its sequence advances" {
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"TICKET",
  "agents":{"impl":{"name":"ticket-impl","dispatchState":"closed"}},
  "events":[{"eventId":"ticket-impl@7","agent":"ticket-impl","kind":"review-ready"}]
}]}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"settled-unswept=0: none"* ]]
  [[ "$output" == *"pending-delivery=0: none"* ]]
}

@test "unhandled settled lane reports its current event id" {
  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"settled-unswept=1: ticket-impl@8"* ]]
  [[ "$output" == *"pending-delivery=0: none"* ]]
}

@test "self-eval ignores agents from another project workspace" {
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","workspace_id":"w1","agent_status":"idle","state_change_seq":3},
  {"name":"other-worker","workspace_id":"w2","agent_status":"done","state_change_seq":9}
]}}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"settled-unswept=0: none"* ]]
  [[ "$output" != *"other-worker"* ]]
}

@test "active streams match exact recorded names after ticket truncation" {
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[
  {
    "ticket":"TICKET-WITH-A-SHARED-VERY-LONG-PREFIX-ONE",
    "phase":"implementing",
    "agents":{"impl":{"name":"ticket-with-a-12ab34cd-impl-1","dispatchState":"active"}}
  },
  {
    "ticket":"TICKET-WITH-A-SHARED-VERY-LONG-PREFIX-TWO",
    "phase":"implementing",
    "agents":{"impl":{"name":"ticket-with-a-98ef76ab-impl-1","dispatchState":"active"}}
  }
]}
JSON
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3},
  {"name":"ticket-with-a-12ab34cd-impl-1","agent_status":"working","state_change_seq":2}
]}}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" != *"ORPHANED: TICKET-WITH-A-SHARED-VERY-LONG-PREFIX-ONE"* ]]
  [[ "$output" == *"ORPHANED: TICKET-WITH-A-SHARED-VERY-LONG-PREFIX-TWO"* ]]
}

@test "closed old role cannot mask a missing active lane" {
  cat > "$FLEET_FILE" <<'JSON'
{"workspace":"w1","streams":[{
  "ticket":"TICKET",
  "phase":"review-1",
  "agents":{
    "impl":{"name":"ticket-old-impl","dispatchState":"closed"},
    "review":{"name":"ticket-current-review","dispatchState":"active"}
  }
}]}
JSON
  cat > "$HERDR_INVENTORY" <<'JSON'
{"result":{"agents":[
  {"name":"coordinator","agent_status":"idle","state_change_seq":3},
  {"name":"ticket-old-impl","agent_status":"idle","state_change_seq":9}
]}}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" == *"ORPHANED: TICKET phase 'review-1'"* ]]
}

@test "fresh ready work is not mistaken for an already-landed queue item" {
  local seed_tip
  seed_tip="$(git -C "$SEED" rev-parse HEAD)"
  cat > "$FLEET_FILE" <<JSON
{"workspace":"w1","streams":[{
  "ticket":"READY-TICKET",
  "phase":"ready",
  "tip":"$seed_tip",
  "agents":{}
}]}
JSON

  invoke_self_eval

  [ "$status" -eq 0 ]
  [[ "$output" != *"QUEUE-DRIFT: READY-TICKET"* ]]
  [[ "$output" == *"train queue: (empty)"* ]]
}
