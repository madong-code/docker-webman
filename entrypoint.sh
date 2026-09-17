#!/bin/sh
# =============================================================================
# 容器入口
#   1. 校验挂载结构（应用仓库根 -> /app，含 backend/ 与 template/）
#   2. 首次启动自动 composer install（vendor/autoload.php 不存在时）
#   3. 修正 runtime / storage 目录权限
#   4. 交给 S6 Overlay 接管进程（webman 作为 longrun 服务）
# =============================================================================
set -e

# 显式补全 PATH（/usr/local/bin 是 node / pnpm / composer 所在），
# 保证容器内任何方式启动的进程都能直呼 pnpm
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:${PATH}}"

APP_MOUNT="${APP_MOUNT:-/app}"
BACKEND_DIR="${BACKEND_DIR:-backend}"
TEMPLATE_DIR="${TEMPLATE_DIR:-template}"
APP_ROOT="${APP_ROOT:-${APP_MOUNT}/${BACKEND_DIR}}"

echo "[entrypoint] PHP        : $(php -r 'echo PHP_VERSION;')"
echo "[entrypoint] pnpm       : $(pnpm --version 2>/dev/null || echo '未安装')"
echo "[entrypoint] APP_MOUNT  : ${APP_MOUNT}"
echo "[entrypoint] APP_ROOT   : ${APP_ROOT}"
echo "[entrypoint] WEBMAN_CMD : ${WEBMAN_CMD:-php start.php start}"

# ---------------------------------------------------------------------------
# 兼容两种仓库结构：
#   A. 仓库根分 backend/ 与 template/  -> APP_ROOT=/app/backend
#   B. 仓库根直接就是 webman 应用        -> APP_ROOT=/app
# ---------------------------------------------------------------------------
if [ ! -d "${APP_ROOT}" ] && [ -f "${APP_MOUNT}/start.php" ]; then
    APP_ROOT="${APP_MOUNT}"
    echo "[entrypoint] 未发现 ${BACKEND_DIR}/，按「仓库根即应用」处理：APP_ROOT=${APP_ROOT}"
fi
export APP_ROOT

if [ ! -d "${APP_ROOT}" ]; then
    echo "[entrypoint] !! 未找到 ${APP_ROOT}"
    echo "[entrypoint] !! 请把应用仓库根挂载到 ${APP_MOUNT}，期望结构："
    echo "[entrypoint] !!   ${APP_MOUNT}/${BACKEND_DIR}    webman 后端应用"
    echo "[entrypoint] !!   ${APP_MOUNT}/${TEMPLATE_DIR}   pnpm 前端工作区"
fi

# ---------------------------------------------------------------------------
# 依赖自动安装（首次启动，或 vendor 被清空时）
# ---------------------------------------------------------------------------
if [ -f "${APP_ROOT}/composer.json" ] && [ ! -f "${APP_ROOT}/vendor/autoload.php" ]; then
    echo "[entrypoint] vendor 不存在，执行 composer install ..."
    (cd "${APP_ROOT}" && composer install \
        --no-interaction \
        --no-scripts \
        --no-plugins \
        --prefer-dist)
    echo "[entrypoint] composer install 完成"
fi

# ---------------------------------------------------------------------------
# runtime 目录：webman 与 think 系组件都需要可写
# ---------------------------------------------------------------------------
for d in "${APP_ROOT}/runtime" "${APP_ROOT}/storage"; do
    if [ -d "$d" ]; then
        chmod -R 0777 "$d" 2>/dev/null || true
    fi
done
mkdir -p "${APP_ROOT}/runtime" 2>/dev/null || true
chmod 0777 "${APP_ROOT}/runtime" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 导出前端工作区路径
#   后端按相对路径推算即可命中：${APP_ROOT}/../${TEMPLATE_DIR}
#   绝对路径同时导出为 APP_TEMPLATE_DIR，业务代码可直接使用
# ---------------------------------------------------------------------------
APP_TEMPLATE_DIR="${APP_MOUNT}/${TEMPLATE_DIR}"
export APP_TEMPLATE_DIR

if [ -d "${APP_TEMPLATE_DIR}" ] && command -v pnpm >/dev/null 2>&1; then
    echo "[entrypoint] 前端工作区 : ${APP_TEMPLATE_DIR}（pnpm $(pnpm --version) 可用，后端可直接调用）"
fi

exec /init "$@"
