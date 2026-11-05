terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kind = { source = "tehcyx/kind", version = "0.13.0" }
  }
  backend "local" {}
}

variable "environment" { type = string }
variable "https_port" { type = number }
variable "kubeconfig_path" { type = string }

resource "kind_cluster" "local" {
  name            = "llm-${var.environment}"
  node_image      = "kindest/node:v1.35.8@sha256:07b2536e30b803ed61d1677a79df6115f798ce64c80f9e22f6ed45afd09323c0"
  kubeconfig_path = var.kubeconfig_path
  wait_for_ready  = false

  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    networking { disable_default_cni = true }
    node {
      role = "control-plane"
      extra_port_mappings {
        container_port = 30443
        host_port      = var.https_port
        listen_address = "127.0.0.1"
      }
    }
  }
}

output "context" { value = kind_cluster.local.context_name }

