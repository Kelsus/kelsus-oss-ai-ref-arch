# Kelsus Sovereign Reference Architecture — task runner
# Uses terraform if installed, else opentofu (tofu). Both read the same .tf.
TF      ?= $(shell command -v terraform 2>/dev/null || command -v tofu 2>/dev/null)
PROFILE ?= kelsus-dev
REGION  ?= us-east-1
MODEL   ?= Qwen/Qwen2.5-7B-Instruct

TF_DEV   = $(TF) -chdir=infra/terraform/envs/dev
TF_SCALE = $(TF) -chdir=infra/terraform/envs/scale

.DEFAULT_GOAL := help
.PHONY: help login fmt validate \
        tf-dev-init tf-dev-plan tf-dev-apply tf-dev-destroy \
        tf-scale-init tf-scale-plan tf-scale-apply tf-scale-destroy \
        kubeconfig-dev gpu-pause gpu-resume seed-model deploy-dev deploy-scale smoke bench \
        data-synthea data-fatura data-corpus

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

login: ## SSO login to the AWS profile
	aws sso login --profile $(PROFILE)
	AWS_PROFILE=$(PROFILE) aws sts get-caller-identity

fmt: ## Format all Terraform
	$(TF) -chdir=infra/terraform fmt -recursive

validate: ## Validate both envs
	cd infra/terraform/envs/dev && $(TF) init -backend=false >/dev/null && $(TF) validate
	cd infra/terraform/envs/scale && $(TF) init -backend=false >/dev/null && $(TF) validate

# --- dev tier ---------------------------------------------------------------
tf-dev-init: ## terraform init (dev)
	$(TF_DEV) init
tf-dev-plan: ## terraform plan (dev)
	$(TF_DEV) plan
tf-dev-apply: ## Provision dev VPC + EKS + 1x GPU node group
	$(TF_DEV) apply
tf-dev-destroy: ## Tear down the dev tier (stop the GPU meter)
	$(TF_DEV) destroy

kubeconfig-dev: ## Point kubectl at the dev cluster
	aws eks update-kubeconfig --name kelsus-refarch-dev --region $(REGION) --profile $(PROFILE)

# GPU on/off, Karpenter edition. The GPU node exists only because the vLLM pod
# wants it: scale vLLM to 0 and Karpenter consolidates the empty node away
# (~5 min); scale to 1 and Karpenter provisions a g6e node (~1-2 min) + model
# load (~8 min). The nightly CronJob (gpu-nightly-off.yaml) enforces pause at
# 06:00 UTC as the dead-man backstop.
gpu-pause: ## Stop GPU spend: scale vLLM to 0; Karpenter removes the node ~5 min later
	kubectl scale deploy/vllm --replicas=0
	@echo "vLLM scaled to 0 — Karpenter consolidates the GPU node away in ~5 min."
gpu-resume: ## Bring the GPU back: scale vLLM to 1 (Karpenter provisions; ~10 min to serving)
	kubectl scale deploy/vllm --replicas=1
	@echo "vLLM scaled to 1 — Karpenter provisions a g6e node; model serving in ~10 min."

# --- scale tier -------------------------------------------------------------
tf-scale-init: ## terraform init (scale)
	$(TF_SCALE) init
tf-scale-plan: ## terraform plan (scale)
	$(TF_SCALE) plan
tf-scale-apply: ## Provision the g6e.12xlarge benchmark tier (no egress, private API)
	$(TF_SCALE) apply
tf-scale-destroy: ## Tear down the scale tier
	$(TF_SCALE) destroy

# --- serving + apps (Helm; cluster must exist) ------------------------------
seed-model: ## One-time: pull model weights into the in-account S3 bucket (build-time egress only)
	./serving/seed-model.sh "$(MODEL)" "$(PROFILE)" "$(REGION)"
deploy-dev: ## Install nvidia-device-plugin + vLLM (small model) + embeddings + gateway
	./infra/helm/deploy.sh dev "$(MODEL)"
deploy-scale: ## Deploy serving at scale tier with MODEL=<candidate>
	./infra/helm/deploy.sh scale "$(MODEL)"
smoke: ## One request end-to-end through the internal ALB
	./bench/smoke.sh
chat: ## Send a prompt to the running vLLM endpoint: make chat PROMPT="your question"
	@bash serving/chat.sh "$(PROMPT)"
webui: ## Open the browser chat UI (Open WebUI) at http://localhost:8080
	@echo "==> Open WebUI -> http://localhost:8080   (Ctrl-C here to close the tunnel)"
	kubectl port-forward --address 127.0.0.1 svc/open-webui 8080:8080

# --- Sovereign RAG (App 2) --------------------------------------------------
rag-init: ## Create the pgvector schema
	@bash apps/sovereign-rag/run-local.sh init
rag-ingest: ## Fetch the regulated-finance corpus and embed it into pgvector
	@python3 data/corpus/build.py
	@bash apps/sovereign-rag/run-local.sh ingest data/corpus/seed
rag-ask: ## Ask the sovereign RAG app: make rag-ask Q="your question"
	@bash apps/sovereign-rag/run-local.sh ask "$(Q)"

# --- Claims/Invoice Intake (App 1) ------------------------------------------
extract: ## Extract fields from synthetic invoices and score vs gold: make extract N=20
	@bash apps/claims-intake/run-local.sh $(or $(N),20)

# --- Gateway (in-cluster API for both apps) ---------------------------------
gateway-deploy: ## (Re)deploy the in-cluster gateway from apps/gateway/app.py
	@bash apps/gateway/deploy.sh
ask: ## Ask the gateway RAG endpoint: make ask Q="your question"
	@bash apps/gateway/call.sh ask "$(Q)"
extract-api: ## Extract one invoice via the gateway: make extract-api PDF=path/to.pdf
	@bash apps/gateway/call.sh extract "$(PDF)"
bench: ## In-cluster cost/latency benchmark -> bench/reports/runs/<ts>/
	@bash bench/run.sh $(CONFIG)
sweep: ## Multi-model cost/latency sweep (swaps the served model; restores it after)
	@bash bench/sweep.sh $(MODELS)
quality-sweep: ## Multi-model quality sweep: extraction F1 + RAG (swaps model; restores after)
	@bash bench/quality-sweep.sh $(MODELS)
quality-incluster: ## Submit the quality eval as an in-cluster Job (detached; survives laptop/SSO death)
	@bash bench/run-quality-incluster.sh
status: ## Show the latest durable run status (from S3; survives laptop/watcher death)
	@AWS_PROFILE=$(PROFILE) bash bench/status.sh get
quality-results: ## Fetch the latest in-cluster quality result from S3
	@ACCOUNT=$$(aws sts get-caller-identity --profile $(PROFILE) --query Account --output text); \
	KEY=$$(aws s3api list-objects-v2 --bucket kelsus-refarch-models-dev-$$ACCOUNT --prefix results/quality/ --profile $(PROFILE) --query 'sort_by(Contents,&Key)[-1].Key' --output text); \
	[ "$$KEY" != "None" ] || { echo "no results yet"; exit 1; }; \
	echo "latest: $$KEY"; \
	aws s3 cp s3://kelsus-refarch-models-dev-$$ACCOUNT/$$KEY - --profile $(PROFILE) | python3 -m json.tool

# --- synthetic data (ADR-0004) ----------------------------------------------
data-synthea: ## Generate synthetic patients + claims -> CMS-1500/EOB PDFs
	./data/synthea/generate.sh
data-fatura: ## Build the FATURA commercial-invoice eval (real layouts) + gold
	python3 data/fatura/build.py $(or $(N),120)
data-corpus: ## Build the SEC EDGAR + NIST RAG corpus
	python3 data/corpus/build.py
