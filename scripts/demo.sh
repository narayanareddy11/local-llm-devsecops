#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
environment="${1:-dev}"
if [[ "$environment" != dev && "$environment" != prod ]]; then exit 2; fi
state_root="${LOCAL_LLM_STATE_DIR:-$HOME/.local/share/local-llm-devsecops}"
state="$state_root/$environment"
export KUBECONFIG="$state/kubeconfig"
namespace="app-$environment"
port=8443
if [[ "$environment" == prod ]]; then port=9443; fi
base_url="https://llm.local:$port"
curl_args=(--fail --silent --show-error --cacert "$state/tls.crt" --resolve "llm.local:$port:127.0.0.1")

retry_get() {
  local label="$1"
  local path="$2"
  local output_file="${3:-}"
  local attempt
  for attempt in {1..30}; do
    if [[ -n "$output_file" ]]; then
      if curl "${curl_args[@]}" --max-time 10 "$base_url$path" -o "$output_file"; then return 0; fi
    elif curl "${curl_args[@]}" --max-time 10 "$base_url$path"; then
      return 0
    fi
    if [[ "$attempt" == 30 ]]; then
      echo "$label failed after $attempt attempts" >&2
      return 1
    fi
    echo "$label attempt $attempt failed; retrying after rollout convergence" >&2
    sleep 2
  done
}

kubectl -n "$namespace" wait --for=condition=complete job/model-download --timeout=900s
for deployment in gateway catalog assistant llm; do
  kubectl -n "$namespace" rollout status "deployment/$deployment" --timeout=600s
done

retry_get "Gateway health check" /healthz
printf '\n'
retry_get "Catalog API check" /api/v1/items
printf '\n'
web_page="$(mktemp)"
trap 'rm -f "$web_page"' EXIT
retry_get "Web application check" / "$web_page"
grep -Fq '<h1>Local Catalog Assistant</h1>' "$web_page"
echo "Web application is accessible at $base_url/"
for attempt in {1..5}; do
  if curl "${curl_args[@]}" --max-time 120 -H 'Content-Type: application/json' --data '{"question":"Summarize this item in one sentence","item_id":"item-1"}' "$base_url/api/v1/ask"; then
    break
  fi
  if [[ "$attempt" == 5 ]]; then exit 1; fi
  echo "Chat smoke test attempt $attempt failed; retrying after model warm-up" >&2
  sleep 3
done
printf '\n'
kubectl -n "$namespace" get hpa gateway
kubectl -n "$namespace" create job --from=cronjob/model-check "model-check-demo-$(date +%s)"

