# s6-overlay 离线文件目录

Dockerfile 构建时会先在本目录查找 s6-overlay 压缩包；**存在则直接解压，不再访问 GitHub**，
适合构建机器无法访问 GitHub 的场景。

需要的两个文件（版本与 Dockerfile 的 `S6_OVERLAY_VERSION` 一致）：

```
overlay/
├── s6-overlay-noarch.tar.xz
└── s6-overlay-x86_64.tar.xz      # arm64 机器为 s6-overlay-aarch64.tar.xz
```

下载地址：

```
https://github.com/just-containers/s6-overlay/releases/download/v3.2.0.2/s6-overlay-noarch.tar.xz
https://github.com/just-containers/s6-overlay/releases/download/v3.2.0.2/s6-overlay-x86_64.tar.xz
```

本目录下的 `*.tar.xz` 已在 `.gitignore` 中忽略，不会提交进仓库。
