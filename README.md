# ai-memory via Docker

Setup do [ai-memory](https://github.com/akitaonrails/ai-memory) rodando em container, com Makefile para gerenciar o ciclo de vida e integração com o Claude Code, o Codex CLI e o Grok CLI.

## Pré-requisitos

- Docker + Docker Compose
- make
- jq (usado por `make init` para configurar os hooks dos agentes)
- ~500MB de espaço em disco

## Setup

Clone o repositório (docker-compose.yml e Makefile já vêm com ele):

```bash
git clone https://github.com/sanotsroger/ai-memory-docker.git
cd ai-memory-docker
make start
```

`make start` cria `.env` a partir de `.env.example`, os diretórios de dados, o `config.toml` padrão, instala os hooks de captura em cada agente instalado (Claude Code, Codex CLI e Grok CLI) e sobe o container.

Verificar:

```bash
make status
# ai-memory   Up 2 minutes (healthy)   127.0.0.1:49374->49374/tcp
```

## Agentes

O ai-memory se integra a cada CLI por dois caminhos independentes: o **servidor MCP** (o agente consulta e escreve memória) e os **hooks de ciclo de vida** (a sessão é capturada automaticamente). Os dois precisam ser configurados.

### Servidor MCP

**Claude Code** (escopo `user`, disponível em todos os projetos):

```bash
claude mcp add --transport http ai-memory http://127.0.0.1:49374/mcp -s user
claude mcp list
# ai-memory: http://127.0.0.1:49374/mcp (HTTP) - ✔ Connected
```

**Codex CLI** e **Grok CLI** usam arquivos TOML. Peça o trecho pronto ao próprio ai-memory e cole no arquivo indicado:

```bash
docker exec ai-memory ai-memory install-mcp --client codex   # → ~/.codex/config.toml
docker exec ai-memory ai-memory install-mcp --client grok    # → ~/.grok/config.toml, [mcp_servers.<nome>]
```

### Hooks de captura automática

`make init` (ou `make hooks`) registra os hooks de cada agente, cada um rodando `docker exec ai-memory ai-memory hook ...`:

| Agente | Arquivo | Eventos |
|---|---|---|
| Claude Code | `~/.claude/settings.json` (chave `hooks`) | 9 |
| Codex CLI | `~/.codex/hooks.json` | 7 |
| Grok CLI | `~/.grok/hooks/ai-memory.json` | 9 |

Os 9 eventos são `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`, `SessionEnd`, `SubagentStart` e `SubagentStop`. O Codex não emite eventos de subagente, então lá são 7.

Um agente cujo diretório de configuração não existe (`~/.codex`, `~/.grok`) é **pulado com aviso** — instale o CLI e rode `make hooks` de novo. Para configurar um agente só: `make hooks AGENTS=codex`.

O arquivo anterior é sempre salvo com sufixo `.bak`, e apenas entradas do próprio ai-memory são substituídas: hooks de outras ferramentas ficam intactos. Rodar `make hooks` várias vezes não duplica nada.

> **`SessionStart` é obrigatório.** Os hooks de meio de sessão apenas enfileiram em `hook-spool/`; quem drena a fila é o `session-start`. Instalar só o `UserPromptSubmit` — o que este Makefile fazia até então — empilha eventos que nunca chegam ao servidor: a captura fica parada indefinidamente, sem nenhum erro visível. E sem `session-end` a sessão nunca fecha, então a consolidação não roda e o wiki fica sem páginas semânticas, só com log episódico.

> Durante uma sessão longa é normal ver `pending` crescendo em `make doctor` — a fila esvazia no início da próxima sessão.

Como os hooks passam pelo container, eles falham sem travar o prompt se o `ai-memory` estiver parado. O stderr vai para `~/.local/share/ai-memory/logs/hook-client.log` (e não para `/dev/null`) — se a captura parecer ter parado, rode `make doctor`.

#### Ressalvas por agente

**Codex CLI** — o Codex exige aprovação explícita de hooks novos. Na primeira execução depois do `make hooks`, a TUI mostra *"Hooks need review"* para cada evento: escolha **"Trust all and continue"** (ou confie um a um). Para instalações automatizadas existe o `codex --dangerously-bypass-hook-trust`, mas revise os hooks antes de usá-lo.

**Grok CLI** — o Grok ignora o stdout do `SessionStart`. A captura funciona normalmente, mas a **injeção de handoff não**: o contexto da sessão anterior não é prependado sozinho. Recupere-o pela tool MCP `memory_handoff_accept`.

#### Por que o Makefile monta o JSON em vez de usar `install-hooks --apply`

O `ai-memory install-hooks --apply` sabe escrever os três arquivos sozinho, mas não serve neste setup:

1. dentro do container `HOME=/data`, então o `--apply` escreveria em `~/.local/share/ai-memory/.codex/hooks.json` em vez do `~/.codex` do host;
2. o comando que ele gera aponta para `/usr/local/bin/ai-memory`, que só existe dentro do container — teria de virar `docker exec` de qualquer forma.

Por isso o `make hooks` monta o JSON no host com `jq`, no mesmo formato que o `install-hooks` produz.

### Escopo do projeto (PROJECTS_DIR)

Os hooks rodam **dentro** do container, então o `cwd` que o Claude Code envia só é útil se o container enxergar a mesma árvore no mesmo caminho absoluto. Por isso o `docker-compose.yml` monta `PROJECTS_DIR` read-only, e os hooks usam `--project-strategy repo-root`.

Sem isso, o roteador não acha o `.git` nem o `.ai-memory.toml` e cai em `basename(cwd)`: abrir uma sessão em `meu-repo/scripts/sqlserver` cria um projeto chamado `sqlserver`, e a memória do repositório se divide em dois escopos que não se enxergam.

`make init` grava `PROJECTS_DIR=$HOME/Projects` no `.env` se ainda não existir — ajuste se seus repositórios ficam em outro lugar (precisa ser caminho absoluto; `~` não é expandido).

## Comandos

```bash
make start                   # subir
make stop                    # parar
make restart                 # reiniciar
make logs                    # logs em tempo real
make status                  # status do container
make doctor                  # diagnóstico da captura (fila, ingestão, hooks por agente, montagem)
make spool-unblock           # destrava a fila parada por item inválido
make hooks                   # reinstala os hooks em todos os agentes instalados
make hooks AGENTS=codex      # reinstala os hooks de um agente só
make version                 # versão rodando
make upgrade VERSION=2.2.0   # atualizar para uma versão específica
make upgrade                 # atualizar para latest
```

`upgrade` atualiza `VERSION` em `.env` (com backup em `.env.backup`), puxa a imagem nova e reinicia. Alternativa manual: editar `VERSION` em `.env` e rodar `docker compose pull && docker compose up -d`.

## Dados

- `~/.local/share/ai-memory/wiki/` — notas/wiki
- `~/.local/share/ai-memory/db/` — banco SQLite
- `~/.local/share/ai-memory/raw/` — dados brutos
- `~/.config/ai-memory/config.toml` — configuração

Backup e restore:

```bash
tar -czf ~/ai-memory-backup-$(date +%Y%m%d).tar.gz ~/.local/share/ai-memory
tar -xzf ~/ai-memory-backup-*.tar.gz -C ~
```

## Troubleshooting

**Container não inicia** — cheque `make logs` e se a porta já está em uso: `lsof -i :49374`. Se sim, pare o processo que a está usando ou mude `PORT` no `.env`.

**Conexão recusada** — `curl http://localhost:49374/health`; se falhar, aguarde a inicialização (até ~30s) e olhe `make logs`.

**A captura parou (wiki não cresce)** — rode `make doctor`. O modo de falha conhecido é silencioso: o drenador envia o `hook-spool` em lote e em ordem, e o servidor é *fail-fast* — um único item inválido no topo (payload sem `session_id` cujo evento não é `session-start`, típico de um `ai-memory hook` rodado à mão sem stdin) aborta o lote inteiro e congela todos os eventos posteriores, indefinidamente. O cliente não reclama; o erro só aparece em `~/.local/share/ai-memory/logs/ai-memory.log.<data>`:

```
WARN hook batch item failed; stopping (fail-fast)
     error=hook payload missing session_id and event is not session-start  accepted=0
```

**A fila não drena nem no `SessionStart`** — o `ai-memory` 2.1.0 cria `hook-spool/.drain.lock` ao drenar e **não o remove ao terminar**. O lock órfão faz a drenagem seguinte desistir em silêncio (`retries: 0`, `pending` só crescendo, `last write` congelado), então a fila fica parada até alguém apagá-lo à mão. Por isso os hooks instalados por `make hooks` vêm prefixados com:

```sh
find ~/.local/share/ai-memory/hook-spool/.drain.lock -mmin +1 -delete 2>/dev/null; docker exec -i ai-memory ...
```

Um lock com mais de 1 minuto é sempre órfão (uma drenagem real leva menos de um segundo) e o servidor protege reentrega com chave de idempotência, então remover é seguro; locks recentes são preservados para não atropelar uma drenagem em curso.

`make spool-unblock` move os itens rejeitados para `~/.local/share/ai-memory/quarentena-spool/` (não apaga) e solta o `.drain.lock`; a fila volta a drenar no próximo hook. Sinais de fila travada em `make doctor`: `pending` crescendo, `oldest` de horas ou dias, `last write: -`.

**Os hooks do Codex estão no `hooks.json` mas nada é capturado** — o Codex exige aprovação de hooks novos. Rode `codex` e responda *"Hooks need review"* com **"Trust all and continue"**; enquanto os hooks não forem confiados, eles simplesmente não executam. Confira depois com `make doctor` (`pending`/`observations` devem voltar a subir).

**A memória do repositório aparece dividida em dois projetos** — é o `PROJECTS_DIR` ausente (ver acima). Depois de corrigir a montagem, sessões já gravadas no escopo errado podem ser movidas com:

```bash
docker exec ai-memory ai-memory move-session \
  --from-project ESCOPO_ERRADO --to PROJETO_CERTO --confirm
```

**Resetar dados** (destrutivo):

```bash
make stop
rm -rf ~/.local/share/ai-memory/*
make start
```

## Segurança

A porta é publicada só em `127.0.0.1` (ver `docker-compose.yml`), então não é acessível pela rede local por padrão. Para expor na LAN, mude o bind para `0.0.0.0:${PORT:-49374}:49374` — só faça isso se confiar na rede, e considere configurar `AI_MEMORY_AUTH_TOKEN` (`ai-memory generate-auth-token`), já que por padrão o servidor não exige autenticação.

## Versões

Tags disponíveis em <https://hub.docker.com/r/akitaonrails/ai-memory/tags>. `2.1.0` é a versão default do `.env.example`.

## Créditos

Este repositório é só o empacotamento em Docker/Makefile em cima do [ai-memory](https://github.com/akitaonrails/ai-memory), criado por [Fabio Akita (akitaonrails)](https://github.com/akitaonrails). Todo o servidor MCP, o storage, os hooks e a wiki vêm de lá — para dúvidas sobre o funcionamento interno do ai-memory em si, consulte o repositório original.

Leitura sobre o projeto, no blog do autor ([akitaonrails.com](https://akitaonrails.com/)):

- [Criei um Sistema de Memória pra Agentes de Código: ai-memory](https://akitaonrails.com/2026/05/23/criei-sistema-memoria-agentes-codigo-ai-memory/)
- [Memória de Agentes IA: Karpathy LLM Wiki e agentmemory na Prática](https://akitaonrails.com/2026/05/18/memoria-agentes-karpathy-llm-wiki-agentmemory/)
- [ai-memory: arquitetura emergente e software maleável](https://akitaonrails.com/2026/06/14/ai-memory-arquitetura-emergente-e-software-maleavel/)
- [ai-memory: memória de longo prazo (Karpathy Wiki) e auto-aprendizado (Hermes) pros seus projetos](https://akitaonrails.com/2026/06/16/ai-memory-memoria-longo-prazo-karpathy-wiki-auto-aprendizado-hermes-projetos/)
- [Novidades no meu AI-MEMORY: cada vez melhor pra usar com suas IAs](https://akitaonrails.com/2026/07/20/novidades-no-meu-ai-memory-cada-vez-melhor-pra-usar-com-suas-ias/)
- [AI-MEMORY 2.0 - o melhor sistema de memória para agentes e times](https://akitaonrails.com/2026/09/02/ai-memory-2-0-melhor-sistema-memoria-agentes-e-times/)
