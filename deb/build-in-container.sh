#!/usr/bin/env bash
# OpnForm TOS Deb 包 — 真实构建脚本（在 ubuntu:22.04 容器内以 root 执行）
# 用法： ./build-in-container.sh <version> <publisher> <maintainer> <arch: amd64|arm64> [opnform-src]
# 产物： dist/opnform_<arch>.deb
#
# 运行时捆绑策略（TOS 指南 §2.4 Option 3：TOS 不预装 PHP8.3/Node，须随包捆绑）：
#   PHP 8.3     — deb.sury.org（ppa:ondrej/php）php8.3-* 包解包捆绑，非默认库随包带
#   Node 24     — nodejs.org 官方 tarball（linux-x64 / linux-arm64）
#   PostgreSQL  — Ubuntu 22.04 主源 postgresql-14（Laravel 无版本硬依赖）
#   Redis       — Ubuntu 22.04 主源 redis-server
#   nginx       — Ubuntu 22.04 主源 nginx-core（独立实例，不占用系统 nginx）
# 所有下载经 apt（同一构建环境保证 ABI 与 TOS 根文件系统 Ubuntu 22.04 兼容，glibc 2.35）
set -euo pipefail

# apt 索引偶发上游镜像同步失败（"Mirror sync in progress?"），带重试。
# 该状态下 Release 记录的文件大小/哈希与 CDN 上的 Packages 实际内容不一致，
# 属于上游同步窗口（实测可延续数分钟），因此用递增退避把总窗口拉到 ~5.5 分钟。
# 注意：不关闭 apt 的哈希校验——放宽校验等于放弃索引完整性，宁可等待。
apt_update_retry() {
  local i delay
  for i in 1 2 3 4 5 6 7 8; do
    apt-get update -qq && return 0
    delay=$(( i * 15 ))
    [ "$delay" -gt 60 ] && delay=60
    echo "==> apt-get update 失败（第 $i 次），${delay} 秒后重试" >&2
    sleep "$delay"
  done
  echo "==> apt-get update 连续 8 次失败（累计等待约 5.5 分钟），放弃" >&2
  return 1
}

VER="${1:?用法: build-in-container.sh <version> <publisher> <maintainer> <amd64|arm64> [opnform-src]}"
PUBLISHER="${2:?缺少 publisher}"
MAINTAINER="${3:?缺少 maintainer，如 'Joffy <joffy@users.noreply.github.com>'}"
ARCH="${4:?缺少架构 amd64|arm64}"
SRC="${5:-./opnform-src}"
# 解析为绝对路径：脚本中途会 cd 到临时目录，相对路径会失效
SRC="$(cd "$SRC" && pwd)"

DEBARCH="$ARCH"                       # dpkg 架构名与 TOS 一致：amd64 / arm64
[ "$ARCH" = amd64 ] && NARCH=x64 || NARCH=arm64     # Node tarball 后缀
DpkgArchDir="$([ "$ARCH" = amd64 ] && echo x86_64-linux-gnu || echo aarch64-linux-gnu)"

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)/pkgroot"
DIST="$HERE/dist"
mkdir -p "$STAGE" "$DIST"

echo "==> [1/8] 安装构建工具"
export DEBIAN_FRONTEND=noninteractive
apt_update_retry
apt-get install -y -qq ca-certificates curl xz-utils bzip2 git dpkg-dev \
    composer-unbundled 2>/dev/null || apt-get install -y -qq ca-certificates curl xz-utils bzip2 git dpkg-dev
PHP_BUILD_PKGS="php8.3-cli php8.3-fpm php8.3-pgsql php8.3-redis php8.3-gd php8.3-zip php8.3-bcmath php8.3-mbstring php8.3-xml php8.3-curl php8.3-intl"

echo "==> [2/8] 准备 apt 源（sury PHP 8.3 + 主源 PG/Redis/nginx）"
apt-get install -y -qq curl gnupg
curl -fsSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/sury.gpg
echo "deb [arch=$DEBARCH] https://packages.sury.org/php/ jammy main" > /etc/apt/sources.list.d/sury.list
apt_update_retry
# 容器内安装 PHP 8.3 全套扩展与 composer（第 5 步要在构建环境里跑 composer）；
# 顺带把 PHP 的运行库依赖装进系统，php 包装器在容器内也能正常启动
apt-get install -y -qq $PHP_BUILD_PKGS composer

echo "==> [3/8] 下载并解包运行时组件"
DL=$(mktemp -d)
cd "$DL"
# 注意：apt-get download 不解析依赖，PHP/PG/nginx 的非默认运行库必须显式下载，
# 否则 rootfs 里没有这些 .so，cp 段会静默跳过、打出的包在 TOS 上缺库
LIB_PKGS="libpq5 libonig5 libzip4 libgd3 libicu70 libwebp7 libjpeg-turbo8 libpng16-16 libfreetype6 libsodium23 libssl3 libxml2 libpcre3"
apt-get download -qq $PHP_BUILD_PKGS \
    postgresql-14 postgresql-client-14 \
    redis-server redis-tools \
    nginx-core \
    $LIB_PKGS
apt-get download -qq libnginx-mod-http-headers-more-filter 2>/dev/null || true
for d in *.deb; do dpkg-deb -x "$d" rootfs/; done
mkdir -p "$HERE/depends-tmp"
DEPENDS="$STAGE/usr/local/opnform/depends"
mkdir -p "$DEPENDS"

# PHP：bin/php + sbin/php-fpm + etc/php/8.3 + 扩展 so + 捆绑非默认库
mkdir -p "$DEPENDS/php"
mkdir -p "$DEPENDS/php/bin" "$DEPENDS/php/sbin"
cp -a rootfs/usr/bin/php8.3 "$DEPENDS/php/bin/php"
cp -a rootfs/usr/sbin/php-fpm8.3 "$DEPENDS/php/sbin/php-fpm"
cp -a rootfs/usr/lib/php/8.3 "$DEPENDS/php/libext" 2>/dev/null || true
cp -a rootfs/etc/php/8.3 "$DEPENDS/php/etc"
cp -a rootfs/usr/share/php/PhpSpreadsheet 2>/dev/null || true
mkdir -p "$DEPENDS/php/libs"
for lib in libpq.so.5 libonig.so.5 libzip.so.4 libgd.so.3 libicuuc.so.70 libicui18n.so.70 \
           libicudata.so.70 libwebp.so.7 libjpeg.so.8 libpng16.so.16 libfreetype.so.6 \
           libsodium.so.23 libssl.so.3 libcrypto.so.3; do
  [ -f "rootfs/usr/lib/$DpkgArchDir/$lib" ] && cp -a "rootfs/usr/lib/$DpkgArchDir/$lib" "$DEPENDS/php/libs/" || true
done
# PHP-FPM 配置：监听 127.0.0.1:9001、进程属主 opnform、error_log 落应用日志
cat > "$DEPENDS/php/etc/fpm/pool.d/www.conf" <<'FPMEOF'
[www]
user = opnform
group = opnform
listen = 127.0.0.1:9001
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
php_admin_value[error_log] = /usr/local/opnform/logs/php-fpm.log
php_admin_flag[log_errors] = on
php_value[upload_max_filesize] = 64M
php_value[post_max_size] = 68M
php_value[memory_limit] = 1G
FPMEOF
sed -i "s|^include=.*|include=$DEPENDS/php/etc/fpm/pool.d/*.conf|" "$DEPENDS/php/etc/fpm/php-fpm.conf" 2>/dev/null || \
  echo "include=$DEPENDS/php/etc/fpm/pool.d/*.conf" >> "$DEPENDS/php/etc/fpm/php-fpm.conf"
# php.ini 生产配置
cat > "$DEPENDS/php/etc/cli/conf.d/99-tos.ini" <<'INIEOF'
memory_limit = 1G
max_execution_time = 600
upload_max_filesize = 64M
post_max_size = 68M
INIEOF
# PHP 扩展目录指向捆绑 libext，库路径用 LD_LIBRARY_PATH（supervisor 环境注入）
PHPEXT=$(ls -d "$DEPENDS/php/libext"/*+*/ 2>/dev/null | head -1 || true)
if [ -n "$PHPEXT" ]; then
  sed -i "s|^extension_dir = .*|extension_dir = $PHPEXT|" "$DEPENDS/php/etc/cli/php.ini" 2>/dev/null || true
fi
# LD_LIBRARY_PATH 包装器（php / php-fpm 通过 wrapper 设置库路径）
mv "$DEPENDS/php/bin/php" "$DEPENDS/php/bin/php.real"
cat > "$DEPENDS/php/bin/php" <<WRAPEOF
#!/bin/sh
export LD_LIBRARY_PATH="/usr/local/opnform/depends/php/libs:\$LD_LIBRARY_PATH"
exec /usr/local/opnform/depends/php/bin/php.real "\$@"
WRAPEOF
chmod 755 "$DEPENDS/php/bin/php"
mv "$DEPENDS/php/sbin/php-fpm" "$DEPENDS/php/sbin/php-fpm.real"
cat > "$DEPENDS/php/sbin/php-fpm" <<WRAPEOF
#!/bin/sh
export LD_LIBRARY_PATH="/usr/local/opnform/depends/php/libs:\$LD_LIBRARY_PATH"
exec /usr/local/opnform/depends/php/sbin/php-fpm.real "\$@"
WRAPEOF
chmod 755 "$DEPENDS/php/sbin/php-fpm"

# PostgreSQL（share 必须保持 share/postgresql/14 层级：PG 二进制按 argv[0] 相对路径推导 share）
mkdir -p "$DEPENDS/postgres"
cp -a rootfs/usr/lib/postgresql/14/bin "$DEPENDS/postgres/bin"
mkdir -p "$DEPENDS/postgres/share"
cp -a rootfs/usr/share/postgresql "$DEPENDS/postgres/share/"
mkdir -p "$DEPENDS/postgres/libs"
for lib in libpq.so.5 libicuuc.so.70 libicudata.so.70 libicui18n.so.70 libssl.so.3 libcrypto.so.3 libxml2.so.2; do
  cp -a "rootfs/usr/lib/$DpkgArchDir/$lib" "$DEPENDS/postgres/libs/" 2>/dev/null || true
done
# initdb/pg_ctl 包装器（LD_LIBRARY_PATH；share 由 PG 二进制按 argv[0] 相对推导）
for b in initdb pg_ctl postgres pg_isready psql; do
  mv "$DEPENDS/postgres/bin/$b" "$DEPENDS/postgres/bin/$b.real"
  cat > "$DEPENDS/postgres/bin/$b" <<PGEOF
#!/bin/sh
export LD_LIBRARY_PATH="/usr/local/opnform/depends/postgres/libs:\$LD_LIBRARY_PATH"
exec /usr/local/opnform/depends/postgres/bin/$b.real "\$@"
PGEOF
  chmod 755 "$DEPENDS/postgres/bin/$b"
done

# Redis
mkdir -p "$DEPENDS/redis/bin"
cp -a rootfs/usr/bin/redis-server "$DEPENDS/redis/bin/"
cp -a rootfs/usr/bin/redis-cli "$DEPENDS/redis/bin/"

# nginx（独立实例）
mkdir -p "$DEPENDS/nginx/sbin" "$DEPENDS/nginx/conf" "$DEPENDS/nginx/libs"
cp -a rootfs/usr/sbin/nginx "$DEPENDS/nginx/sbin/nginx"
chmod 755 "$DEPENDS/nginx/sbin/nginx"
cp -a rootfs/etc/nginx/mime.types "$DEPENDS/nginx/conf/" 2>/dev/null || echo "types { }" > "$DEPENDS/nginx/conf/mime.types"
cp -a rootfs/etc/nginx/fastcgi_params "$DEPENDS/nginx/conf/" 2>/dev/null || \
  printf 'fastcgi_param REQUEST_METHOD $request_method;\nfastcgi_param CONTENT_TYPE $content_type;\nfastcgi_param CONTENT_LENGTH $content_length;\n' > "$DEPENDS/nginx/conf/fastcgi_params"
cp -a "rootfs/usr/lib/$DpkgArchDir/libpcre.so.3" "$DEPENDS/nginx/libs/" 2>/dev/null || true
# nginx 库路径由 supervisor 环境统一注入 LD_LIBRARY_PATH

echo "==> [4/8] Node.js 24（官方 tarball）"
NODEVER=24.22.1
mkdir -p "$DEPENDS/node"
curl -fsSL "https://nodejs.org/dist/v${NODEVER}/node-v${NODEVER}-linux-${NARCH}.tar.xz" \
  | tar -xJ -C "$DEPENDS/node" --strip-components=1

echo "==> [5/8] 安装 PHP 依赖（composer）"
export PATH="$DEPENDS/php/bin:$PATH"
export COMPOSER_HOME="$(mktemp -d)"
cd "$SRC/api"
composer install --optimize-autoloader --no-interaction --no-dev
mkdir -p "$STAGE/usr/local/opnform/api"
cp -a "$SRC/api/." "$STAGE/usr/local/opnform/api/"
rm -rf "$STAGE/usr/local/opnform/api/tests"

echo "==> [6/8] 构建 Nuxt 客户端"
export PATH="$DEPENDS/node/bin:$PATH"
export NUXT_TELEMETRY_DISABLED=1
cd "$SRC/client"
npm ci --no-audit --no-fund
NODE_OPTIONS=--max-old-space-size=4096 NUXT_BUILD_CONCURRENCY=1 npm run build
mkdir -p "$STAGE/usr/local/opnform/client"
cp -a "$SRC/client/.output/." "$STAGE/usr/local/opnform/client/"

echo "==> [7/8] 组装包骨架"
cp -a "$HERE/payload/DEBIAN" "$STAGE/"
rm -f "$STAGE/DEBIAN/control.in"
sed "s/__APP_VERSION__/$VER/g; s/__ARCH__/$DEBARCH/g; s/__MAINTAINER__/$MAINTAINER/g" \
  "$HERE/payload/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
chmod 755 "$STAGE/DEBIAN"/{preinst,postinst,prerm,postrm}
cp -a "$HERE/payload/usr" "$STAGE/"
sed -i "s/__PUBLISHER__/$PUBLISHER/g; s/__APP_VERSION__/$VER/g; s/__PLATFORM__/$([ "$ARCH" = amd64 ] && echo x86_64 || echo aarch64)/g" \
  "$STAGE/usr/local/opnform/config.ini" "$STAGE/usr/local/opnform/opnform.lang"
chmod 755 "$STAGE/usr/local/opnform/bin/"*
find "$STAGE" -name '*.sh' -exec chmod 755 {} +

# supervisor 环境统一注入库路径
cat >> "$STAGE/usr/local/opnform/opnform.env" <<'ENVEOF'
LD_LIBRARY_PATH=/usr/local/opnform/depends/php/libs:/usr/local/opnform/depends/postgres/libs:/usr/local/opnform/depends/nginx/libs
ENVEOF

echo "==> [8/8] dpkg-deb 打包"
mkdir -p "$STAGE/usr/local/opnform/data" "$STAGE/usr/local/opnform/logs"
chown -R 1000:1000 "$STAGE/usr/local/opnform/data" "$STAGE/usr/local/opnform/logs" 2>/dev/null || true
dpkg-deb --build "$STAGE" "$DIST/opnform_${DEBARCH}.deb"
echo "==> 完成：$DIST/opnform_${DEBARCH}.deb"
