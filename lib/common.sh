# shellcheck shell=bash
# Shared configuration and helpers for install.sh and uninstall.sh.
# Source this file; do not execute it directly.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LIB_DIR/.." && pwd)"
SKILLS_ROOT="${SKILLS_ROOT:-$REPO_DIR/skills}"

# Most supported agents share the Agent Skills standard location. Claude and
# Grok use their own global directories.
AGENTS_SKILLS_DIR="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
CLAUDE_SKILLS_DIR="${CLAUDE_SKILLS_DIR:-$CLAUDE_HOME/skills}"
GROK_HOME="${GROK_HOME:-$HOME/.grok}"
GROK_SKILLS_DIR="${GROK_SKILLS_DIR:-$GROK_HOME/skills}"

# Codex previously used this location. It is cleanup-only now that Codex uses
# the shared Agent Skills directory.
LEGACY_CODEX_SKILLS_DIR="${LEGACY_CODEX_SKILLS_DIR:-$HOME/.codex/skills}"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_CONFIG_FILE="${HERMES_CONFIG_FILE:-$HERMES_HOME/config.yaml}"
HERMES_EXTERNAL_SKILLS_DIR="$SKILLS_ROOT"
HERMES_MARKER="managed by sidwood/skills installer"

SKILLS_TARGET_DIRS=(
  "$AGENTS_SKILLS_DIR"
  "$CLAUDE_SKILLS_DIR"
  "$GROK_SKILLS_DIR"
)

# Skills that were renamed or removed; their stale links should be cleaned up.
LEGACY_SKILLS=(
  write-a-prd
  prd-to-issues
  write-a-skill
  grill-me
  caveman
  domain-model
  design-an-interface
)

# Print one frontmatter value without parsing body content.
frontmatter_value() {
  local key="$1"
  local skill_file="$2"

  awk -v key="$key" '
    NR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter && $0 == "---" { exit }
    in_frontmatter && index($0, key ":") == 1 {
      sub("^" key ":[[:space:]]*", "")
      print
      exit
    }
  ' "$skill_file"
}

# Print canonical skill directories in a stable order. The repository taxonomy
# is two levels deep: skills/<category>/<skill>/SKILL.md.
catalog_skill_dirs() {
  find "$SKILLS_ROOT" -mindepth 3 -maxdepth 3 -type f -name SKILL.md -print \
    | LC_ALL=C sort \
    | while IFS= read -r skill_file; do
      dirname "$skill_file"
    done
}

# Fail early when catalog structure, metadata, references, or invocation policy
# would make a skill ambiguous or behave differently between harnesses.
validate_skill_catalog() {
  local all_skill_files
  local category
  local description
  local duplicates
  local empty_optional_dirs
  local explicit_frontmatter
  local explicit_openai
  local frontmatter_name
  local license_file
  local license_path
  local openai_file
  local reference_link
  local reference_links
  local relative_path
  local remainder
  local singular_reference_dirs
  local skill_dir
  local skill_file
  local skill_name
  local skill_names
  local skill_parent_dir
  local top_level_dir

  if [ ! -d "$SKILLS_ROOT" ]; then
    echo "Error: skill catalog not found at '$SKILLS_ROOT'." >&2
    return 1
  fi

  while IFS= read -r top_level_dir; do
    category="$(basename "$top_level_dir")"
    case "$category" in
      product | engineering | workflow | authoring | creative) ;;
      *)
        echo "Error: unknown skill category '$category'." >&2
        return 1
        ;;
    esac
  done < <(find "$SKILLS_ROOT" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort)

  while IFS= read -r skill_parent_dir; do
    if [ ! -f "$skill_parent_dir/SKILL.md" ]; then
      echo "Error: skill directory '$skill_parent_dir' has no SKILL.md." >&2
      return 1
    fi
  done < <(find "$SKILLS_ROOT" -mindepth 2 -maxdepth 2 -type d -print | LC_ALL=C sort)

  singular_reference_dirs="$(find "$SKILLS_ROOT" -type d -name reference -print | LC_ALL=C sort)"
  if [ -n "$singular_reference_dirs" ]; then
    echo "Error: use 'references/' rather than 'reference/':" >&2
    printf '%s\n' "$singular_reference_dirs" >&2
    return 1
  fi

  empty_optional_dirs="$(find "$SKILLS_ROOT" -type d \
    \( -name agents -o -name assets -o -name references -o -name scripts \) \
    -empty -print | LC_ALL=C sort)"
  if [ -n "$empty_optional_dirs" ]; then
    echo "Error: remove empty optional skill directories:" >&2
    printf '%s\n' "$empty_optional_dirs" >&2
    return 1
  fi

  all_skill_files="$(find "$SKILLS_ROOT" -type f -name SKILL.md -print | LC_ALL=C sort)"
  if [ -z "$all_skill_files" ]; then
    echo "Error: no skills found under '$SKILLS_ROOT'." >&2
    return 1
  fi

  skill_names=""
  while IFS= read -r skill_file; do
      relative_path="${skill_file#"$SKILLS_ROOT"/}"
      category="${relative_path%%/*}"
      remainder="${relative_path#*/}"
      skill_name="${remainder%%/*}"

      if [ "$remainder" != "$skill_name/SKILL.md" ]; then
        echo "Error: '$skill_file' must be at skills/<category>/<skill>/SKILL.md." >&2
        return 1
      fi

      case "$category" in
        product | engineering | workflow | authoring | creative) ;;
        *)
          echo "Error: '$skill_file' uses unknown category '$category'." >&2
          return 1
          ;;
      esac

      if [[ ! "$skill_name" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ "${#skill_name}" -gt 64 ]; then
        echo "Error: invalid skill folder name '$skill_name'." >&2
        return 1
      fi

      skill_dir="$(dirname "$skill_file")"
      skill_name="$(basename "$skill_dir")"
      if [ "$(sed -n '1p' "$skill_file")" != "---" ] || ! awk '
        NR > 1 && $0 == "---" { found = 1; exit }
        END { exit !found }
      ' "$skill_file"; then
        echo "Error: '$skill_file' has invalid YAML frontmatter delimiters." >&2
        return 1
      fi

      frontmatter_name="$(frontmatter_value name "$skill_file")"
      description="$(frontmatter_value description "$skill_file")"

      if [ "$frontmatter_name" != "$skill_name" ]; then
        echo "Error: '$skill_file' declares name '$frontmatter_name'; expected '$skill_name'." >&2
        return 1
      fi

      if [ -z "$description" ]; then
        echo "Error: '$skill_file' must declare a non-empty description." >&2
        return 1
      fi

      license_file="$(frontmatter_value license "$skill_file")"
      if [ -n "$license_file" ]; then
        license_file="${license_file%\"}"
        license_file="${license_file%\'}"
        license_file="${license_file#\"}"
        license_file="${license_file#\'}"
        license_path="$skill_dir/$license_file"
        if [ ! -f "$license_path" ]; then
          echo "Error: '$skill_file' refers to missing license '$license_file'." >&2
          return 1
        fi
      fi

      reference_links="$(awk '
        /^```/ { in_fence = !in_fence; next }
        !in_fence {
          while (match($0, /\]\(references\/[^)#[:space:]]+/)) {
            print substr($0, RSTART + 2, RLENGTH - 2)
            $0 = substr($0, RSTART + RLENGTH)
          }
        }
      ' "$skill_file")"
      while IFS= read -r reference_link; do
        [ -n "$reference_link" ] || continue
        if [ ! -f "$skill_dir/$reference_link" ]; then
          echo "Error: '$skill_file' refers to missing '$reference_link'." >&2
          return 1
        fi
      done <<< "$reference_links"

      explicit_frontmatter=false
      if [ "$(frontmatter_value disable-model-invocation "$skill_file")" = "true" ]; then
        explicit_frontmatter=true
      fi

      openai_file="$skill_dir/agents/openai.yaml"
      explicit_openai=false
      if [ -f "$openai_file" ] && grep -Eq \
        '^[[:space:]]+allow_implicit_invocation:[[:space:]]*false[[:space:]]*$' \
        "$openai_file"; then
        explicit_openai=true
      fi

      if [ "$explicit_frontmatter" != "$explicit_openai" ]; then
        echo "Error: '$skill_name' must encode explicit invocation in both SKILL.md and agents/openai.yaml." >&2
        return 1
      fi

      if [ -n "$skill_names" ]; then
        skill_names+=$'\n'
      fi
      skill_names+="$skill_name"
  done <<< "$all_skill_files"

  duplicates="$(printf '%s\n' "$skill_names" | LC_ALL=C sort | uniq -d)"
  if [ -n "$duplicates" ]; then
    echo "Error: duplicate skill names in the catalog:" >&2
    printf '%s\n' "$duplicates" >&2
    return 1
  fi
}

# Resolve a symlink target even when the final path no longer exists, provided
# its parent still does. All links created by this installer are absolute.
resolve_link_target() {
  local link_path="$1"
  local link_target
  local resolved_dir

  link_target="$(readlink "$link_path")"
  case "$link_target" in
    /*)
      printf '%s\n' "$link_target"
      ;;
    *)
      if ! resolved_dir="$(cd "$(dirname "$link_path")" && cd "$(dirname "$link_target")" 2>/dev/null && pwd -P)"; then
        return 1
      fi
      printf '%s/%s\n' "$resolved_dir" "$(basename "$link_target")"
      ;;
  esac
}

link_points_to() {
  local link_path="$1"
  local expected_target="$2"
  local resolved_target

  [ -L "$link_path" ] || return 1
  resolved_target="$(resolve_link_target "$link_path")" || return 1
  [ "$resolved_target" = "$expected_target" ]
}

remove_link_if_target() {
  local link_path="$1"
  shift
  local expected_target

  [ -L "$link_path" ] || return 0

  for expected_target in "$@"; do
    if link_points_to "$link_path" "$expected_target"; then
      rm "$link_path"
      return 0
    fi
  done

  return 0
}

install_skill_link() {
  local source_dir="$1"
  local target_dir="$2"
  local skill_name
  local link_path

  skill_name="$(basename "$source_dir")"
  link_path="$target_dir/$skill_name"

  if [ -L "$link_path" ]; then
    if link_points_to "$link_path" "$source_dir"; then
      return 0
    fi

    # Replace links made by the old flat-layout installer after the source
    # folder has moved into the taxonomy.
    if link_points_to "$link_path" "$REPO_DIR/$skill_name"; then
      rm "$link_path"
    else
      echo "Warning: '$link_path' is already a foreign symlink; leaving it untouched." >&2
      return 0
    fi
  elif [ -e "$link_path" ]; then
    echo "Warning: '$link_path' already exists; leaving it untouched." >&2
    return 0
  fi

  ln -s "$source_dir" "$link_path"
}

install_skill_links() {
  local source_dir
  local target_dir

  for target_dir in "${SKILLS_TARGET_DIRS[@]}"; do
    mkdir -p "$target_dir"
    while IFS= read -r source_dir; do
      install_skill_link "$source_dir" "$target_dir"
    done < <(catalog_skill_dirs)
  done
}

remove_catalog_links_from_target() {
  local source_dir
  local skill_name
  local target_dir="$1"

  while IFS= read -r source_dir; do
    skill_name="$(basename "$source_dir")"
    remove_link_if_target \
      "$target_dir/$skill_name" \
      "$source_dir" \
      "$REPO_DIR/$skill_name"
  done < <(catalog_skill_dirs)
}

remove_legacy_links() {
  local legacy_skill
  local target_dir

  for target_dir in "${SKILLS_TARGET_DIRS[@]}" "$LEGACY_CODEX_SKILLS_DIR"; do
    for legacy_skill in "${LEGACY_SKILLS[@]}"; do
      remove_link_if_target \
        "$target_dir/$legacy_skill" \
        "$REPO_DIR/$legacy_skill" \
        "$SKILLS_ROOT/product/$legacy_skill" \
        "$SKILLS_ROOT/engineering/$legacy_skill" \
        "$SKILLS_ROOT/workflow/$legacy_skill" \
        "$SKILLS_ROOT/authoring/$legacy_skill" \
        "$SKILLS_ROOT/creative/$legacy_skill"
    done

    if [ -d "$REPO_DIR/.claude" ]; then
      remove_link_if_target "$target_dir/.claude" "$(cd "$REPO_DIR/.claude" && pwd -P)"
    fi
  done

  # Codex no longer reads this repository from ~/.codex/skills. Remove only
  # links owned by this repository and leave every other entry untouched.
  remove_catalog_links_from_target "$LEGACY_CODEX_SKILLS_DIR"
}

# Hermes owns ~/.hermes/skills, so expose this repository as an external skill
# directory instead of placing links among Hermes-managed skills.
configure_hermes() {
  local config_dir
  local escaped_path
  local external_line
  local managed_entry
  local skills_line
  local temp_file

  config_dir="$(dirname "$HERMES_CONFIG_FILE")"
  mkdir -p "$config_dir"
  escaped_path="$(printf '%s' "$HERMES_EXTERNAL_SKILLS_DIR" | sed "s/'/''/g")"
  managed_entry="    - '$escaped_path' # $HERMES_MARKER"

  if [ ! -e "$HERMES_CONFIG_FILE" ]; then
    printf 'skills:\n  external_dirs:\n%s\n' "$managed_entry" > "$HERMES_CONFIG_FILE"
    return 0
  fi

  if grep -Fq "$managed_entry" "$HERMES_CONFIG_FILE"; then
    return 0
  fi

  skills_line="$(awk '/^skills:[[:space:]]*(#.*)?$/ { print NR; exit }' "$HERMES_CONFIG_FILE")"
  if [ -z "$skills_line" ]; then
    printf '\nskills:\n  external_dirs:\n%s\n' "$managed_entry" >> "$HERMES_CONFIG_FILE"
    return 0
  fi

  external_line="$(awk '
    /^skills:[[:space:]]*(#.*)?$/ { in_skills = 1; next }
    in_skills && /^[^[:space:]#]/ { exit }
    in_skills && /^  external_dirs:/ { print NR; exit }
  ' "$HERMES_CONFIG_FILE")"

  temp_file="$(mktemp "${TMPDIR:-/tmp}/skills-hermes-config.XXXXXX")"
  if [ -z "$external_line" ]; then
    awk -v insert_after="$skills_line" -v entry="$managed_entry" '
      { print }
      NR == insert_after { print "  external_dirs:"; print entry }
    ' "$HERMES_CONFIG_FILE" > "$temp_file"
  elif sed -n "${external_line}p" "$HERMES_CONFIG_FILE" | grep -Eq '^  external_dirs:[[:space:]]*(#.*)?$'; then
    awk -v insert_after="$external_line" -v entry="$managed_entry" '
      { print }
      NR == insert_after { print entry }
    ' "$HERMES_CONFIG_FILE" > "$temp_file"
  else
    rm "$temp_file"
    echo "Warning: Hermes skills.external_dirs is not a YAML list; add '$HERMES_EXTERNAL_SKILLS_DIR' manually." >&2
    return 0
  fi

  mv "$temp_file" "$HERMES_CONFIG_FILE"
}

unconfigure_hermes() {
  local temp_file

  [ -f "$HERMES_CONFIG_FILE" ] || return 0
  grep -Fq "$HERMES_MARKER" "$HERMES_CONFIG_FILE" || return 0

  temp_file="$(mktemp "${TMPDIR:-/tmp}/skills-hermes-config.XXXXXX")"
  awk -v marker="$HERMES_MARKER" 'index($0, marker) == 0 { print }' \
    "$HERMES_CONFIG_FILE" > "$temp_file"
  mv "$temp_file" "$HERMES_CONFIG_FILE"
}

remove_empty_skill_directories() {
  local target_dir

  for target_dir in "${SKILLS_TARGET_DIRS[@]}" "$LEGACY_CODEX_SKILLS_DIR"; do
    if [ -d "$target_dir" ] && [ -z "$(ls -A "$target_dir")" ]; then
      rmdir "$target_dir"
    fi
  done
}
