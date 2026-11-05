#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then echo 'This runner setup targets macOS ARM64' >&2; exit 2; fi
for tool in gh curl tar; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 2; }; done
runner_dir="$PWD/.runner"
mkdir -p "$runner_dir"
chmod 700 "$runner_dir"
version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
asset="actions-runner-osx-arm64-${version#v}.tar.gz"
if [[ ! -f "$runner_dir/config.sh" ]]; then
  gh release download "$version" -R actions/runner -p "$asset" -D "$runner_dir"
  tar -xzf "$runner_dir/$asset" -C "$runner_dir"
fi
token="$(gh api -X POST repos/narayanareddy11/local-llm-devsecops/actions/runners/registration-token --jq .token)"
(cd "$runner_dir" && ./config.sh --unattended --url https://github.com/narayanareddy11/local-llm-devsecops --token "$token" --name "$(scutil --get ComputerName | tr ' ' '-')-llm" --labels local-llm --work _work --replace)
unset token
echo 'Runner registered. Start it with: cd .runner && ./run.sh'

