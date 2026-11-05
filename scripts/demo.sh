#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
environment="${1:-dev}"
if [[ "$environment" != dev && "$environment" != prod ]]; then exit 2; fi
export KUBECONFIG="$PWD/.state/$environment/kubeconfig"
port=8443
if [[ "$environment" == prod ]]; then port=9443; fi
kubectl -n "app-$environment" wait --for=condition=complete job/model-download --timeout=900s
curl --fail --silent --show-error --cacert ".state/$environment/tls.crt" --resolve "llm.local:$port:127.0.0.1" "https://llm.local:$port/healthz"
curl --fail --silent --show-error --cacert ".state/$environment/tls.crt" --resolve "llm.local:$port:127.0.0.1" "https://llm.local:$port/api/v1/items"
curl --fail --silent --show-error --cacert ".state/$environment/tls.crt" --resolve "llm.local:$port:127.0.0.1" -H 'Content-Type: application/json' --data '{"question":"Summarize this item in one sentence","item_id":"item-1"}' "https://llm.local:$port/api/v1/ask"
kubectl -n "app-$environment" get hpa gateway
kubectl -n "app-$environment" create job --from=cronjob/model-check "model-check-demo-$(date +%s)"

