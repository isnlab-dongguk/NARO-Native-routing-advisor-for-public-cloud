#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load .env if present
if [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"

# Install dependencies if needed
if ! python3 -c "import fastapi" &>/dev/null; then
  echo "Installing dependencies..."
  pip3 install -q -r requirements.txt
fi

echo "Starting NARO at http://${HOST}:${PORT}"
uvicorn backend.app:app --host "$HOST" --port "$PORT" --reload
