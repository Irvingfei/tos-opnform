# OpnForm for TOS 7（铁威马 NAS 应用适配工程）

将开源表单构建器 [OpnForm](https://github.com/OpnForm/OpnForm)（AGPL-3.0）适配为 TOS 7
Docker 应用，同时产出 **x86_64** 与 **aarch64** 两个架构的提交包。

依据：[TOS 7 应用开发与发布指南](https://github.com/TerraMasterOfficial/app-pkg-tools#tos-7-application-development-and-publishing-guide)（指南第 8/9 章）。

## CI 自动构建与发布（GitHub Actions）

本仓库内置两条流水线，推送 `v*` 标签时自动触发：

- **build-images.yml** — 克隆固定版本（`OPNFORM_REF`，当前 v2.8.6）的 OpnForm 源码，
  注入补丁版入口脚本，用 buildx 一次构建三个自建镜像的 linux/amd64 + linux/arm64
  双架构 manifest 并推送 Docker Hub；
- **release-packages.yml** — 生成双架构 TOS 提交包、跑静态合规自检、创建 GitHub
  Release 并挂载 `opnform_x86_64.tar.gz` / `opnform_aarch64.tar.gz`（TOS 开发者平台
  提审时直接从该 Release 拉取，见指南第 15 章）。

使用前在仓库 **Settings → Secrets and variables → Actions** 配置：

| Secret | 用途 |
|---|---|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名 = 镜像命名空间，写入 compose 的 image 引用 |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token（仅构建流水线需要） |
| `PUBLISHER_NAME` | 发布者显示名，写入 config.ini 与 26 语言 lang 文件 |

```bash
git tag v1.0.0 && git push origin v1.0.0   # 触发构建 + 发布
```

## 目录结构

```
tos-opnform/
├── images/                  # 自建镜像（TOS 仅接受 Docker Hub 镜像，需推到你自己的命名空间）
│   ├── Dockerfile.api       # Laravel API：官方版 + UID1000 www-data + 非root + 密钥首启生成
│   ├── Dockerfile.client    # Nuxt 客户端：官方版 + 非root(node)
│   ├── Dockerfile.ingress   # nginx 入口：配置固化进镜像（TOS 包不允许第 5 个文件）
│   ├── nginx.conf.template  # 基于官方 nginx.conf，仅改监听端口 8080（非root 不能绑 80）
│   ├── php-fpm-entrypoint   # 官方入口脚本补丁版：APP_KEY/JWT_SECRET 首启生成并持久化
│   └── build-multiarch.sh   # docker buildx 双架构(amd64+arm64)构建推送脚本
├── package/                 # TOS 提交包模板（含占位符，由 make-packages.sh 注入）
│   ├── config.ini           # 应用元数据（platform 按架构注入）
│   ├── opnform.lang         # 26 语言多语言文件
│   ├── opnform.svg          # 应用图标
│   └── docker-compose.yml   # TOS 合规编排（端口 18080 / bind mount / 非 root / 全量健康检查）
├── make-packages.sh         # 生成 dist/opnform_x86_64.tar.gz 与 dist/opnform_aarch64.tar.gz
├── verify.py                # 静态合规自检（对照指南第 8/9 章逐条检查）
└── dist/                    # 生成产物
```

## 使用步骤

1. **准备源码与镜像**
   ```bash
   git clone https://github.com/OpnForm/OpnForm.git
   cd tos-opnform/images && chmod +x build-multiarch.sh
   ./build-multiarch.sh <你的DockerHub命名空间> <版本号> ../OpnForm
   ```
   构建脚本用 `docker buildx --platform linux/amd64,linux/arm64` 一次产出双架构
   manifest，与 OpnForm 官方发布流水线（`.github/workflows/docker-client-release.yml`
   的 amd64/arm64 matrix）同构。

2. **生成提交包**
   ```bash
   cd tos-opnform && chmod +x make-packages.sh
   ./make-packages.sh <你的DockerHub命名空间> "<发布者名称>" <版本号>
   python3 verify.py
   ```

3. **本地试运行**（在任意有 Docker 的机器，模拟 TOS 安装结果）
   ```bash
   mkdir -p /tmp/opnform-test && cd /tmp/opnform-test
   tar -xzf <tos-opnform>/dist/opnform_x86_64.tar.gz
   sudo chown -R 1000:0 storage postgres redis   # 模拟 TOS 平台的目录属主
   docker compose up -d
   curl -f http://localhost:18080/health || curl -f http://localhost:18080/
   ```

4. **真机验证**：拷贝到 TNAS，按指南第 13 章 `TOSAppSelfTestingTool` 安装自测，
   确认 7 个容器全部 healthy、应用中心显示"运行中"。

5. **提交发布**：按指南第 15 章，在 TNAS 开发者平台创建应用（类型 Docker），
   分 x86_64 / aarch64 两次提交对应的 tar.gz。

## 相对官方 docker-compose.yml 的关键改造（TOS 合规点）

| 项 | 官方做法 | TOS 适配做法 | 依据 |
|---|---|---|---|
| 宿主端口 | `80:80` | `18080:8080`（推荐区间 8000-19999，80 为系统保留） | §9.3 Rule 5 |
| 配置注入 | `env_file: ./api/.env` | 全部环境变量内联（包内仅允许 4 个文件） | §9.2 |
| YAML 锚点 | `&api-environment` / `<<: *` | 展开为显式配置（平台逐行解析，避免锚点歧义） | §9.3 |
| 数据卷 | named volume | 相对路径 bind mount（./storage ./postgres ./redis），平台解析到 DockerAppData 数据根 | §9.3 Rule 4 |
| 运行用户 | 默认 root / www-data | 全服务非 root；自建镜像 UID 1000，postgres/redis 以 `user: "1000:1000"` 运行 | §9.4 Rule 5 |
| nginx 配置 | 卷挂载注入 | 固化进自建 ingress 镜像 | §9.2 |
| 镜像 tag | `:latest` | 锁定版本号 | §9.4 / 模板清单 |
| 密钥 | 用户手写 .env | APP_KEY/JWT_SECRET 首启生成、持久化到 storage 卷；DB 口令打包时随机生成 | §9.4 Rule 3 |
| 健康检查 | 已有 | 保留并确认每服务都有 | §9.5 |
| 升级 | — | TOS Docker 应用不支持平台升级，重装不丢数据（bind mount 在数据根下） | §9.6.2/9.6.4 |

## 验证边界（诚实声明）

以下内容在本工程交付时**未验证**，需要真实环境确认：

- 镜像构建与运行：编写本工程的沙箱没有 Docker，`images/` 下的 Dockerfile 与
  entrypoint 基于官方文件修改，需按上面步骤 1-3 实际构建试跑；
- OpnForm 官方镜像 `jhumanj/opnform-api|client` 虽由官方 CI 双架构发布，但 TOS
  安全审核对"非验证个人/社区镜像"有拒审可能，因此本工程默认走自建镜像路线；
- `postgres:16` / `redis:7` 以 `user: "1000:1000"` 运行依赖平台对 bind mount 目录
  的 chown 行为（1000:0），指南有描述但需真机确认；
- 液态玻璃 UI 原型是设计方向稿，未合入 OpnForm 前端源码（见方案文档）。

## 许可证提示

OpnForm 核心代码采用 AGPL-3.0。对外分发的镜像包含修改后的 OpnForm 代码，
须以同等许可提供修改后的源码（如公开你的 fork 仓库并在应用介绍中链接）。
