#!/usr/bin/env bash
# Downloads the difftest reports of the base commit into <out-dir> for the difftest
# ratchet and prints the argument to pass to difftest (`--baseline <dir>`) on stdout.
#
#   scripts/ci/difftest-baseline.sh <event> <base-sha> <out-dir>
#
# <event> is github.event_name; <base-sha> is the PR base, the merge-group base, or the
# previous head (push). Reports are CI artifacts, never committed: every push to main
# uploads its `difftest-reports` artifact, and the ratchet must use the exact base
# commit's run. A snapshot from another commit could hide a regression (a case that
# still passed later) or invent one (a case that had not been added yet).
#
# The ratchet may only be skipped where there is nothing to compare with: a push whose
# `before` is empty or all zeros (a new branch) or a manual run. Then it prints nothing
# and exits 0. Anything else must produce a baseline: a pull request without a base, a
# base with no push run or no unexpired artifact, a failed download or an empty artifact
# exits nonzero, so CI never silently runs --green without its baseline.
# Tested by scripts/ci/test-difftest-baseline.sh.
set -euo pipefail
if [ $# -ne 3 ]; then
  echo "usage: $0 <event> <base-sha> <out-dir>" >&2
  exit 2
fi
event=$1 base=$2 out=$3
zero=0000000000000000000000000000000000000000

if [ -z "$base" ] || [ "$base" = "$zero" ]; then
  case "$event" in
    push | workflow_dispatch)
      echo "difftest-baseline: $event without a base commit; the ratchet is skipped" >&2
      exit 0
      ;;
    *)
      echo "difftest-baseline: $event needs a base commit, got '$base'" >&2
      exit 1
      ;;
  esac
fi

# The SHA is interpolated into the API query below: accept only a full commit hash.
case "$base" in
  *[!0-9a-f]*)
    echo "difftest-baseline: base '$base' is not a lowercase hexadecimal commit SHA" >&2
    exit 1
    ;;
esac
if [ "${#base}" -ne 40 ]; then
  echo "difftest-baseline: base '$base' is not a full commit SHA" >&2
  exit 1
fi

repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}
if ! command -v gh >/dev/null; then
  echo "difftest-baseline: gh is not installed" >&2
  exit 1
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The push run of this repository's own ci.yml for the base commit (never a fork's run:
# a fork PR can name its branch "main", but its runs belong to the fork).
runs=$(gh api --paginate \
  "repos/$repo/actions/workflows/ci.yml/runs?head_sha=$base&event=push&per_page=100" \
  -q ".workflow_runs[]
      | select(.head_sha == \"$base\"
               and .event == \"push\"
               and .path == \".github/workflows/ci.yml\"
               and .head_branch == \"main\"
               and .repository.full_name == \"$repo\"
               and .head_repository.full_name == \"$repo\")
      | .id" 2>/dev/null || true)
if [ -z "$runs" ]; then
  echo "difftest-baseline: no push run of ci.yml on main for base commit $base" >&2
  exit 1
fi

for id in $runs; do
  art=$(gh api "repos/$repo/actions/runs/$id/artifacts?name=difftest-reports" \
          -q '.artifacts[] | select(.expired | not) | .id' 2>/dev/null | head -n 1 || true)
  if [ -z "$art" ]; then
    continue
  fi
  rm -rf "$tmp/run"
  if ! gh run download "$id" -R "$repo" -n difftest-reports -D "$tmp/run" >/dev/null 2>&1; then
    echo "difftest-baseline: cannot download difftest-reports from run $id" >&2
    exit 1
  fi
  n=$(find "$tmp/run" -maxdepth 1 -name '*.json' | wc -l | tr -d ' ')
  if [ "$n" -eq 0 ]; then
    echo "difftest-baseline: run $id's difftest-reports artifact has no reports" >&2
    exit 1
  fi
  rm -rf "$out"
  mkdir -p "$out"
  find "$tmp/run" -maxdepth 1 -name '*.json' -exec cp {} "$out/" \;
  echo "difftest-baseline: $n reports from $base (run $id)" >&2
  echo "--baseline $out"
  exit 0
done

echo "difftest-baseline: no unexpired difftest-reports artifact for base commit $base" >&2
exit 1
