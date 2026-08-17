#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "uninstall: exits with an error when stow is missing" {
  local bindir
  bindir="$(make_stowless_path)"
  run env PATH="$bindir" bash "$REPO_ROOT/uninstall.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GNU Stow is required"* ]]
}

@test "uninstall: removes skill symlinks created by install" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SKILLS_DIR/bug-report" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/commit-message" ]
  [ ! -e "$CODEX_SKILLS_DIR/bug-report" ]
}

@test "uninstall: removes the CLAUDE.md symlink pointing at this repo" {
  run_install
  [ "$status" -eq 0 ]
  [ -L "$CLAUDE_HOME/CLAUDE.md" ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_HOME/CLAUDE.md" ]
}

@test "uninstall: leaves a foreign CLAUDE.md symlink untouched" {
  mkdir -p "$CLAUDE_HOME"
  ln -s "$SANDBOX/other-agents.md" "$CLAUDE_HOME/CLAUDE.md"
  run_uninstall
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_HOME/CLAUDE.md" "$SANDBOX/other-agents.md"
}

@test "uninstall: removes empty skills directories" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -d "$CLAUDE_SKILLS_DIR" ]
  [ ! -d "$CODEX_SKILLS_DIR" ]
}

@test "uninstall: removes a legacy renamed-skill link pointing into the repo" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$REPO_ROOT/caveman" "$CLAUDE_SKILLS_DIR/caveman"
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SKILLS_DIR/caveman" ]
}

@test "uninstall: is idempotent when run twice" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
}
