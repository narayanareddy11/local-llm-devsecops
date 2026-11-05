# Local LLM DevSecOps deployment

This repository implements the take-home assessment as a laptop-only proof of concept. It uses three FastAPI services, a CPU-only `llama.cpp` workload, Kind, Cilium, Traefik, OpenTofu-compatible IaC, and a self-hosted GitHub Actions runner on macOS ARM64. The private catalog and inference services use ClusterIP only. The only public route is the gateway through TLS.

```text
Mac localhost:8443 -> Traefik TLS/IP allowlist -> gateway
                                            |-> catalog
                                            |-> assistant -> catalog + llama.cpp -> model PVC
Hugging Face (one-time download only) -> Job -> model PVC
```

## Status and prerequisites

The repository includes application code, tests, pinned model metadata, images, a Kind cluster definition, Helm chart, a check/release script, and GitHub Actions workflow. A complete cluster and pipeline run has **not yet been verified** on this Mac; do not present it as a passing demo until the GitHub run and commands below pass. The current machine has an ARM64 Docker Desktop context; switch to open-source [Colima](https://colima.run/docs/installation/) before running this assessment. Allow at least 6 CPU cores, 8 GiB container VM memory, and 10 GiB free disk. Two full environments should run sequentially on an 8 GiB VM.

Install open-source Colima, Moby/Docker CLI, Kind, kubectl, Helm, OpenTofu, Trivy, Hadolint, uv, OpenSSL, and GitHub CLI. `brew install colima docker kind kubectl helm opentofu trivy hadolint uv gh` is a convenient setup on macOS. Use `colima start --cpu 6 --memory 8 --disk 40` and `docker context use colima`; then confirm `docker context show` says `colima`.

```bash
./scripts/pipeline.sh check       # quick interview proof on every push
./scripts/pipeline.sh release dev # manual Kubernetes demo
./scripts/pipeline.sh full        # separate complete image scan and SBOM run
```

GitHub Actions follows the example's shape: checkout, five independent check branches running in parallel, a verify gate, then a manually selected release or full scan. The check branches cover application tests/Ruff; Helm; OpenTofu/shell syntax; Dockerfiles/base digests; and model metadata/browser chat. Each job has no more than two steps. To deploy, open **Actions → Local DevSecOps CI CD → Run workflow**, select `release`, and keep the Mac runner online. Select `full` separately for Trivy and SBOM generation.

After release, open `https://llm.local:8443/` in a browser. Add `127.0.0.1 llm.local` to `/etc/hosts` if the name does not resolve. The local certificate is self-signed, so the browser will ask you to trust it for this demo. The page displays catalog items and sends questions to `/api/v1/ask`, which reaches the assistant and local model. To bypass ingress and TLS while diagnosing, run `KUBECONFIG=$HOME/.local/share/local-llm-devsecops/dev/kubeconfig kubectl -n app-dev port-forward svc/gateway 18000:8000` and open `http://localhost:18000/`.

`check` runs two representative tests, Ruff, Helm lint/render, and Hadolint when installed. `release` runs check first, builds the four images, smoke-tests the catalog container, plans and applies a Kind cluster, installs Cilium, Traefik, and metrics-server, loads images, deploys Helm, then performs the end-to-end demo. `full` separately runs all tests, Trivy IaC and image scans, and SPDX SBOM generation with a HIGH/CRITICAL vulnerability gate. Outputs go to ignored `artifacts/`. Persistent OpenTofu state, kubeconfig, and TLS key are stored outside the checkout at `$HOME/.local/share/local-llm-devsecops/<environment>` (override with `LOCAL_LLM_STATE_DIR`) so GitHub Actions checkout cleanup cannot erase them. If an existing Kind cluster has no state file, the release script reuses it and skips OpenTofu for that cluster; delete the cluster and rerun release to return it to IaC management.

Dev and prod use the same code with separate state directories, clusters, namespaces, and host ports (`8443`, `9443`). Add a third environment by copying a tfvars file, choosing a unique environment name and port, and adding the name to the script allowlists. This environment design isolates state but does not provide cloud-level failure isolation on one laptop.

## Self-hosted GitHub Actions

The workflow follows the example pipeline: a checkout job fans out to five independent checks, which run in parallel, then a verification gate enables the manually selected release or full scan. It requires a self-hosted macOS ARM64 runner with the `local-llm` label. The runner is already registered on this Mac. Keep `.runner/run.sh` running while GitHub Actions executes jobs. Treat the runner as trusted because repository code runs directly on the Mac. No cloud account or hosted registry is used in deployment; GitHub orchestrates local commands and stores CI results.

## Model and security

`model/manifest.json` pins the Qwen/Qwen2.5-0.5B-Instruct-GGUF revision, the Q4_K_M filename, the 491400032-byte size, and SHA-256 from Hugging Face metadata. The model is Apache-2.0 and has 0.49 billion parameters. A one-time Kubernetes Job downloads weights into a 1 GiB PVC and checks the full SHA-256 before atomic rename. The LLM container mounts the weights read-only and has no hosted inference dependency. The CronJob rechecks the SHA-256 and runs two fixed prompts daily at 03:00 UTC; check status with `kubectl -n app-dev get cronjobs,jobs` and `kubectl -n app-dev logs job/<job-name>`.

Application pods are non-root with dropped capabilities, read-only root filesystems, seccomp, no service-account token, probes, and resource limits. Cilium enforces namespace default-deny policy and explicit service flows. The downloader alone has public HTTPS egress; its HTTP redirect/CDN path is a known broad egress exception. TLS material is generated locally and stored as a Kubernetes Secret. Secrets and state are gitignored; in a managed cluster, an external-secrets controller would fetch from a managed store. The ingress IP allowlist is set to the Docker bridge gateway detected during release. This tests one local source, not a cloud firewall. The ClusterIP services remain internal.

## Demo, rollback, teardown

Before presenting, verify `artifacts/dev-demo.txt` contains a real answer for `item-1`, show the model Job and CronJob, show HPA and scan/SBOM output, and run a negative ingress request from another container network source. Use `helm -n app-dev history app` and `helm -n app-dev rollback app <previous-revision> --wait` for rollback. Teardown: set `LOCAL_LLM_STATE_DIR=$HOME/.local/share/local-llm-devsecops` and `KUBECONFIG=$LOCAL_LLM_STATE_DIR/dev/kubeconfig`, run `helm -n app-dev uninstall app`, `helm -n ingress-system uninstall traefik`, `helm -n kube-system uninstall cilium metrics-server`, then `tofu -chdir=infra/cluster destroy -var-file="$PWD/environments/dev.tfvars" -var="kubeconfig_path=$KUBECONFIG"`. Run the corresponding commands for prod separately. Keep the local state directory until after destroy.

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

Codex was used to draft the service code, Kubernetes chart, pipeline, and documentation from the assessment. Representative prompts were “read the complete assessment” and “use this existing GitHub repo with GitHub Actions on my self-hosted Mac.” I accepted the simple service boundaries and revised the model delivery path and ingress source handling during review. Tests and a live cluster run are required to validate generated code. Main risks are invented Kubernetes configuration, unsafe network policy assumptions, model licensing mistakes, and hallucinated demo evidence; this README states unverified work explicitly.

Model: [Qwen model card](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF). Runtime: [llama.cpp](https://github.com/ggml-org/llama.cpp). Kind: [Kind quick start](https://kind.sigs.k8s.io/docs/user/quick-start/).
