#!/usr/bin/env bash
# Tests scripts/ci/difftest-baseline.sh without network: `gh` is a stub that serves the
# base commit's run and its `difftest-reports` artifact from scratch. A real base must
# yield a baseline, and every way of not getting one, except the documented bootstrap
# cases, must fail.
set -euo pipefail
script=$(cd "$(dirname "$0")" && pwd)/difftest-baseline.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
log=$tmp/gh.log
: >"$log"

# A fake `gh`: MODE selects what the API and the artifact download do. The real script
# asks for `-q`-filtered ids, so the stub only has to print them.
stub=$tmp/bin
mkdir -p "$stub"
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_GH_LOG"
case "$1" in
  api)
    url=
    for a in "$@"; do
      case "$a" in
        repos/*/actions/workflows/* | repos/*/actions/runs/*) url=$a ;;
      esac
    done
    case "$url" in
      *workflows*)
        [ "$MODE" = no-run ] && exit 0
        echo 4242
        ;;
      *artifacts*)
        [ "$MODE" = no-artifact ] && exit 0
        echo 99
        ;;
      *) exit 1 ;;
    esac
    ;;
  run)
    dir= prev=
    for a in "$@"; do
      [ "$prev" = -D ] && dir=$a
      prev=$a
    done
    [ "$MODE" = download-fails ] && exit 1
    [ -n "$dir" ] || exit 1
    mkdir -p "$dir"
    [ "$MODE" = empty ] && exit 0
    printf '{"unit":"a.b","cases":[]}\n' >"$dir/a.b.json"
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$stub/gh"

zero=0000000000000000000000000000000000000000
with_reports=1111111111111111111111111111111111111111
no_run=2222222222222222222222222222222222222222
malformed='main'

# expect <name> <exit status: 0|nonzero> <stdout: baseline|empty> <event> <base> [mode]
expect() {
  local name=$1 want=$2 out=$3 event=$4 base=$5 mode=${6:-ok} status=0 got
  : >"$log"
  got=$(PATH="$stub:$PATH" GITHUB_REPOSITORY=o/r MODE="$mode" FAKE_GH_LOG="$log" \
    "$script" "$event" "$base" "$tmp/out" 2>"$tmp/err") || status=$?
  local ok=1
  if [ "$want" = 0 ] && [ "$status" -ne 0 ]; then ok=0; fi
  if [ "$want" = nonzero ] && [ "$status" -eq 0 ]; then ok=0; fi
  if [ "$out" = baseline ]; then
    [ "$got" = "--baseline $tmp/out" ] || ok=0
    [ -f "$tmp/out/a.b.json" ] || ok=0
    grep -q "head_sha=$base" "$log" || ok=0
  fi
  if [ "$out" = empty ] && [ -n "$got" ]; then ok=0; fi
  if [ "$ok" = 1 ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: status=$status stdout='$got' stderr='$(cat "$tmp/err")'"
    fails=$((fails + 1))
  fi
}

# A baseline run replaces the directory's previous contents.
rm -rf "$tmp/out" && mkdir -p "$tmp/out" && echo stale >"$tmp/out/stale.json"

expect "pull request with a base artifact"         0       baseline pull_request "$with_reports"
if [ -e "$tmp/out/stale.json" ]; then
  echo "FAIL stale report left in the baseline directory"
  fails=$((fails + 1))
else
  echo "ok   stale report removed from the baseline directory"
fi
expect "push with a base artifact"                 0       baseline push "$with_reports"
expect "merge queue entry with a base artifact"    0       baseline merge_group "$with_reports"

expect "pull request, no run for the base"         nonzero empty    pull_request "$no_run" no-run
expect "push, no run for the base"                 nonzero empty    push "$no_run" no-run
expect "pull request, run without an artifact"     nonzero empty    pull_request "$with_reports" no-artifact
expect "pull request, artifact download fails"     nonzero empty    pull_request "$with_reports" download-fails
expect "pull request, empty artifact"              nonzero empty    pull_request "$with_reports" empty

expect "pull request without a base"               nonzero empty    pull_request ""
expect "pull request with an all-zero base"        nonzero empty    pull_request "$zero"
expect "push creating a branch (bootstrap)"        0       empty    push "$zero"
expect "manual run (bootstrap)"                    0       empty    workflow_dispatch ""
expect "unknown event without a base"              nonzero empty    schedule ""
expect "malformed base SHA"                        nonzero empty    pull_request "$malformed"

# The bootstrap paths must not call the API at all.
if [ -s "$log" ]; then
  echo "FAIL bootstrap run called gh: $(cat "$log")"
  fails=$((fails + 1))
else
  echo "ok   bootstrap runs do not call gh"
fi

if [ "$fails" -gt 0 ]; then
  echo "test-difftest-baseline: $fails failure(s)"
  exit 1
fi
echo "test-difftest-baseline: all passed"
