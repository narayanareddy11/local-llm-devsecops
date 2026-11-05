#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
mode="${1:-}"
environment="${2:-dev}"
if [[ "$environment" != dev && "$environment" != prod ]]; then echo 'Environment must be dev or prod' >&2; exit 2; fi
if [[ "$mode" != check && "$mode" != release ]]; then echo 'Usage: pipeline.sh check|release [dev|prod]' >&2; exit 2; fi
for command in uv docker trivy helm; do command -v "$command" >/dev/null || { echo "Missing required tool: $command" >&2; exit 2; }; done
if [[ "$(docker context show)" == desktop-linux ]]; then echo 'Use open-source Colima/Moby, not Docker Desktop, for the assessment' >&2; exit 2; fi
docker info >/dev/null
mkdir -p artifacts
tag="$(git rev-parse --short=12 HEAD)"
uv venv .venv >/dev/null
uv pip install --python .venv/bin/python -e . pytest ruff
.venv/bin/python -m pytest -q | tee artifacts/unit-tests.txt
.venv/bin/python -m ruff check services jobs tests
.venv/bin/python -m ruff format --check services jobs tests
helm lint charts/app
helm template demo charts/app --set imageTag="$tag" > artifacts/rendered.yaml
if command -v tofu >/dev/null; then iac=tofu; elif command -v terraform >/dev/null; then iac=terraform; else echo 'OpenTofu is required' >&2; exit 2; fi
"$iac" -chdir=infra/cluster fmt -check
for role in gateway catalog assistant; do
  docker build --build-arg "SERVICE=$role" -f containers/app.Dockerfile -t "local-llm/$role:$tag" .
done
docker build -f containers/llm.Dockerfile -t "local-llm/llm:$tag" .
for role in gateway catalog assistant llm; do
  image="local-llm/$role:$tag"
  trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --format json -o "artifacts/$role-scan.json" "$image" || { echo "Vulnerability gate failed for $image" >&2; exit 1; }
  trivy image --format spdx-json -o "artifacts/$role-sbom.spdx.json" "$image"
done
echo "Check passed for $tag"
if [[ "$mode" == check ]]; then exit 0; fi
for command in kind kubectl openssl; do command -v "$command" >/dev/null || { echo "Missing release tool: $command" >&2; exit 2; }; done
state="$PWD/.state/$environment"
mkdir -p "$state"
chmod 700 "$state"
"$iac" -chdir=infra/cluster init -backend-config="path=$state/cluster.tfstate" -input=false
"$iac" -chdir=infra/cluster plan -var-file="$PWD/environments/$environment.tfvars" -var="kubeconfig_path=$state/kubeconfig" -out="$state/cluster.tfplan" -input=false
"$iac" -chdir=infra/cluster show -no-color "$state/cluster.tfplan" > "artifacts/$environment-plan.txt"
"$iac" -chdir=infra/cluster apply -input=false -auto-approve "$state/cluster.tfplan"
export KUBECONFIG="$state/kubeconfig"
cluster="llm-$environment"
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
gateway_ip="$(docker inspect "$cluster-control-plane" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}')"
if [[ -z "$gateway_ip" ]]; then echo 'Cannot determine ingress source IP' >&2; exit 1; fi
helm upgrade --install app charts/app --namespace "$namespace" --set "imageTag=$tag" --set "environment=$environment" --set "allowedCIDRs[0]=$gateway_ip/32" --wait --wait-for-jobs --timeout 15m --history-max 5
kubectl -n "$namespace" get pods,jobs,hpa,ingress -o wide > "artifacts/$environment-resources.txt"
"$PWD/scripts/demo.sh" "$environment" | tee "artifacts/$environment-demo.txt"
echo "Release passed for $environment at $tag"

