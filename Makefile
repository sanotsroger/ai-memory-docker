COMPOSE_FILE := docker-compose.yml
DATA_DIR := $(HOME)/.local/share/ai-memory
CONFIG_DIR := $(HOME)/.config/ai-memory
ENV_FILE := .env
ENV_EXAMPLE := .env.example

-include $(ENV_FILE)

VERSION ?= latest
PORT ?= 49374

CLAUDE_SETTINGS := $(HOME)/.claude/settings.json
HOOK_CMD := docker exec -i ai-memory ai-memory hook --event user-prompt-submit --agent claude-code --server-url http://127.0.0.1:$(PORT) 2>/dev/null || :

.PHONY: help init start stop restart logs status upgrade version

help:
	@echo "Uso: make {init|start|stop|restart|logs|status|upgrade|version}"
	@echo ""
	@echo "Exemplos:"
	@echo "  make init                    # Criar .env, diretórios e config padrão"
	@echo "  make start                   # Iniciar ai-memory"
	@echo "  make stop                    # Parar ai-memory"
	@echo "  make logs                    # Ver logs em tempo real"
	@echo "  make upgrade VERSION=2.2.0   # Atualizar para versão específica"
	@echo "  make upgrade                 # Atualizar para 'latest'"
	@echo "  make version                 # Mostrar versão rodando"

init:
	@if [ ! -f $(ENV_FILE) ]; then \
		cp $(ENV_EXAMPLE) $(ENV_FILE); \
		echo "✓ $(ENV_FILE) criado a partir de $(ENV_EXAMPLE)"; \
	fi
	@mkdir -p $(DATA_DIR)/wiki $(DATA_DIR)/raw $(DATA_DIR)/db $(DATA_DIR)/models
	@mkdir -p $(CONFIG_DIR)
	@if [ ! -f $(CONFIG_DIR)/config.toml ]; then \
		echo "Criando arquivo de configuração padrão..."; \
		printf '[server]\nbind = "0.0.0.0:$(PORT)"\ndata_dir = "/data"\n\n[logging]\nlevel = "info"\n\n[storage]\n# SQLite por padrão\ndatabase = "sqlite"\n' > $(CONFIG_DIR)/config.toml; \
		echo "✓ Configuração criada em $(CONFIG_DIR)/config.toml"; \
	fi
	@if ! command -v jq >/dev/null 2>&1; then \
		echo "⚠ jq não encontrado — pulando configuração do hook do Claude Code (instale jq e rode 'make init' de novo)"; \
	elif [ -f $(CLAUDE_SETTINGS) ]; then \
		tmp=$$(mktemp); \
		jq --arg cmd '$(HOOK_CMD)' \
			'.hooks.UserPromptSubmit = ((.hooks.UserPromptSubmit // []) | map(select(([.hooks[]?.command] | any(test("ai-memory .*hook --event user-prompt-submit"))) | not))) + [{"matcher":"","hooks":[{"type":"command","command":$$cmd}]}]' \
			$(CLAUDE_SETTINGS) > $$tmp && mv $$tmp $(CLAUDE_SETTINGS); \
		echo "✓ Hook UserPromptSubmit do Claude Code apontado para 'docker exec ai-memory'"; \
	else \
		echo "⚠ $(CLAUDE_SETTINGS) não existe — pulando configuração do hook (rode o Claude Code ao menos uma vez antes)"; \
	fi

start: init
	@echo "Iniciando ai-memory..."
	docker compose -f $(COMPOSE_FILE) up -d
	@echo "✓ ai-memory iniciado"
	@echo "URL: http://localhost:$(PORT)"

stop:
	@echo "Parando ai-memory..."
	docker compose -f $(COMPOSE_FILE) down
	@echo "✓ ai-memory parado"

restart: stop start

logs:
	docker compose -f $(COMPOSE_FILE) logs -f --tail=50

status:
	@if docker ps | grep -q ai-memory; then \
		echo "✓ ai-memory está rodando"; \
		docker ps --filter "name=ai-memory" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"; \
	else \
		echo "✗ ai-memory não está rodando"; \
	fi

upgrade:
	@echo "Atualizando para versão: $(VERSION)"
	@cp $(ENV_FILE) $(ENV_FILE).backup
	@if grep -q '^VERSION=' $(ENV_FILE); then \
		sed -i 's/^VERSION=.*/VERSION=$(VERSION)/' $(ENV_FILE); \
	else \
		echo "VERSION=$(VERSION)" >> $(ENV_FILE); \
	fi
	docker compose -f $(COMPOSE_FILE) pull
	$(MAKE) restart
	@echo "✓ Upgrade para $(VERSION) concluído"
	@echo "Backup salvo em: $(ENV_FILE).backup"

version:
	@echo "Versão rodando:"
	@docker compose -f $(COMPOSE_FILE) exec ai-memory ai-memory --version 2>/dev/null || echo "Não conseguiu obter versão"
