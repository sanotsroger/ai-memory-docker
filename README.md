# ai-memory via Docker

Setup do [ai-memory](https://github.com/akitaonrails/ai-memory) rodando em container, com Makefile para gerenciar o ciclo de vida e integração com o Claude Code.

## Pré-requisitos

- Docker + Docker Compose
- make
- jq (usado por `make init` para configurar o hook do Claude Code)
- ~500MB de espaço em disco

## Setup

Clone o repositório (docker-compose.yml e Makefile já vêm com ele):

```bash
git clone https://github.com/sanotsroger/ai-memory-docker.git
cd ai-memory-docker
make start
```

`make start` cria `.env` a partir de `.env.example`, os diretórios de dados, o `config.toml` padrão, configura o hook `UserPromptSubmit` do Claude Code e sobe o container.

Verificar:

```bash
make status
# ai-memory   Up 2 minutes (healthy)   127.0.0.1:49374->49374/tcp
```

## Claude Code

Registre o servidor MCP (escopo `user`, disponível em todos os projetos):

```bash
claude mcp add --transport http ai-memory http://127.0.0.1:49374/mcp -s user
claude mcp list
# ai-memory: http://127.0.0.1:49374/mcp (HTTP) - ✔ Connected
```

### Hook de captura automática

`make init` configura o hook `UserPromptSubmit` (`~/.claude/settings.json`) para rodar `docker exec ai-memory ai-memory hook ...` a cada prompt, alimentando a captura automática de observações de sessão. Como passa pelo container, ele falha silenciosamente (sem travar o prompt) se o `ai-memory` estiver parado — se a captura parecer ter parado, primeiro cheque `make status`.

## Comandos

```bash
make start                   # subir
make stop                    # parar
make restart                 # reiniciar
make logs                    # logs em tempo real
make status                  # status do container
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
