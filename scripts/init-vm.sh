#!/usr/bin/env bash
set -euo pipefail

echo "==> Inicializando infraestrutura na VM..."

# 1. Cria a rede Docker compartilhada se não existir
if ! docker network inspect incinera-network >/dev/null 2>&1; then
  echo "Criando rede Docker 'incinera-network'..."
  docker network create incinera-network
else
  echo "Rede 'incinera-network' já existe."
fi

echo "==> Bootstrap finalizado com sucesso!"
