#!/usr/bin/env python3
"""v2 M4 共享层部署：DSU 登记 + 双原语身份登记 + 原语选择器（Sepolia）"""
import json
import os
import subprocess
import sys

CONTRACTS_DIR = os.path.expanduser("~/v2/contracts")
SCRIPT = "DeployM4SharedLayer.s.sol"
FORGE = os.environ.get("FORGE", "/home/reslsatoshigold/.foundry/bin/forge")
RPC = os.environ.get("FCT_SEPOLIA_RPC", "https://ethereum-sepolia-rpc.publicnode.com")
DEPLOYMENTS = os.path.expanduser("~/v2/deployments")


def run(cmd, cwd=CONTRACTS_DIR, extra_env=None):
    print(f"$ {' '.join(cmd)}", flush=True)
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
    pk = os.environ.get("DEPLOY_PRIVATE_KEY")
    if not pk:
        with open(os.path.expanduser("~/.fct-sepolia.env")) as f:
            for line in f:
                if line.startswith("DEPLOY_PRIVATE_KEY="):
                    pk = line.split("=", 1)[1].strip().strip('"')
    assert pk, "缺少 DEPLOY_PRIVATE_KEY"

    out = run([FORGE, "script", f"script/{SCRIPT}", "--rpc-url", RPC,
               "--broadcast", "--skip-simulation", "--private-key", pk],
              cwd=CONTRACTS_DIR, extra_env={"DEPLOY_PRIVATE_KEY": pk})
    # 解析地址
    lines = out.splitlines()
    addrs = {}
    for i, ln in enumerate(lines):
        if "DSU_REGISTRY:" in ln or "IDENTITY_REGISTRY:" in ln or "PRIMITIVE_SELECTOR:" in ln:
            key, _, val = ln.partition(":")
            addrs[key.strip()] = val.strip()
    print(out[-2000:])

    record = {
        "milestone": "M4",
        "deployedAt": "2026-09-24",
        "network": "sepolia",
        "rpc": RPC,
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