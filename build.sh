#!/usr/bin/env bash
# 本地建置。用法：
#   ./build.sh                    本機平台建置，映像名 docker-sing-box:dev
#   ./build.sh v1.13.21           指定上游 sing-box 版本
#   ./build.sh --push v1.13.21    全架構建置並推送 latest 與 v1.13.21（需先
#                                 docker login ghcr.io）；正式發佈走 CI
#                                 （推 v* 標籤），本命令用於驗證
set -euo pipefail

repo=ghcr.io/openxbond/sing-box
version=v1.13.21
push=0
for arg in "$@"; do
  case $arg in
    --push) push=1 ;;
    --*) echo "未知選項：$arg"; exit 2 ;;
    *) version=$arg ;;
  esac
done

platforms=linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64,linux/loong64,linux/ppc64le,linux/riscv64,linux/s390x

if [ "$push" -eq 1 ]; then
  docker buildx build \
    --platform "$platforms" \
    --build-arg SINGBOX_VERSION="$version" \
    -t "$repo:latest" \
    -t "$repo:$version" \
    --push .
else
  docker build \
    --build-arg SINGBOX_VERSION="$version" \
    -t docker-sing-box:dev .
fi
