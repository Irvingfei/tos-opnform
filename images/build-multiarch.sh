#!/usr/bin/env bash
# OpnForm TOS 适配镜像 — 双架构构建/推送脚本
# 前置条件：
#   1. Docker Desktop / Docker Engine 已启用 containerd + buildx（binfmt 支持 arm64 交叉构建）
#   2. docker login 已登录你自己的 Docker Hub 命名空间（TOS 仅接受 Docker Hub 镜像）
# 用法：
#   ./build-multiarch.sh <docker_hub_namespace> <version_tag> [opnform 源码路径]
# 示例：
#   ./build-multiarch.sh myaccount 1.0.0-tos ../OpnForm
set -euo pipefail

NS="${1:?用法: build-multiarch.sh <docker_hub_namespace> <version_tag> [opnform源码路径]}"
VER="${2:?缺少版本号，例如 1.0.0-tos}"
SRC="${3:-../OpnForm}"

BUILDER=opnform-tos-builder
docker buildx inspect "$BUILDER" >/dev/null 2>&1 || docker buildx create --name "$BUILDER" --use
docker buildx use "$BUILDER"

# OpnForm 官方 CI 同样以 amd64 + arm64 双架构发布（.github/workflows/docker-client-release.yml matrix）
PLATFORMS="linux/amd64,linux/arm64"

echo "==> 注入补丁版入口脚本到 OpnForm 源码"
cp images/php-fpm-entrypoint "$SRC/docker/php-fpm-entrypoint"

echo "==> 构建 ${NS}/opnform-api:${VER}"
docker buildx build \
  -f images/Dockerfile.api \
  --platform "$PLATFORMS" \
  --build-arg APP_VERSION="$VER" \
  -t "${NS}/opnform-api:${VER}" \
  --push "$SRC"

echo "==> 构建 ${NS}/opnform-client:${VER}"
docker buildx build \
  -f images/Dockerfile.client \
  --platform "$PLATFORMS" \
  -t "${NS}/opnform-client:${VER}" \
  --push "$SRC"

echo "==> 构建 ${NS}/opnform-ingress:${VER}"
docker buildx build \
  -f images/Dockerfile.ingress \
  --platform "$PLATFORMS" \
  -t "${NS}/opnform-ingress:${VER}" \
  --push .

echo "==> 完成。请到 Docker Hub 确认三个镜像的 latest tag 均显示 linux/amd64 + linux/arm64"
