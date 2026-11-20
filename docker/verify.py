#!/usr/bin/env python3
"""OpnForm TOS 包静态合规自检。

对照《TOS 7 应用开发指南》第 8/9 章逐条检查 dist/ 下的两个 tar.gz：
  1. 包内恰好 4 个文件（config.ini / opnform.lang / opnform.svg / docker-compose.yml）
  2. config.ini 为合法 JSON，必填字段齐全，platform ∈ {x86_64, aarch64}，application_type=docker，
     depend 含 DockerEngine，compose_project 非空，icon 路径正确
  3. lang 文件 26 节齐全，每节 name/auth/descript 非空
  4. compose：YAML 可解析；宿主端口不在保留列表且在 8000-19999；
     无 privileged / network_mode:host；volumes/ports 序列内无注释；
     每个服务有 healthcheck；镜像 tag 非 latest；x-app-meta 存在且端口一致
  5. 全部文件 LF 行尾
不检查（需要真实 Docker/TOS 环境，见 README）：镜像架构、运行时行为、真机安装。
"""
import io
import json
import sys
import tarfile

try:
    import yaml
except ImportError:
    sys.exit("缺少 PyYAML：pip install pyyaml")

REQUIRED_LANGS = [
    "zh-cn", "zh-hk", "en-us", "ko-kr", "ja-jp", "de-de", "fr-fr", "it-it",
    "es-es", "hu-hu", "pl-pl", "tr-tr", "ru-ru", "pt-pt", "cs-cz", "da-dk",
    "nl-nl", "nb-no", "sv-se", "el-gr", "ro-ro", "th-th", "vi-vn", "id-id",
    "ar-sa", "he-il",
]
RESERVED_PORTS = {22, 80, 443, 445, 3306, 5050, 5432, 6379, 8181, 8443}
REQUIRED_CONFIG = ["id", "icon", "publisher", "exec", "version", "help",
                   "category", "platform", "application_type", "user",
                   "compose_project", "depend"]

errors, warnings = [], []


def check_package(path):
    with tarfile.open(path) as tf:
        names = sorted(tf.getnames())
        expect = sorted(["config.ini", "opnform.lang", "opnform.svg", "docker-compose.yml"])
        if names != expect:
            errors.append(f"{path}: 包内文件应为 {expect}，实际 {names}")
            return
        files = {n: io.TextIOWrapper(tf.extractfile(n), encoding="utf-8").read() for n in names}

    # ---- config.ini ----
    try:
        cfg = json.loads(files["config.ini"])
    except json.JSONDecodeError as e:
        errors.append(f"config.ini 不是合法 JSON: {e}")
        cfg = None
    if cfg:
        for f in REQUIRED_CONFIG:
            if not cfg.get(f):
                errors.append(f"config.ini 缺少必填字段 {f}")
        if cfg.get("application_type") != "docker":
            errors.append("config.ini application_type 必须为 docker")
        if cfg.get("platform") not in ("x86_64", "aarch64"):
            errors.append(f"config.ini platform 非法: {cfg.get('platform')}")
        if "DockerEngine" not in (cfg.get("depend") or []):
            errors.append("config.ini depend 必须包含 DockerEngine")
        if cfg.get("icon") != f"/images/icons/{cfg.get('id')}.svg":
            errors.append("config.ini icon 路径与 id 不匹配")
        if cfg.get("system_id") or cfg.get("package"):
            warnings.append("config.ini system_id/package 对 Docker 应用应为空")

    # ---- lang ----
    sections, current = {}, None
    for line in files["opnform.lang"].splitlines():
        line = line.strip()
        if line.startswith("#") or not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections[current] = {}
        elif "=" in line and current:
            k, v = line.split("=", 1)
            sections[current][k.strip()] = v.strip().strip('"')
    for lang in REQUIRED_LANGS:
        if lang not in sections:
            errors.append(f"lang 缺少语种 {lang}")
        else:
            for f in ("name", "auth", "descript"):
                if not sections[lang].get(f, "").strip():
                    errors.append(f"lang[{lang}].{f} 为空（未翻译语种应填英文，不得留空）")

    # ---- docker-compose.yml ----
    try:
        compose = yaml.safe_load(files["docker-compose.yml"])
    except yaml.YAMLError as e:
        errors.append(f"docker-compose.yml 解析失败: {e}")
        compose = None
    if compose:
        services = compose.get("services", {})
        for name, svc in services.items():
            if svc.get("privileged"):
                errors.append(f"服务 {name} 使用 privileged（禁止）")
            if svc.get("network_mode") == "host":
                errors.append(f"服务 {name} 使用 network_mode: host（禁止）")
            if not svc.get("healthcheck"):
                errors.append(f"服务 {name} 缺少 healthcheck")
            image = svc.get("image", "")
            if image.endswith(":latest") or image.endswith("-latest"):
                errors.append(f"服务 {name} 镜像 tag 为 latest（必须锁定版本）")
            ports = svc.get("ports") or []
            for p in ports:
                host = str(p).split(":")[0]
                if host.isdigit():
                    n = int(host)
                    if n in RESERVED_PORTS:
                        errors.append(f"服务 {name} 宿主端口 {n} 在系统保留列表")
                    if not (8000 <= n <= 19999):
                        warnings.append(f"服务 {name} 宿主端口 {n} 不在推荐区间 8000-19999")
        meta = compose.get("x-app-meta", {}).get("web", {})
        if not meta.get("port"):
            errors.append("缺少 x-app-meta.web.port")
        main = services.get("opnform", {})
        host_ports = [str(p).split(":")[0] for p in (main.get("ports") or [])]
        if str(meta.get("port")) not in host_ports:
            errors.append("x-app-meta.web.port 与主服务宿主端口不一致")
        # volumes/ports 序列内不得有注释（平台逐行解析）
        in_block, block = False, None
        for line in files["docker-compose.yml"].splitlines():
            s = line.strip()
            if s in ("volumes:", "ports:"):
                in_block, block = True, s
                continue
            if in_block and s.startswith("- "):
                if "#" in s:
                    errors.append(f"volumes/ports 序列内发现注释: {s}")
            elif in_block and s and not s.startswith("-"):
                in_block = False

    # ---- 行尾 ----
    for n, content in files.items():
        if "\r\n" in content:
            errors.append(f"{n} 存在 CRLF 行尾（必须 LF）")

    print(f"[检查] {path}: {'通过' if not [e for e in errors if path in e] else '发现问题'}")


def main():
    import glob
    pkgs = sorted(glob.glob("dist/opnform_*.tar.gz"))
    if not pkgs:
        print("dist/ 下没有包，请先运行 ./make-packages.sh")
        sys.exit(1)
    for p in pkgs:
        check_package(p)
    if warnings:
        print("\n警告（不阻断提交，建议处理）:")
        for w in warnings:
            print(f"  - {w}")
    if errors:
        print("\n未通过项:")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)
    print("\n全部静态检查通过。剩余需真机验证项见 README.md「验证边界」。")


if __name__ == "__main__":
    main()
