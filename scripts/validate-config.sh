#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Validando sintaxe da configuração do Nginx..."
docker run --rm \
  -v "${ROOT_DIR}/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${ROOT_DIR}/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "${ROOT_DIR}/nginx/includes:/etc/nginx/includes:ro" \
  nginx:1.27-alpine nginx -t

echo "==> Configuração do Nginx é válida!"
