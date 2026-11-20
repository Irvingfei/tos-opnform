#!/usr/bin/env bash
# 用静态骨架构建「结构样例 deb」并自检（无需 Docker/运行时，验证 §8.2 布局与元数据）
# 真实运行时填充见 build-in-container.sh（CI 执行）
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VER="${1:-1.0.0}"
ARCH="${2:-amd64}"
PUBLISHER="${3:-Joffy}"
MAINTAINER="${4:-Joffy <joffy@users.noreply.github.com>}"
[ "$ARCH" = amd64 ] && PLATFORM=x86_64 || PLATFORM=aarch64

STAGE="$(mktemp -d)/pkgroot"
mkdir -p "$STAGE"

cp -a "$HERE/payload/DEBIAN" "$STAGE/"
rm -f "$STAGE/DEBIAN/control.in"
sed "s/__APP_VERSION__/$VER/g; s/__ARCH__/$ARCH/g; s/__MAINTAINER__/$MAINTAINER/g" \
  "$HERE/payload/DEBIAN/control.in" > "$STAGE/DEBIAN/control"
chmod 755 "$STAGE/DEBIAN"/{preinst,postinst,prerm,postrm}

cp -a "$HERE/payload/usr" "$STAGE/"
sed -i "s/__PUBLISHER__/$PUBLISHER/g; s/__APP_VERSION__/$VER/g; s/__PLATFORM__/$PLATFORM/g" \
  "$STAGE/usr/local/opnform/config.ini" "$STAGE/usr/local/opnform/opnform.lang"
chmod 755 "$STAGE/usr/local/opnform/bin/"*
mkdir -p "$STAGE/usr/local/opnform/data" "$STAGE/usr/local/opnform/logs"

mkdir -p "$HERE/dist"
dpkg-deb --build "$STAGE" "$HERE/dist/opnform_${ARCH}_skeleton.deb"
echo "==> 已生成 dist/opnform_${ARCH}_skeleton.deb"
