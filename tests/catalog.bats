#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox
  CATALOG_ROOT="$SANDBOX/catalog"
  mkdir -p "$CATALOG_ROOT/engineering"
}

teardown() {
  teardown_sandbox
}

make_skill() {
  local skill_name="$1"
  local invocation="${2:-implicit}"
  local skill_dir="$CATALOG_ROOT/engineering/$skill_name"

  mkdir -p "$skill_dir"
  if [ "$invocation" = explicit ]; then
    printf '%s\n' \
      '---' \
      "name: $skill_name" \
      'description: Use when testing the skill catalog.' \
      'disable-model-invocation: true' \
      '---' \
      '' \
      '# Test skill' > "$skill_dir/SKILL.md"
  else
    printf '%s\n' \
      '---' \
      "name: $skill_name" \
      'description: Use when testing the skill catalog.' \
      '---' \
      '' \
      '# Test skill' > "$skill_dir/SKILL.md"
  fi
}

run_catalog_validation() {
  # $1 expands inside the child Bash process.
  # shellcheck disable=SC2016
  run env SKILLS_ROOT="$CATALOG_ROOT" bash -c \
    'source "$1/lib/common.sh" && validate_skill_catalog' _ "$REPO_ROOT"
}

@test "catalog: accepts valid skills and plural references" {
  make_skill test-skill
  mkdir -p "$CATALOG_ROOT/engineering/test-skill/agents"
  printf 'policy:\n  allow_implicit_invocation: true\n' > \
    "$CATALOG_ROOT/engineering/test-skill/agents/openai.yaml"
  mkdir -p "$CATALOG_ROOT/engineering/test-skill/references"
  printf '# Details\n' > \
    "$CATALOG_ROOT/engineering/test-skill/references/details.md"
  printf '\nFor details, see [details](references/details.md).\n' >> \
    "$CATALOG_ROOT/engineering/test-skill/SKILL.md"

  run_catalog_validation

  [ "$status" -eq 0 ]
}

@test "catalog: rejects singular reference directories" {
  make_skill test-skill
  mkdir -p "$CATALOG_ROOT/engineering/test-skill/reference"
  printf '# Details\n' > \
    "$CATALOG_ROOT/engineering/test-skill/reference/details.md"

  run_catalog_validation

  [ "$status" -ne 0 ]
  [[ "$output" == *"use 'references/' rather than 'reference/'"* ]]
}

@test "catalog: rejects missing reference targets" {
  make_skill test-skill
  printf '\nSee [missing](references/missing.md).\n' >> \
    "$CATALOG_ROOT/engineering/test-skill/SKILL.md"

  run_catalog_validation

  [ "$status" -ne 0 ]
  [[ "$output" == *"refers to missing 'references/missing.md'"* ]]
}

@test "catalog: requires matching explicit-invocation metadata" {
  make_skill test-skill explicit

  run_catalog_validation

  [ "$status" -ne 0 ]
  [[ "$output" == *"must encode explicit invocation in both"* ]]
}

@test "catalog: accepts matching explicit-invocation metadata" {
  make_skill test-skill explicit
  mkdir -p "$CATALOG_ROOT/engineering/test-skill/agents"
  printf 'policy:\n  allow_implicit_invocation: false\n' > \
    "$CATALOG_ROOT/engineering/test-skill/agents/openai.yaml"

  run_catalog_validation

  [ "$status" -eq 0 ]
}

@test "catalog: rejects empty optional directories" {
  make_skill test-skill
  mkdir -p "$CATALOG_ROOT/engineering/test-skill/assets"

  run_catalog_validation

  [ "$status" -ne 0 ]
  [[ "$output" == *"remove empty optional skill directories"* ]]
}
