#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
}

teardown() {
  teardown_sandbox
}

@test "install: creates the shared, Claude, and Grok skill directories" {
  run_install
  [ "$status" -eq 0 ]
  [ -d "$AGENTS_SKILLS_DIR" ]
  [ -d "$CLAUDE_SKILLS_DIR" ]
  [ -d "$GROK_SKILLS_DIR" ]
}

@test "install: exposes every category as flat skill links" {
  run_install
  [ "$status" -eq 0 ]
  assert_catalog_links "$AGENTS_SKILLS_DIR"
  assert_catalog_links "$CLAUDE_SKILLS_DIR"
  assert_catalog_links "$GROK_SKILLS_DIR"
  [ ! -e "$AGENTS_SKILLS_DIR/engineering" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/product" ]
}

@test "install: does not expose repository metadata" {
  run_install
  [ "$status" -eq 0 ]
  [ ! -e "$AGENTS_SKILLS_DIR/README.md" ]
  [ ! -e "$AGENTS_SKILLS_DIR/install.sh" ]
  [ ! -e "$AGENTS_SKILLS_DIR/lib" ]
  [ ! -e "$CLAUDE_SKILLS_DIR/tests" ]
  [ ! -e "$GROK_SKILLS_DIR/.githooks" ]
}

@test "install: leaves Claude global instructions untouched" {
  mkdir -p "$CLAUDE_HOME"
  ln -s "$SANDBOX/other-agents.md" "$CLAUDE_HOME/CLAUDE.md"

  run_install

  [ "$status" -eq 0 ]
  assert_symlink_to "$CLAUDE_HOME/CLAUDE.md" "$SANDBOX/other-agents.md"
}

@test "install: is idempotent" {
  run_install
  [ "$status" -eq 0 ]
  run_install
  [ "$status" -eq 0 ]
  assert_catalog_links "$AGENTS_SKILLS_DIR"
}

@test "install: leaves a foreign same-named skill untouched" {
  mkdir -p "$AGENTS_SKILLS_DIR"
  ln -s "$SANDBOX/foreign-skill" "$AGENTS_SKILLS_DIR/bug-report"
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to "$AGENTS_SKILLS_DIR/bug-report" "$SANDBOX/foreign-skill"
  [[ "$output" == *"foreign symlink"* ]]
}

@test "install: refreshes links from the old flat repository layout" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$REPO_ROOT/bug-report" "$CLAUDE_SKILLS_DIR/bug-report"
  run_install
  [ "$status" -eq 0 ]
  assert_symlink_to \
    "$CLAUDE_SKILLS_DIR/bug-report" \
    "$REPO_ROOT/skills/engineering/bug-report"
}

@test "install: removes repository links from the former Codex directory" {
  mkdir -p "$LEGACY_CODEX_SKILLS_DIR"
  ln -s "$REPO_ROOT/bug-report" "$LEGACY_CODEX_SKILLS_DIR/bug-report"
  run_install
  [ "$status" -eq 0 ]
  [ ! -L "$LEGACY_CODEX_SKILLS_DIR/bug-report" ]
}

@test "install: removes renamed-skill links owned by the repository" {
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$REPO_ROOT/write-a-prd" "$CLAUDE_SKILLS_DIR/write-a-prd"
  ln -s \
    "$REPO_ROOT/skills/engineering/domain-model" \
    "$CLAUDE_SKILLS_DIR/domain-model"
  run_install
  [ "$status" -eq 0 ]
  [ ! -L "$CLAUDE_SKILLS_DIR/write-a-prd" ]
  [ ! -L "$CLAUDE_SKILLS_DIR/domain-model" ]
}

@test "install: configures the repository as a Hermes external directory" {
  run_install
  [ "$status" -eq 0 ]
  grep -Fq "'$REPO_ROOT/skills'" "$HERMES_CONFIG_FILE"
  grep -Fq "managed by sidwood/skills installer" "$HERMES_CONFIG_FILE"
  [ ! -e "$HERMES_HOME/skills/bug-report" ]
}

@test "install: merges Hermes configuration without replacing existing values" {
  mkdir -p "$HERMES_HOME"
  printf 'model: test\nskills:\n  write_approval: true\n  external_dirs:\n    - /existing/skills\n' > "$HERMES_CONFIG_FILE"
  run_install
  [ "$status" -eq 0 ]
  grep -Fq 'model: test' "$HERMES_CONFIG_FILE"
  grep -Fq '    - /existing/skills' "$HERMES_CONFIG_FILE"
  grep -Fq "'$REPO_ROOT/skills'" "$HERMES_CONFIG_FILE"
}

@test "install: does not rewrite a scalar Hermes external_dirs setting" {
  mkdir -p "$HERMES_HOME"
  printf 'skills:\n  external_dirs: /existing/skills\n' > "$HERMES_CONFIG_FILE"
  run_install
  [ "$status" -eq 0 ]
  [ "$(cat "$HERMES_CONFIG_FILE")" = $'skills:\n  external_dirs: /existing/skills' ]
  [[ "$output" == *"not a YAML list"* ]]
}
