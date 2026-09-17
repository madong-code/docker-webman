#!/bin/sh
# =============================================================================
# PHP 扩展安装脚本
#
#   · 目前发布 8.2，脚本已兼容 8.3 / 8.4 / 8.5（后续加 tag 即可）
#   · 在线安装统一走 PIE（PECL 的官方替代品，基于 Packagist）
#   · 离线构建：把 pie.phar 预置到本目录（extension/pie.phar）
#
# 用法（由 Dockerfile 调用）：
#   EXTENSIONS=",gd,redis,swoole," sh install.sh
# =============================================================================

export MC="-j$(nproc)"

PIE_VERSION="${PIE_VERSION:-1.4.9}"
PIE_PHAR="$(pwd)/pie.phar"

# ---------------------------------------------------------------------------
# 默认扩展清单
#   注意：字符串以逗号包裹，便于用 ${EXTENSIONS##*,name,*} 做「包含」判断
#   posix / pdo / curl / mbstring / openssl 官方镜像已内置，无需安装
# ---------------------------------------------------------------------------
if [ -z "${EXTENSIONS}" ]; then
    EXTENSIONS=",bcmath,bz2,calendar,event,exif,gd,intl,mysqli,opcache,pcntl,pdo_mysql,redis,sockets,swoole,xlswriter,zip,"
fi
export EXTENSIONS

echo "======================================================"
echo " PHP version      : ${PHP_VERSION}"
echo " PIE version      : ${PIE_VERSION}"
echo " EXTENSIONS       : ${EXTENSIONS}"
echo "======================================================"
echo

# ---------------------------------------------------------------------------
# has_ext <name>  —— 扩展是否在清单中
# ---------------------------------------------------------------------------
has_ext() {
    [ -z "${EXTENSIONS##*,$1,*}" ]
}

# ---------------------------------------------------------------------------
# isPhpVersionGreaterOrEqual <major> <minor>
#   当前版本 >= 目标版本 → return 1（沿用参考脚本语义，配合 if 使用）
# ---------------------------------------------------------------------------
isPhpVersionGreaterOrEqual() {
    _major=$(php -r "echo PHP_MAJOR_VERSION;")
    _minor=$(php -r "echo PHP_MINOR_VERSION;")
    if [ "${_major}" -gt "$1" ] || { [ "${_major}" -eq "$1" ] && [ "${_minor}" -ge "$2" ]; }; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# ensurePie —— 准备 pie.phar（优先使用预置文件，否则下载）
# ---------------------------------------------------------------------------
ensurePie() {
    if [ -f "${PIE_PHAR}" ]; then
        echo "---------- 使用预置 pie.phar ----------"
        return 0
    fi

    echo "---------- 获取 PIE (${PIE_VERSION}) ----------"
    if ! curl -fsSL --retry 3 --retry-delay 3 -o "${PIE_PHAR}" \
            "https://github.com/php/pie/releases/download/${PIE_VERSION}/pie.phar"; then
        echo "---------- 指定版本下载失败，回退 latest ----------"
        curl -fsSL --retry 3 --retry-delay 3 -o "${PIE_PHAR}" \
            "https://github.com/php/pie/releases/latest/download/pie.phar"
    fi
    php "${PIE_PHAR}" --version
}

# ---------------------------------------------------------------------------
# installExtensionFromPie <vendor/package> [version-constraint] [configure-options]
#   PIE 会自行编译 + 安装 + 启用；仅在其漏启用时兜底 docker-php-ext-enable
# ---------------------------------------------------------------------------
installExtensionFromPie() {
    _pkg="$1"
    _constraint="$2"
    _configure="$3"

    ensurePie

    _target="${_pkg}"
    [ -n "${_constraint}" ] && _target="${_pkg}:${_constraint}"

    if [ -n "${_configure}" ]; then
        php "${PIE_PHAR}" install "${_target}" --with-configure-options="${_configure}"
    else
        php "${PIE_PHAR}" install "${_target}"
    fi

    # PIE 包名与扩展名不一定一致，做一次映射
    case "${_pkg}" in
        phpredis/phpredis)   _ext="redis" ;;
        osmanov/pecl-event)  _ext="event" ;;
        viest/xlswriter)     _ext="xlswriter" ;;
        swoole/swoole)       _ext="swoole" ;;
        *)
            _ext="${_pkg##*/}"
            _ext="${_ext#pecl-}"
            ;;
    esac

    if ! php -r "exit(extension_loaded('${_ext}') ? 0 : 1);"; then
        echo "---------- PIE 未自动启用 ${_ext}，手动启用 ----------"
        docker-php-ext-enable "${_ext}"
    fi
}

# ===========================================================================
# 核心 / 常用扩展
# ===========================================================================
if has_ext pdo_mysql; then
    echo "---------- pdo_mysql ----------"
    docker-php-ext-install ${MC} pdo_mysql
fi

if has_ext mysqli; then
    echo "---------- mysqli ----------"
    docker-php-ext-install ${MC} mysqli
fi

if has_ext pcntl; then
    echo "---------- pcntl ----------"
    docker-php-ext-install ${MC} pcntl
fi

if has_ext bcmath; then
    echo "---------- bcmath ----------"
    docker-php-ext-install ${MC} bcmath
fi

if has_ext calendar; then
    echo "---------- calendar ----------"
    docker-php-ext-install ${MC} calendar
fi

if has_ext exif; then
    echo "---------- exif ----------"
    docker-php-ext-install ${MC} exif
fi

if has_ext bz2; then
    echo "---------- bz2 ----------"
    docker-php-ext-install ${MC} bz2
fi

if has_ext sockets; then
    echo "---------- sockets ----------"
    docker-php-ext-install ${MC} sockets
fi

if has_ext opcache; then
    if isPhpVersionGreaterOrEqual 8 5; then
        echo "---------- opcache：PHP 8.5+ 已静态编译进核心，跳过编译 ----------"
        php -m | grep -qi "OPcache" || { echo "ERROR: OPcache 缺失于 PHP 8.5 构建"; exit 1; }
    else
        echo "---------- opcache ----------"
        docker-php-ext-install ${MC} opcache
    fi
fi

if has_ext zip; then
    echo "---------- zip ----------"
    # libzip-dev 由 Dockerfile 的 .build-deps 提供，此处不要 apk add，否则会残留
    docker-php-ext-install ${MC} zip
fi

# ===========================================================================
# 图像 / 国际化
# ===========================================================================
if has_ext gd; then
    echo "---------- gd ----------"
    apk add --no-cache freetype libpng libjpeg-turbo libwebp libwebp-dev
    docker-php-ext-configure gd --enable-gd --with-freetype --with-jpeg --with-webp
    docker-php-ext-install ${MC} gd
    apk del libwebp-dev
fi

if has_ext intl; then
    echo "---------- intl ----------"
    apk add --no-cache icu-dev
    docker-php-ext-install ${MC} intl
fi

# ===========================================================================
# 常驻服务相关（webman / workerman）
# ===========================================================================
if has_ext event; then
    echo "---------- event ----------"
    # event 依赖 sockets 的符号
    php -r "exit(extension_loaded('sockets') ? 0 : 1);" || docker-php-ext-install ${MC} sockets

    installExtensionFromPie osmanov/pecl-event "" ""

    # event.so 需要 sockets 先加载：docker-php-ext-event.ini 排序会早于 sockets，
    # 因此重命名为 event.ini 保证在 sockets 之后加载
    rm -f /usr/local/etc/php/conf.d/docker-php-ext-event.ini
    docker-php-ext-enable --ini-name event.ini event
fi

if has_ext swoole; then
    echo "---------- swoole ----------"
    installExtensionFromPie swoole/swoole "" ""
fi

# ===========================================================================
# 业务扩展
# ===========================================================================
if has_ext redis; then
    echo "---------- redis ----------"
    installExtensionFromPie phpredis/phpredis "" ""
fi

if has_ext xlswriter; then
    echo "---------- xlswriter ----------"
    installExtensionFromPie viest/xlswriter "" ""
fi

# ===========================================================================
# 校验：脚本本身没有 set -e，必须显式确认每个扩展都已加载
# ===========================================================================
echo
echo "---------- 校验扩展 ----------"
_verify_failed=0
for ext in $(echo "${EXTENSIONS}" | tr ',' ' '); do
    if [ -z "${ext}" ]; then
        continue
    fi

    if [ "${ext}" = "opcache" ] && php -m | grep -qi "OPcache"; then
        echo "  OK    ${ext} (built-in)"
        continue
    fi

    if ! php -r "exit(extension_loaded('${ext}') ? 0 : 1);"; then
        echo "  FAIL  ${ext}"
        _verify_failed=1
        continue
    fi
    echo "  OK    ${ext}"
done

# 官方镜像内置扩展
for ext in pdo posix curl mbstring openssl; do
    if ! php -r "exit(extension_loaded('${ext}') ? 0 : 1);"; then
        echo "  FAIL  ${ext} (应内置于官方镜像)"
        _verify_failed=1
    fi
done
echo "  OK    built-in: pdo / posix / curl / mbstring / openssl"

if [ "${_verify_failed}" != "0" ]; then
    echo
    echo "ERROR: 有扩展未能成功加载，请检查上方日志。"
    echo "       若为 swoole / event / xlswriter 编译失败，可从 EXTENSIONS 中移除后重试。"
    exit 1
fi

# ===========================================================================
# 清理
# ===========================================================================
echo
echo "---------- 清理 ----------"
rm -rf /tmp/* /var/cache/apk/* /root/.pearrc /root/.cache/pecl /usr/local/include/php 2>/dev/null || true
docker-php-source delete 2>/dev/null || true

echo "---------- 扩展安装完成：$(php -r 'echo PHP_VERSION;') ----------"
