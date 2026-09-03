#!/bin/zsh
set -euo pipefail

export PATH="${PATH:-}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
APP_SUPPORT="${MAC_CI_BURST_HOME:-$HOME/Library/Application Support/MacCIBurst}"
CONFIG_FILE="${MAC_CI_BURST_CONFIG:-$APP_SUPPORT/config.env}"
[[ -f "$CONFIG_FILE" ]] || { print -u2 "Missing configuration: $CONFIG_FILE"; exit 78; }
source "$CONFIG_FILE"

for tool in gh jq curl shasum tar uname; do
  command -v "$tool" >/dev/null || { print -u2 "Missing required tool: $tool"; exit 69; }
done

: "${GITHUB_SCOPE_TYPE:?GITHUB_SCOPE_TYPE must be org or repo}"
: "${GITHUB_OWNER:?GITHUB_OWNER is required}"
: "${RUNNER_NAME:?RUNNER_NAME is required}"
: "${BURST_LABEL:?BURST_LABEL is required}"
: "${RUNNER_DIR:?RUNNER_DIR is required}"
: "${MIN_FREE_GIB:=100}"
: "${SOFT_FREE_GIB:=$(( MIN_FREE_GIB * 2 ))}"
: "${SETUP_MIN_FREE_GIB:=5}"
: "${CACHE_DIRS:=}"
: "${ARTIFACT_DIR:=}"
: "${ARTIFACT_KEEP:=3}"
: "${SWEEP_CMD:=}"
: "${SWEEP_DAYS:=3}"
: "${CLEAN_CMD:=}"
: "${CLEAN_RM:=0}"
: "${RUNNER_LABELS:=self-hosted,macOS,burst}"
: "${DISK_VOLUME:=/System/Volumes/Data}"

[[ ",$RUNNER_LABELS," == *",$BURST_LABEL,"* ]] || {
  print -u2 "RUNNER_LABELS must include BURST_LABEL ($BURST_LABEL)"; exit 78;
}
if [[ "$GITHUB_SCOPE_TYPE" == org ]]; then
  : "${RUNNER_GROUP:=Default}"
  scope_api="/orgs/$GITHUB_OWNER"
  scope_url="https://github.com/$GITHUB_OWNER"
elif [[ "$GITHUB_SCOPE_TYPE" == repo ]]; then
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required for repo scope}"
  scope_api="/repos/$GITHUB_OWNER/$GITHUB_REPOSITORY"
  scope_url="https://github.com/$GITHUB_OWNER/$GITHUB_REPOSITORY"
else
  print -u2 "GITHUB_SCOPE_TYPE must be org or repo"; exit 78
fi

free_gib="$(df -Pk "$DISK_VOLUME" | awk 'NR == 2 { printf "%d", $4 / 1024 / 1024 }')"
(( free_gib >= SETUP_MIN_FREE_GIB )) || {
  print -u2 "Runner setup blocked: ${free_gib} GiB free; ${SETUP_MIN_FREE_GIB} GiB required"; exit 75;
}
[[ ! -e "$RUNNER_DIR" ]] || { print -u2 "Runner directory already exists: $RUNNER_DIR"; exit 73; }

case "$(uname -m)" in
  arm64) runner_asset_pattern='^actions-runner-osx-arm64-.*\.tar\.gz$' ;;
  x86_64) runner_asset_pattern='^actions-runner-osx-x64-.*\.tar\.gz$' ;;
  *) print -u2 "Unsupported Mac architecture: $(uname -m)"; exit 69 ;;
esac

release_json="$(gh api /repos/actions/runner/releases/latest)"
asset_json="$(jq -c --arg pattern "$runner_asset_pattern" '.assets[] | select(.name | test($pattern))' <<<"$release_json" | head -n 1)"
asset_url="$(jq -r '.browser_download_url // empty' <<<"$asset_json")"
asset_digest="$(jq -r '.digest // empty' <<<"$asset_json")"
[[ -n "$asset_url" ]] || { print -u2 "Could not resolve the current macOS runner package"; exit 69; }

download_dir="$(mktemp -d "${TMPDIR:-/tmp}/mac-ci-burst.XXXXXX")"
archive="$download_dir/runner.tar.gz"
trap '/bin/rm -rf "$download_dir"' EXIT
curl --fail --location --silent --show-error "$asset_url" --output "$archive"

expected=""
[[ "$asset_digest" == sha256:* ]] && expected="${asset_digest#sha256:}"
[[ -z "$expected" && -n "${ACTIONS_RUNNER_SHA256:-}" ]] && expected="$ACTIONS_RUNNER_SHA256"
[[ -n "$expected" ]] || { print -u2 "No trusted SHA-256 was available; refusing an unverified install"; exit 65; }
actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || { print -u2 "Runner package checksum mismatch"; exit 65; }

mkdir -p "$RUNNER_DIR"
tar -xzf "$archive" -C "$RUNNER_DIR"

registration_token="$(gh api --method POST "$scope_api/actions/runners/registration-token" --jq '.token')"
config_args=(
  --unattended --url "$scope_url" --token "$registration_token" --name "$RUNNER_NAME"
  --work _work --labels "$RUNNER_LABELS" --no-default-labels
)
[[ "$GITHUB_SCOPE_TYPE" == org && "$RUNNER_GROUP" != Default ]] && config_args+=(--runnergroup "$RUNNER_GROUP")
"$RUNNER_DIR/config.sh" "${config_args[@]}"

# The job-started hook reads its policy from the runner .env, so the same
# thresholds and command templates apply whether a job or the controller runs it.
{
  print -r -- "ACTIONS_RUNNER_HOOK_JOB_STARTED=$APP_SUPPORT/bin/pre-job-disk-guard.sh"
  print -r -- "MAC_CI_BURST_MIN_FREE_GIB=$MIN_FREE_GIB"
  print -r -- "MAC_CI_BURST_SOFT_FREE_GIB=$SOFT_FREE_GIB"
  print -r -- "MAC_CI_BURST_DISK_VOLUME=$DISK_VOLUME"
  print -r -- "MAC_CI_BURST_CACHE_DIRS=$CACHE_DIRS"
  print -r -- "MAC_CI_BURST_ARTIFACT_DIR=$ARTIFACT_DIR"
  print -r -- "MAC_CI_BURST_ARTIFACT_KEEP=$ARTIFACT_KEEP"
  print -r -- "MAC_CI_BURST_SWEEP_CMD=$SWEEP_CMD"
  print -r -- "MAC_CI_BURST_SWEEP_DAYS=$SWEEP_DAYS"
  print -r -- "MAC_CI_BURST_CLEAN_CMD=$CLEAN_CMD"
  print -r -- "MAC_CI_BURST_CLEAN_RM=$CLEAN_RM"
} > "$RUNNER_DIR/.env"
(cd "$RUNNER_DIR" && ./svc.sh install)

"$APP_SUPPORT/bin/mac-ci-burst" off
print "Runner registered in the Off state. Audit workflow labels before making it available."
