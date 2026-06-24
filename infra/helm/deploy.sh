#!/usr/bin/env bash
# Install in-cluster components AFTER Terraform has created the cluster.
# Kept out of Terraform's provider graph to avoid the kubernetes/helm
# chicken-and-egg on first apply (see infra/terraform/README.md).
set -euo pipefail

TIER="${1:-dev}"
MODEL="${2:-Qwen/Qwen2.5-7B-Instruct}"

# --- rag-db secret: generated Postgres password, never committed (SOC2 CC6) ---
# Idempotent. pgvector (POSTGRES_PASSWORD) and gateway (PGPASSWORD) both read it.
if ! kubectl get secret rag-db >/dev/null 2>&1; then
  echo "==> [$TIER] creating rag-db secret (generated Postgres password)"
  kubectl create secret generic rag-db --from-literal=password="$(openssl rand -hex 16)"
fi

echo "==> [$TIER] NVIDIA device plugin (exposes nvidia.com/gpu on the GPU nodes)"
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin >/dev/null 2>&1 || true
helm repo update >/dev/null
# The device-plugin chart's default nodeAffinity matches nvidia.com/gpu.present=true.
# The GPU node group sets that label in Terraform — but a node group scaled via the
# AWS CLI (gpu-pause/resume) is born from the launch template as it was at group
# creation, so the label can be missing until a terraform apply. Re-apply it here so
# the plugin schedules after a pause/resume (SE-6). Harmless if already set.
kubectl label nodes -l workload=inference nvidia.com/gpu.present=true --overwrite >/dev/null 2>&1 || true
helm upgrade --install nvdp nvdp/nvidia-device-plugin \
  --namespace kube-system \
  --set-json 'tolerations=[{"key":"nvidia.com/gpu","operator":"Exists","effect":"NoSchedule"}]'

echo "==> [$TIER] verify a GPU is allocatable"
kubectl get nodes -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.'nvidia\.com/gpu'

# --- vLLM serving -----------------------------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
if [ "$TIER" = "dev" ]; then
  echo "==> [$TIER] vLLM (Qwen2.5-7B) — applying manifests"
  kubectl apply -f "$HERE/vllm-dev.yaml"
  echo "    image (~10GB) + weights (~15GB) pull on first start; watch with:"
  echo "    kubectl get pods -l app=vllm -w"
else
  echo "==> [$TIER] vLLM at scale (70B/TP) — parameterized chart: next step"
fi
# embeddings + gateway charts: next in Sprint 2.
