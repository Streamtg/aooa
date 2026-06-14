#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="$(basename "$ROOT_DIR")"
cd "$(dirname "$ROOT_DIR")"
tar --exclude="$NAME/.git" --exclude="$NAME/.env" --exclude="$NAME/*.db" --exclude="$NAME/logs" --exclude="$NAME/data" --exclude="$NAME/pgdata" -czf "$NAME.tar.gz" "$NAME"
echo "✅ Paquete creado: $(pwd)/$NAME.tar.gz"
