# OpnForm for TOS 7（铁威马 NAS 应用适配工程）

将开源表单构建器 [OpnForm](https://github.com/OpnForm/OpnForm)（AGPL-3.0，Laravel 12 + Nuxt）适配为铁威马 TOS 7 应用，同时产出 **x86_64** 与 **aarch64** 双架构提交包。包含两条并行路线：

- **`deb/`** — Deb 原生应用（WebUI 外部打开，自带全套捆绑运行时，systemd 单元管理）
- **`docker/`** — Docker 应用（7 容器 compose 编排，依赖 DockerEngine）

依据：[TOS 7 应用开发与发布指南](https://github.com/TerraMasterOfficial/app-pkg-tools#tos-7-application-development-and-publishing-guide)（第 8 章 Deb / 第 9 章 Docker）。

> ⚠️ **路线合规提示**：指南 §2.2 规定「多服务架构应用（Web + 数据库）必须用 Docker、禁止 Deb」。OpnForm 属于该场景——Deb 路线按 §2.4 Option 3 捆绑全套运行时实现，技术上可安装运行，但**送审应用中心存在被拒风险**（保留 Docker 路线作为合规上架通道）。两条路线共存即为此因。

## Deb 路线（`deb/`）

**架构**：单一 systemd 单元 `opnform.service` → python3 监督器（TOS 预装 Python 3.10）按依赖顺序拉起捆绑的 PostgreSQL 14 → Redis → PHP-FPM 8.3 → Nuxt(Node 24) → nginx，全部绑定 127.0.0.1，仅 18080 对外。数据落 `/usr/local/opnform/data`，首启自动生成 APP_KEY/JWT_SECRET/DB 口令并完成迁移。

```
deb/
├── payload/                      # 包内静态骨架（§8.2 布局）
│   ├── DEBIAN/{control.in,preinst,postinst,prerm,postrm}
│   └── usr/local/opnform/
│       ├── config.ini            # §8.4 模板 2（open_path=true 外部打开）
│       ├── opnform.lang          # 26 语言（§8.5.1）
│       ├── images/icons/opnform.svg
│       ├── init.d/opnform.service        # §8.12 安全加固单元
│       ├── bin/opnform-supervisor        # python3 进程监督器
│       ├── bin/{opnform-setup,opnform-migrate}.sh
│       ├── nginx/nginx.conf              # 应用自带 nginx（路由沿用官方 ingress）
│       └── opnform.env
├── build-in-container.sh         # 真实构建：ubuntu:22.04 容器内捆绑
│                                 #   PHP8.3(sury) / Node24(官方tarball) /
│                                 #   PG14+Redis+nginx-core(Ubuntu 主源)
├── make-skeleton-deb.sh          # 骨架样例包（本地即可跑，验证布局）
└── verify-deb.py                 # 静态合规自检（dpkg-deb 解包逐项校验）
```

**本地验证布局**（无需 Docker）：

```bash
cd deb && ./make-skeleton-deb.sh 1.0.0 amd64 && python3 verify-deb.py --skeleton
```

**真实构建**（CI 自动，见 `.github/workflows/build-deb.yml`）：

```bash
docker run --rm -v "$PWD:/work" -w /work ubuntu:22.04 \
  bash -c "deb/build-in-container.sh 1.0.0 'Joffy' 'Joffy <joffy@users.noreply.github.com>' amd64 ./opnform-src"
```

## Docker 路线（`docker/`）

见 `docker/README.md`。7 容器编排（ingress/api/worker/scheduler/client/redis/db），端口 18080、bind mount、全服务非 root、健康检查齐备；`make-packages.sh` 生成两架构 tar.gz 提交包，`verify.py` 静态自检。

## CI 自动构建与发布（GitHub Actions）

推送 `v*` 标签时三条流水线自动触发：

| Workflow | 产物 | 说明 |
|---|---|---|
| `build-deb.yml` | `opnform_amd64.deb` + `opnform_arm64.deb` | ubuntu:22.04 容器内捆绑运行时（arm64 用原生 arm runner，非交叉） |
| `build-images.yml` | Docker Hub 双架构镜像 ×3 | buildx linux/amd64+arm64 |
| `release-packages.yml` | `opnform_x86_64.tar.gz` + `opnform_aarch64.tar.gz` | Docker 应用提交包，静态自检后挂 Release |

Secrets 配置（Settings → Secrets and variables → Actions）：`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`、`PUBLISHER_NAME`。

## 提交发布（指南第 15 章）

Deb 应用：每个架构单独提交 `opnform_amd64.deb` / `opnform_arm64.deb`（文件名规范 §8.15：`<appid>_<platform>.deb`，`<platform>` 取 config.ini 的 platform 字段值）。Docker 应用：提交对应架构 tar.gz。

## 验证边界

- 骨架 deb（双架构）已通过 `verify-deb.py` 全部静态检查（dpkg-deb 实际构建 + 解包校验）；
- **未验证**：完整 deb 的构建与安装（沙箱无 Docker/无 root），需 CI 跑通后在 TNAS 上用 `TOSAppSelfTestingTool` 真机自测；
- PG share 目录用相对布局（`bin/../share/postgresql/14`）适配捆绑路径，需真机确认 postgres 启动；
- lintian 检查在 CI 步骤中执行（本地沙箱无 lintian）。

## 许可证

OpnForm 核心代码 AGPL-3.0。对外分发（deb 包/镜像）包含修改后的 OpnForm 代码，须以同等许可公开修改后的源码——本仓库即满足该要求的源码披露载体，发布页应附仓库链接。
