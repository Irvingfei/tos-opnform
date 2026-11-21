#!/usr/bin/env python3
"""OpnForm TOS Deb 包静态合规自检。

对照《TOS 7 应用开发指南》第 8 章检查 deb 包（骨架样例或完整包）：
  1. control 字段齐全，Architecture ∈ {amd64, arm64}（禁 x86_64 写法），无占位符残留
  2. data.tar 内元数据在 usr/local/opnform/ 下（解析器只认这个路径，§8.2 致命错误项）
     config.ini / opnform.lang / images/icons/opnform.svg / init.d/opnform.service
  3. config.ini：application_type=deb、open_path=true 且无 type（外部打开互斥）、
     system_id=package=control.Package、id=opnform、icon 路径、无 depend 字段（Deb 禁用）
  4. lang 26 节、每节 name/auth/descript 非空
  5. systemd 单元：User/Group=opnform、ProtectSystem=strict、ReadWritePaths、无 Restart=
  6. 生命周期脚本存在、bash -n 语法通过
不检查（需真实环境）：运行时二进制可用性、真机安装运行。
用法：python3 verify-deb.py [--skeleton]
  --skeleton 允许缺 depends/ api/ client/（结构样例）
"""
import json
import subprocess
import sys
import tarfile
import tempfile
import os

REQUIRED_LANGS = [
    "zh-cn", "zh-hk", "en-us", "ko-kr", "ja-jp", "de-de", "fr-fr", "it-it",
    "es-es", "hu-hu", "pl-pl", "tr-tr", "ru-ru", "pt-pt", "cs-cz", "da-dk",
    "nl-nl", "nb-no", "sv-se", "el-gr", "ro-ro", "th-th", "vi-vn", "id-id",
    "ar-sa", "he-il",
]
errors, warnings = [], []
SKELETON = "--skeleton" in sys.argv


def sh(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


def check(deb_path):
    # ---- control ----
    rc, info = sh(["dpkg-deb", "-f", deb_path])
    if rc != 0:
        errors.append(f"{deb_path}: dpkg-deb -f 失败: {info}")
        return
    fields = {}
    for line in info.splitlines():
        if ":" in line and not line.startswith(" "):
            k, v = line.split(":", 1)
            fields[k.strip()] = v.strip()
    for f in ("Package", "Version", "Architecture", "Maintainer", "Description", "Section"):
        if not fields.get(f):
            errors.append(f"control 缺少 {f}")
    if fields.get("Architecture") not in ("amd64", "arm64"):
        errors.append(f"control Architecture 非法: {fields.get('Architecture')}（必须 amd64/arm64）")
    if "__" in info:
        errors.append("control 存在未注入的占位符")

    # ---- data.tar 布局 ----
    rc, listing = sh(["dpkg-deb", "-c", deb_path])
    if rc != 0:
        errors.append(f"dpkg-deb -c 失败: {listing}")
        return
    required_paths = [
        "usr/local/opnform/config.ini",
        "usr/local/opnform/opnform.lang",
        "usr/local/opnform/images/icons/opnform.svg",
        "usr/local/opnform/init.d/opnform.service",
        "usr/local/opnform/bin/opnform-supervisor",
        "usr/local/opnform/bin/opnform-setup.sh",
        "usr/local/opnform/bin/opnform-migrate.sh",
    ]
    if not SKELETON:
        required_paths += [
            "usr/local/opnform/depends/php/bin/php",
            "usr/local/opnform/depends/node/bin/node",
            "usr/local/opnform/depends/postgres/bin/postgres",
            "usr/local/opnform/depends/redis/bin/redis-server",
            "usr/local/opnform/depends/nginx/sbin/nginx",
        ]
    for p in required_paths:
        if f"./{p}" not in listing:
            errors.append(f"data.tar 缺少 {p}")
    # 元数据绝不能落在 deb 根（§8.2 常见致命错误）
    for bad in ("./config.ini", "./opnform.lang", "./images/"):
        if any(l.split()[-1] == bad.rstrip("/") for l in listing.splitlines() if l.strip()):
            errors.append(f"发现元数据错误落位 {bad}（必须在 usr/local/opnform/ 下）")

    # ---- 解出内容做深检 ----
    with tempfile.TemporaryDirectory() as td:
        subprocess.run(["dpkg-deb", "-R", deb_path, td], capture_output=True)  # -R 解出 DEBIAN/ + data
        base = os.path.join(td, "usr/local/opnform")

        cfg = json.load(open(os.path.join(base, "config.ini")))
        if cfg.get("application_type") != "deb":
            errors.append("config.ini application_type 必须为 deb")
        if cfg.get("id") != "opnform":
            errors.append("config.ini id 应为 opnform")
        if cfg.get("system_id") != "opnform" or cfg.get("package") != "opnform":
            errors.append("config.ini system_id/package 必须为 opnform")
        if fields.get("Package") != cfg.get("package"):
            errors.append("control.Package 与 config.ini.package 不一致")
        if cfg.get("open_path") is not True:
            errors.append("外部打开模式必须 open_path=true")
        if "type" in cfg:
            errors.append("open_path 与 type 互斥，不得同时出现")
        if "depend" in cfg:
            errors.append("Deb 应用 config.ini 禁止 depend 字段（依赖在 control.Depends 声明）")
        if cfg.get("icon") != "/images/icons/opnform.svg":
            errors.append("config.ini icon 路径非法")
        if cfg.get("user") != "opnform":
            errors.append("config.ini user 必须为 opnform（非 root）")
        if cfg.get("platform") not in ("x86_64", "aarch64"):
            errors.append(f"config.ini platform 非法: {cfg.get('platform')}")
        expected_platform = "x86_64" if fields.get("Architecture") == "amd64" else "aarch64"
        if cfg.get("platform") != expected_platform:
            errors.append(f"config.ini.platform({cfg.get('platform')}) 与 Architecture({fields.get('Architecture')}) 不匹配")

        # lang
        sections, cur = {}, None
        for line in open(os.path.join(base, "opnform.lang"), encoding="utf-8"):
            s = line.strip()
            if s.startswith("[") and s.endswith("]"):
                cur = s[1:-1]
                sections[cur] = {}
            elif "=" in s and cur:
                k, v = s.split("=", 1)
                sections[cur][k.strip()] = v.strip().strip('"')
        for lang in REQUIRED_LANGS:
            if lang not in sections:
                errors.append(f"lang 缺少 {lang}")
            else:
                for f in ("name", "auth", "descript"):
                    if not sections[lang].get(f, ""):
                        errors.append(f"lang[{lang}].{f} 为空")

        # systemd 单元
        unit = open(os.path.join(base, "init.d/opnform.service")).read()
        for must in ("User=opnform", "Group=opnform", "ProtectSystem=strict",
                     "ProtectHome=true", "NoNewPrivileges=true",
                     "ReadWritePaths=/usr/local/opnform/data /usr/local/opnform/logs"):
            if not any(l.strip().startswith(must) for l in unit.splitlines()):
                errors.append(f"systemd 单元缺少 {must}")
        if any(l.strip().startswith("Restart=") for l in unit.splitlines()):
            errors.append("systemd 单元不得配置 Restart=（平台管理）")

        # 生命周期脚本语法
        for script in ("preinst", "postinst", "prerm", "postrm"):
            p = os.path.join(td, "DEBIAN", script)
            if not os.path.exists(p):
                errors.append(f"缺少 DEBIAN/{script}")
                continue
            rc, out = sh(["bash", "-n", p])
            if rc != 0:
                errors.append(f"DEBIAN/{script} bash 语法错误: {out.strip()[:120]}")
            mode = os.stat(p).st_mode & 0o777
            if mode != 0o755:
                errors.append(f"DEBIAN/{script} 权限应为 755，实际 {oct(mode)}")

        # supervisor / setup 语法
        rc, out = sh(["python3", "-m", "py_compile", os.path.join(base, "bin/opnform-supervisor")])
        if rc != 0:
            errors.append(f"opnform-supervisor 语法错误: {out.strip()[:120]}")
        for s in ("opnform-setup.sh", "opnform-migrate.sh"):
            rc, out = sh(["bash", "-n", os.path.join(base, "bin", s)])
            if rc != 0:
                errors.append(f"{s} bash 语法错误: {out.strip()[:120]}")


def main():
    import glob
    pkgs = sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), "dist", "opnform_*.deb")))
    if not pkgs:
        print("dist/ 下没有 deb，请先运行 ./make-skeleton-deb.sh 或 build-in-container.sh")
        sys.exit(1)
    for p in pkgs:
        before = len(errors)
        check(p)
        print(f"[检查] {p}: {'通过' if len(errors) == before else '发现问题'}")
    if warnings:
        print("\n警告:")
        for w in warnings:
            print(f"  - {w}")
    if errors:
        print("\n未通过项:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("\n全部静态检查通过。运行时行为需按 README 在真机验证。")


if __name__ == "__main__":
    main()
