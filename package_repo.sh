#!/usr/bin/env bash
set -euo pipefail
BASE_DIR="${WEBTOR_UDOCKER_DIR:-$HOME/qooq-webtor-udocker}"
PID_FILE="$BASE_DIR/webtor.pid"
if [ ! -f "$PID_FILE" ]; then
  echo "No existe $PID_FILE"
  exit 0
fi
PID="$(cat "$PID_FILE")"
if kill -0 "$PID" 2>/dev/null; then
  kill "$PID"
  echo "Webtor detenido: PID $PID"
else
  echo "PID $PID no está activo"
fi
rm -f "$PID_FILE"
