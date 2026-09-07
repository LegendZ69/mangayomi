#!/usr/bin/env bash
# Run with the workflow's pinned Dart SDK. Never leave formatted source behind:
# subsequent analysis, tests, and builds must use the checked-out commit.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.."
repo_root="$(git rev-parse --show-toplevel)"
cd -- "$repo_root"

scope=(
  lib/modules/translation
  lib/services/translation
  test/services/translation_settings_test.dart
  test/services/vertex_translation_client_test.dart
  test/services/translation_queue_test.dart
  test/modules/translation_screen_test.dart
  lib/modules/manga/reader/widgets/image_actions_dialog.dart
  lib/modules/more/settings/settings_screen.dart
  lib/router/router.dart
)

# Restoration to HEAD is safe only when both the index and working tree are
# pristine in this scope. Refuse untracked files here as well, rather than
# silently omitting a new translation source from the format check.
scope_status="$(git status --porcelain=v1 --untracked-files=all -- "${scope[@]}")"
if [[ -n "$scope_status" ]]; then
  printf '%s\n' 'Translation format check requires a pristine source scope.' >&2
  printf '%s\n' "$scope_status" >&2
  exit 2
fi

files=()
while IFS= read -r -d '' path; do
  if [[ "$path" == *.dart ]]; then
    files+=("$path")
  fi
done < <(git ls-files -z -- "${scope[@]}")

if [[ ${#files[@]} -eq 0 ]]; then
  printf '%s\n' 'No tracked translation Dart files were found.' >&2
  exit 2
fi

restore_required=0
restore_source() {
  local exit_status=$?
  trap - EXIT
  if [[ "$restore_required" -eq 1 ]] &&
    ! git restore --source=HEAD --worktree -- "${files[@]}"; then
    printf '%s\n' 'ERROR: Could not restore source after generating the format patch.' >&2
    exit_status=74
  elif ! git diff --quiet --no-ext-diff --no-textconv HEAD -- "${files[@]}"; then
    printf '%s\n' 'ERROR: Source differs from the checked-out commit after the format check.' >&2
    exit_status=74
  else
    # Downstream cloud steps must require this output. A restoration failure
    # must never let analysis/tests/builds use uncommitted formatted source.
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
      if ! printf '%s\n' 'source_pristine=true' >> "$GITHUB_OUTPUT"; then
        printf '%s\n' 'ERROR: Could not report that checked-out source is pristine.' >&2
        exit_status=74
      fi
    fi
    if [[ "$restore_required" -eq 1 ]]; then
      printf '%s\n' 'Restored checked-out source before analysis, tests, and builds.'
    fi
  fi
  exit "$exit_status"
}
trap restore_source EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p artifacts/logs
log_path="$repo_root/artifacts/logs/translation-format.log"
patch_path="$repo_root/artifacts/translation-format.patch"
: > "$patch_path"

# Capture the formatter's own status separately from tee. A syntax/SDK error
# must remain a failure, even when its output was successfully saved.
set +e
dart format --output=none --set-exit-if-changed "${files[@]}" 2>&1 | tee "$log_path"
dry_status=("${PIPESTATUS[@]}")
set -e

if [[ ${dry_status[0]} -ne 0 && ${dry_status[0]} -ne 1 ]]; then
  exit "${dry_status[0]}"
fi
if [[ ${dry_status[1]} -ne 0 ]]; then
  exit "${dry_status[1]}"
fi
if [[ ${dry_status[0]} -eq 0 ]]; then
  exit 0
fi

# Format in the real package so Dart uses its SDK constraint, analysis options,
# and package configuration. The EXIT trap restores only these pristine files,
# including when formatting, diff generation, or log writing fails.
restore_required=1
set +e
dart format --output=write "${files[@]}" 2>&1 | tee -a "$log_path"
write_status=("${PIPESTATUS[@]}")
set -e

if [[ ${write_status[0]} -ne 0 ]]; then
  exit "${write_status[0]}"
fi
if [[ ${write_status[1]} -ne 0 ]]; then
  exit "${write_status[1]}"
fi

git diff --binary --no-ext-diff --no-textconv -- "${files[@]}" > "$patch_path"
printf '%s\n' "Formatting required; patch saved to $patch_path."
exit 1
