#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
  HOOK="$REPO_ROOT/.githooks/pre-commit"
  FAKE_BIN="$SANDBOX/bin"
  mkdir -p "$FAKE_BIN"
}

teardown() {
  teardown_sandbox
}

@test "pre-commit hook: is executable" {
  [ -x "$HOOK" ]
}

@test "pre-commit hook: explains how to install a missing runner" {
  run env PATH="/usr/bin:/bin" bash "$HOOK"
  [ "$status" -eq 1 ]
  [[ "$output" == *"brew install pre-commit"* ]]
  [[ "$output" == *"do not re-run"* ]]
  [[ "$output" == *"--no-verify"* ]]
}

@test "pre-commit hook: runs the configured pre-commit stage" {
  local invocation_log="$SANDBOX/invocation.log"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "printf '%s\\n' \"\$*\" > \"\$INVOCATION_LOG\"" \
    > "$FAKE_BIN/pre-commit"
  chmod +x "$FAKE_BIN/pre-commit"

  run env \
    PATH="$FAKE_BIN:$PATH" \
    INVOCATION_LOG="$invocation_log" \
    bash "$HOOK"

  [ "$status" -eq 0 ]
  [ "$(cat "$invocation_log")" = "run --hook-stage pre-commit" ]
}

@test "pre-commit hook: gives recovery guidance after a failed check" {
  printf '#!/usr/bin/env bash\necho "ShellCheck failed" >&2\nexit 1\n' > "$FAKE_BIN/pre-commit"
  chmod +x "$FAKE_BIN/pre-commit"

  run env PATH="$FAKE_BIN:$PATH" bash "$HOOK"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ShellCheck failed"* ]]
  [[ "$output" == *"Fix the reported problems"* ]]
  [[ "$output" == *"do not re-run"* ]]
  [[ "$output" == *"--no-verify"* ]]
}
