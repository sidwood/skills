#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "install: exits with an error when stow is missing" {
  local bindir
  bindir="$(make_stowless_path)"
  run env PATH="$bindir" bash "$REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"GNU Stow is required"* ]]
}

@test "install: creates the Claude and Codex skills directories" {
  run_install
  [ "$status" -eq 0 ]
  [ -d "$CLAUDE_SKILLS_DIR" ]
  [ -d "$CODEX_SKILLS_DIR" ]
}

@test "install: symlinks repo skills into both targets" {
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_SKILLS_DIR/bug-report" "$REPO_ROOT/bug-report"
  assert_symlink_to "$CLAUDE_SKILLS_DIR/commit-message" "$REPO_ROOT/commit-message"
  assert_symlink_to "$CODEX_SKILLS_DIR/bug-report" "$REPO_ROOT/bug-report"
  assert_symlink_to "$CODEX_SKILLS_DIR/commit-message" "$REPO_ROOT/commit-message"
}

@test "install: does not expose repo metadata files as skills" {
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SKILLS_DIR/README.md" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/install.sh" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/uninstall.sh" ]
  [ ! -e "$CODEX_SKILLS_DIR/AGENTS.md" ]
}

@test "install: links AGENTS.md as ~/.claude/CLAUDE.md" {
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_HOME/CLAUDE.md" "$REPO_ROOT/AGENTS.md"
}

@test "install: is idempotent when run twice" {
  run_install
  [ "$status" -eq 0 ]
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_SKILLS_DIR/bug-report" "$REPO_ROOT/bug-report"
}

@test "install: refreshes CLAUDE.md when it already points elsewhere" {
  mkdir -p "$CLAUDE_HOME"
  ln -s "$SANDBOX/other-agents.md" "$CLAUDE_HOME/CLAUDE.md"
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_HOME/CLAUDE.md" "$REPO_ROOT/AGENTS.md"
}

@test "install: removes a legacy renamed-skill link pointing into the repo" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$REPO_ROOT/write-a-prd" "$CLAUDE_SKILLS_DIR/write-a-prd"
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SKILLS_DIR/write-a-prd" ]
}

@test "install: leaves an unrelated same-named link untouched" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$SANDBOX/somewhere-else" "$CLAUDE_SKILLS_DIR/write-a-prd"
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_SKILLS_DIR/write-a-prd" "$SANDBOX/somewhere-else"
}
