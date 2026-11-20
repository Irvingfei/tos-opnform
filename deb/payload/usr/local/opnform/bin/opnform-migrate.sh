#!/bin/bash
# OpnForm 数据库迁移（supervisor 在 postgres 就绪后调用）
set -euo pipefail

ROOT=/usr/local/opnform
DEP="$ROOT/depends"
DATA="$ROOT/data"
PHP="$DEP/php/bin/php"
PSQL="$DEP/postgres/bin/psql"
PG_PORT="${OPNFORM_PG_PORT:-5433}"
RUNTIME_ENV="$DATA/.env-runtime"

exec >> "$ROOT/logs/setup.log" 2>&1
echo "=== opnform-migrate $(date) ==="
# shellcheck disable=SC1090
. "$RUNTIME_ENV"

# 建角色与库（幂等）
"$PSQL" -h 127.0.0.1 -p "$PG_PORT" -U postgres -tc \
  "SELECT 1 FROM pg_roles WHERE rolname='opnform'" | grep -q 1 || \
  "$PSQL" -h 127.0.0.1 -p "$PG_PORT" -U postgres -c "CREATE ROLE opnform LOGIN SUPERUSER"
"$PSQL" -h 127.0.0.1 -p "$PG_PORT" -U postgres -tc \
  "SELECT 1 FROM pg_database WHERE datname='opnform'" | grep -q 1 || \
  "$PSQL" -h 127.0.0.1 -p "$PG_PORT" -U postgres -c "CREATE DATABASE opnform OWNER opnform"

cd "$ROOT/api"

# 等待迁移表可用（复用官方 entrypoint 的就绪判定）
until $PHP ./artisan migrate:status 2>&1 | grep -q -E "(Migration table not found|Migration name)"; do
  sleep 1
done

echo "running migrations"
$PHP ./artisan migrate --force
$PHP ./artisan telemetry:initialize-instance || true

# Passport keys（MCP OAuth）
if [ ! -f storage/oauth-private.key ]; then
  $PHP ./artisan passport:keys --force
fi

$PHP ./artisan optimize:clear
$PHP ./artisan optimize
echo "=== migrate done ==="
exit 0
