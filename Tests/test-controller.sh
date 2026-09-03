#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/mac-ci-burst-test.XXXXXX")"
trap '/bin/rm -rf "$test_root"' EXIT

mkdir -p "$test_root/bin" "$test_root/home/Library/Application Support/MacCIBurst" \
  "$test_root/home/Library/LaunchAgents" "$test_root/runner"
export MOCK_STATE="$test_root/github.json"
export MOCK_SERVICE="$test_root/service-loaded"
export MOCK_CAFFEINATE="$test_root/caffeinate-loaded"
export MOCK_FREE_KIB=209715200

print -r -- '{"runners":[{"id":42,"name":"Test-Mac","os":"macOS","status":"offline","busy":false,"labels":[{"name":"self-hosted"},{"name":"macOS"}]}]}' > "$MOCK_STATE"

cat > "$test_root/bin/gh" <<'MOCK_GH'
#!/bin/zsh
set -euo pipefail
method=GET
path=""
while (( $# )); do
  case "$1" in
    --method|-X) method="$2"; shift 2 ;;
    --input) shift 2 ;;
    --paginate|api) shift ;;
    /*) path="$1"; shift ;;
    *) shift ;;
  esac
done
case "$path" in
  /orgs/test-owner/actions/runners|/repos/test-owner/test-repo/actions/runners) /bin/cat "$MOCK_STATE" ;;
  /orgs/test-owner/actions/runners/42/labels|/repos/test-owner/test-repo/actions/runners/42/labels)
    [[ "$method" == POST ]]
    label="$(/bin/cat | /usr/bin/jq -r '.labels[0]')"
    /usr/bin/jq --arg label "$label" '.runners[0].labels += [{name:$label}]' "$MOCK_STATE" > "$MOCK_STATE.tmp"
    /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    /bin/cat "$MOCK_STATE"
    ;;
  /orgs/test-owner/actions/runners/42/labels/*|/repos/test-owner/test-repo/actions/runners/42/labels/*)
    [[ "$method" == DELETE ]]
    label="${path##*/}"
    /usr/bin/jq --arg label "$label" '.runners[0].labels |= map(select(.name != $label))' "$MOCK_STATE" > "$MOCK_STATE.tmp"
    /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    /bin/cat "$MOCK_STATE"
    ;;
  *) print -u2 "unexpected mock gh path: $path"; exit 2 ;;
esac
MOCK_GH

cat > "$test_root/bin/df" <<'MOCK_DF'
#!/bin/zsh
print 'Filesystem 1024-blocks Used Available Capacity Mounted'
print "mock 500000000 100000000 $MOCK_FREE_KIB 33% /System/Volumes/Data"
MOCK_DF

cat > "$test_root/bin/launchctl" <<'MOCK_LAUNCHCTL'
#!/bin/zsh
set -euo pipefail
case "$1" in
  print) [[ "$2" == *dev.mac-ci-burst.caffeinate ]] && [[ -f "$MOCK_CAFFEINATE" ]] || [[ -f "$MOCK_SERVICE" ]] ;;
  bootstrap) /usr/bin/touch "$MOCK_CAFFEINATE" ;;
  bootout) /bin/rm -f "$MOCK_CAFFEINATE" ;;
  *) exit 2 ;;
esac
MOCK_LAUNCHCTL

cat > "$test_root/runner/svc.sh" <<'MOCK_SERVICE'
#!/bin/zsh
set -euo pipefail
case "$1" in
  start)
    /usr/bin/touch "$MOCK_SERVICE"
    /usr/bin/jq '.runners[0].status="online"' "$MOCK_STATE" > "$MOCK_STATE.tmp"
    /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    ;;
  stop)
    /bin/rm -f "$MOCK_SERVICE"
    /usr/bin/jq '.runners[0].status="offline" | .runners[0].busy=false' "$MOCK_STATE" > "$MOCK_STATE.tmp"
    /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
    ;;
  *) exit 2 ;;
esac
MOCK_SERVICE

chmod +x "$test_root/bin/gh" "$test_root/bin/df" "$test_root/bin/launchctl" "$test_root/runner/svc.sh"
print 'actions.runner.test.Test-Mac' > "$test_root/runner/.service"
print '<plist version="1.0"><dict/></plist>' > "$test_root/home/Library/LaunchAgents/dev.mac-ci-burst.caffeinate.plist"

app_support="$test_root/home/Library/Application Support/MacCIBurst"
cat > "$app_support/config.env" <<CONFIG
GITHUB_SCOPE_TYPE=org
GITHUB_OWNER=test-owner
RUNNER_NAME=Test-Mac
BURST_LABEL=burst
RUNNER_DIR="$test_root/runner"
MIN_FREE_GIB=100
MONITORED_REPOSITORIES=
CONFIG
print off > "$app_support/desired-state"

export HOME="$test_root/home"
export PATH="$test_root/bin:/usr/bin:/bin"
export MAC_CI_BURST_HOME="$app_support"
ctl="$project_root/Scripts/mac-ci-burst"

[[ "$("$ctl" status | /usr/bin/jq -r '.state')" == off ]]
"$ctl" available
[[ "$("$ctl" status | /usr/bin/jq -r '.state')" == available ]]
[[ -f "$MOCK_SERVICE" && -f "$MOCK_CAFFEINATE" ]]

/usr/bin/jq '.runners[0].busy=true' "$MOCK_STATE" > "$MOCK_STATE.tmp" && /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
"$ctl" drain
[[ "$(<"$app_support/desired-state")" == drain ]]
[[ -f "$MOCK_SERVICE" ]]
! /usr/bin/jq -e '.runners[0].labels | any(.name == "burst")' "$MOCK_STATE" >/dev/null

set +e
"$ctl" off >/dev/null 2>&1
off_rc=$?
set -e
[[ "$off_rc" == 75 ]]

/usr/bin/jq '.runners[0].busy=false' "$MOCK_STATE" > "$MOCK_STATE.tmp" && /bin/mv "$MOCK_STATE.tmp" "$MOCK_STATE"
"$ctl" reconcile
[[ "$(<"$app_support/desired-state")" == off ]]
[[ ! -f "$MOCK_SERVICE" && ! -f "$MOCK_CAFFEINATE" ]]

export MOCK_FREE_KIB=52428800
set +e
"$ctl" available >/dev/null 2>&1
disk_rc=$?
set -e
[[ "$disk_rc" == 75 ]]

cat > "$app_support/config.env" <<CONFIG
GITHUB_SCOPE_TYPE=repo
GITHUB_OWNER=test-owner
GITHUB_REPOSITORY=test-repo
RUNNER_NAME=Test-Mac
BURST_LABEL=burst
RUNNER_DIR="$test_root/runner"
MIN_FREE_GIB=100
CONFIG
[[ "$("$ctl" status | /usr/bin/jq -r '.settingsURL')" == "https://github.com/test-owner/test-repo/settings/actions/runners" ]]

print 'controller transition, disk-gate, and scope tests passed'

# ---------------------------------------------------------------------------
# Tiered disk guard
# ---------------------------------------------------------------------------

guard="$project_root/Scripts/pre-job-disk-guard.sh"
guard_root="$test_root/guard"
work_root="$guard_root/_work"
tool_root="$work_root/_tool/my-ci"
export CARGO_HOME="$test_root/cargohome"
export CARGO_LOG="$test_root/cargo.log"
export SWEEP_LOG="$test_root/cargo-sweep.log"
export CUSTOM_LOG="$test_root/custom-sweep.log"

mkdir -p "$CARGO_HOME/bin"
cat > "$CARGO_HOME/bin/cargo" <<'MOCK_CARGO'
#!/bin/zsh
print -r -- "$*" >> "$CARGO_LOG"
MOCK_CARGO
cat > "$CARGO_HOME/bin/cargo-sweep" <<'MOCK_SWEEP'
#!/bin/zsh
# cargo-sweep is driven through CARGO_TARGET_DIR; log the tree it would sweep.
print -r -- "${CARGO_TARGET_DIR:-none} $*" >> "$SWEEP_LOG"
MOCK_SWEEP
cat > "$test_root/bin/custom-sweep" <<'MOCK_CUSTOM'
#!/bin/zsh
print -r -- "$*" >> "$CUSTOM_LOG"
MOCK_CUSTOM
chmod +x "$CARGO_HOME/bin/cargo" "$CARGO_HOME/bin/cargo-sweep" "$test_root/bin/custom-sweep"

make_guard_tree() {
  /bin/rm -rf "$guard_root"
  mkdir -p "$tool_root/build" \
    "$work_root/proj/.ci-cache/cache-a" \
    "$work_root/proj/.ci-cache/cache-b" \
    "$work_root/_temp/job-77-target" \
    "$work_root/_temp/_runner_file_commands"

  local stamp run
  # Oldest to newest: 100 200 300 400 500.
  stamp=1
  for run in 100 200 300 400 500; do
    mkdir -p "$tool_root/artifacts/$run"
    /usr/bin/touch -t "0201010${stamp}00" "$tool_root/artifacts/$run"
    stamp=$(( stamp + 1 ))
  done
  # cache-b is the older per-workspace cache and must be handled first.
  /usr/bin/touch -t 202601010000 "$work_root/proj/.ci-cache/cache-b"
  /usr/bin/touch -t 202602010000 "$work_root/proj/.ci-cache/cache-a"
  : > "$CARGO_LOG"
  : > "$SWEEP_LOG"
  : > "$CUSTOM_LOG"
}

guard_env=(
  RUNNER_WORK="$work_root"
  MAC_CI_BURST_MIN_FREE_GIB=100
  MAC_CI_BURST_SOFT_FREE_GIB=200
  MAC_CI_BURST_ARTIFACT_DIR=_tool/my-ci/artifacts
  MAC_CI_BURST_ARTIFACT_KEEP=3
  MAC_CI_BURST_CACHE_DIRS='_tool/my-ci/build:*/.ci-cache/*:_temp/*-target'
)

artifact_dirs() {
  /usr/bin/find "$tool_root/artifacts" -mindepth 1 -maxdepth 1 -type d \
    -exec /usr/bin/basename {} \; | /usr/bin/sort | /usr/bin/tr '\n' ' '
}

# (1) Tier 0 keeps the newest three artifact directories and the current run.
make_guard_tree
MOCK_FREE_KIB=209715200 GITHUB_RUN_ID=100 env $guard_env "$guard" >/dev/null
[[ "$(artifact_dirs)" == "100 300 400 500 " ]] || {
  print -u2 "tier 0 retention wrong: $(artifact_dirs)"; exit 1
}

# (2) Above the soft threshold nothing beyond tier 0 runs.
[[ ! -s "$SWEEP_LOG" ]] || { print -u2 "tier 1 ran above the soft threshold"; exit 1 }
[[ ! -s "$CARGO_LOG" ]] || { print -u2 "tier 2 ran above the soft threshold"; exit 1 }

# (3) Sweep mode below SOFT sweeps every configured directory in order, never
#     cleans, and always exits 0.
make_guard_tree
MOCK_FREE_KIB=157286400 env $guard_env MAC_CI_BURST_GUARD_MODE=sweep "$guard" >/dev/null
[[ ! -s "$CARGO_LOG" ]] || { print -u2 "sweep mode invoked cargo clean"; exit 1 }
expected_sweep="$tool_root/build sweep --time 3
$work_root/proj/.ci-cache/cache-b sweep --time 3
$work_root/proj/.ci-cache/cache-a sweep --time 3
$work_root/_temp/job-77-target sweep --time 3"
[[ "$(/usr/bin/sed 's/ [^ ]*sweep-probe[^ ]*$//' "$SWEEP_LOG")" == "$expected_sweep" ]] || {
  print -u2 "sweep order wrong:"; print -u2 -r -- "$(<"$SWEEP_LOG")"; exit 1
}
# A directory outside the configured globs is never touched.
! /usr/bin/grep -qF -- "_runner_file_commands" "$SWEEP_LOG"

# (4) Admit mode below MIN cleans in the same order and denies when space never
#     returns.
make_guard_tree
set +e
MOCK_FREE_KIB=52428800 env $guard_env "$guard" >/dev/null 2>&1
guard_rc=$?
set -e
[[ "$guard_rc" == 75 ]] || { print -u2 "expected denial, got rc=$guard_rc"; exit 1 }
expected_clean="clean --target-dir $tool_root/build
clean --target-dir $work_root/proj/.ci-cache/cache-b
clean --target-dir $work_root/proj/.ci-cache/cache-a
clean --target-dir $work_root/_temp/job-77-target"
[[ "$(<"$CARGO_LOG")" == "$expected_clean" ]] || {
  print -u2 "clean order wrong:"; print -u2 -r -- "$(<"$CARGO_LOG")"; exit 1
}

# (5) Dry run removes nothing and never cleans.
make_guard_tree
set +e
MOCK_FREE_KIB=52428800 GITHUB_RUN_ID=100 env $guard_env \
  MAC_CI_BURST_DRY_RUN=1 "$guard" >/dev/null 2>&1
dry_rc=$?
set -e
[[ "$dry_rc" == 75 ]]
[[ "$(artifact_dirs)" == "100 200 300 400 500 " ]] || {
  print -u2 "dry run removed artifacts: $(artifact_dirs)"; exit 1
}
[[ ! -s "$CARGO_LOG" ]] || { print -u2 "dry run invoked cargo clean"; exit 1 }

# (6) A custom SWEEP_CMD template replaces cargo-sweep and receives {dir}/{days}.
make_guard_tree
MOCK_FREE_KIB=157286400 env $guard_env MAC_CI_BURST_GUARD_MODE=sweep \
  MAC_CI_BURST_SWEEP_CMD='custom-sweep {dir} {days}' \
  MAC_CI_BURST_SWEEP_DAYS=7 "$guard" >/dev/null
[[ ! -s "$SWEEP_LOG" ]] || { print -u2 "custom template did not replace cargo-sweep"; exit 1 }
[[ "$(/usr/bin/head -n 1 "$CUSTOM_LOG")" == "$tool_root/build 7" ]] || {
  print -u2 "custom sweep template wrong:"; print -u2 -r -- "$(<"$CUSTOM_LOG")"; exit 1
}
[[ "$(/usr/bin/wc -l < "$CUSTOM_LOG" | /usr/bin/tr -d ' ')" == 4 ]]

# (7) With no cache directories configured the guard is just the floor.
make_guard_tree
MOCK_FREE_KIB=209715200 env RUNNER_WORK="$work_root" \
  MAC_CI_BURST_MIN_FREE_GIB=100 "$guard" >/dev/null
[[ ! -s "$SWEEP_LOG" && ! -s "$CARGO_LOG" ]] || {
  print -u2 "unconfigured guard swept something"; exit 1
}
[[ "$(artifact_dirs)" == "100 200 300 400 500 " ]] || {
  print -u2 "unconfigured guard pruned artifacts: $(artifact_dirs)"; exit 1
}

# (8) Without cargo, tier 2 refuses to delete unless CLEAN_RM is set explicitly.
make_guard_tree
set +e
MOCK_FREE_KIB=52428800 env $guard_env CARGO_HOME="$test_root/no-cargo" \
  PATH="$test_root/bin:/usr/bin:/bin" "$guard" >/dev/null 2>&1
norm_rc=$?
set -e
[[ "$norm_rc" == 75 ]]
[[ -d "$tool_root/build" ]] || { print -u2 "tier 2 deleted without CLEAN_RM"; exit 1 }

set +e
MOCK_FREE_KIB=52428800 env $guard_env CARGO_HOME="$test_root/no-cargo" \
  PATH="$test_root/bin:/usr/bin:/bin" MAC_CI_BURST_CLEAN_RM=1 "$guard" >/dev/null 2>&1
rm_rc=$?
set -e
[[ "$rm_rc" == 75 ]]
[[ ! -d "$tool_root/build" ]] || { print -u2 "CLEAN_RM=1 did not delete the cache"; exit 1 }
[[ -d "$work_root/_temp/_runner_file_commands" ]] || {
  print -u2 "CLEAN_RM deleted an unconfigured directory"; exit 1
}

print 'disk guard tier tests passed'

# ---------------------------------------------------------------------------
# Idle sweep driven by the reconciler
# ---------------------------------------------------------------------------

export GUARD_SHIM_LOG="$test_root/guard-shim.log"
mkdir -p "$app_support/bin"
cat > "$app_support/bin/pre-job-disk-guard.sh" <<'MOCK_GUARD'
#!/bin/zsh
print -r -- "$MAC_CI_BURST_GUARD_MODE $MAC_CI_BURST_MIN_FREE_GIB $MAC_CI_BURST_SOFT_FREE_GIB $MAC_CI_BURST_CACHE_DIRS $RUNNER_WORK $CARGO_HOME" >> "$GUARD_SHIM_LOG"
MOCK_GUARD
chmod +x "$app_support/bin/pre-job-disk-guard.sh"

cat >> "$app_support/config.env" <<CONFIG
SOFT_FREE_GIB=200
SWEEP_INTERVAL_SECONDS=3600
CACHE_DIRS="_temp/*"
CONFIG
print -r -- "CARGO_HOME=$test_root/runner/_toolcache/cargo" > "$test_root/runner/.env"
print -r -- "GITHUB_TOKEN=not-forwarded" >> "$test_root/runner/.env"
print available > "$app_support/desired-state"
/bin/rm -f "$app_support/last-sweep"

# Idle, between the floor and the soft threshold: one sweep, then rate limited.
MOCK_FREE_KIB=157286400 "$ctl" reconcile
[[ "$(<"$app_support/desired-state")" == available ]]
[[ -f "$app_support/last-sweep" ]]
[[ "$(<"$GUARD_SHIM_LOG")" == "sweep 100 200 _temp/* $test_root/runner/_work $test_root/runner/_toolcache/cargo" ]] || {
  print -u2 "sweep invocation wrong:"; print -u2 -r -- "$(<"$GUARD_SHIM_LOG")"; exit 1
}
MOCK_FREE_KIB=157286400 "$ctl" reconcile
[[ "$(/usr/bin/wc -l < "$GUARD_SHIM_LOG" | /usr/bin/tr -d ' ')" == 1 ]] || {
  print -u2 "idle sweep was not rate limited"; exit 1
}

# Above the soft threshold nothing runs even once the interval has elapsed.
/bin/rm -f "$app_support/last-sweep"
MOCK_FREE_KIB=419430400 "$ctl" reconcile
[[ ! -f "$app_support/last-sweep" ]]

# Busy runners are never swept.
tmp="$MOCK_STATE.tmp"
/usr/bin/jq '.runners[0].busy=true' "$MOCK_STATE" > "$tmp" && /bin/mv "$tmp" "$MOCK_STATE"
MOCK_FREE_KIB=157286400 "$ctl" reconcile
[[ ! -f "$app_support/last-sweep" ]]
/usr/bin/jq '.runners[0].busy=false' "$MOCK_STATE" > "$tmp" && /bin/mv "$tmp" "$MOCK_STATE"

[[ "$(MOCK_FREE_KIB=157286400 "$ctl" status | /usr/bin/jq -r '.softFreeGiB')" == 200 ]]

# Availability retries admission through the guard before refusing.
print off > "$app_support/desired-state"
/bin/rm -f "$GUARD_SHIM_LOG" "$app_support/last-sweep"
set +e
MOCK_FREE_KIB=52428800 "$ctl" available >/dev/null 2>&1
retry_rc=$?
set -e
[[ "$retry_rc" == 75 ]]
[[ "$(<"$GUARD_SHIM_LOG")" == admit* ]] || {
  print -u2 "available did not consult the guard:"; print -u2 -r -- "$(<"$GUARD_SHIM_LOG")"; exit 1
}

print 'idle sweep and admission-retry tests passed'
