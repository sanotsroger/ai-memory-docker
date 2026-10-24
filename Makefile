COMPOSE_FILE := docker-compose.yml
DATA_DIR := $(HOME)/.local/share/ai-memory
CONFIG_DIR := $(HOME)/.config/ai-memory
ENV_FILE := .env
ENV_EXAMPLE := .env.example

-include $(ENV_FILE)

VERSION ?= latest
PORT ?= 49374

SPOOL_DIR := $(DATA_DIR)/hook-spool
QUARANTINE_DIR := $(DATA_DIR)/quarentena-spool
HOOK_LOG := $(DATA_DIR)/logs/hook-client.log

# Arquivo de hooks de cada CLI. O formato JSON é o mesmo nos três
# (raiz .hooks, evento -> [{matcher, hooks:[{type,command}]}]); muda só o caminho:
# o Claude Code guarda os hooks dentro do settings.json geral, Codex e Grok usam
# arquivos dedicados. O diretório-raiz de cada um serve de sinal de "CLI instalado".
CLAUDE_DIR := $(HOME)/.claude
CLAUDE_SETTINGS := $(CLAUDE_DIR)/settings.json
CODEX_DIR := $(HOME)/.codex
CODEX_HOOKS := $(CODEX_DIR)/hooks.json
GROK_DIR := $(HOME)/.grok
GROK_HOOKS := $(GROK_DIR)/hooks/ai-memory.json

# Agentes que `make hooks` configura. Dá para restringir: make hooks AGENTS=codex
SUPPORTED_AGENTS := claude-code codex grok
AGENTS ?= $(SUPPORTED_AGENTS)
ifneq ($(filter-out $(SUPPORTED_AGENTS),$(AGENTS)),)
$(error AGENTS inválido: $(filter-out $(SUPPORTED_AGENTS),$(AGENTS)) — válidos: $(SUPPORTED_AGENTS))
endif

# Todos os eventos que o `ai-memory install-hooks` registra.
# SessionStart é obrigatório: os hooks de meio de sessão apenas ENFILEIRAM em
# hook-spool/, e é o session-start que drena a fila. Instalar só UserPromptSubmit
# (como fazia a versão anterior deste Makefile) empilha eventos que nunca são
# entregues — a captura fica parada indefinidamente, sem erro visível.
# Sem session-end, por sua vez, a sessão nunca fecha: não roda consolidação e o
# wiki fica sem páginas semânticas.
HOOK_EVENTS := \
	SessionStart:session-start \
	UserPromptSubmit:user-prompt-submit \
	PreToolUse:pre-tool-use \
	PostToolUse:post-tool-use \
	PreCompact:pre-compact \
	Stop:stop \
	SessionEnd:session-end \
	SubagentStart:subagent-start \
	SubagentStop:subagent-stop

# O Codex CLI não emite eventos de subagente: `install-hooks --agent codex` registra
# 7 eventos, e os dois restantes só poluiriam o hooks.json.
CODEX_HOOK_EVENTS := $(filter-out SubagentStart:% SubagentStop:%,$(HOOK_EVENTS))

# repo-root colapsa subdiretórios e worktrees no projeto da raiz do repositório
# (exige PROJECTS_DIR montado no container). Um .ai-memory.toml no repo ainda vence.
PROJECT_STRATEGY ?= repo-root

# Workaround nascido no ai-memory 2.1.0 (o changelog da 3.x não registra a correção,
# então segue no modo local): o drenador cria $(SPOOL_DIR)/.drain.lock e não o
# remove ao terminar. O lock órfão faz a drenagem seguinte desistir em silêncio
# (`retries: 0`, `pending` só crescendo), e a fila fica parada até alguém apagá-lo à mão.
# Por isso todo hook apaga antes um lock com mais de 1 minuto: uma drenagem real leva
# menos de um segundo, e o servidor já protege reentrega com chave de idempotência.

# --- Modo remoto ---------------------------------------------------------------
# Servidor: roda no host que expõe o ai-memory na rede (LXC atrás do Traefik).
SERVER_DIR := server
SERVER_ENV := $(SERVER_DIR)/.env.production
SERVER_COMPOSE := docker compose --project-directory $(SERVER_DIR) --env-file $(SERVER_ENV) -f $(SERVER_DIR)/docker-compose.yml

# Cliente: hooks nativos (binário ai-memory no host) falando HTTP com o servidor.
REMOTE_URL ?= https://memo.sanotsroger.com.br
TOKEN ?=

.PHONY: help init start stop restart logs status upgrade version doctor spool-unblock \
	hooks hooks-claude-code hooks-codex hooks-grok require-jq \
	server-init server-start server-stop server-logs server-upgrade server-backup \
	remote-client remote-doctor require-ai-memory

help:
	@echo "Uso (modo local):  make {init|start|stop|restart|logs|status|doctor|spool-unblock|hooks|upgrade|version}"
	@echo "Uso (servidor):    make {server-init|server-start|server-stop|server-logs|server-upgrade|server-backup}"
	@echo "Uso (cliente):     make {remote-client|remote-doctor}"
	@echo ""
	@echo "Exemplos:"
	@echo "  make init                    # Criar .env, diretórios e config padrão"
	@echo "  make start                   # Iniciar ai-memory"
	@echo "  make stop                    # Parar ai-memory"
	@echo "  make logs                    # Ver logs em tempo real"
	@echo "  make upgrade VERSION=2.2.0   # Atualizar para versão específica"
	@echo "  make upgrade                 # Atualizar para 'latest'"
	@echo "  make version                 # Mostrar versão rodando"
	@echo "  make doctor                  # Diagnosticar captura (fila de hooks, ingestão)"
	@echo "  make spool-unblock           # Destravar a fila de hooks parada por item inválido"
	@echo "  make hooks                   # Reinstalar os hooks (Claude Code, Codex e Grok)"
	@echo "  make hooks AGENTS=codex      # Reinstalar os hooks de um agente só"
	@echo ""
	@echo "  make server-init             # (servidor) .env.production com token novo + diretório de dados"
	@echo "  make server-start            # (servidor) subir o ai-memory exposto na rede"
	@echo "  make server-upgrade VERSION=3.2.2"
	@echo "  make server-backup           # (servidor) snapshot consistente em \$$SERVER_DATA_DIR"
	@echo "  make remote-client TOKEN=... # (cliente) hooks + MCP apontando para $(REMOTE_URL)"
	@echo "  make remote-doctor           # (cliente) status do servidor e da fila local de hooks"

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
	@mkdir -p $(dir $(HOOK_LOG))
	@if ! grep -q '^PROJECTS_DIR=' $(ENV_FILE) 2>/dev/null; then \
		printf '\n# Raiz dos repositórios montada no container (ver .env.example)\nPROJECTS_DIR=%s/Projects\n' "$(HOME)" >> $(ENV_FILE); \
		echo "✓ PROJECTS_DIR=$(HOME)/Projects adicionado a $(ENV_FILE)"; \
	fi
	@$(MAKE) --no-print-directory hooks

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

# Instala/atualiza TODOS os hooks de um agente apontando para o container.
# Idempotente: remove antes qualquer hook ai-memory já registrado no evento, e
# preserva hooks de outras ferramentas.
# stderr vai para $(HOOK_LOG) em vez de /dev/null — uma falha de entrega silenciosa
# já custou 6 dias de captura perdida.
#
# Por que montar o JSON aqui em vez de chamar `ai-memory install-hooks --apply`:
#  1. dentro do container HOME=/data, então o --apply escreve em
#     $(DATA_DIR)/.codex/hooks.json e não no ~/.codex do host;
#  2. o comando que ele gera aponta para /usr/local/bin/ai-memory, que só existe
#     dentro do container — teria de virar `docker exec` de qualquer forma.
#
# $(1) arquivo de hooks  $(2) agente (--agent)  $(3) eventos  $(4) rótulo  $(5) dir do CLI
define install_agent_hooks
	@if [ ! -d $(5) ]; then \
		echo "⚠ $(4) não detectado ($(5) ausente) — pulando"; \
	else \
		mkdir -p $(dir $(1)) $(dir $(HOOK_LOG)); \
		[ -f $(1) ] || echo '{}' > $(1); \
		cp $(1) $(1).bak; \
		for pair in $(3); do \
			agent_ev=$${pair%%:*}; aim_ev=$${pair#*:}; \
			cmd="find $(SPOOL_DIR)/.drain.lock -mmin +1 -delete 2>/dev/null; docker exec -i ai-memory ai-memory --data-dir /data hook --event $$aim_ev --agent $(2) --server-url http://127.0.0.1:$(PORT) --project-strategy $(PROJECT_STRATEGY) 2>>$(HOOK_LOG) || :"; \
			tmp=$$(mktemp); \
			jq --arg ev "$$agent_ev" --arg cmd "$$cmd" \
				'.hooks //= {} | .hooks[$$ev] = (((.hooks[$$ev] // []) | map(select(([.hooks[]?.command] | any(test("ai-memory .*hook --event"))) | not))) + [{"matcher":"","hooks":[{"type":"command","command":$$cmd}]}])' \
				$(1) > $$tmp && mv $$tmp $(1); \
		done; \
		echo "✓ $(words $(3)) hooks do $(4) instalados → $(1)"; \
		echo "  backup do arquivo anterior: $(1).bak"; \
	fi
endef

require-jq:
	@command -v jq >/dev/null 2>&1 || { echo "✗ jq não encontrado — instale jq e rode de novo"; exit 1; }

hooks: require-jq $(addprefix hooks-,$(AGENTS))
	@echo "  estratégia de projeto: $(PROJECT_STRATEGY)"
	@echo "  stderr dos hooks: $(HOOK_LOG)"

hooks-claude-code: require-jq
	$(call install_agent_hooks,$(CLAUDE_SETTINGS),claude-code,$(HOOK_EVENTS),Claude Code,$(CLAUDE_DIR))

# O Codex exige aprovação explícita de hooks novos: na primeira execução a TUI
# mostra "Hooks need review" — escolha "Trust all and continue".
hooks-codex: require-jq
	$(call install_agent_hooks,$(CODEX_HOOKS),codex,$(CODEX_HOOK_EVENTS),Codex CLI,$(CODEX_DIR))

# O Grok ignora o stdout do SessionStart: a captura funciona, mas a injeção de
# handoff não — recupere o handoff da sessão anterior pela tool MCP
# `memory_handoff_accept`.
hooks-grok: require-jq
	$(call install_agent_hooks,$(GROK_HOOKS),grok,$(HOOK_EVENTS),Grok CLI,$(GROK_DIR))

# Diagnóstico da captura. O modo de falha conhecido é silencioso: o drenador manda
# o spool em lote e o servidor é fail-fast, então um único item inválido no topo
# congela a fila inteira sem que o cliente reclame.
doctor:
	@echo "== container =="
	@docker ps --filter "name=ai-memory" --format "  {{.Names}}  {{.Status}}" | grep . || echo "  ✗ não está rodando"
	@echo "== o container enxerga os repositórios? =="
	@docker exec ai-memory sh -c 'test -d "$(PROJECTS_DIR)" && echo "  ✓ $(PROJECTS_DIR) montado" || echo "  ✗ $(PROJECTS_DIR) NÃO montado — o projeto será derivado de basename(cwd)"' 2>/dev/null || echo "  ✗ container indisponível"
	@echo "== ingestão =="
	@docker exec ai-memory ai-memory status 2>/dev/null | grep -E "pages:|sessions:|observations:|pending:|oldest:|last write:" || echo "  ✗ não foi possível consultar o status"
	@echo "== hooks registrados nos agentes =="
	@if command -v jq >/dev/null 2>&1; then \
		for t in "$(CLAUDE_SETTINGS):$(words $(HOOK_EVENTS)):Claude Code" \
			"$(CODEX_HOOKS):$(words $(CODEX_HOOK_EVENTS)):Codex CLI" \
			"$(GROK_HOOKS):$(words $(HOOK_EVENTS)):Grok CLI"; do \
			f=$${t%%:*}; rest=$${t#*:}; exp=$${rest%%:*}; label=$${rest#*:}; \
			if [ ! -f "$$f" ]; then echo "  $$label: não configurado ($$f ausente)"; continue; fi; \
			n=$$(jq '[.hooks // {} | to_entries[] | select([.value[]?.hooks[]?.command] | any(test("ai-memory .*hook --event")))] | length' "$$f"); \
			echo "  $$label: $$n de $$exp eventos"; \
			[ "$$n" -eq "$$exp" ] || echo "    → rode 'make hooks' (sem session-end não há consolidação, e o wiki fica sem páginas)"; \
		done; \
	else \
		echo "  ✗ jq não encontrado — não dá para inspecionar"; \
	fi
	@echo "== lock do drenador =="
	@if [ -f $(SPOOL_DIR)/.drain.lock ]; then \
		if [ -n "$$(find $(SPOOL_DIR)/.drain.lock -mmin +1 2>/dev/null)" ]; then \
			echo "  ⚠ .drain.lock obsoleto (>1min) — bloquearia a próxima drenagem; o próximo hook o remove"; \
		else \
			echo "  ✓ lock recente (drenagem em curso ou recém-concluída)"; \
		fi; \
	else \
		echo "  ✓ sem lock"; \
	fi
	@echo "  (pending > 0 é normal durante uma sessão: a fila drena no próximo SessionStart)"
	@echo "== itens inválidos na fila (bloqueiam todos os posteriores) =="
	@bad=0; for f in $(SPOOL_DIR)/*.json; do \
		[ -e "$$f" ] || continue; \
		ev=$$(jq -r '.url' "$$f" | sed -n 's/.*[?&]event=\([^&]*\).*/\1/p'); \
		sid=$$(jq -r '.body // "{}"' "$$f" | jq -r '.session_id // empty' 2>/dev/null); \
		if [ -z "$$sid" ] && [ "$$ev" != "session-start" ]; then \
			echo "  ✗ $$(basename $$f)  event=$$ev  (sem session_id)"; \
			bad=$$((bad+1)); \
		fi; \
	done; \
	if [ "$$bad" = "0" ]; then echo "  ✓ nenhum"; else echo "  → rode 'make spool-unblock'"; fi

# Move os itens que o servidor rejeita para quarentena e solta o lock do drenador.
# Nada é apagado: os arquivos ficam em $(QUARANTINE_DIR) para inspeção.
spool-unblock:
	@command -v jq >/dev/null 2>&1 || { echo "✗ jq não encontrado"; exit 1; }
	@mkdir -p $(QUARANTINE_DIR)
	@moved=0; for f in $(SPOOL_DIR)/*.json; do \
		[ -e "$$f" ] || continue; \
		ev=$$(jq -r '.url' "$$f" | sed -n 's/.*[?&]event=\([^&]*\).*/\1/p'); \
		sid=$$(jq -r '.body // "{}"' "$$f" | jq -r '.session_id // empty' 2>/dev/null); \
		if [ -z "$$sid" ] && [ "$$ev" != "session-start" ]; then \
			mv "$$f" $(QUARANTINE_DIR)/ && echo "  → quarentena: $$(basename $$f) (event=$$ev, sem session_id)"; \
		fi; \
	done
	@rm -f $(SPOOL_DIR)/.drain.lock
	@echo "✓ fila liberada — o próximo hook (próximo prompt em qualquer agente) drena o que ficou pendente"
	@echo "  confira depois com: make doctor"

# --- Modo remoto: servidor ------------------------------------------------------
# Rodam no host do servidor (ex.: LXC 138 em /opt/ai-memory-docker).

server-init:
	@if [ ! -f $(SERVER_ENV) ]; then \
		cp $(SERVER_ENV).example $(SERVER_ENV); chmod 600 $(SERVER_ENV); \
		echo "✓ $(SERVER_ENV) criado a partir de $(SERVER_ENV).example"; \
	fi
	@if grep -q '^AI_MEMORY_AUTH_TOKEN=$$' $(SERVER_ENV); then \
		ver=$$(sed -n 's/^VERSION=//p' $(SERVER_ENV)); \
		tok=$$(docker run --rm -e RUST_LOG=error akitaonrails/ai-memory:$${ver:-latest} generate-auth-token) || exit 1; \
		sed -i "s/^AI_MEMORY_AUTH_TOKEN=$$/AI_MEMORY_AUTH_TOKEN=$$tok/" $(SERVER_ENV); \
		echo "✓ token bearer gerado em $(SERVER_ENV) — guarde-o: os clientes usam em 'make remote-client TOKEN=...'"; \
	fi
	@dir=$$(sed -n 's/^SERVER_DATA_DIR=//p' $(SERVER_ENV)); dir=$${dir:-/var/opt/ai-memory/data}; \
		mkdir -p "$$dir" && chown 1000:1000 "$$dir" && echo "✓ dados em $$dir (dono 1000:1000)"

server-start: server-init
	$(SERVER_COMPOSE) up -d
	@echo "✓ ai-memory (servidor) iniciado — confira com: docker inspect -f '{{.State.Health.Status}}' ai-memory"

server-stop:
	$(SERVER_COMPOSE) down

server-logs:
	$(SERVER_COMPOSE) logs -f --tail=50

# Exige VERSION explícita: no servidor não há .env local, e o default do Makefile
# (latest) trocaria de versão sem querer.
server-upgrade:
	@[ "$(origin VERSION)" = "command line" ] || { echo "✗ informe a versão: make server-upgrade VERSION=x.y.z"; exit 1; }
	@cp $(SERVER_ENV) $(SERVER_ENV).backup
	@sed -i 's/^VERSION=.*/VERSION=$(VERSION)/' $(SERVER_ENV)
	@$(MAKE) --no-print-directory server-backup
	$(SERVER_COMPOSE) pull
	$(SERVER_COMPOSE) up -d
	@echo "✓ servidor em $(VERSION) (env anterior em $(SERVER_ENV).backup)"

# Snapshot pela API de backup online do SQLite: coerente mesmo com o servidor no ar.
server-backup:
	docker exec ai-memory ai-memory backup --to /data/snapshot-$$(date +%F-%H%M).tar.gz
	@echo "✓ snapshot em \$$SERVER_DATA_DIR/snapshot-*.tar.gz"

# --- Modo remoto: cliente -------------------------------------------------------
# Usa o binário nativo (no Arch: paru -S ai-memory-bin). Os hooks rodam no host,
# então enxergam o .git direto e dispensam o PROJECTS_DIR do modo local; a fila
# (hook-spool) fica no data dir do cliente e drena quando o servidor responde.
# O install-hooks guarda o token em <data_dir>/auth-token, que o bridge MCP do
# Claude Code (--session-aware) também lê: nada de token no ~/.claude.json.
# Cuidado: com AI_MEMORY_AUTH_TOKEN exportado no shell, o install-mcp trata o
# token como explícito e o grava no ~/.claude.json, por isso o env -u.
# O <data_dir>/config.toml aponta o CLI avulso (status, search...) para o mesmo
# servidor e token; sem ele o CLI tenta 127.0.0.1.
CLIENT_DATA_DIR := $(DATA_DIR)
CLIENT_CONFIG := $(CLIENT_DATA_DIR)/config.toml

require-ai-memory:
	@command -v ai-memory >/dev/null 2>&1 || { echo "✗ ai-memory não encontrado — no Arch: paru -S ai-memory-bin"; exit 1; }

remote-client: require-ai-memory
	@for a in $(AGENTS); do \
		case $$a in claude-code) d=$(CLAUDE_DIR);; codex) d=$(CODEX_DIR);; grok) d=$(GROK_DIR);; esac; \
		if [ ! -d "$$d" ]; then echo "⚠ $$a não detectado ($$d ausente) — pulando"; continue; fi; \
		env -u AI_MEMORY_AUTH_TOKEN ai-memory install-hooks --agent $$a --apply --server-url $(REMOTE_URL) \
			$(if $(TOKEN),--auth-token $(TOKEN)) --project-strategy $(PROJECT_STRATEGY) || exit 1; \
		if [ $$a = claude-code ]; then \
			env -u AI_MEMORY_AUTH_TOKEN ai-memory install-mcp --client claude-code --session-aware --apply --server-url $(REMOTE_URL) || exit 1; \
		else \
			env -u AI_MEMORY_AUTH_TOKEN ai-memory install-mcp --client $$a --apply --server-url $(REMOTE_URL) || exit 1; \
		fi; \
		echo "✓ $$a → $(REMOTE_URL)"; \
	done
	@if [ -f $(CLIENT_CONFIG) ] && ! grep -q '^server_url = "$(REMOTE_URL)"' $(CLIENT_CONFIG); then \
		echo "⚠ $(CLIENT_CONFIG) já existe e não aponta para $(REMOTE_URL) — ajuste server_url à mão"; \
	elif [ ! -f $(CLIENT_CONFIG) ]; then \
		printf 'server_url = "%s"\n\n[auth]\nbearer_token_file = "auth-token"\n' "$(REMOTE_URL)" > $(CLIENT_CONFIG); \
		echo "✓ $(CLIENT_CONFIG): CLI avulso aponta para $(REMOTE_URL) com o token do auth-token"; \
	fi

remote-doctor: require-ai-memory
	@echo "== servidor =="
	@code=$$(curl -s -o /dev/null -w '%{http_code}' $(REMOTE_URL)/handoff); \
		case $$code in 401) echo "  ✓ $(REMOTE_URL) responde e exige token";; \
		200) echo "  ⚠ $(REMOTE_URL) responde SEM exigir token";; \
		*) echo "  ✗ $(REMOTE_URL)/handoff → HTTP $$code";; esac
	@echo "== status (servidor + fila local de hooks) =="
	@RUST_LOG=warn ai-memory status
