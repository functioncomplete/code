"""v2 M1 容器组件 Sepolia 部署脚本。

用法（在目标机）：
    python3 script/deploy_container_sepolia.py

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
DEPLOY_OUT = Path(__file__).resolve().parent.parent.parent / "deployments" / "container-sepolia.json"


def load_env():
    env_file = Path.home() / ".fct-sepolia.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"'))


def main():
    load_env()
    pk = os.environ.get("DEPLOY_PRIVATE_KEY")
    addr = os.environ.get("DEPLOY_ADDRESS")
    if not pk or not addr:
        print("缺少 DEPLOY_PRIVATE_KEY / DEPLOY_ADDRESS（见 ~/.fct-sepolia.env）")
        sys.exit(1)

    env = dict(
        os.environ,
        PATH=os.path.dirname(FORGE) + ":" + os.environ.get("PATH", ""),
    )

    print(f"部署容器组件到 Sepolia: {RPC}\n部署账户: {addr}\n")
    r = subprocess.run(
        [FORGE, "script", "script/DeployContainer.s.sol",
         "--rpc-url", RPC, "--broadcast", "--private-key", pk],
        cwd=CONTRACTS, capture_output=True, text=True, env=env, timeout=300,
    )
    if r.returncode != 0:
        print("部署失败:\n", (r.stderr or r.stdout)[-1500:])
        sys.exit(1)

    # 解析 console.log 输出的地址（子串匹配，容忍行前缩进/前缀）
    addrs = {}
    for line in (r.stdout + r.stderr).splitlines():
        for k in ["ContainerNFT", "Container", "ContainerTokenId"]:
            if k + ":" in line and ("0x" in line or k == "ContainerTokenId"):
                addrs[k] = line.split(k + ":", 1)[1].strip()
    if "ContainerNFT" not in addrs or "Container" not in addrs:
        print("地址解析不完整:", addrs)
        print("--- 部署输出尾部 ---\n", (r.stdout + r.stderr)[-2000:])
        sys.exit(1)

    DEPLOY_OUT.parent.mkdir(parents=True, exist_ok=True)
    DEPLOY_OUT.write_text(json.dumps(addrs, indent=2))
    print("✓ 容器组件部署完成:")
    print(json.dumps(addrs, indent=2))
    print(f"地址已写入 {DEPLOY_OUT}")


if __name__ == "__main__":
    main()