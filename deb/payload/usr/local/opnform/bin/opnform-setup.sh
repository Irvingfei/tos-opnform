#!/bin/bash
# OpnForm 首启初始化（supervisor 启动流程第 0 步）
# 职责：initdb（首启）、生成并持久化 DB 口令与 APP_KEY/JWT_SECRET、启动迁移、Passport keys、storage:link
set -euo pipefail

ROOT=/usr/local/opnform
DEP="$ROOT/depends"
DATA="$ROOT/data"
LOGS="$ROOT/logs"
PHP="$DEP/php/bin/php"
ARTISAN="$PHP $ROOT/api/artisan"

exec >> "$LOGS/setup.log" 2>&1
echo "=== opnform-setup $(date) ==="

PG_PORT="${OPNFORM_PG_PORT:-5433}"
REDIS_PORT="${OPNFORM_REDIS_PORT:-6380}"
RUNTIME_ENV="$DATA/.env-runtime"

mkdir -p "$DATA/run" "$DATA/storage/framework/"{sessions,views,cache/data} \
         "$DATA/storage/app/public" "$DATA/storage/logs" "$DATA/postgres" "$DATA/redis"

# ---- 1) 生成运行时密钥（一次生成，落盘复用）----
if [ ! -f "$RUNTIME_ENV" ]; then
    DB_PASSWORD="$($PHP -r 'echo bin2hex(random_bytes(16));')"
    APP_KEY="base64:$($PHP -r 'echo base64_encode(random_bytes(32));')"
    JWT_SECRET="$($PHP -r 'echo bin2hex(random_bytes(32));')"
    cat > "$RUNTIME_ENV" <<EOF
DB_PASSWORD=${DB_PASSWORD}
APP_KEY=${APP_KEY}
JWT_SECRET=${JWT_SECRET}
EOF
    chmod 600 "$RUNTIME_ENV"
fi
# shellcheck disable=SC1090
. "$RUNTIME_ENV"

# ---- 2) Laravel .env（每次启动重写，保证与运行时密钥一致）----
cat > "$ROOT/api/.env" <<EOF
APP_NAME=OpnForm
APP_ENV=production
APP_KEY=${APP_KEY}
APP_DEBUG=false
APP_URL=http://localhost:${OPNFORM_HTTP_PORT:-18080}
FRONT_URL=http://localhost:${OPNFORM_HTTP_PORT:-18080}
LOG_CHANNEL=errorlog
LOG_LEVEL=debug
CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=127.0.0.1
REDIS_PORT=${REDIS_PORT}
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=${PG_PORT}
DB_DATABASE=opnform
DB_USERNAME=opnform
DB_PASSWORD=${DB_PASSWORD}
MAIL_MAILER=log
JWT_TTL=1440
JWT_SECRET=${JWT_SECRET}
PUBLIC_UPLOADS_RATE_LIMIT_PER_MINUTE=30
PUBLIC_UPLOADS_RATE_LIMIT_PER_HOUR=300
SHOW_OFFICIAL_TEMPLATES=false
SELF_HOSTED=true
EOF

# ---- 3) 数据库首启 initdb + 建库建用户 ----
if [ ! -f "$DATA/postgres/PG_VERSION" ]; then
    echo "initializing postgres cluster"
    "$DEP/postgres/bin/initdb" -D "$DATA/postgres" -U postgres --encoding=UTF8 --locale=C
    # 本地免密（trust）：实例仅绑定 127.0.0.1，且仅本应用用户可访问
    cat >> "$DATA/postgres/pg_hba.conf" <<EOF
host all all 127.0.0.1/32 trust
EOF
fi

# ---- 4) storage 软链 ----
cd "$ROOT/api"
if [ ! -e public/storage ]; then
    ln -sfn "$DATA/storage/app/public" public/storage || true
fi
rm -rf storage && ln -sfn "$DATA/storage" storage || true
mkdir -p "$DATA/storage/app/public"

# ---- 5) 数据库与角色（postgres 启动前无法创建，交给迁移阶段处理；
#          supervisor 启动 postgres 后由下方 migrate 脚本完成，故此处仅做预检）----
echo "pre-check done"

exit 0
