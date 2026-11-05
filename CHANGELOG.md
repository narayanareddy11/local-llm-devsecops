# Changelog

## 1.0.0

- Added a local web chat backed by Qwen 2.5 through llama.cpp.
- Added catalog, assistant, gateway, and model workloads for Kind/Kubernetes.
- Added Helm deployment, Cilium network policies, Traefik TLS ingress, and OpenTofu cluster setup.
- Added GitHub Actions parallel checks, local release, release-only retry, and Kubernetes diagnostics.
- Added focused application tests, container smoke test, and Trivy/SBOM full-scan stage.
- Added rollout-aware HTTPS health, catalog, browser UI, and chat smoke tests with diagnostic artifact uploads.
- Added a documented Mac browser demo using a local port-forward, example prompts, and troubleshooting guidance.
- Added MIT licensing for repository code.

The Qwen GGUF model is separately distributed under Apache-2.0; see `model/manifest.json` and the linked model card in the README.
