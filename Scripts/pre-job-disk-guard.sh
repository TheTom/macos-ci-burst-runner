#!/bin/bash
set -euo pipefail

# Tiered disk guard for the Mac CI burst runner.
#
# Runs as the runner's ACTIONS_RUNNER_HOOK_JOB_STARTED hook (mode "admit") and
# as an idle housekeeping pass driven by mac-ci-burst reconcile (mode "sweep").
#
# Tiers, cheapest first, each re-measuring free space and stopping early:
#   0  prune stale per-run artifact directories        (always, if configured)
#   1  sweep old build artifacts out of cache dirs     (free < SOFT)
#   2  clean whole cache directories                   (free < MIN, admit only)
#
# Everything the guard touches is configuration. With no cache configuration it
# degrades to the plain free-space floor it replaces.
#
# Env (all optional except where noted):
#   MAC_CI_BURST_MIN_FREE_GIB    hard floor; admission denied below it   (100)
#   MAC_CI_BURST_SOFT_FREE_GIB   soft threshold that triggers tier 1     (2 * MIN)
#   MAC_CI_BURST_DISK_VOLUME     volume measured   (/System/Volumes/Data)
#   MAC_CI_BURST_CACHE_DIRS      colon-separated directories or globs swept and
#                                cleaned, in the order listed; relative entries
#                                resolve under RUNNER_WORK. Empty = no sweeping.
#   MAC_CI_BURST_ARTIFACT_DIR    parent of per-run artifact directories; relative
#                                resolves under RUNNER_WORK. Unset = tier 0 off.
#   MAC_CI_BURST_ARTIFACT_KEEP   newest artifact directories to keep       (3)
#   MAC_CI_BURST_SWEEP_CMD       tier 1 template, "{dir}" and "{days}" are
#                                substituted. Default: cargo-sweep when present.
#   MAC_CI_BURST_SWEEP_DAYS      age threshold handed to the sweep command  (3)
#   MAC_CI_BURST_CLEAN_CMD       tier 2 template, "{dir}" is substituted.
#                                Default: cargo clean when cargo is present.
#   MAC_CI_BURST_CLEAN_RM=1      opt in to "rm -rf {dir}" as the tier 2 default
#                                when no cargo and no CLEAN_CMD are available.
#   MAC_CI_BURST_GUARD_MODE      admit | sweep                          (admit)
#   MAC_CI_BURST_DRY_RUN=1       log intended work, change nothing
#   RUNNER_WORK                  runner work directory (<script dir>/_work)
#   CARGO_HOME / RUSTUP_HOME     used to locate cargo and cargo-sweep
#   GITHUB_RUN_ID                artifact directory that is never pruned

minimum_free_gib="${MAC_CI_BURST_MIN_FREE_GIB:-100}"
soft_free_gib="${MAC_CI_BURST_SOFT_FREE_GIB:-$(( minimum_free_gib * 2 ))}"
disk_volume="${MAC_CI_BURST_DISK_VOLUME:-/System/Volumes/Data}"
cache_dirs_spec="${MAC_CI_BURST_CACHE_DIRS:-}"
artifact_dir_spec="${MAC_CI_BURST_ARTIFACT_DIR:-}"
artifact_keep="${MAC_CI_BURST_ARTIFACT_KEEP:-3}"
sweep_days="${MAC_CI_BURST_SWEEP_DAYS:-3}"
sweep_cmd="${MAC_CI_BURST_SWEEP_CMD:-}"
clean_cmd="${MAC_CI_BURST_CLEAN_CMD:-}"
clean_rm="${MAC_CI_BURST_CLEAN_RM:-0}"
guard_mode="${MAC_CI_BURST_GUARD_MODE:-admit}"
dry_run="${MAC_CI_BURST_DRY_RUN:-0}"

case "$guard_mode" in
  admit|sweep) ;;
  *)
    printf '%s\n' "CI disk guard: unknown MAC_CI_BURST_GUARD_MODE '$guard_mode'" >&2
    exit 64
    ;;
esac

script_root="$(cd "$(dirname "$0")" && pwd)"
runner_work="${RUNNER_WORK:-$script_root/_work}"

reclaimed_kib=0

log() {
  printf '%s\n' "CI disk guard: $*" >&2
}

free_gib() {
  df -Pk "$disk_volume" | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }'
}

dir_kib() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

# Relative configuration is interpreted against the runner work directory, so a
# single config.env works no matter where the runner was installed.
absolute_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) printf '%s' "$runner_work/$1" ;;
  esac
}

# Single-quote a path so it can be substituted into a command template that is
# evaluated by the shell.
shell_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\\\'\'}"
}

render_template() {
  local rendered="$1"
  rendered="${rendered//\{dir\}/$(shell_quote "$2")}"
  rendered="${rendered//\{days\}/$sweep_days}"
  printf '%s' "$rendered"
}

# ------------------------------------------------------------- cache dirs ----
# CACHE_DIRS is a colon-separated list of directories or globs. Entries are
# visited in the order configured; within one glob the oldest directory (by
# mtime) is visited first, because it is the least likely to be reused.
cache_dirs=()
collect_cache_dirs() {
  local entry pattern listing line path old_ifs
  cache_dirs=()
  [[ -n "$cache_dirs_spec" ]] || return 0
  listing="$(mktemp "${TMPDIR:-/tmp}/mac-ci-burst-cache.XXXXXX")"

  old_ifs="$IFS"
  IFS=':'
  # shellcheck disable=SC2206
  local entries=($cache_dirs_spec)
  IFS="$old_ifs"

  for entry in ${entries+"${entries[@]}"}; do
    [[ -n "$entry" ]] || continue
    pattern="$(absolute_path "$entry")"
    : > "$listing"
    old_ifs="$IFS"
    IFS=$'\n'
    # Unquoted so the entry is glob-expanded; IFS keeps spaces in the pattern
    # itself from splitting it into separate words.
    for path in $pattern; do
      [[ -d "$path" ]] || continue
      stat -f '%m %N' "$path" 2>/dev/null >> "$listing" || true
    done
    IFS="$old_ifs"
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      cache_dirs+=("${line#* }")
    done < <(sort -n "$listing")
  done

  rm -f "$listing"
}

# ---------------------------------------------------------------- tier 0 ----
# Per-run artifact directories are not reused after their run finishes. Keep the
# newest ARTIFACT_KEEP plus the directory belonging to the run being admitted.
prune_artifacts() {
  local art_root listing index=0 line dir base kib
  [[ -n "$artifact_dir_spec" ]] || return 0
  art_root="$(absolute_path "$artifact_dir_spec")"
  [[ -d "$art_root" ]] || return 0

  listing="$(mktemp "${TMPDIR:-/tmp}/mac-ci-burst-artifacts.XXXXXX")"
  find "$art_root" -mindepth 1 -maxdepth 1 -type d -exec stat -f '%m %N' {} + \
    2>/dev/null | sort -rn > "$listing" || true

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    dir="${line#* }"
    index=$(( index + 1 ))
    if (( index <= artifact_keep )); then
      continue
    fi
    base="${dir##*/}"
    if [[ -n "${GITHUB_RUN_ID:-}" && "$base" == "$GITHUB_RUN_ID" ]]; then
      log "keeping current run artifacts $dir"
      continue
    fi
    kib="$(dir_kib "$dir")"
    if [[ "$dry_run" == "1" ]]; then
      log "would remove stale artifacts $dir (${kib:-0} KiB)"
      continue
    fi
    log "removing stale artifacts $dir (${kib:-0} KiB)"
    rm -rf "$dir"
    reclaimed_kib=$(( reclaimed_kib + ${kib:-0} ))
  done < "$listing"

  rm -f "$listing"
}

# ---------------------------------------------------------------- tier 1 ----
# Resolve cargo / cargo-sweep, honouring the runner's CARGO_HOME, so the default
# templates work without the operator configuring anything.
cargo_bin=""
cargo_sweep_bin=""
resolve_tools() {
  local home_bin="${CARGO_HOME:-}/bin"
  if [[ -n "${CARGO_HOME:-}" && -x "$home_bin/cargo" ]]; then
    cargo_bin="$home_bin/cargo"
  elif command -v cargo >/dev/null 2>&1; then
    cargo_bin="$(command -v cargo)"
  fi
  if [[ -n "${CARGO_HOME:-}" && -x "$home_bin/cargo-sweep" ]]; then
    cargo_sweep_bin="$home_bin/cargo-sweep"
  elif command -v cargo-sweep >/dev/null 2>&1; then
    cargo_sweep_bin="$(command -v cargo-sweep)"
  fi
}

# cargo-sweep resolves the target directory through `cargo metadata`, so it needs
# a manifest -- it cannot be pointed at a bare target tree. CI caches outlive the
# checkouts that produced them, so drive it from a throwaway probe crate with
# CARGO_TARGET_DIR aimed at the tree we actually want swept.
sweep_probe=""
make_sweep_probe() {
  [[ -n "$sweep_probe" ]] && return 0
  sweep_probe="$(mktemp -d "${TMPDIR:-/tmp}/mac-ci-burst-sweep-probe.XXXXXX")"
  mkdir -p "$sweep_probe/src"
  printf '%s\n' '[package]' 'name = "mac-ci-burst-sweep-probe"' 'version = "0.0.0"' \
    'edition = "2021"' '[lib]' 'path = "src/lib.rs"' > "$sweep_probe/Cargo.toml"
  : > "$sweep_probe/src/lib.rs"
}

cleanup_sweep_probe() {
  [[ -n "$sweep_probe" ]] && rm -rf "$sweep_probe"
  sweep_probe=""
}
trap cleanup_sweep_probe EXIT

# Returns the tier 1 template, or empty when nothing can sweep.
sweep_template=""
sweep_template_is_default=0
resolve_sweep_template() {
  local dry_flag=""
  if [[ -n "$sweep_cmd" ]]; then
    sweep_template="$sweep_cmd"
    sweep_template_is_default=0
    return 0
  fi
  if [[ -z "$cargo_sweep_bin" ]]; then
    log "no MAC_CI_BURST_SWEEP_CMD and cargo-sweep not found; skipping tier 1"
    return 1
  fi
  if [[ -z "$cargo_bin" ]]; then
    log "cargo not found; cargo-sweep cannot read metadata, skipping tier 1"
    return 1
  fi
  make_sweep_probe
  # cargo-sweep shells out to cargo; make sure the runner's cargo wins.
  [[ "$dry_run" == "1" ]] && dry_flag=" --dry-run"
  sweep_template="env PATH=$(shell_quote "$(dirname "$cargo_bin"):$PATH")"
  sweep_template+=" CARGO_TARGET_DIR={dir} $(shell_quote "$cargo_sweep_bin")"
  sweep_template+=" sweep${dry_flag} --time {days} $(shell_quote "$sweep_probe")"
  sweep_template_is_default=1
  return 0
}

run_sweep() {
  local dir free_now rendered
  collect_cache_dirs
  (( ${#cache_dirs[@]} )) || {
    log "no cache directories configured; skipping tier 1"
    return 0
  }
  resolve_sweep_template || return 0

  for dir in ${cache_dirs+"${cache_dirs[@]}"}; do
    free_now="$(free_gib)"
    if (( free_now >= soft_free_gib )); then
      return 0
    fi
    rendered="$(render_template "$sweep_template" "$dir")"
    # A custom template is never executed during a dry run; the built-in
    # cargo-sweep template gets --dry-run instead so its report still appears.
    if [[ "$dry_run" == "1" && "$sweep_template_is_default" != "1" ]]; then
      log "would sweep $dir: $rendered"
      continue
    fi
    log "sweeping $dir (older than ${sweep_days}d)"
    # A sweep failure is never fatal: the guard still has tier 2 and the floor.
    eval "$rendered" >&2 || log "sweep failed for $dir (ignored)"
  done
}

# ---------------------------------------------------------------- tier 2 ----
clean_template=""
resolve_clean_template() {
  if [[ -n "$clean_cmd" ]]; then
    clean_template="$clean_cmd"
    return 0
  fi
  if [[ -n "$cargo_bin" ]]; then
    clean_template="$(shell_quote "$cargo_bin") clean --target-dir {dir}"
    return 0
  fi
  if [[ "$clean_rm" == "1" ]]; then
    clean_template="rm -rf {dir}"
    return 0
  fi
  log "no MAC_CI_BURST_CLEAN_CMD and no cargo; set MAC_CI_BURST_CLEAN_RM=1 to allow deletion. Skipping tier 2"
  return 1
}

run_clean() {
  local dir free_now rendered
  collect_cache_dirs
  (( ${#cache_dirs[@]} )) || {
    log "no cache directories configured; skipping tier 2"
    return 0
  }
  resolve_clean_template || return 0

  for dir in ${cache_dirs+"${cache_dirs[@]}"}; do
    free_now="$(free_gib)"
    if (( free_now >= minimum_free_gib )); then
      return 0
    fi
    rendered="$(render_template "$clean_template" "$dir")"
    if [[ "$dry_run" == "1" ]]; then
      log "would clean $dir: $rendered"
      continue
    fi
    log "cleaning $dir"
    eval "$rendered" >&2 || log "clean failed for $dir (ignored)"
  done
}

# -------------------------------------------------------------------- run ---
resolve_tools
free_before="$(free_gib)"

prune_artifacts

free_now="$(free_gib)"
if (( free_now < soft_free_gib )); then
  run_sweep
  free_now="$(free_gib)"
fi

if [[ "$guard_mode" == "sweep" ]]; then
  printf '%s\n' "CI disk sweep: ${free_before} -> ${free_now} GiB free; ${reclaimed_kib} KiB of stale artifacts removed"
  exit 0
fi

if (( free_now < minimum_free_gib )); then
  run_clean
  free_now="$(free_gib)"
fi

if (( free_now < minimum_free_gib )); then
  printf '%s\n' "CI admission denied after cache recovery: ${free_now} GiB free; ${minimum_free_gib} GiB required" >&2
  exit 75
fi

printf '%s\n' "CI disk admission passed: ${free_now} GiB free"
