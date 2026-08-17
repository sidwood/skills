#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "uninstall: removes repository skill links from every target" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -L "$AGENTS_SKILLS_DIR/bug-report" ]
  [ ! -L "$CLAUDE_SKILLS_DIR/commit-message" ]
  [ ! -L "$GROK_SKILLS_DIR/to-prd" ]
}

@test "uninstall: leaves foreign links untouched" {
  mkdir -p "$CLAUDE_HOME" "$AGENTS_SKILLS_DIR"
  ln -s "$SANDBOX/other-agents.md" "$CLAUDE_HOME/CLAUDE.md"
  ln -s "$SANDBOX/foreign-skill" "$AGENTS_SKILLS_DIR/bug-report"
  run_uninstall
  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_HOME/CLAUDE.md" "$SANDBOX/other-agents.md"
  assert_symlink_to "$AGENTS_SKILLS_DIR/bug-report" "$SANDBOX/foreign-skill"
}

@test "uninstall: removes empty skill directories" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -d "$AGENTS_SKILLS_DIR" ]
  [ ! -d "$CLAUDE_SKILLS_DIR" ]
  [ ! -d "$GROK_SKILLS_DIR" ]
}

@test "uninstall: leaves non-empty skill directories" {
  run_install
  [ "$status" -eq 0 ]
  printf 'foreign\n' > "$CLAUDE_SKILLS_DIR/foreign-skill"
  run_uninstall
  [ "$status" -eq 0 ]
  [ -f "$CLAUDE_SKILLS_DIR/foreign-skill" ]
}

@test "uninstall: removes only its Hermes external directory entry" {
  mkdir -p "$HERMES_HOME"
  printf 'skills:\n  external_dirs:\n    - /existing/skills\n' > "$HERMES_CONFIG_FILE"
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  grep -Fq '    - /existing/skills' "$HERMES_CONFIG_FILE"
  run grep -Fq "$REPO_ROOT/skills" "$HERMES_CONFIG_FILE"
  [ "$status" -eq 1 ]
}

@test "uninstall: removes renamed-skill links owned by the repository" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$REPO_ROOT/caveman" "$CLAUDE_SKILLS_DIR/caveman"
  ln -s \
    "$REPO_ROOT/skills/engineering/design-an-interface" \
    "$CLAUDE_SKILLS_DIR/design-an-interface"
  run_uninstall
  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_SKILLS_DIR/caveman" ]
  [ ! -L "$CLAUDE_SKILLS_DIR/design-an-interface" ]
}

@test "uninstall: is idempotent" {
  run_install
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
  run_uninstall
  [ "$status" -eq 0 ]
}
