# docker-webman

webman 应用的容器运行时：PHP CLI Alpine + S6 Overlay v3 托管 webman 常驻进程，
应用挂载在 `/app`，首次启动自动 `composer install`，**默认监听 8787**。

主要特性：

| 特性 | 说明 |
| --- | --- |
| 挂载仓库根 | `/app/backend`（后端）+ `/app/template`（前端）同时可读；仓库根直接就是 webman 应用时，自动回落为 `/app` |
| 内置 pnpm | 镜像自带 Node + pnpm，后端可在运行期推算相对路径直接构建 `template` 前端工作区 |
| 进程托管 | S6 Overlay v3 守护 webman 常驻进程，`WEBMAN_CMD` 可自定义启动命令 |
| 版本即 tag | 镜像 tag 就是 PHP 版本号（如 `8.2-cli-alpine`），打 tag 由 CI 自动构建推送 |
| 离线可构建 | s6-overlay 与 PIE 随仓库提供，构建机无需访问 GitHub |

---

## 1. 目录结构

```
docker-webman/
├── Dockerfile                      # 单阶段构建：PHP CLI Alpine + S6 v3 + Node/pnpm
├── entrypoint.sh                   # 校验挂载 / composer install / 权限修正 / 交给 S6
├── config/
│   ├── php.ini                     # 默认 PHP 配置（容器内 zzz-webman.ini）
│   └── s6-rc.d/webman/run          # webman longrun 服务定义
├── extension/
│   └── install.sh                  # 扩展安装（PIE）+ 安装后校验门（离线可放 pie.phar）
├── overlay/                        # 离线构建时放 s6-overlay-*.tar.xz
├── .github/workflows/build.yml     # 打 tag 即构建并推送镜像
├── .gitattributes / .gitignore
├── LICENSE
└── README.md
```

---

## 2. 快速开始

### 2.1 获取镜像

**方式 A：拉取已发布的镜像**（CI 已构建好，推荐）

```bash
# 公开包直接拉
docker pull ghcr.io/madong-code/docker-webman:8.2-cli-alpine

# 私有包先登录（PAT 需勾选 read:packages）
echo "<YOUR_GITHUB_PAT>" | docker login ghcr.io -u madong-code --password-stdin
docker pull ghcr.io/madong-code/docker-webman:8.2-cli-alpine
```

> 国内服务器拉 `ghcr.io` 经常不通，处理办法见 9.1。

**方式 B：本地构建**

```bash
# 一键脚本（推荐）
sh build.sh                                       # 默认 8.2
sh build.sh 8.3                                   # 指定 PHP 版本
sh build.sh 8.3 myreg.example.com/docker-webman   # 指定镜像仓库前缀

# 或直接用 docker build（脚本已兼容 8.3 / 8.4 / 8.5，按需构建）
docker build -t docker-webman:8.2-cli-alpine .
docker build --build-arg PHP_VERSION=8.3 -t docker-webman:8.3-cli-alpine .
```

> 完整扩展清单（含 swoole / intl / xlswriter）单次构建约 8～15 分钟。
> `build.sh` 会先检查 docker 是否可用、离线资源是否齐全，构建完成后自动跑一次
> 镜像自检（PHP 版本 / 关键扩展 / Node / pnpm / s6 服务定义）。

### 2.2 启动容器

镜像名按你实际使用的替换：拉取的是 `ghcr.io/madong-code/docker-webman:8.2-cli-alpine`，
本地构建的是 `docker-webman:8.2-cli-alpine`。

```bash
docker run -d --name webman \
  -p 8787:8787 \
  -v /path/to/your-app:/app \
  ghcr.io/madong-code/docker-webman:8.2-cli-alpine
```

Windows（Docker Desktop）：

```bash
docker run -d --name webman -p 8787:8787 -v D:/www/your-app:/app ghcr.io/madong-code/docker-webman:8.2-cli-alpine
```

### 端口必须先确认，再映射

**容器监听什么端口由应用自身的配置决定，不由镜像决定**。`8787` 只是 webman 官方默认值，
本文的 `docker run` 示例沿用它；换应用（如 madong）就必须换数字，否则映射配得再对也访问不通。

先启动一次，看监听列：

```bash
docker exec webman php start.php status
```

常见情况：

| 应用 | 容器内监听 | 端口映射写 |
| --- | --- | --- |
| webman 裸装默认 | `http://0.0.0.0:8787` | `-p 8787:8787` |
| madong | `http://0.0.0.0:8500` | `-p 8500:8500` |
| madong（前端 websocket 推送） | `websocket://0.0.0.0:3501` | `-p 3501:3501` |

端口来源是后端 `config/server.php` 里的 `listen`；容器侧不需任何改动，
改后端配置后按同样的数字映射即可。

进入容器 / 查看日志：

```bash
docker exec -it webman sh
docker logs -f webman
```

### 2.3 验证

```bash
docker exec webman php -v          # PHP 版本
docker exec webman php -m          # 已加载扩展
docker exec webman php start.php status
curl -i http://127.0.0.1:8787/     # 应用响应
```

---

## 3. 应用目录约定

推荐在仓库根下分后端与前端两个目录：

```
your-app/
├── backend/            -> 容器 /app/backend   （webman 应用，APP_ROOT）
└── template/           -> 容器 /app/template  （pnpm 前端工作区）
```

- 挂载**仓库根**，而不是只挂 `backend/`：后端常驻进程才能读到前端构建产物
  （资源发布、代码生成器模板、SSR 等场景）。
- 仓库根直接就是 webman 应用（无 `backend/`）时，`entrypoint.sh` 会检测到
  `/app/start.php` 并把 `APP_ROOT` 回落为 `/app`，与「直接挂 webman 应用目录」的用法一致。

可覆盖的环境变量：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `APP_MOUNT` | `/app` | 容器内挂载点 |
| `APP_ROOT` | `/app/backend` | webman 工作目录 |
| `BACKEND_DIR` / `TEMPLATE_DIR` | `backend` / `template` | 仓库根下的子目录名 |
| `WEBMAN_CMD` | `php start.php start` | 启动命令（改端口/进程数常改这里） |

`backend/` 中 `runtime` 与 `storage` 会被自动置为可写（`0777`）。

---

## 4. pnpm（前端工作区）

镜像内置 Node 与 pnpm（`/usr/local/bin/pnpm`，位于标准 `PATH`），宿主无需安装 Node。
**典型用法是后端进程自己推算相对路径去调用 pnpm**，而不是从宿主机进容器手工执行。

### 4.1 后端调用（相对路径推算）

后端工作目录是 `/app/backend`，前端工作区是它的兄弟目录 `../template`，
所以后端只要按相对关系推算就能拿到前端目录：

```php
// 方式一：相对推算（不依赖任何配置）
$backend  = base_path();                        // /app/backend
$template = dirname($backend) . '/template';    // /app/template

// 方式二：读容器导出的环境变量（entrypoint / s6 均已注入）
$template = getenv('APP_TEMPLATE_DIR') ?: dirname(base_path()) . '/template';

// 执行 pnpm —— 镜像内已是全局命令，子进程直接调用即可
exec("cd {$template} && pnpm install --frozen-lockfile && pnpm run build 2>&1", $output, $code);
```

这里的相对关系之所以成立，正是因为**挂载的是仓库根**：

```
/app/backend   <- webman 后端（cwd）
/app/template  <- pnpm 工作区（../template）
```

前端语言栈相关的注意点：

- pnpm / node 都在镜像里，容器重建后依旧可用，宿主不需要装 Node
- `node_modules`、构建产物都落在挂载目录（宿主机）里，不会随容器销毁而丢失
- pnpm store 在容器内 `/root/.local/share/pnpm/store`，容器重建后会重新下载依赖；
  需要复用时可挂个卷：

  ```bash
  docker run -d --name webman -p 8787:8787 \
    -v /path/to/your-app:/app \
    -v pnpm-store:/root/.local/share/pnpm/store \
    docker-webman:8.2-cli-alpine
  ```

### 4.2 手工执行

在运行中的容器里构建：

```bash
docker exec -it webman sh -lc "cd /app/template && pnpm install && pnpm build"
```

用一次性容器构建（不启动服务）：

```bash
docker run --rm \
  -v /path/to/your-app:/app \
  -w /app/template \
  docker-webman:8.2-cli-alpine \
  sh -lc "pnpm install --frozen-lockfile && pnpm build"
```

只构建某个子包（pnpm 工作区）：

```bash
docker run --rm -v /path/to/your-app:/app -w /app/template \
  docker-webman:8.2-cli-alpine sh -lc "pnpm --filter @your-scope/admin build"
```

说明：

- pnpm 与 npm 的 registry 默认指向 `registry.npmmirror.com`，构建时可用
  `--build-arg NPM_MIRROR=https://registry.npmjs.org` 改回官方源。
- pnpm 版本由 `--build-arg PNPM_VERSION=10` 决定。
- Node 由基础镜像的 Alpine 仓库提供，版本随 Alpine 版本走。
- 构建产物位于 `/app/template/**/dist`，后端进程（cwd `/app/backend`）可直接读取。

---

## 5. 版本控制（tag）

**镜像 tag 就是 PHP 版本号**，首个版本从 8.2 开始。

```bash
git tag 8.2-cli-alpine
git push origin 8.2-cli-alpine
```

`.github/workflows/build.yml` 会在 tag 推送时：

1. 从 tag 解析 `PHP_VERSION`（取第一个 `-` 之前的部分，`8.2-cli-alpine` → `8.2`）
2. `docker build --build-arg PHP_VERSION=<解析结果>`
3. 跑一次容器自检（`php -v` / `php -m` / `node -v` / `pnpm -v`）
4. 推送镜像到 GHCR：`ghcr.io/madong-code/docker-webman:<tag>` 与 `:latest`

### 5.1 版本矩阵

**一个 Dockerfile 覆盖所有版本**，不需要为每个 PHP 版本维护分支或单独文件。
版本只体现在「构建参数 `PHP_VERSION`」和「tag」两处：
`Dockerfile` 里 `ARG PHP_VERSION=8.2` 是默认值（不带参数就是 8.2），
`FROM php:${PHP_VERSION}-cli-alpine` 决定基础镜像，`extension/install.sh` 按版本自动门控差异。

| PHP 版本 | 基础镜像 | tag | 构建参数 | 备注 |
| --- | --- | --- | --- | --- |
| **8.2** | `php:8.2-cli-alpine` | `8.2-cli-alpine` | `--build-arg PHP_VERSION=8.2` | 首发版本，也是 Dockerfile 默认值 |
| 8.3 | `php:8.3-cli-alpine` | `8.3-cli-alpine` | `--build-arg PHP_VERSION=8.3` | 无需改任何代码 |
| 8.4 | `php:8.4-cli-alpine` | `8.4-cli-alpine` | `--build-arg PHP_VERSION=8.4` | 无需改任何代码 |
| 8.5 | `php:8.5-cli-alpine` | `8.5-cli-alpine` | `--build-arg PHP_VERSION=8.5` | OPcache 已内置，脚本自动跳过编译 |

> Node / pnpm 不受 PHP 版本影响：Node 由各自基础镜像的 Alpine 仓库提供（20/22 一线），
> pnpm 版本统一由 `--build-arg PNPM_VERSION` 决定，pnpm 10 在 Node 18+ 均可用。

### 5.2 两种 tag 粒度

| tag 形态 | 含义 | 适用场景 |
| --- | --- | --- |
| `8.2-cli-alpine` | 跟随官方 `php:8.2-cli-alpine` 的最新补丁 | 日常发布、滚动更新 |
| `8.2.28-cli-alpine` | 锁定到具体补丁版本，构建结果可复现 | 生产固定版本、排查回归 |

两种都支持：workflow 取第一个 `-` 之前的部分作为 `PHP_VERSION`，
所以 `8.2.28-cli-alpine` 会去构建 `php:8.2.28-cli-alpine`。

### 5.3 新增一个 PHP 版本（不用改代码）

```bash
git tag 8.3-cli-alpine
git push origin 8.3-cli-alpine      # CI 自动构建 + 自检 + 推 GHCR
```

只有当「该版本行为与已有版本不同」时才需要动 `extension/install.sh`，
差异用版本门控写在脚本里即可（8.5 的 OPcache 就是这么处理的）：

```sh
if isPhpVersionGreaterOrEqual 8 5; then
    # 已静态编译进核心：跳过编译，只校验存在
fi
```

### 5.4 本地构建

```bash
# 单个版本
docker build --build-arg PHP_VERSION=8.2 -t docker-webman:8.2-cli-alpine .

# 一次构建全部版本
for v in 8.2 8.3 8.4 8.5; do
  docker build --build-arg PHP_VERSION="$v" -t "docker-webman:${v}-cli-alpine" .
done

# 推私有仓库
docker tag docker-webman:8.3-cli-alpine your-registry/docker-webman:8.3-cli-alpine
docker push your-registry/docker-webman:8.3-cli-alpine
```

运行时"设置版本"就是换镜像 tag：

```bash
docker run -d --name webman -p 8787:8787 \
  -v /path/to/your-app:/app \
  docker-webman:8.3-cli-alpine      # ← 换这里即换 PHP 版本
```

### 5.5 版本要不要写死

**Dockerfile 里不写死补丁号，精确版本由 tag 决定。** 理由是：

- 写死就等于"一个版本一份文件"，失去单 Dockerfile 覆盖全版本的意义
- 默认滚动小版本（`php:8.2-cli-alpine`）能让重建自动吃到安全补丁 ——
  webman 是常驻服务，安全补丁比"逐字节可复现"更重要
- 需要可复现时，把补丁号写进 **tag** 即可（`8.2.28-cli-alpine`），
  CI 会自动用它当 `PHP_VERSION`，不用改任何文件

| 场景 | `PHP_VERSION` 取值 | 效果 |
| --- | --- | --- |
| 日常开发 / 本地构建 | `8.2` | 跟随 8.2 线最新补丁，重建即升级 |
| 发布正式镜像 | tag 带的精确值，如 `8.2.28` | 构建结果可复现、可追溯 |
| 安全补丁发布 | 新 tag，如 `8.2.29-cli-alpine` | 老 tag 不动，新 tag 上线 |

构建期依赖的固定情况（按"是否需要人工跟进"决定）：

| 依赖 | 当前设置 | 说明 |
| --- | --- | --- |
| s6-overlay | `3.2.0.2` 精确 | 很少变动，固定更稳 |
| PIE | `1.4.9` 精确 | 同上 |
| pnpm | `10`（大版本） | 默认跟随 10.x；发布时可用 `--build-arg PNPM_VERSION=10.15.0` 精确固定 |
| apk 包（nodejs/npm 及各类 -dev） | 不固定 | 随基础镜像的 Alpine 版本走，只有锁 base 镜像 digest 才能完全复现 |

> 真要做到 100% 可复现，可以把 digest 也带上：
> `docker build --build-arg PHP_VERSION=8.2.28 -t ... .` 配合
> `FROM php:8.2.28-cli-alpine@sha256:...`（把 digest 写进 Dockerfile 或用构建参数传入）。
> 一般项目不需要，除非有合规/审计要求。

---

## 6. 扩展

内置清单（`extension/install.sh`，可用 `--build-arg EXTENSIONS=` 覆盖）：

```
bcmath, bz2, calendar, event, exif, gd, intl, mysqli, opcache,
pcntl, pdo_mysql, redis, sockets, swoole, xlswriter, zip
```

外加官方镜像自带的 `pdo / posix / curl / mbstring / openssl`。

裁剪清单（逗号包裹且首尾各带一个逗号）：

```bash
docker build \
  --build-arg EXTENSIONS=",bcmath,gd,opcache,pcntl,pdo_mysql,redis,sockets,zip,event," \
  -t docker-webman:8.2-slim .
```

- **PHP 8.2 / 8.3 / 8.4**：OPcache 走 `docker-php-ext-install opcache`
- **PHP 8.5**：OPcache 已静态编译进核心，脚本只做存在性校验（版本门控已内置）

扩展通过 **PIE**（PECL 的官方替代品）安装，所需资源已随仓库提供，见第 7 节。

---

## 7. 离线 / 国内构建

构建时唯一需要访问 GitHub 的两个依赖，**已随仓库提供**：

```
overlay/s6-overlay-noarch.tar.xz     （约 7 KB）
overlay/s6-overlay-x86_64.tar.xz     （约 642 KB）
extension/pie.phar                   （约 6.6 MB）
```

Dockerfile 检测到文件存在就直接使用，因此**没有外网的构建机（含国内 CI、内网服务器）也能构建**。

升级这两个依赖时（同时改 Dockerfile 里的 `S6_OVERLAY_VERSION` / `PIE_VERSION`），
重新下载覆盖即可（GitHub 直连受限时可在地址前加加速前缀，如 `https://ghproxy.net/`）：

```bash
# s6-overlay（按 CPU 架构取文件：x86_64 / aarch64）
curl -fL -o overlay/s6-overlay-noarch.tar.xz \
  https://github.com/just-containers/s6-overlay/releases/download/v3.2.0.2/s6-overlay-noarch.tar.xz
curl -fL -o overlay/s6-overlay-x86_64.tar.xz \
  https://github.com/just-containers/s6-overlay/releases/download/v3.2.0.2/s6-overlay-x86_64.tar.xz

# pie.phar（PIE 本体）
curl -fL -o extension/pie.phar \
  https://github.com/php/pie/releases/download/1.4.9/pie.phar
```

> 扩展源码（redis / swoole / event / xlswriter）由 PIE 从 Packagist 拉取，国内一般可达；
> 完全离线时把 `EXTENSIONS` 裁到纯内置扩展。

apk / composer / npm 源默认已指向国内镜像，可用
`--build-arg APK_MIRROR=` / `COMPOSER_MIRROR=` / `NPM_MIRROR=` 置空改回官方源。

---

## 8. 覆盖 PHP 配置

容器内默认配置是 `/usr/local/etc/php/conf.d/zzz-webman.ini`。
业务自定义配置挂到排序更靠后的文件即可覆盖：

```bash
docker run -d --name webman \
  -p 8787:8787 \
  -v /path/to/your-app:/app \
  -v /path/to/custom.ini:/usr/local/etc/php/conf.d/zzz-custom.ini:ro \
  docker-webman:8.2-cli-alpine
```

---

## 9. 1Panel 部署

本镜像**不带 compose 编排**，在 1Panel 上直接「创建容器」即可。需要 MySQL / Redis 时，
用面板应用商店安装，再把容器接入同一网络。

### 9.1 拉取镜像

**容器 → 镜像 → 拉取**：`ghcr.io/madong-code/docker-webman:8.2-cli-alpine`
（私有包需填 GitHub 用户名 + 带 `read:packages` 的 PAT）

国内服务器拉 `ghcr.io` 通常会失败（1Panel 的「镜像加速」只对 Docker Hub 生效），三种处理：

| 方案 | 做法 |
| --- | --- |
| 改为公开包 | GitHub → 你的 Packages → 该包 → Package settings → Change visibility → Public |
| 让 CI 同时推 ACR | 仓库加 3 个 Secrets：`ACR_IMAGE_PREFIX` / `ACR_USERNAME` / `ACR_PASSWORD`，重跑 workflow；服务器改拉 ACR |
| 人工中转 | 在能访问 ghcr 的机器 `docker pull` → `docker tag` → `docker push` 到 ACR，服务器再拉 ACR |

### 9.2 创建容器

**容器 → 容器 → 创建容器**：

| 字段 | 填什么 |
| --- | --- |
| 名称 | `webman` |
| 镜像 | `ghcr.io/madong-code/docker-webman:8.2-cli-alpine` |
| 端口映射 | 按②实际监听填：madong 是 宿主 `8500` → 容器 `8500`（前端推送再加 `3501`）；webman 裸装才用 `8787` |
| 挂载 | 宿主 `/opt/app/madong` → 容器 `/app`，**挂仓库根**（含 `backend/` 与 `template/`，不要只挂 `backend`） |
| 环境变量 | `TZ=Asia/Shanghai` |
| 重启策略 | 除非停止（unless-stopped） |
| 网络 | `1panel-network`（要与面板装的 MySQL / Redis 互通就选它） |

### 9.3 验证

容器日志正常应出现：

```
[entrypoint] PHP        : 8.2.x
[entrypoint] pnpm       : 10.x
[entrypoint] APP_ROOT   : /app/backend
[s6][webman] cwd      = /app/backend
[s6][webman] template = /app/template
[s6][webman] command  = php start.php start
```

面板终端里：

```bash
docker exec webman php start.php status      # 先看 listen 列，确认端口（madong = 8500）
curl -i http://127.0.0.1:8500/               # 端口按实际监听填
docker exec webman php -m | tr '\n' ' '
```

### 9.4 常见报错

| 现象 | 原因 / 处理 |
| --- | --- |
| `FATAL: 目录不存在 /app/backend` | 挂载点挂成了 `backend/` 子目录，要挂**仓库根** |
| 容器起来但端口不通 | 后端 `config/server.php` 的监听端口与映射不一致 |
| `composer install` 失败 | 容器内出网问题；镜像里 composer 已指向阿里云 |
| 前端 404 / 空白 | `template/` 未构建：`docker exec webman sh -lc "cd /app/template && pnpm install && pnpm build"` |
| 需要 MySQL / Redis | 面板应用商店安装，后端 `backend/.env` 的 `DB_HOST` / `REDIS_HOST` 填面板里的容器名，并把容器加入同一网络 |

---

## 10. 常见问题

> 1Panel 相关的报错见 9.4。

| 现象 | 处理 |
| --- | --- |
| 启动报 `FATAL: 目录不存在 /app/backend` | 挂载目录里没有 `backend/`，且根下没有 `start.php`；确认 `-v` 路径是否正确 |
| 端口不通 | webman 监听端口与 `-p` 映射不一致；改 `WEBMAN_CMD` 或 `config/server.php` |
| `composer install` 慢或失败 | 设置 `--build-arg COMPOSER_MIRROR=`（默认已用阿里云） |
| pnpm 安装慢 | 默认走 npmmirror；企业内网可改 `NPM_MIRROR` |
| 改代码不生效 | webman 常驻进程需 reload：`docker exec webman php start.php reload` |
| 脚本报 `#!/bin/sh^M: not found` | 换行符被改成 CRLF，仓库已带 `.gitattributes`（强制 LF）；必要时 `dos2unix` |
| 扩展编译失败（swoole / event / xlswriter） | 从 `EXTENSIONS` 移除后重建；PHP 8.5 上优先只保留稳定扩展 |

常用命令：

```bash
docker exec webman php start.php reload      # 平滑重载（改完代码最常用）
docker exec webman php start.php restart     # 重启
docker exec webman php start.php stop        # 停止
docker exec webman php start.php status      # 进程与连接状态
```

---

## License

[Apache License 2.0](./LICENSE)
