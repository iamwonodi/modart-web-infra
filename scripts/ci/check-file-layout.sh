#!/usr/bin/env bash

set -euo pipefail

# ==============================================================================
# CHECK FILE LAYOUT
#
# The repository's layout rules, each a failure when broken:
#   - a top-level locals block lives only in locals.tf;
#   - a top-level data block lives only in data.tf;
#   - a workflow runs on a pinned runner image, never ubuntu-latest (which
#     moves to a new Ubuntu on GitHub's schedule, in the middle of anything).
#
# Usage: check-file-layout.sh [repository-root]   (default: the current directory)
# ==============================================================================

ROOT="${1:-.}"
failed=0

while IFS= read -r file; do
  base="$(basename "${file}")"
  if [[ "${base}" != "locals.tf" ]] && grep -qE '^locals[[:space:]]*\{' "${file}"; then
    echo "FAIL ${file#"${ROOT}"/}: a locals block outside locals.tf"
    failed=1
  fi
  if [[ "${base}" != "data.tf" ]] && grep -qE '^data[[:space:]]+"' "${file}"; then
    echo "FAIL ${file#"${ROOT}"/}: a data block outside data.tf"
    failed=1
  fi
done < <(find "${ROOT}" -name '*.tf' -not -path '*/.terraform/*' -not -path '*/.git/*' | sort)

if [[ -d "${ROOT}/.github/workflows" ]]; then
  while IFS= read -r hit; do
    echo "FAIL ${hit#"${ROOT}"/}: runs on ubuntu-latest; pin the image (ubuntu-24.04)"
    failed=1
  done < <(grep -rn 'ubuntu-latest' "${ROOT}/.github/workflows" || true)
fi

if [[ "${failed}" -eq 0 ]]; then
  echo "ok   locals only in locals.tf, data only in data.tf, every workflow on a pinned runner"
fi
exit "${failed}"
