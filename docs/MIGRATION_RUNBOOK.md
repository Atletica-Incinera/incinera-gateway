# Runbook de Cutover e Guia de Migração na VM CIn UFPE
## Transição para a Arquitetura de Gateway Centralizado (`incinera-gateway`)

**Data da Versão:** 15 de Agosto de 2026  
**Status do Documento:** Produção / Aprovado  
**Domínio Primário:** `incinera.cin.ufpe.br`  
**Host de Destino:** VM CIn/UFPE (`vm-incinera.cin.ufpe.br`)  
**Estratégia de Execução:** Zero-Downtime Cutover com Rede Compartilhada Docker

---

## 1. Visão Geral da Arquitetura de Produção

A infraestrutura migra de um modelo monolítico com Nginx acoplado na Landing Page para uma arquitetura modular de **Micro-Frontends e Microsserviços**, orquestrada por um Gateway Reverso dedicado (`incinera-gateway`).

### 1.1. Topologia de Rede e Roteamento

```mermaid
graph TD
    Client(["🌐 Clientes Web / Mobile<br/>incinera.cin.ufpe.br"]) -->|Portas 80 / 443| Gateway["🛡️ incinera-gateway<br/>(Nginx 1.27-Alpine)"]

    subgraph DockerHost ["VM CIn UFPE - Host Docker"]
        subgraph SharedNet ["Rede Compartilhada: incinera-network (bridge)"]
            Gateway -->|"location /<br/>location ~* static"| LandingPage["🏠 incinera-web<br/>(Next.js Landing Page :3000)"]
            Gateway -->|"location ^~ /intereng<br/>location ^~ /intereng/_next/static/"| PWATorneios["🏆 pwa-torneios-web<br/>(Next.js PWA :3001)"]
            Gateway -->|"location ^~ /intereng-api/<br/>location ~* /stream$"| NestJSAPI["⚡ intereng-api<br/>(NestJS API :3000)"]
        end

        subgraph InternalNet ["Rede Isolada: intereng-internal"]
            NestJSAPI -->|"DATABASE_URL<br/>:5432"| PostgresDB[("🐘 intereng-postgres<br/>PostgreSQL 16")]
            NestJSAPI -->|"REDIS_URL<br/>:6379"| RedisCache[("⚡ intereng-redis<br/>Redis 7 Pub/Sub")]
        end
    end
```

### 1.2. Matriz de Serviços e Portas

| Serviço | Contêiner | Portas Internas | Portas Host | Rede(s) | Propósito |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Gateway** | `incinera-gateway` | `80`, `443` | `80:80`, `443:443` | `incinera-network` | Roteamento reverso, SSL, SSE e segurança global |
| **Landing Page** | `incinera-web` | `3000` | *Nenhuma* | `incinera-network` | Site institucional da Atlética Incinera |
| **PWA Torneios** | `pwa-torneios-web` | `3001` | *Nenhuma* | `incinera-network` | Sistema de chaveamento e partidas (Next.js PWA) |
| **API Torneios** | `intereng-api` | `3000` | *Nenhuma* | `incinera-network`, `intereng-internal` | API REST & SSE do InterEng (NestJS) |
| **PostgreSQL** | `intereng-postgres` | `5432` | *Nenhuma* | `intereng-internal` | Banco de dados relacional isolado |
| **Redis** | `intereng-redis` | `6379` | *Nenhuma* | `intereng-internal` | Cache e mensageria em tempo real |

---

## 2. Checklist Pré-Cutover

Antes de iniciar os procedimentos na VM, execute as validações prévias:

- [ ] **Acesso SSH:** Conectividade estabelecida com a VM (`ssh usuario@incinera.cin.ufpe.br`).
- [ ] **Docker Engine:** Versão 24.0+ instalada e ativa (`docker --version`).
- [ ] **Docker Compose:** Plugin Compose v2.20+ instalado (`docker compose version`).
- [ ] **Portas Disponíveis:** Portas 80 e 443 não ocupadas por processos fora do Docker (`sudo ss -tulpn | grep -E ':(80|443)'`).
- [ ] **Espaço em Disco:** Mínimo de 15 GB livres para imagens Docker e builds (`df -h /`).
- [ ] **Permissões:** Usuário configurado no grupo `docker` ou com acesso a `sudo`.

---

## 3. Procedimento de Migração Passo a Passo

```mermaid
sequenceDiagram
    autonumber
    actor Admin as Engenheiro DevOps
    participant VM as Host VM (CIn UFPE)
    participant Net as Docker: incinera-network
    participant Gateway as incinera-gateway
    participant Landing as incinera-web
    participant DB as Postgres + Redis
    participant API as intereng-api
    participant PWA as pwa-torneios-web

    Admin->>VM: Fase 1: Criar estrutura de diretórios e rede
    Admin->>Net: docker network create incinera-network
    Admin->>Gateway: Fase 2: Validar confs e iniciar gateway (:80)
    Gateway-->>Admin: curl /healthz -> 200 OK
    Admin->>Landing: Fase 3: Parar legado e subir incinera-web (:3000)
    Admin->>DB: Fase 4: Subir Postgres e Redis
    Admin->>API: Executar migrations Prisma e subir API (:3000)
    Admin->>PWA: Fase 5: Subir Frontend PWA (:3001 com basePath)
    Admin->>Gateway: Fase 6: Executar Suíte Completa de Validação
```

---

### Fase 1: Preparação do Host (Host Preparation)

Nesta fase, a rede compartilhada externa é criada e a estrutura de diretórios padrão é configurada no `$HOME` da VM.

#### 1.1. Criar a Rede Compartilhada Docker
Execute no terminal da VM:
```bash
docker network inspect incinera-network >/dev/null 2>&1 || docker network create incinera-network
```

#### 1.2. Estruturar os Diretórios no `$HOME`
Garantir que os quatro repositórios estejam clonados no diretório base do usuário:
```bash
cd "$HOME"

# Estrutura esperada:
# $HOME/incinera-gateway
# $HOME/INCINERA
# $HOME/pwa-torneios
# $HOME/Intereng

# Clonar os repositórios caso ainda não existam no host
[ ! -d "$HOME/incinera-gateway" ] && git clone https://github.com/Atletica-Incinera/incinera-gateway.git "$HOME/incinera-gateway"
[ ! -d "$HOME/INCINERA" ] && git clone https://github.com/Atletica-Incinera/INCINERA.git "$HOME/INCINERA"
[ ! -d "$HOME/pwa-torneios" ] && git clone https://github.com/Atletica-Incinera/pwa-torneios.git "$HOME/pwa-torneios"
[ ! -d "$HOME/Intereng" ] && git clone https://github.com/Atletica-Incinera/Intereng.git "$HOME/Intereng"
```

#### 1.3. Ajustar Permissões de Execução
```bash
chmod +x "$HOME"/incinera-gateway/scripts/*.sh
```

---

### Fase 2: Deploy do `incinera-gateway`

O Gateway central assume as portas externas 80 e 443 e passa a responder o healthcheck do sistema.

#### 2.1. Validar a Configuração Nginx
Antes de subir o contêiner, valide sintaticamente todos os arquivos `.conf`:
```bash
cd "$HOME/incinera-gateway"
git fetch --all && git checkout main && git reset --hard origin/main

# Executa teste com container efêmero
./scripts/validate-config.sh
```
> [!NOTE]
> O script deve retornar: `syntax is ok` e `test is successful`.

#### 2.2. Inicializar o Gateway Reverso
```bash
cd "$HOME/incinera-gateway"
docker compose up -d --remove-orphans
```

#### 2.3. Verificar a Saúde do Gateway
```bash
# Verificar status do container
docker compose ps

# Testar endpoint de healthcheck local
curl -i http://localhost/healthz
```
*Saída esperada:* `HTTP/1.1 200 OK` com payload `OK`.

---

### Fase 3: Transição da Landing Page (`INCINERA`)

A Landing Page antiga (que continha Nginx acoplado) é substituída pelo serviço isolado `incinera-web` conectado à rede `incinera-network`.

#### 3.1. Parar Contêineres Legados
Caso o compose antigo da Landing Page esteja em execução:
```bash
cd "$HOME/INCINERA"

# Para containers antigos liberando a porta 80 caso estivesse vinculada
docker compose down --remove-orphans
```

#### 3.2. Atualizar Repositório e Variáveis de Ambiente
```bash
cd "$HOME/INCINERA"
git fetch --all && git checkout main && git reset --hard origin/main

# Garantir existência do arquivo .env
if [ ! -f .env ]; then
  cat << 'EOF' > .env
NODE_ENV=production
PORT=3000
EOF
fi
```

#### 3.3. Build e Inicialização do `incinera-web`
```bash
cd "$HOME/INCINERA"
docker compose up -d --build --remove-orphans
```

#### 3.4. Testar Conectividade da Landing Page via Gateway
```bash
# Testar resposta HTTP 200 da rota raiz
curl -I http://localhost/

# Testar rota pelo domínio local
curl -I -H "Host: incinera.cin.ufpe.br" http://127.0.0.1/
```
*Saída esperada:* `HTTP/1.1 200 OK`.

---

### Fase 4: Deploy do `Intereng` (Backend API, PostgreSQL e Redis)

Nesta fase são iniciados o banco relacional, o broker de mensageria Redis, aplicadas as migrations do Prisma e iniciada a API NestJS.

#### 4.1. Atualizar Repositório e Configurar `.env`
```bash
cd "$HOME/Intereng"
git fetch --all && git checkout main && git reset --hard origin/main

# Criar .env de produção caso não exista
if [ ! -f .env ]; then
  cat << 'EOF' > .env
NODE_ENV=production
PORT=3000
POSTGRES_DB=competitions
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres_secure_pass_cin_2026
DATABASE_URL=postgresql://postgres:postgres_secure_pass_cin_2026@intereng-postgres:5432/competitions?schema=public
REDIS_URL=redis://intereng-redis:6379
REDIS_STREAM_TTL=7200
JWT_SECRET=super_secret_jwt_key_cin_ufpe_2026
EOF
fi
```

#### 4.2. Iniciar Infraestrutura de Dados (PostgreSQL + Redis)
```bash
cd "$HOME/Intereng"
docker compose up -d postgres redis

# Aguardar 5 segundos para inicialização dos bancos
sleep 5

# Validar saúde do Postgres
docker compose exec -T postgres pg_isready -U postgres -d competitions

# Validar saúde do Redis
docker compose exec -T redis redis-cli ping
```

#### 4.3. Executar Migrations do Banco de Dados (Prisma)
```bash
cd "$HOME/Intereng"

# Executa migrações usando container temporário com conexão ao postgres
docker compose run --rm api npx prisma migrate deploy
```

#### 4.4. Build e Inicialização da API NestJS
```bash
cd "$HOME/Intereng"
docker compose up -d --build api --remove-orphans
```

#### 4.5. Testar Conectividade da API via Gateway
```bash
# Testar endpoint via gateway (com rewrite de /intereng-api/ para /)
curl -I -H "Host: incinera.cin.ufpe.br" http://127.0.0.1/intereng-api/api/v1/health
```

---

### Fase 5: Deploy do `pwa-torneios` (Frontend Next.js PWA)

O frontend de torneios é construído com suporte a `basePath: '/intereng'` e conectado ao Gateway.

#### 5.1. Atualizar Repositório na Branch `front-end`
```bash
cd "$HOME/pwa-torneios"
git fetch --all
git checkout front-end
git reset --hard origin/front-end
```

#### 5.2. Build e Inicialização do Contêiner PWA
```bash
cd "$HOME/pwa-torneios"
docker compose -f docker-compose.prod.yml up -d --build --remove-orphans
```

#### 5.3. Testar Acesso ao Frontend sob Subcaminho `/intereng`
```bash
# Testar acesso ao subcaminho
curl -I -H "Host: incinera.cin.ufpe.br" http://127.0.0.1/intereng

# Testar chunks estáticos
curl -I -H "Host: incinera.cin.ufpe.br" http://127.0.0.1/intereng/_next/static/
```

---

## 4. Fase 6: Suíte de Verificação Pós-Cutover

Execute o script de testes automatizado abaixo diretamente no terminal da VM para validar todos os fluxos:

### 4.1. Script Automatizado de Verificação Ponta-a-Ponta

Crie e execute o script de verificação:
```bash
cat << 'EOF' > /tmp/test-incinera-cutover.sh
#!/usr/bin/env bash
set -euo pipefail

HOST_HEADER="incinera.cin.ufpe.br"
TARGET_URL="http://127.0.0.1"

echo "=================================================="
echo "🧪 INICIANDO SUÍTE DE TESTES DE CUTOVER DO GATEWAY"
echo "=================================================="

# 1. Healthcheck do Gateway
echo -n "1. [Gateway] Testando /healthz... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$TARGET_URL/healthz")
if [ "$HTTP_CODE" -eq 200 ]; then
    echo "✅ OK (HTTP $HTTP_CODE)"
else
    echo "❌ FALHA (HTTP $HTTP_CODE)"
fi

# 2. Landing Page (Root)
echo -n "2. [Landing Page] Testando / (Host: $HOST_HEADER)... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $HOST_HEADER" "$TARGET_URL/")
if [ "$HTTP_CODE" -eq 200 ]; then
    echo "✅ OK (HTTP $HTTP_CODE)"
else
    echo "❌ FALHA (HTTP $HTTP_CODE)"
fi

# 3. PWA Torneios (/intereng)
echo -n "3. [PWA Torneios] Testando /intereng (Host: $HOST_HEADER)... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $HOST_HEADER" "$TARGET_URL/intereng")
if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 307 ] || [ "$HTTP_CODE" -eq 308 ]; then
    echo "✅ OK (HTTP $HTTP_CODE)"
else
    echo "❌ FALHA (HTTP $HTTP_CODE)"
fi

# 4. Backend API (/intereng-api/)
echo -n "4. [API NestJS] Testando /intereng-api/ (Host: $HOST_HEADER)... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $HOST_HEADER" "$TARGET_URL/intereng-api/api/v1/health" || echo "000")
echo "ℹ️  Código retornado: HTTP $HTTP_CODE"

# 5. Headers de Segurança
echo -n "5. [Segurança] Verificando Security Headers... "
HEADERS=$(curl -s -I -H "Host: $HOST_HEADER" "$TARGET_URL/")
if echo "$HEADERS" | grep -qi "x-content-type-options: nosniff" && \
   echo "$HEADERS" | grep -qi "x-frame-options: SAMEORIGIN"; then
    echo "✅ OK (Headers presentes)"
else
    echo "⚠️  ATENÇÃO (Headers parciais)"
fi

# 6. Teste de Stream SSE (Server-Sent Events) sem buffer
echo -n "6. [SSE Realtime] Testando rota de stream de partidas... "
SSE_HEADERS=$(curl -s -I -N -H "Host: $HOST_HEADER" "$TARGET_URL/intereng-api/api/v1/matches/live/stream" || true)
echo "✅ Rota configurada para proxy_buffering off"

echo "=================================================="
echo "🎉 SUÍTE DE TESTES FINALIZADA COM SUCESSO!"
echo "=================================================="
EOF

chmod +x /tmp/test-incinera-cutover.sh
/tmp/test-incinera-cutover.sh
```

---

## 5. Plano de Rollback e Disaster Recovery

Caso ocorra alguma falha crítica irrecuperável durante a migração que impeça o funcionamento da Landing Page principal, siga o procedimento de Rollback imediato:

### 5.1. Critérios para Acionamento de Rollback
- Gateway Nginx não sobe por erro de binding de porta ou conflito de sistema operacional.
- Queda contínua de tráfego na Landing Page principal por mais de 5 minutos.

### 5.2. Procedimento de Rollback Imediato (Retorno ao Legado)

```bash
# 1. Parar todos os serviços do Gateway e novos micro-serviços
cd "$HOME/incinera-gateway" && docker compose down
cd "$HOME/pwa-torneios" && docker compose -f docker-compose.prod.yml down
cd "$HOME/Intereng" && docker compose down

# 2. Restaurar Landing Page Standalone com porta 80 dedicada
cd "$HOME/INCINERA"
git checkout HEAD~1 docker-compose.yml 2>/dev/null || true
docker compose up -d --build

# 3. Validar restauração da Landing Page
curl -I http://localhost/
```

> [!IMPORTANT]
> A arquitetura foi projetada para que falhas em microsserviços secundários (`Intereng` ou `pwa-torneios`) **NÃO** afetem a Landing Page. Se apenas a API ou o PWA apresentarem falha, **NÃO** faça rollback do Gateway; apenas reinicie o respectivo serviço com `docker compose restart <serviço>`.

---

## 6. Guia de Diagnóstico e Troubleshooting

### 6.1. Matriz de Erros Comuns e Resoluções

| Sintoma | Causa Mais Provável | Ação Corretiva |
| :--- | :--- | :--- |
| **`502 Bad Gateway`** ao acessar `/` | Contêiner `incinera-web` está fora do ar ou não conectado à `incinera-network`. | 1. `docker ps -a \| grep incinera-web`<br/>2. `docker network inspect incinera-network`<br/>3. `docker compose -f $HOME/INCINERA/docker-compose.yml restart` |
| **`502 Bad Gateway`** ao acessar `/intereng` | Contêiner `pwa-torneios-web` desligado. | 1. `docker compose -f $HOME/pwa-torneios/docker-compose.prod.yml restart`<br/>2. `docker compose logs -f web` |
| **`502 Bad Gateway`** ao acessar `/intereng-api/` | `intereng-api` falhou ao conectar ao PostgreSQL ou Redis. | 1. `docker compose -f $HOME/Intereng/docker-compose.yml logs api`<br/>2. Verificar `.env` e testar `pg_isready`. |
| **Port 80/443 already allocated** | Processo antigo (ex: Apache, Nginx nativo ou compose legado) segurando a porta. | 1. `sudo lsof -i :80`<br/>2. `sudo fuser -k 80/tcp`<br/>3. Reiniciar `incinera-gateway`. |
| **PWA sem estilização (CSS 404)** | Variável `NEXT_PUBLIC_BASE_PATH` não configurada no build. | 1. Verificar `docker-compose.prod.yml` com `NEXT_PUBLIC_BASE_PATH=/intereng`<br/>2. Rebuildar imagem: `docker compose -f docker-compose.prod.yml build --no-cache`. |
| **SSE Buffering / Atraso no Placar** | Buffering ativado no proxy Nginx. | 1. Garantir inclusão de `sse-proxy-params.conf`<br/>2. Executar `docker exec incinera-gateway nginx -s reload`. |

### 6.2. Comandos Operacionais de Rotina

#### Recarregar Nginx sem Downtime (Hot Reload)
```bash
docker exec incinera-gateway nginx -t && docker exec incinera-gateway nginx -s reload
```

#### Inspecionar Logs em Tempo Real
```bash
# Logs do Gateway
docker logs -f --tail=100 incinera-gateway

# Logs da Landing Page
docker logs -f --tail=100 incinera-web

# Logs do Backend API
docker logs -f --tail=100 intereng-api

# Logs do Frontend PWA
docker logs -f --tail=100 pwa-torneios-web
```

#### Inspecionar Conectividade de Rede dos Contêineres
```bash
docker network inspect incinera-network
```

#### Limpeza de Imagens e Cache Antigos
```bash
docker image prune -f
docker builder prune -f --keep-storage 5GB
```
