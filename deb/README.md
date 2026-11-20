# OpnForm for TOS 7 — Deb 应用骨架
# 目录布局按指南 §8.2：元数据必须在 usr/local/<appid>/ 下（dpkg-deb 从 data.tar 该路径解析）

payload/usr/local/opnform/config.ini     # 应用元数据（§8.4 模板 2：外部打开）
payload/usr/local/opnform/opnform.lang   # 26 语言文件（§8.5）
payload/usr/local/opnform/images/icons/opnform.svg
payload/usr/local/opnform/init.d/opnform.service        # systemd 单元（§8.12）
payload/usr/local/opnform/opnform.env    # 环境变量（EnvironmentFile）
payload/usr/local/opnform/nginx/nginx.conf               # 应用自带 nginx 的完整配置（含 events/http）
payload/usr/local/opnform/bin/opnform-supervisor         # python3 进程监督器（主入口）
payload/usr/local/opnform/bin/opnform-setup.sh           # 首启初始化（密钥生成/迁移/Passport keys）
payload/DEBIAN/control.in                # control 模板（Architecture 构建时注入 amd64/arm64）
payload/DEBIAN/preinst|postinst|prerm|postrm             # 生命周期脚本（§8.14）

build-in-container.sh    # 真实构建脚本（在 ubuntu:22.04 容器内捆绑全套运行时并 dpkg-deb 打包）
make-skeleton-deb.sh     # 仅用静态骨架构建结构样例 deb 并自检（无需 Docker，本地可跑）
verify-deb.py            # deb 包结构合规自检
