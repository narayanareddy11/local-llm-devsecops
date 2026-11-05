# Local LLM DevSecOps — v1.0.0

This repository implements the take-home assessment as a laptop-only proof of concept. It uses three FastAPI services, a CPU-only `llama.cpp` workload, Kind, Cilium, Traefik, OpenTofu-compatible IaC, and a self-hosted GitHub Actions runner on macOS ARM64. The private catalog and inference services use ClusterIP only. The only exposed route is the localhost gateway through TLS.

## Repository overview

- Repository: [narayanareddy11/local-llm-devsecops](https://github.com/narayanareddy11/local-llm-devsecops)
- Current release: `v1.0.0`
- Runtime target: Apple Silicon Mac with Colima and Kind
- Inference: local CPU-only Qwen 2.5 0.5B through `llama.cpp`
- Application: FastAPI gateway, catalog, and assistant services
- Delivery: GitHub Actions on a self-hosted macOS ARM64 runner
- Infrastructure: OpenTofu, Kubernetes, Helm, Cilium, and Traefik
- Security: pinned container bases and model metadata, restricted containers, default-deny network policies, TLS ingress, Trivy scanning, and SPDX SBOM generation
- License: MIT for repository code; Apache-2.0 for the separately distributed Qwen model

### Repository layout

| Path | Purpose |
| --- | --- |
| `.github/workflows/` | Parallel CI checks, release deployment, full security scan, and diagnostics |
| `services/` | Gateway, catalog, assistant API, and browser chat interface |
| `jobs/` | Model download and integrity-check job logic |
| `containers/` | Pinned application and `llama.cpp` container builds |
| `charts/app/` | Helm chart for workloads, ingress, jobs, and network policies |
| `infra/cluster/` | OpenTofu definition for the local Kind cluster |
| `environments/` | Separate development and production cluster variables |
| `model/` | Pinned model revision, filename, size, license, and SHA-256 metadata |
| `scripts/` | Validation, release, runner setup, and demo commands |
| `tests/` | Application and model-contract tests |

The project is intentionally local-first: model inference, catalog data, application traffic, and deployment remain on the laptop. GitHub Actions orchestrates the trusted self-hosted runner but does not host the model or application runtime.

```text
Mac localhost:8443 -> Traefik TLS -> gateway
                                            |-> catalog
                                            |-> assistant -> catalog + llama.cpp -> model PVC
Hugging Face (one-time download only) -> Job -> model PVC
```

## Local chat app

The app runs on the Mac's local Kubernetes cluster. It is not a public internet service.

- Web chat: **https://llm.local:8443/**
- Health: `https://llm.local:8443/healthz`
- Catalog: `https://llm.local:8443/api/v1/items`
- Chat API: `POST https://llm.local:8443/api/v1/ask`

### Quick Mac browser demo

The most reliable presentation route uses a local port-forward and does not require DNS or a self-signed TLS exception.

1. Confirm the local release workflow completed successfully and the Kind cluster is running.
2. Open Terminal on the Mac and run:

   ```bash
   export KUBECONFIG="$HOME/.local/share/local-llm-devsecops/dev/kubeconfig"
   kubectl -n app-dev port-forward svc/gateway 18000:8000
   ```

3. Keep that Terminal window open. A successful forward prints:

   ```text
   Forwarding from 127.0.0.1:18000 -> 8000
   Forwarding from [::1]:18000 -> 8000
   ```

4. Open **http://localhost:18000/** in the browser.
5. Select a catalog item, enter a question, and choose **Ask assistant**.

The demo catalog contains these items:

| Item | Catalog facts | Example question |
| --- | --- | --- |
| Trail backpack | 25 litre, water-resistant hiking backpack | `Is this backpack water-resistant and what is its capacity?` |
| Travel mug | 350 ml, insulated stainless steel mug | `What material is this mug made from?` |
| Desk lamp | Adjustable LED lamp with three brightness levels | `How many brightness levels does this lamp have?` |

A reliable general demonstration prompt is:

```text
Summarize this item in one sentence using only the catalog information.
```

The assistant only has the supplied product catalog. It cannot answer questions about orders, customers, shipping, inventory, or other external data. A question such as `Where is my order?` should produce a missing-information response rather than invented details.

The chat API can also be tested while the port-forward is running:

```bash
curl --fail --silent --show-error http://localhost:18000/api/v1/ask \
  -H 'Content-Type: application/json' \
  --data '{"question":"Summarize this item in one sentence","item_id":"item-1"}'
```

### HTTPS ingress access

To use the TLS ingress route, add the local hostname once:

```bash
echo '127.0.0.1 llm.local' | sudo tee -a /etc/hosts
sudo dscacheutil -flushcache
```

Then open **https://llm.local:8443/**. The demo uses a locally generated self-signed certificate, so the browser displays a certificate warning until that certificate is trusted locally.

### Browser troubleshooting

- `ERR_CONNECTION_REFUSED` at `localhost:18000` means the port-forward is not running. Start the command above and keep its Terminal window open.
- `Could not resolve host: llm.local` means the `/etc/hosts` entry is missing.
- A certificate warning at `https://llm.local:8443` is expected for the self-signed development certificate. Use the HTTP port-forward route for a presentation without that warning.
- If port 18000 is already in use, run `kubectl -n app-dev port-forward svc/gateway 18001:8000` and open **http://localhost:18001/**.
- If the page opens but a request fails, inspect the workload with `kubectl -n app-dev get pods,endpoints` and confirm every application pod is ready.

## Status and prerequisites

The repository includes application code, focused tests, pinned model metadata, container images, a Kind cluster definition, Helm chart, OpenTofu configuration, and GitHub Actions workflows. The supported demo uses an ARM64 Mac with open-source [Colima](https://colima.run/docs/installation/). Allow at least 6 CPU cores, 8 GiB container VM memory, and 10 GiB free disk.

Install open-source Colima, Moby/Docker CLI, Kind, kubectl, Helm, OpenTofu, Trivy, Hadolint, uv, OpenSSL, and GitHub CLI. `brew install colima docker kind kubectl helm opentofu trivy hadolint uv gh` is a convenient setup on macOS. Use `colima start --cpu 6 --memory 8 --disk 40` and `docker context use colima`; then confirm `docker context show` says `colima`.

```bash
./scripts/pipeline.sh check       # quick interview proof on every push
./scripts/pipeline.sh release dev # manual Kubernetes demo
./scripts/pipeline.sh full        # separate complete image scan and SBOM run
```

GitHub Actions follows the assessment pipeline: checkout, five independent check branches, a verify gate, then a manually selected release or full scan. The branches cover application tests/Ruff; Helm; OpenTofu/shell syntax; Dockerfiles/base digests; and model metadata/browser chat. GitHub can schedule independent branches concurrently, subject to available self-hosted runner capacity. Each check job has no more than two steps. To deploy, open **Actions → Local DevSecOps CI CD → Run workflow**, select `release`, and keep the Mac runner online. Select `release-only` to rerun only deployment, `diagnose` for one Kubernetes diagnostics job, or `full` for Trivy and SBOM generation.

After deployment, `./scripts/demo.sh dev` repeats the health, catalog, chat, HPA, and model-check smoke tests.

`check` runs two representative tests, Ruff, Helm lint/render, and Hadolint when installed. `release` runs those checks, builds the app and model images, smoke-tests the catalog container, plans/applies Kind when needed, installs Cilium, Traefik, and metrics-server, loads images, deploys Helm, and verifies the HTTPS chat endpoint. The chat smoke test retries briefly to allow the local model to warm up. `full` separately runs all tests, Trivy IaC and image scans, and SPDX SBOM generation with a HIGH/CRITICAL vulnerability gate. Outputs go to ignored `artifacts/`. Persistent OpenTofu state, kubeconfig, and TLS key are stored outside the checkout at `$HOME/.local/share/local-llm-devsecops/<environment>` (override with `LOCAL_LLM_STATE_DIR`) so GitHub Actions checkout cleanup cannot erase them. If an existing Kind cluster has no state file, release reuses it because the Kind provider cannot import that cluster; delete the cluster and rerun release to return it to IaC management.

Dev and prod use the same code with separate state directories, clusters, namespaces, and host ports (`8443`, `9443`). Add a third environment by copying a tfvars file, choosing a unique environment name and port, and adding the name to the script allowlists. This environment design isolates state but does not provide cloud-level failure isolation on one laptop.

## Self-hosted GitHub Actions

The workflow follows the example pipeline: a checkout job fans out to five independent checks, which run in parallel, then a verification gate enables the manually selected release or full scan. It requires a self-hosted macOS ARM64 runner with the `local-llm` label. The runner is already registered on this Mac. Keep `.runner/run.sh` running while GitHub Actions executes jobs. Treat the runner as trusted because repository code runs directly on the Mac. No cloud account or hosted registry is used in deployment; GitHub orchestrates local commands and stores CI results.

## Model and security

`model/manifest.json` pins the Qwen/Qwen2.5-0.5B-Instruct-GGUF revision, the Q4_K_M filename, the 491400032-byte size, and SHA-256 from Hugging Face metadata. The model is Apache-2.0 and has 0.49 billion parameters. A one-time Kubernetes Job downloads weights into a 1 GiB PVC and checks the full SHA-256 before atomic rename. The LLM container mounts the weights read-only and has no hosted inference dependency. The CronJob rechecks the SHA-256 and runs two fixed prompts daily at 03:00 UTC; check status with `kubectl -n app-dev get cronjobs,jobs` and `kubectl -n app-dev logs job/<job-name>`.

Application pods are non-root with dropped capabilities, read-only root filesystems, seccomp, no service-account token, probes, and resource limits. Cilium enforces namespace default-deny policy and explicit service flows. The downloader alone has public HTTPS egress; its HTTP redirect/CDN path is a known broad egress exception. TLS material is generated locally and stored as a Kubernetes Secret. Secrets and state are gitignored; in a managed cluster, an external-secrets controller would fetch from a managed store. Traefik's Kind host port binds to `127.0.0.1`; the in-cluster IP allowlist is disabled because Colima source NAT makes the peer IP unreliable. ClusterIP services remain internal.

## Demo, rollback, teardown

Before presenting, verify `artifacts/dev-demo.txt` contains a real answer for `item-1`, show the model Job and CronJob, show HPA and scan/SBOM output, and run a negative ingress request from another container network source. Use `helm -n app-dev history app` and `helm -n app-dev rollback app <previous-revision> --wait` for rollback. Teardown: set `LOCAL_LLM_STATE_DIR=$HOME/.local/share/local-llm-devsecops` and `KUBECONFIG=$LOCAL_LLM_STATE_DIR/dev/kubeconfig`, run `helm -n app-dev uninstall app`, `helm -n ingress-system uninstall traefik`, `helm -n kube-system uninstall cilium metrics-server`, then `tofu -chdir=infra/cluster destroy -var-file="$PWD/environments/dev.tfvars" -var="kubeconfig_path=$KUBECONFIG"`. Run the corresponding commands for prod separately. Keep the local state directory until after destroy.

## Kind, pod access, and final verification

Run these commands after `./scripts/pipeline.sh release dev` to confirm that Kind, Kubernetes, and every application workload are working. Use `ENV=prod` and `PORT=9443` for the production environment.

```bash
ENV=dev
PORT=8443
STATE_ROOT="${LOCAL_LLM_STATE_DIR:-$HOME/.local/share/local-llm-devsecops}"
CLUSTER="llm-$ENV"
NAMESPACE="app-$ENV"
export KUBECONFIG="$STATE_ROOT/$ENV/kubeconfig"

# 1. Check that Kind and the Kubernetes context are available.
kind get clusters
kind get nodes --name "$CLUSTER"
kubectl config current-context
kubectl cluster-info --context "kind-$CLUSTER"

# 2. Check pods, deployments, services, jobs, ingress, and HPA.
kubectl -n "$NAMESPACE" get pods -o wide
kubectl -n "$NAMESPACE" get deployments,services,endpoints,ingress,jobs,cronjobs,hpa

# 3. Access a running gateway pod and inspect its health from inside the cluster.
POD="$(kubectl -n "$NAMESPACE" get pods -l app=gateway -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" describe pod "$POD"
kubectl -n "$NAMESPACE" logs "$POD" --tail=100
kubectl -n "$NAMESPACE" exec "$POD" -- python -c \
  'import urllib.request; print(urllib.request.urlopen("http://127.0.0.1:8000/healthz", timeout=10).read().decode())'

# 4. Verify rollout and the model download job.
kubectl -n "$NAMESPACE" wait --for=condition=complete job/model-download --timeout=900s
for deployment in gateway catalog assistant llm; do
  kubectl -n "$NAMESPACE" rollout status "deployment/$deployment" --timeout=600s
done

# 5. Verify the external HTTPS route and chat response.
curl --fail --silent --show-error \
  --cacert "$STATE_ROOT/$ENV/tls.crt" \
  --resolve "llm.local:$PORT:127.0.0.1" \
  "https://llm.local:$PORT/healthz"
curl --fail --silent --show-error \
  --cacert "$STATE_ROOT/$ENV/tls.crt" \
  --resolve "llm.local:$PORT:127.0.0.1" \
  "https://llm.local:$PORT/api/v1/items"
curl --fail --silent --show-error \
  --cacert "$STATE_ROOT/$ENV/tls.crt" \
  --resolve "llm.local:$PORT:127.0.0.1" \
  -H 'Content-Type: application/json' \
  --data '{"question":"Summarize this item in one sentence","item_id":"item-1"}' \
  "https://llm.local:$PORT/api/v1/ask"

# 6. Run the complete repository smoke-test verification.
./scripts/demo.sh "$ENV"
```

For direct browser access without TLS setup, use a local port-forward in a separate terminal:

```bash
kubectl -n "$NAMESPACE" port-forward svc/gateway 18000:8000
# Open http://localhost:18000/ in the browser.
```

## Chat tracing and LangSmith

Application logs include a request ID, route, status, and latency without recording prompts or answers. This is local tracing for the assessment. [LangSmith](https://docs.smith.langchain.com/) sends traces to a hosted service, so it is deliberately not enabled in the local-only pipeline. Connecting it would require a separate opt-in configuration, an API key in a Kubernetes Secret, limited trace content, and an approved outbound route. No LangSmith connection has been tested or claimed.

## Design trade-offs and unfinished items

The release pipeline deploys directly to a local Kind cluster. It does not yet use GitOps, signed OCI images, or a private registry; `kind load docker-image` avoids a hosted registry. Base images and upstream llama.cpp source are pinned, but Python dependency ranges and chart packages need full lockfiles for stronger reproducibility. The Kubernetes application chart has a gateway HPA/PDB and readiness-gated rollout. The CPU-bound LLM runs one replica using one PVC; scaling it would require per-replica model volumes or shared read-only storage and a bounded concurrency budget. Observability currently consists of structured stdout logs, Prometheus-format application metrics, health probes, and Kubernetes Job status; a central log store, dashboard, and real alert rule remain to be added. A live negative IP test and a bad-release rollback need recording before submission.

## Cloud portability

| Local component | Managed equivalent | Main change |
| --- | --- | --- |
| Kind | Managed Kubernetes | Cluster upgrades, identity, multi-zone nodes |
| `kind load` | Private OCI registry | Signed immutable digest references and pull identity |
| Kubernetes Secret | Managed secret store | External Secrets and rotation |
| Traefik/self-signed TLS | Cloud load balancer/cert manager | Public certificate, trusted proxy chain, WAF |
| Local PVC | CSI block/shared storage | Storage class, backup, regional durability |
| stdout/metrics | Managed logging and monitoring | Retention, alerts, incident receiver |

## AI use

Codex was used to draft the service code, Kubernetes chart, pipeline, and documentation from the assessment. Representative prompts were “read the complete assessment” and “use this existing GitHub repo with GitHub Actions on my self-hosted Mac.” The lightweight CI checks and release smoke test provide verification evidence. Follow-up work includes a negative ingress test, a recorded rollback exercise, fully locked Python dependencies, and a broader dashboard/alerting stack.

Model: [Qwen model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF). Runtime: [llama.cpp](https://github.com/ggml-org/llama.cpp). Kind: [Kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/).

## License

Repository code is released under the [MIT License](LICENSE). The Qwen model weights are separately licensed under Apache-2.0 by their publisher; see the [model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF). Third-party tools and dependencies retain their own licenses.
