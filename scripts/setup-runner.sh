#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then echo 'This runner setup targets macOS ARM64' >&2; exit 2; fi
for tool in gh curl tar; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }; done
authenticated=false
for attempt in 1 2 3 4 5; do
  if gh api user --jq .login >/dev/null 2>&1; then authenticated=true; break; fi
  sleep "$attempt"
done
if [[ "$authenticated" != true ]]; then echo 'GitHub API authentication or connectivity is unavailable' >&2; exit 2; fi
runner_dir="$PWD/.runner"
mkdir -p "$runner_dir"
chmod 700 "$runner_dir"
for attempt in 1 2 3 4 5; do
  version="$(gh api repos/actions/runner/releases/latest --jq .tag_name 2>/dev/null)" && break
  sleep "$attempt"
done
if [[ -z "${version:-}" ]]; then echo 'GitHub API unavailable; runner setup could not begin' >&2; exit 1; fi
asset="actions-runner-osx-arm64-${version#v}.tar.gz"
if [[ ! -f "$runner_dir/config.sh" ]]; then
  gh release download "$version" -R actions/runner -p "$asset" -D "$runner_dir" || { echo 'Could not download the official runner; check GitHub network access' >&2; exit 1; }
  tar -xzf "$runner_dir/$asset" -C "$runner_dir"
fi
token="$(gh api -X POST repos/narayanareddy11/local-llm-devsecops/actions/runners/registration-token --jq .token)" || { echo 'Runner registration requires repository admin access' >&2; exit 1; }
(cd "$runner_dir" && ./config.sh --unattended --url https://github.com/narayanareddy11/local-llm-devsecops --token "$token" --name "$(scutil --get ComputerName | tr ' ' '-')-llm" --labels local-llm --work _work --replace)
unset token
echo 'Runner registered. Start it with: cd .runner && ./run.sh'

