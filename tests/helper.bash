# Shared helpers for install/uninstall bats tests.

# Absolute path to the repository root (parent of the tests directory).
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Create an isolated fake HOME with separate Claude and Codex trees, and export
# the environment variables the scripts honour so nothing touches the real HOME.
setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export HOME="$SANDBOX/home"
  export CLAUDE_HOME="$SANDBOX/claude"
  export CLAUDE_SKILLS_DIR="$CLAUDE_HOME/skills"
  export CODEX_HOME="$SANDBOX/codex"
  export CODEX_SKILLS_DIR="$CODEX_HOME/skills"
  mkdir -p "$HOME"
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

# Build a PATH directory that contains the given commands but deliberately
# excludes "stow", so we can exercise the "stow missing" error branch while the
# scripts can still resolve dirname/basename/etc.
make_stowless_path() {
  local bindir="$SANDBOX/nostow-bin"
  mkdir -p "$bindir"
  local cmd src
  for cmd in bash dirname basename readlink mkdir rm ln cd pwd rmdir cat env; do
    src="$(command -v "$cmd" 2>/dev/null || true)"
    [ -n "$src" ] && ln -sf "$src" "$bindir/$cmd"
  done
  echo "$bindir"
}

# Assert that $link is a symlink whose resolved target equals $target.
assert_symlink_to() {
  local link="$1" target="$2"
  [ -L "$link" ] || {
    echo "expected symlink at: $link" >&2
    return 1
  }
  local resolved
  resolved="$(cd "$(dirname "$link")" && readlink -f "$link")"
  [ "$resolved" = "$target" ] || {
    echo "symlink $link -> $resolved, expected $target" >&2
    return 1
  }
}
