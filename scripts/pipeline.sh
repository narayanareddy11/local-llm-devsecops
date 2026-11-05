#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
environment="${2:-dev}"
if [[ "$environment" != dev && "$environment" != prod ]]; then echo 'Environment must be dev or prod' >&2; exit 2; fi
if [[ "$mode" != check && "$mode" != release && "$mode" != full ]]; then echo 'Usage: pipeline.sh check|release|full [dev|prod]' >&2; exit 2; fi
for command in uv helm; do command -v "$command" >/dev/null || { echo "Missing required tool: $command" >&2; exit 2; }; done
mkdir -p artifacts
tag="$(git rev-parse --short=12 HEAD)"
export UV_CACHE_DIR="$PWD/.cache/uv"
if [[ ! -x .venv/bin/python ]]; then uv venv --clear .venv >/dev/null; fi
uv pip install --python .venv/bin/python -r requirements.txt pytest ruff
.venv/bin/python -m pytest -q tests/test_services.py::test_catalog_contract tests/test_services.py::test_gateway_serves_web_chat | tee artifacts/unit-tests.txt
.venv/bin/python -m ruff check services jobs tests
.venv/bin/python -m ruff format --check services jobs tests
helm lint charts/app
helm template demo charts/app --set imageTag="$tag" > artifacts/rendered.yaml
if command -v hadolint >/dev/null; then
  hadolint --ignore DL3008 containers/*.Dockerfile
else
  echo 'Hadolint unavailable; install it to enable Dockerfile lint' >&2
fi
if [[ "$mode" == check ]]; then echo "Lightweight check passed for $tag"; exit 0; fi
for command in docker curl; do command -v "$command" >/dev/null || { echo "Missing required tool: $command" >&2; exit 2; }; done
if [[ "$(docker context show)" == desktop-linux ]]; then echo 'Switch Docker context to open-source Colima' >&2; exit 2; fi
docker info >/dev/null
if [[ "$mode" == full ]]; then
  command -v trivy >/dev/null || { echo 'Trivy is required for full scan' >&2; exit 2; }
  export TRIVY_CACHE_DIR="$PWD/.cache/trivy"
  mkdir -p "$TRIVY_CACHE_DIR"
  for config_dir in infra charts; do
    trivy config --severity HIGH,CRITICAL --exit-code 1 "$config_dir"
  done
  .venv/bin/python -m pytest -q | tee artifacts/full-unit-tests.txt
fi
if command -v tofu >/dev/null; then iac=tofu; elif command -v terraform >/dev/null; then iac=terraform; else echo 'OpenTofu is required' >&2; exit 2; fi
"$iac" -chdir=infra/cluster fmt -check
for role in gateway catalog assistant; do
  docker build --build-arg "SERVICE=$role" -f containers/app.Dockerfile -t "local-llm/$role:$tag" .
done
docker build -f containers/llm.Dockerfile -t "local-llm/llm:$tag" .
smoke="$(docker run -d --rm -p 127.0.0.1::8000 "local-llm/catalog:$tag")"
trap 'docker rm -f "$smoke" >/dev/null 2>&1 || true' EXIT
smoke_port="$(docker port "$smoke" 8000/tcp | tail -n 1 | sed 's/.*://')"
for attempt in {1..30}; do
  if curl --fail --silent "http://127.0.0.1:$smoke_port/healthz" >/dev/null; then break; fi
  sleep 1
done
curl --fail --silent --show-error "http://127.0.0.1:$smoke_port/items/item-1" > artifacts/container-smoke.json
docker rm -f "$smoke" >/dev/null
trap - EXIT
if [[ "$mode" == full ]]; then
  for role in gateway catalog assistant llm; do
    image="local-llm/$role:$tag"
    trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --format json -o "artifacts/$role-scan.json" "$image" || { echo "Vulnerability gate failed for $image" >&2; exit 1; }
    trivy image --format spdx-json -o "artifacts/$role-sbom.spdx.json" "$image"
  done
  echo "Full scan passed for $tag"
  exit 0
fi
for command in kind kubectl openssl; do command -v "$command" >/dev/null || { echo "Missing release tool: $command" >&2; exit 2; }; done
state_root="${LOCAL_LLM_STATE_DIR:-$HOME/.local/share/local-llm-devsecops}"
state="$state_root/$environment"
mkdir -p "$state"
chmod 700 "$state"
cluster="llm-$environment"
"$iac" -chdir=infra/cluster init -backend-config="path=$state/cluster.tfstate" -input=false
if [[ ! -s "$state/cluster.tfstate" ]] && kind get clusters | grep -Fxq "$cluster"; then
  echo "Reusing existing Kind cluster $cluster; its previous OpenTofu state is unavailable"
  echo "Existing cluster reused; no OpenTofu plan was run" > "artifacts/$environment-plan.txt"
else
  "$iac" -chdir=infra/cluster plan -var-file="$PWD/environments/$environment.tfvars" -var="kubeconfig_path=$state/kubeconfig" -out="$state/cluster.tfplan" -input=false
  "$iac" -chdir=infra/cluster show -no-color "$state/cluster.tfplan" > "artifacts/$environment-plan.txt"
  "$iac" -chdir=infra/cluster apply -input=false -auto-approve "$state/cluster.tfplan"
fi
export KUBECONFIG="$state/kubeconfig"
if [[ ! -s "$KUBECONFIG" ]]; then kind export kubeconfig --name "$cluster" --kubeconfig "$KUBECONFIG"; fi
kubectl config use-context "kind-$cluster" >/dev/null
helm repo add cilium https://helm.cilium.io --force-update >/dev/null
helm repo add traefik https://traefik.github.io/charts --force-update >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update >/dev/null
helm repo update >/dev/null
helm upgrade --install cilium cilium/cilium --version 1.20.4 --namespace kube-system --set ipam.mode=kubernetes --set operator.replicas=1 --set kubeProxyReplacement=false --wait --timeout 10m
kubectl wait --for=condition=Ready nodes --all --timeout=600s
helm upgrade --install traefik traefik/traefik --version 42.3.0 --namespace ingress-system --create-namespace --set service.type=NodePort --set ports.websecure.nodePort=30443 --set ports.websecure.exposedPort=443 --set ports.web.expose.default=false --set providers.kubernetesCRD.enabled=true --wait --timeout 5m
helm upgrade --install metrics-server metrics-server/metrics-server --version 3.14.0 --namespace kube-system --set 'args[0]=--kubelet-insecure-tls' --wait --timeout 5m
namespace="app-$environment"
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$namespace" pod-security.kubernetes.io/enforce=restricted --overwrite
if [[ ! -f "$state/tls.key" ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$state/tls.key" -out "$state/tls.crt" -days 30 -subj '/CN=llm.local' -addext 'subjectAltName=DNS:llm.local' >/dev/null 2>&1
  chmod 600 "$state/tls.key"
fi
kubectl -n "$namespace" create secret tls gateway-tls --cert="$state/tls.crt" --key="$state/tls.key" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
for role in gateway catalog assistant llm; do kind load docker-image "local-llm/$role:$tag" --name "$cluster"; done
# Kind's HTTPS host port is bound to 127.0.0.1. Docker/Colima source NAT makes
# Traefik's peer address differ across hosts, so the local-only bind is the
# access boundary; do not enforce a source-IP allowlist inside the cluster.
kubectl -n "$namespace" delete job model-download --ignore-not-found --wait=true
helm upgrade --install app charts/app --namespace "$namespace" --set "imageTag=$tag" --set "environment=$environment" --set ipAllowList.enabled=false --wait --wait-for-jobs --timeout 15m --history-max 5
kubectl -n "$namespace" get pods,jobs,hpa,ingress -o wide > "artifacts/$environment-resources.txt"
"$PWD/scripts/demo.sh" "$environment" | tee "artifacts/$environment-demo.txt"
echo "Release passed for $environment at $tag"

