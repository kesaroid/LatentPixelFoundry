# =============================================================================
# Makefile — Local Development & Deployment Commands
# =============================================================================

.PHONY: up down logs shell db-reset clean help
.PHONY: worker-init worker-up worker-down worker-stop worker-start
.PHONY: worker-status worker-ssh worker-tunnel worker-logs

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

up: ## Start all services (postgres + backend)
	docker-compose up --build

up-d: ## Start all services in background
	docker-compose up --build -d

down: ## Stop all services
	docker-compose down

down-v: ## Stop all services and remove volumes (deletes DB data)
	docker-compose down -v

logs: ## Tail backend logs
	docker-compose logs -f backend

logs-all: ## Tail all service logs
	docker-compose logs -f

shell: ## Open a shell in the backend container
	docker-compose exec backend /bin/bash

db-reset: ## Drop and recreate the database (destructive!)
	docker-compose exec postgres psql -U videogen -c "DROP DATABASE IF EXISTS videogen;"
	docker-compose exec postgres psql -U videogen -d postgres -c "CREATE DATABASE videogen;"
	docker-compose restart backend
	@echo "Database reset complete. Backend restarting..."

clean: ## Remove generated videos
	rm -f backend/generated_videos/*.mp4
	@echo "Generated videos cleaned."

status: ## Show running containers
	docker-compose ps

# =============================================================================
# GPU Worker Deployment (Vast.ai + ComfyUI)
# =============================================================================

worker-init: ## Create default Vast.ai config at infra/worker.conf
	./deploy-worker.sh init

worker-up: ## Launch GPU instance on Vast.ai with ComfyUI + LTX-2
	./deploy-worker.sh up

worker-down: ## Destroy Vast.ai instance (irreversible, deletes data)
	./deploy-worker.sh down

worker-stop: ## Stop Vast.ai instance (preserves data, small storage fee)
	./deploy-worker.sh stop

worker-start: ## Start a stopped Vast.ai instance
	./deploy-worker.sh start

worker-status: ## Show Vast.ai instance info (GPU, status, cost)
	./deploy-worker.sh status

worker-ssh: ## SSH into the Vast.ai instance
	./deploy-worker.sh ssh

worker-tunnel: ## Open SSH tunnel for ComfyUI (localhost:8188)
	./deploy-worker.sh tunnel

worker-logs: ## View Vast.ai instance logs
	./deploy-worker.sh logs
