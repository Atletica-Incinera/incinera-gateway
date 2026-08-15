# Incinera Gateway (Nginx Reverse Proxy)

Gateway reverso global centralizado para o ecossistema Atlética Incinera.

## Arquitetura de Roteamento

- `/` -> Landing Page Next.js (`incinera-web:3000`)
- `/_next/static/` -> Static assets da Landing Page
- `/intereng` -> PWA Torneios Next.js (`pwa-torneios-web:3001`)
- `/intereng/_next/static/` -> Static assets do PWA Torneios
- `/intereng-api/` -> NestJS Backend (`intereng-api:3000`) com rewrite para remover `/intereng-api/`
- `/intereng-api/.../stream` -> SSE / Realtime matches com buffering desativado e timeout longo
- `/healthz` -> Healthcheck do Gateway

## Estrutura do Repositório

```
incinera-gateway/
├── docker-compose.yml
├── nginx/
│   ├── nginx.conf
│   ├── conf.d/
│   │   ├── incinera.conf
│   │   └── upstreams.conf
│   └── includes/
│       ├── proxy-params.conf
│       ├── security-headers.conf
│       └── sse-proxy-params.conf
└── scripts/
    ├── init-vm.sh
    └── validate-config.sh
```

## Operação

1. **Bootstrap da rede compartilhada na VM:**
   ```bash
   ./scripts/init-vm.sh
   ```

2. **Validar sintaxe do Nginx:**
   ```bash
   ./scripts/validate-config.sh
   ```

3. **Subir o Gateway:**
   ```bash
   docker compose up -d
   ```
