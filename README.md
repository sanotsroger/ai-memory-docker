# ai-memory via Docker

Setup do [ai-memory](https://github.com/akitaonrails/ai-memory) rodando em container, com Makefile para gerenciar o ciclo de vida e integração com o Claude Code, o Codex CLI e o Grok CLI.

Dois modos de uso:

| | Modo local | Modo remoto (homelab) |
|---|---|---|
| Servidor | container nesta máquina, em `127.0.0.1` | container num host da rede ([`server/`](server/)), atrás de um proxy TLS |
| Hooks | `docker exec ai-memory ai-memory hook ...` | binário nativo `ai-memory hook ...` no host |
| Escopo do projeto | precisa do `PROJECTS_DIR` montado no container | o hook já enxerga o `.git`, então não precisa de nada |
| Autenticação | nenhuma (loopback) | token bearer |
| Comandos | `make start`, `make hooks`, `make doctor` | `make server-*` no servidor, `make remote-client` / `make remote-doctor` no cliente |

O modo local é descrito logo abaixo. O remoto está em [Modo remoto (homelab)](#modo-remoto-homelab).

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

## Modo remoto (homelab)

Um único servidor na rede atende todas as máquinas. Cada cliente roda o binário nativo do ai-memory só como cliente HTTP: os hooks enfileiram os eventos no `hook-spool` local e drenam para o servidor (se ele estiver fora do ar, nada se perde e a fila drena quando ele voltar). O MCP do Claude Code usa o bridge `--session-aware`, que lê o token do data dir do cliente em vez de deixá-lo no `~/.claude.json`.

### Servidor

Num host com Docker (aqui, um LXC Alpine no Proxmox):

```bash
git clone https://github.com/sanotsroger/ai-memory-docker.git /opt/ai-memory-docker
cd /opt/ai-memory-docker
make server-start
```

O `make server-start` chama o `server-init`, que:

- cria `server/.env.production` (gitignored, chmod 600) a partir de [`server/.env.production.example`](server/.env.production.example);
- gera o `AI_MEMORY_AUTH_TOKEN` com `ai-memory generate-auth-token` se ele estiver vazio. **Guarde o token**, porque os clientes vão precisar dele;
- cria o diretório de dados (`SERVER_DATA_DIR`, por padrão `/var/opt/ai-memory/data`) com dono `1000:1000`, o usuário da imagem.

Depois sobe o [`server/docker-compose.yml`](server/docker-compose.yml) em `0.0.0.0:49374`, com healthcheck. Antes do primeiro start, revise no `.env.production`:

- `AI_MEMORY_ALLOWED_HOSTS`: todo nome ou IP pelo qual os clientes chegam ao servidor (o domínio público basta quando o proxy repassa o `Host`);
- `AI_MEMORY_AUTH__SECURE_COOKIE=true`: vale para quando o `/web` é servido em HTTPS pelo proxy. Tire se for acessar direto por HTTP.

**Proxy TLS.** O token viaja no header `Authorization`, então exponha o servidor só atrás de HTTPS. O ai-memory não serve nada em `/` (responde 404), porque a interface fica em `/web/`. Por isso o exemplo redireciona a raiz. Com o Traefik (file provider):

```yaml
http:
  routers:
    memo:
      entryPoints: ["https"]
      rule: "Host(`memo.sanotsroger.com.br`)"
      tls: {}
      middlewares: [memo-root-to-web]
      service: memo
  middlewares:
    memo-root-to-web:
      redirectRegex:
        regex: "^https://memo\\.sanotsroger\\.com\\.br/$"
        replacement: "https://memo.sanotsroger.com.br/web/"
  services:
    memo:
      loadBalancer:
        servers:
          - url: "http://<ip-do-servidor>:49374"
        passHostHeader: true
```

**Interface web.** O login em `/web/` é com usuário e senha. O token bearer vale só para MCP, hooks e CLI. Para criar o usuário `root`:

1. Ponha `AI_MEMORY_AUTH__INITIAL_ROOT_PASSWORD=<12+ caracteres>` no `.env.production` e rode `make server-start`.
2. Apague a linha e rode `make server-start` de novo, para a senha não ficar no ambiente do processo.
3. No primeiro login, a web obriga a trocar a senha.

Se perder a senha, siga o fluxo de recuperação (`AI_MEMORY_AUTH__RECOVERY_TOKEN`) do [guia do upstream](https://github.com/akitaonrails/ai-memory/blob/main/docs/install.md#human-password-bootstrap-and-recovery).

**LLM.** Sem provedor configurado, o servidor funciona com busca FTS5 e resumos por regras, sem custo. Para ligar a consolidação por LLM (handoffs e páginas da wiki melhores), descomente o bloco de LLM no `.env.production` e rode `make server-start` de novo. As opções e os custos estão na [documentação do upstream](https://github.com/akitaonrails/ai-memory/blob/main/docs/deploy.md#llm-provider-choices).

Comandos do servidor:

```bash
make server-start                  # sobe (idempotente)
make server-stop                   # derruba
make server-logs                   # logs em tempo real
make server-backup                 # snapshot online (SQLite + wiki) em $SERVER_DATA_DIR/snapshot-*.tar.gz
make server-upgrade VERSION=3.2.3  # backup, troca VERSION no .env.production, pull e recria
```

O `server-upgrade` exige `VERSION` explícita para não cair em `latest` sem querer.

### Cliente

1. Instale o binário nativo. No Arch: `paru -S ai-memory-bin`. Outras plataformas estão no [guia de instalação do upstream](https://github.com/akitaonrails/ai-memory/blob/main/docs/install.md).
2. Configure hooks e MCP de cada agente instalado:

   ```bash
   make remote-client TOKEN=<token-do-servidor>
   # outro servidor: make remote-client REMOTE_URL=https://outro.host TOKEN=...
   ```

   Para cada agente em `AGENTS` (Claude Code, Codex e Grok; os ausentes são pulados), o alvo roda:
   - `ai-memory install-hooks --apply --server-url $REMOTE_URL --auth-token $TOKEN --project-strategy repo-root`;
   - `ai-memory install-mcp --apply`, que no Claude Code é o bridge `--session-aware`.

   O token fica em `~/.local/share/ai-memory/auth-token`. Uma reinstalação posterior sem `TOKEN=` reaproveita esse token. O alvo também cria `~/.local/share/ai-memory/config.toml` com `server_url` e `[auth] bearer_token_file = "auth-token"`, para que o CLI avulso (`ai-memory status`, `search`...) fale com o mesmo servidor. Sem isso, ele tenta `127.0.0.1`.

   > Passe o token só por `TOKEN=`. Com `AI_MEMORY_AUTH_TOKEN` exportado no shell, o `install-mcp` trata o token como explícito e o grava em texto puro no `~/.claude.json` (e no backup `.claude.json.bak-*` ao lado). O `make remote-client` roda os instaladores com `env -u AI_MEMORY_AUTH_TOKEN` para evitar isso.
3. Abra uma sessão nova do agente e confira:

   ```bash
   make remote-doctor   # 401 sem token no /handoff + `ai-memory status` (servidor e fila local)
   claude mcp list      # ai-memory: ✔ Connected
   ```

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
make upgrade VERSION=3.2.2   # atualizar para uma versão específica
make upgrade                 # atualizar para latest
```

(Os comandos do modo remoto estão na [seção própria](#modo-remoto-homelab).)

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

No modo local, a porta é publicada só em `127.0.0.1` (ver `docker-compose.yml`), então o servidor não é acessível pela rede. Para expor na LAN, não mexa no bind do modo local: use o [modo remoto](#modo-remoto-homelab), que já sobe com token bearer e `AI_MEMORY_ALLOWED_HOSTS` e foi pensado para ficar atrás de um proxy TLS.

## Versões

Tags disponíveis em <https://hub.docker.com/r/akitaonrails/ai-memory/tags>. `3.2.2` é a versão default do `.env.example` e do `server/.env.production.example`. Ao subir de 2.x para 3.x com dados existentes, leia antes o [guia de upgrade do upstream](https://github.com/akitaonrails/ai-memory/blob/main/docs/upgrading-to-3.0.md).

## Créditos

Este repositório é só o empacotamento em Docker/Makefile em cima do [ai-memory](https://github.com/akitaonrails/ai-memory), criado por [Fabio Akita (akitaonrails)](https://github.com/akitaonrails). Todo o servidor MCP, o storage, os hooks e a wiki vêm de lá — para dúvidas sobre o funcionamento interno do ai-memory em si, consulte o repositório original.

Leitura sobre o projeto, no blog do autor ([akitaonrails.com](https://akitaonrails.com/)):

- [Criei um Sistema de Memória pra Agentes de Código: ai-memory](https://akitaonrails.com/2026/05/23/criei-sistema-memoria-agentes-codigo-ai-memory/)
- [Memória de Agentes IA: Karpathy LLM Wiki e agentmemory na Prática](https://akitaonrails.com/2026/05/18/memoria-agentes-karpathy-llm-wiki-agentmemory/)
- [ai-memory: arquitetura emergente e software maleável](https://akitaonrails.com/2026/06/14/ai-memory-arquitetura-emergente-e-software-maleavel/)
- [ai-memory: memória de longo prazo (Karpathy Wiki) e auto-aprendizado (Hermes) pros seus projetos](https://akitaonrails.com/2026/06/16/ai-memory-memoria-longo-prazo-karpathy-wiki-auto-aprendizado-hermes-projetos/)
- [Novidades no meu AI-MEMORY: cada vez melhor pra usar com suas IAs](https://akitaonrails.com/2026/07/20/novidades-no-meu-ai-memory-cada-vez-melhor-pra-usar-com-suas-ias/)
- [AI-MEMORY 2.0 - o melhor sistema de memória para agentes e times](https://akitaonrails.com/2026/09/02/ai-memory-2-0-melhor-sistema-memoria-agentes-e-times/)
