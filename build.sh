#!/bin/sh
# =============================================================================
# 本地一键构建镜像（Linux / macOS / WSL / Git Bash 通用）
#
#   sh build.sh                          # 构建 8.2（Dockerfile 默认版本）
#   sh build.sh 8.3                      # 指定 PHP 版本
#   sh build.sh 8.3 myreg.example.com/docker-webman
#                                        # 指定镜像仓库前缀（默认 docker-webman）
#
# 构建完成后会自动跑一次镜像自检（PHP 版本 / 扩展 / Node / pnpm）。
# =============================================================================
set -e

cd "$(dirname "$0")"

PHP_VERSION="${1:-8.2}"
IMAGE_PREFIX="${2:-docker-webman}"
TAG="${PHP_VERSION}-cli-alpine"
IMAGE_REF="${IMAGE_PREFIX}:${TAG}"

# ---------------------------------------------------------------------------
# 前置检查
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 未找到 docker 命令。"
    echo "       请先安装 Docker："
    echo "         Windows / macOS -> Docker Desktop"
    echo "         Linux           -> docker-ce（含 docker compose 插件）"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker 守护进程不可用（Docker Desktop 是否已启动？）"
    exit 1
fi

echo "======================================================"
echo " PHP_VERSION : ${PHP_VERSION}"
echo " 目标镜像    : ${IMAGE_REF}"
echo "======================================================"
echo

# ---------------------------------------------------------------------------
# 离线资源检查：缺失时构建阶段会联网从 GitHub 下载
# ---------------------------------------------------------------------------
case "$(uname -m)" in
    x86_64|amd64)     ARCH=x86_64 ;;
    aarch64|arm64)    ARCH=aarch64 ;;
    *)                ARCH="$(uname -m)" ;;
esac

MISSING=''
[ -f overlay/s6-overlay-noarch.tar.xz ] || MISSING="${MISSING} overlay/s6-overlay-noarch.tar.xz"
[ -f "overlay/s6-overlay-${ARCH}.tar.xz" ] || MISSING="${MISSING} overlay/s6-overlay-${ARCH}.tar.xz"
[ -f extension/pie.phar ] || MISSING="${MISSING} extension/pie.phar"

if [ -n "${MISSING}" ]; then
    echo "提示：以下离线资源不存在，构建时会联网从 GitHub 获取："
    for m in ${MISSING}; do
        echo "  - ${m}"
    done
    echo "      访问 GitHub 受限时，请先按 README 第 7 节把文件预置好。"
    echo
fi

# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------
docker build \
    --build-arg "PHP_VERSION=${PHP_VERSION}" \
    -t "${IMAGE_REF}" \
    .

echo
echo "镜像构建完成：${IMAGE_REF}"

# ---------------------------------------------------------------------------
# 自检（覆盖 entrypoint，避免直接启动 s6）
# ---------------------------------------------------------------------------
echo
echo "---------- 镜像自检 ----------"
docker run --rm --entrypoint sh "${IMAGE_REF}" -c '
    php -v | head -1
    echo -n "node: "; node -v
    echo -n "pnpm: "; pnpm -v
    php -r "exit(extension_loaded(\"pcntl\") && extension_loaded(\"posix\") && extension_loaded(\"event\") ? 0 : 1);" \
        && echo "关键扩展: pcntl / posix / event OK" || { echo "关键扩展缺失"; exit 1; }
    # s6 服务定义三项缺一不可：type 缺失会让容器启动即 s6-rc-compile fatal，
    # user/contents.d/webman 缺失则服务根本不会被启用（曾踩过）
    [ "$(cat /etc/s6-overlay/s6-rc.d/webman/type 2>/dev/null)" = "longrun" ] \
        && [ -x /etc/s6-overlay/s6-rc.d/webman/run ] \
        && [ -f /etc/s6-overlay/s6-rc.d/user/contents.d/webman ] \
        && echo "s6 服务定义: type=longrun / run 可执行 / user bundle 已注册 OK" \
        || { echo "s6 服务定义不完整（缺 type、run 或 user bundle）"; exit 1; }
'

echo
echo "运行示例（端口按应用实际监听填，webman 默认 8787，madong 是 8500）："
echo "  docker run -d --name webman -p 8500:8500 \\"
echo "    -v /path/to/your-app:/app \\"
echo "    ${IMAGE_REF}"
