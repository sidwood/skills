# Shared helpers for install/uninstall bats tests.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export AGENTS_SKILLS_DIR="$SANDBOX/agents/skills"
  export CLAUDE_HOME="$SANDBOX/claude"
  export CLAUDE_SKILLS_DIR="$CLAUDE_HOME/skills"
  export GROK_HOME="$SANDBOX/grok"
  export GROK_SKILLS_DIR="$GROK_HOME/skills"
  export LEGACY_CODEX_SKILLS_DIR="$SANDBOX/codex/skills"
  export HERMES_HOME="$SANDBOX/hermes"
  export HERMES_CONFIG_FILE="$HERMES_HOME/config.yaml"
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

run_install() {
  run bash "$REPO_ROOT/install.sh"
}

run_uninstall() {
  run bash "$REPO_ROOT/uninstall.sh"
}

assert_symlink_to() {
  local link="$1"
  local target="$2"

  [ -L "$link" ] || {
    echo "expected symlink at: $link" >&2
    return 1
  }

  [ "$(readlink "$link")" = "$target" ] || {
    echo "symlink $link -> $(readlink "$link"), expected $target" >&2
    return 1
  }
}

assert_catalog_links() {
  local target_dir="$1"

  assert_symlink_to \
    "$target_dir/bug-report" \
    "$REPO_ROOT/skills/engineering/bug-report"
  assert_symlink_to \
    "$target_dir/to-prd" \
    "$REPO_ROOT/skills/product/to-prd"
  assert_symlink_to \
    "$target_dir/grilling" \
    "$REPO_ROOT/skills/workflow/grilling"
  assert_symlink_to \
    "$target_dir/to-skill" \
    "$REPO_ROOT/skills/authoring/to-skill"
  assert_symlink_to \
    "$target_dir/rpg-scenario-beats" \
    "$REPO_ROOT/skills/creative/rpg-scenario-beats"
}
