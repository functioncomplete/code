#!/usr/bin/env python3
"""v2 M4 共享层部署：DSU 登记 + 双原语身份登记 + 原语选择器（Sepolia）"""
import json
import os
import subprocess
import sys
from pathlib import Path

CONTRACTS_DIR = str(Path(__file__).resolve().parent.parent)
SCRIPT = "DeployM4SharedLayer.s.sol"
FORGE = os.environ.get("FORGE", "/home/reslsatoshigold/.foundry/bin/forge")
RPC = os.environ.get("FCT_SEPOLIA_RPC", "https://ethereum-sepolia-rpc.publicnode.com")
DEPLOYMENTS = str(Path(__file__).resolve().parent.parent.parent / "deployments")


def _auth(pk, acct):
    """认证参数：优先 Foundry keystore（FORGE_ACCOUNT），否则回退 --private-key 并告警。"""
    if acct:
        return ["--account", acct]
    print("WARNING: 使用 --private-key —— 私钥会出现在进程参数中（ps/proc 可读）；"
          "建议改用 Foundry keystore 并设 FORGE_ACCOUNT=<name>。", flush=True)
    return ["--private-key", pk]


def _check_env_perms(env_file):
    try:
        mode = env_file.stat().st_mode & 0o777
        if mode & 0o077:
            print(f"WARNING: {env_file} 权限 {oct(mode)} 过于宽松（含私钥，建议 chmod 600）", flush=True)
    except OSError:
        pass


def load_env():
    env_file = Path.home() / ".fct-sepolia.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"'))
    _check_env_perms(env_file)


def run(cmd, cwd=CONTRACTS_DIR, extra_env=None, redact=None):
    # 绝不回显私钥：argv 中的密钥一律打码
    shown = ["***" if (redact and a == redact) else a for a in cmd]
    print(f"$ {' '.join(shown)}", flush=True)
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, env=env)
    if p.returncode != 0:
        print(p.stderr[-3000:])
        sys.exit(1)
    return p.stdout


def main():
    os.makedirs(DEPLOYMENTS, exist_ok=True)
    load_env()
    # load_env 之后重解析：使 ~/.fct-sepolia.env 中的 FORGE/RPC 生效
    forge = os.environ.get("FORGE", FORGE)
    rpc = os.environ.get("FCT_SEPOLIA_RPC", RPC)
    pk = os.environ.get("DEPLOY_PRIVATE_KEY")
    acct = os.environ.get("FORGE_ACCOUNT")
    if not pk and not acct:
        print("缺少 DEPLOY_PRIVATE_KEY（或用 FORGE_ACCOUNT 指定 keystore）")
        sys.exit(1)

    out = run([forge, "script", f"script/{SCRIPT}", "--rpc-url", rpc,
               "--broadcast", "--skip-simulation", *_auth(pk, acct)],
              cwd=CONTRACTS_DIR, extra_env={"DEPLOY_PRIVATE_KEY": pk}, redact=pk)
    # 解析地址
    lines = out.splitlines()
    addrs = {}
    for i, ln in enumerate(lines):
        if "DSU_REGISTRY:" in ln or "IDENTITY_REGISTRY:" in ln or "PRIMITIVE_SELECTOR:" in ln:
            key, _, val = ln.partition(":")
            addrs[key.strip()] = val.strip()
    print(out[-2000:])

    # 三个地址都必须解析成功（否则 M4 部署未完成，不得记为成功）
    for k in ("DSU_REGISTRY", "IDENTITY_REGISTRY", "PRIMITIVE_SELECTOR"):
        v = addrs.get(k)
        if not v or not v.startswith("0x"):
            print(f"ERROR: 未能解析 {k} 地址，M4 部署可能失败")
            sys.exit(1)

    record = {
        "milestone": "M4",
        "deployedAt": "2026-09-24",
        "network": "sepolia",
        "rpc": rpc,
        "dsuRegistry": addrs.get("DSU_REGISTRY"),
        "identityRegistry": addrs.get("IDENTITY_REGISTRY"),
        "primitiveSelector": addrs.get("PRIMITIVE_SELECTOR"),
    }
    path = os.path.join(DEPLOYMENTS, "m4-shared-layer-sepolia.json")
    with open(path, "w") as f:
        json.dump(record, f, indent=2)
    print(f"\nrecord -> {path}")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()