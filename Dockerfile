# syntax=docker/dockerfile:1
#
# =============================================================================
# webman 应用运行时镜像
#
#   运行形态：PHP CLI Alpine + S6 Overlay v3 托管 webman 常驻进程，
#   应用挂载在 /app，首次启动自动 composer install。
#   监听端口由应用自身配置决定（webman 默认 8787，madong 实际是 8500），镜像不做假设，
#   映射前先 `php start.php status` 看 listen 列。
#
#   两点约定：
#     1. 应用挂仓库根（含 backend/ 与 template/），webman 工作目录为 /app/backend
#        —— 若仓库根本身就是 webman 应用（无 backend/），entrypoint 会自动回落
#     2. 额外内置 Node + pnpm，用于构建 template/ 前端工作区
#
#   版本控制：镜像 tag = PHP 版本号（如 8.2-cli-alpine），
#   打 git tag 由 .github/workflows/build.yml 构建推送。
#
#   构建示例：
#     docker build -t docker-webman:8.2-cli-alpine .
#     docker build --build-arg PHP_VERSION=8.3 -t docker-webman:8.3-cli-alpine .
# =============================================================================

ARG PHP_VERSION=8.2
# Node 版本必须固定：apk 的 nodejs 会随基础镜像的 Alpine 仓库漂移，
# 曾装到 Node 24，导致 template 前端构建 ERR_MODULE_NOT_FOUND（cross-env 解析不到依赖）
ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-alpine AS nodejs

FROM php:${PHP_VERSION}-cli-alpine

ARG PHP_VERSION
ARG S6_OVERLAY_VERSION=3.2.0.2
ARG PIE_VERSION=1.4.9
ARG APK_MIRROR=mirrors.aliyun.com
ARG COMPOSER_MIRROR=https://mirrors.aliyun.com/composer/
ARG EXTENSIONS=

# pnpm 支持（构建 template/ 前端工作区用）
#   Node 已在上文由 NODE_VERSION 固定（来自官方 node 镜像，非 apk）
ARG PNPM_VERSION=10
ARG NPM_MIRROR=https://registry.npmmirror.com

LABEL org.opencontainers.image.title="docker-webman" \
      org.opencontainers.image.description="webman runtime: PHP ${PHP_VERSION} CLI Alpine + S6 Overlay v3 + Node/pnpm" \
      org.opencontainers.image.base.name="php:${PHP_VERSION}-cli-alpine"

ENV TZ=Asia/Shanghai \
    LANG=C.UTF-8 \
    COMPOSER_HOME=/root/.composer \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_MIRROR=${COMPOSER_MIRROR} \
    PIE_VERSION=${PIE_VERSION}

# ---------------------------------------------------------------------------
# apk 镜像源（置空 APK_MIRROR 走官方源）
# ---------------------------------------------------------------------------
RUN set -eux; \
    if [ -n "${APK_MIRROR}" ]; then \
        sed -i "s#dl-cdn.alpinelinux.org#${APK_MIRROR}#g" /etc/apk/repositories; \
    fi

# ---------------------------------------------------------------------------
# 运行时依赖
#   libstdc++(swoole) / libzip(zip) / libevent(event) / gd 图形库必须显式声明，
#   否则 apk del .build-deps 会把它们连同 -dev 包一起清掉，扩展静默失效
# ---------------------------------------------------------------------------
RUN apk add --no-cache \
        curl ca-certificates tzdata \
        libstdc++ libzip libevent \
        freetype libpng libjpeg-turbo libwebp icu-libs

# ---------------------------------------------------------------------------
# 编译并安装 PHP 扩展（清单见 extension/install.sh）
# ---------------------------------------------------------------------------
COPY extension/ /tmp/extension/
WORKDIR /tmp/extension
RUN set -eux; \
    apk add --no-cache --virtual .build-deps \
        libxml2-dev libzip-dev libjpeg-turbo-dev libpng-dev freetype-dev \
        libwebp-dev libevent-dev openssl-dev libffi-dev icu-dev bzip2-dev \
        autoconf g++ gcc make libc-dev pkgconf re2c libtool automake linux-headers; \
    sed -i 's/\r$//' install.sh; \
    chmod +x install.sh; \
    sh install.sh; \
    rm -rf /tmp/extension; \
    apk del .build-deps; \
    rm -rf /var/cache/apk/* /tmp/* /usr/local/include/php /usr/src/php.tar.xz* /usr/share/man /usr/share/doc
WORKDIR /

# ---------------------------------------------------------------------------
# Composer
# ---------------------------------------------------------------------------
RUN set -eux; \
    curl -fsSL --retry 3 --retry-delay 3 https://getcomposer.org/installer \
        | php -- --install-dir=/usr/local/bin --filename=composer; \
    composer --version; \
    if [ -n "${COMPOSER_MIRROR}" ]; then \
        composer config -g repos.packagist composer "${COMPOSER_MIRROR}"; \
    fi; \
    rm -rf /root/.composer/cache /tmp/*

# ---------------------------------------------------------------------------
# Node + pnpm
#
#   用途：webman 后端在运行期推算 template 的相对路径后，直接调用 pnpm 构建前端
#         （前端目录 = $APP_ROOT/../$TEMPLATE_DIR = /app/template）
#   因此 pnpm 必须：
#     1. 是镜像内的全局命令，且在标准 PATH 中（后端 exec/shell_exec 子进程能找到）
#     2. 不依赖宿主机环境，容器重建后依旧可用
#     3. **Node 版本固定**：从 node:<NODE_VERSION>-alpine COPY 二进制
#        （两者同为 Alpine/musl，二进制兼容）。不用 apk 的 nodejs —— 它随
#        Alpine 仓库漂移，曾装到 Node 24 导致前端构建 ERR_MODULE_NOT_FOUND
# ---------------------------------------------------------------------------
COPY --from=nodejs /usr/local/bin/node /usr/local/bin/node
COPY --from=nodejs /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm
RUN set -eux; \
    ln -sf /usr/local/lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm; \
    ln -sf /usr/local/lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx; \
    npm config set registry "${NPM_MIRROR}"; \
    npm install -g "pnpm@${PNPM_VERSION}"; \
    pnpm config set registry "${NPM_MIRROR}"; \
    _prefix="$(npm prefix -g 2>/dev/null || echo /usr)"; \
    if [ -x "${_prefix}/bin/pnpm" ] && [ "${_prefix}/bin/pnpm" != "/usr/local/bin/pnpm" ]; then \
        ln -sf "${_prefix}/bin/pnpm" /usr/local/bin/pnpm; \
    fi; \
    command -v pnpm; \
    node -v; \
    pnpm -v; \
    npm cache clean --force; \
    rm -rf /root/.npm /tmp/*

# ---------------------------------------------------------------------------
# PHP 配置
# ---------------------------------------------------------------------------
COPY config/php.ini /usr/local/etc/php/conf.d/zzz-webman.ini

# ---------------------------------------------------------------------------
# S6 Overlay v3（离线构建：把 tar.xz 预置到 overlay/ 即可跳过下载）
#   注意：/command 下的可执行文件是指向 /package 的软链，请勿删除 /package
# ---------------------------------------------------------------------------
COPY overlay/ /tmp/s6-overlay/
RUN set -eux; \
    cd /tmp/s6-overlay; \
    arch="$(apk --print-arch)"; \
    for f in s6-overlay-noarch.tar.xz "s6-overlay-${arch}.tar.xz"; do \
        if [ ! -f "$f" ]; then \
            echo "downloading $f ..."; \
            curl -fsSL --retry 3 --retry-delay 3 -o "$f" \
                "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/${f}"; \
        fi; \
        tar -C / -Jxpf "$f"; \
    done; \
    rm -rf /tmp/s6-overlay

# ---------------------------------------------------------------------------
# 注册 webman 为 S6 longrun 服务
# ---------------------------------------------------------------------------
COPY config/s6-rc.d/ /etc/s6-overlay/s6-rc.d/
RUN set -eux; \
    sed -i 's/\r$//' /etc/s6-overlay/s6-rc.d/webman/run; \
    chmod +x /etc/s6-overlay/s6-rc.d/webman/run; \
    test -f /etc/s6-overlay/s6-rc.d/webman/type; \
    test -f /etc/s6-overlay/s6-rc.d/webman/run; \
    mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d; \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/webman

# ---------------------------------------------------------------------------
# 入口脚本
# ---------------------------------------------------------------------------
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN set -eux; \
    sed -i 's/\r$//' /usr/local/bin/entrypoint.sh; \
    chmod +x /usr/local/bin/entrypoint.sh

# ---------------------------------------------------------------------------
# 应用目录
#   docker run 把「应用仓库根」挂载到 /app：
#     /app/backend   -> webman 后端应用（APP_ROOT）
#     /app/template  -> pnpm 前端工作区
#   仓库根直接就是 webman 应用时（无 backend/），entrypoint 自动回落 APP_ROOT=/app
# ---------------------------------------------------------------------------
RUN mkdir -p /app/backend /app/template
ENV APP_MOUNT=/app \
    APP_ROOT=/app/backend \
    BACKEND_DIR=backend \
    TEMPLATE_DIR=template \
    WEBMAN_CMD="php start.php start"
VOLUME ["/app"]
WORKDIR /app/backend
# EXPOSE 仅作声明，不影响运行与 -p 映射；列出常见端口：
#   8787 = webman 官方默认
#   8500 = madong 的 HTTP
#   3501 = madong 的 websocket push
EXPOSE 8787 8500 3501

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
