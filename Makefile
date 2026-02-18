# =============================================================================
# Makefile — Local Development Commands
# =============================================================================

.PHONY: up down logs shell db-reset clean help

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
