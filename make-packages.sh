#!/usr/bin/env bash
# 生成 TOS 7 应用包：x86_64 与 aarch64 各一个 .tar.gz
# 用法： ./make-packages.sh <docker_hub_namespace> <publisher> <version>
# 示例： ./make-packages.sh myaccount "Joffy" 1.0.0
set -euo pipefail

NS="${1:?用法: make-packages.sh <docker_hub_namespace> <publisher> <version>}"
PUBLISHER="${2:?缺少 publisher}"
VER="${3:?缺少 version}"

cd "$(dirname "$0")"
ROOT=$(pwd)
DIST="$ROOT/dist"
rm -rf "$DIST"; mkdir -p "$DIST"

# 生成随机数据库口令（写包一次、随包发布；NAS 内网部署、DB 不暴露宿主端口。
# 如需更换，可在 TNAS 上编辑已安装应用的 docker-compose.yml 后重启）
DB_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(12))')"

for ARCH in x86_64 aarch64; do
  STAGE=$(mktemp -d)
  cp package/config.ini package/opnform.lang package/opnform.svg package/docker-compose.yml "$STAGE/"
  sed -i "s/__DOCKER_NS__/${NS}/g; s/__PUBLISHER__/${PUBLISHER}/g; s/__APP_VERSION__/${VER}/g; s/__PLATFORM__/${ARCH}/g; s/__DB_PASSWORD__/${DB_PASSWORD}/g" \
    "$STAGE/config.ini" "$STAGE/opnform.lang" "$STAGE/docker-compose.yml"
  # TOS 要求：所有文件 LF 行尾
  sed -i 's/\r$//' "$STAGE"/*
  # 包内必须恰好 4 个文件
  (cd "$STAGE" && tar -czf "$DIST/opnform_${ARCH}.tar.gz" config.ini opnform.lang opnform.svg docker-compose.yml)
  rm -rf "$STAGE"
  echo "==> 已生成 dist/opnform_${ARCH}.tar.gz"
done

echo "数据库口令（请妥善保存）：${DB_PASSWORD}"
echo "完成。提交前请先运行 python3 verify.py"
