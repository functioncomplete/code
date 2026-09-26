"""v2 M3 ProofMarket 证明市场 Sepolia 部署脚本。

用法（在目标机）：
    python3 script/deploy_proofmarket_sepolia.py

环境变量（或 ~/.fct-sepolia.env）：
    SEPOLIA_RPC / DEPLOY_PRIVATE_KEY / DEPLOY_ADDRESS
"""

import json
import os
import subprocess
import sys
from pathlib import Path

FORGE = os.environ.get("FORGE", "/home/reslsatoshigold/.foundry/bin/forge")
RPC = os.environ.get("SEPOLIA_RPC", "https://ethereum-sepolia-rpc.publicnode.com")
CONTRACTS = Path(__file__).resolve().parent.parent
DEPLOY_OUT = Path(__file__).resolve().parent.parent.parent / "deployments" / "proofmarket-sepolia.json"


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


def main():
    load_env()
    # load_env 之后重解析：使 ~/.fct-sepolia.env 中的 FORGE/SEPOLIA_RPC 生效
    forge = os.environ.get("FORGE", FORGE)
    rpc = os.environ.get("SEPOLIA_RPC", RPC)
    pk = os.environ.get("DEPLOY_PRIVATE_KEY")
    acct = os.environ.get("FORGE_ACCOUNT")
    addr = os.environ.get("DEPLOY_ADDRESS")
    if (not pk and not acct) or not addr:
        print("缺少 DEPLOY_PRIVATE_KEY（或用 FORGE_ACCOUNT 指定 keystore）/ DEPLOY_ADDRESS（见 ~/.fct-sepolia.env）")
        sys.exit(1)

    env = dict(
        os.environ,
        PATH=(os.path.dirname(forge) + ":" if os.path.dirname(forge) else "") + os.environ.get("PATH", ""),
    )

    print(f"部署 ProofMarket 证明市场到 Sepolia: {rpc}\n部署账户: {addr}\n")
    r = subprocess.run(
        [forge, "script", "script/DeployProofMarket.s.sol",
         "--rpc-url", rpc, "--broadcast", *_auth(pk, acct)],
        cwd=CONTRACTS, capture_output=True, text=True, env=env, timeout=300,
    )
    if r.returncode != 0:
        print("部署失败:\n", (r.stderr or r.stdout)[-1500:])
        sys.exit(1)

    out = {}
    keys = ["PROOFMARKET", "PM_VOTING_WINDOW", "PM_VOTER_NUM", "PM_VOTER_DEN",
            "PM_FEE_BPS", "PM_SLASH_VALIDATOR_BPS", "PM_MIN_STAKE", "PM_OWNER"]
    for line in (r.stdout + r.stderr).splitlines():
        for k in keys:
            if k + ":" in line and ("0x" in line or any(ch.isdigit() for ch in line)):
                out[k] = line.split(k + ":", 1)[1].strip()
    if "PROOFMARKET" not in out or not out["PROOFMARKET"].startswith("0x"):
        print("地址解析不完整:", out)
        print("--- 部署输出尾部 ---\n", (r.stdout + r.stderr)[-2000:])
        sys.exit(1)

    out["deployedAt"] = "2026-09-24"
    out["deployer"] = addr

    DEPLOY_OUT.parent.mkdir(parents=True, exist_ok=True)
    DEPLOY_OUT.write_text(json.dumps(out, indent=2))
    print("✓ ProofMarket 部署完成:")
    print(json.dumps(out, indent=2))
    print(f"地址已写入 {DEPLOY_OUT}")


if __name__ == "__main__":
    main()