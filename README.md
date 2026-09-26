# FunctionComplete v2 — 双原语组件套件

**依据**：《FunctionComplete 技术组件白皮书 v1.3》（2026-09）

**定位**：FCT 是 Ethercoin 团队维护的**链上计算与状态技术组件套件**，不是链、不是代币。本仓库为双原语（门级链上函数 + 领域专用执行单元 DSU）的组件化实现。

**重要声明**：FCT 链尚未激活，FCT 未发行任何代币。经济媒介统一使用 ETHER。

## 组件（白皮书五类）

| 组件 | 实现 | 状态 |
|---|---|---|
| 执行组件：门级函数 | 借 1.0 `fct-library` + `FunctionNFT` | 借用 |
| 执行组件：DSU | `dsu-runtime/`（Rust） | 全新 |
| 状态组件：容器 | `ContainerNFT` + `Container`（Solidity） | M1 |
| 状态组件：CSC | 二进制 Merkle（keccak256；Poseidon/Blake3 待接预编译） | M2 |
| 证明组件：证明市场 | `ProofMarket`（Solidity） | M3 |
| 清算组件：适配器/锚定 | 状态根锚定 + 资产托管 | M7 |
| 身份组件：NFT/版税 | `FunctionNFT` + `ContainerNFT` + 版税登记 | 借+扩 |

## 目录

```
v2/
├── contracts/     Foundry 链上组件（Solidity 0.8.24）
├── dsu-runtime/   DSU 运行时（Rust）
├── indexer/       事件索引器（借 1.0 扩展）
├── frontend/      前端（借 1.0 改造）
├── website/       官网（v1.3 定位，白皮书 v1.3 为准）
├── deployments/   Sepolia 部署记录
└── docs/          架构文档
```

### website 官网（v1.3）

`website/` 为升级后的官网（**独立于 V1.0/website**，1.0 保留不动），内容以白皮书 v1.3 为准：

- **定位**：技术组件套件（非 L2、非代币）+ 双原语（门级函数 + DSU）+ 五类组件
- **无代币声明**：经济章节含反诈骗横幅（FCT 无代币/预售/空投）
- **开发状态**：容器章节含 M1 已部署 Sepolia 的合约地址
- 双语：HTML 内联中文 + JS EN 词典（156 键，已校验一一对应）
- **GateLang 章节**（`#gatelang`）：统一语言前端说明（四层抽象表 + 编译产物），
  导航 / 首页 CTA / 页脚均含 GateLang 入口；下载 GateLang 白皮书 v2.1（`GateLang-whitepaper-zh.md`）
- 白皮书下载：FCT 白皮书 v1.3（`FCT-whitepaper-zh.md`）+ GateLang 白皮书 v2.1（`GateLang-whitepaper-zh.md`）
- 白皮书下载链接指向 v1.3（`FCT-whitepaper-zh.md`）

```bash
cd website && python3 -m http.server 8770   # 本地预览
```

## 目标链

Sepolia 测试网（组件真实上链验证）。持有 1.0 部署账户：`0x376fcC6cA7aeF7B0501771dF314E06e550d62D37`。

## 参考

- 白皮书 v1.3：`docs/FCT-whitepaper-v1.3.md`（仓库内）；源文件：`../FunctionComplete 技术组件白皮书 v1.3.md`
- 开发计划 v1.0：`../FCT 双原语开发计划 v1.0.md`
- 1.0 资产（保留不动）：`../V1.0/`

## 依赖（构建/测试）

- `contracts/` 使用 **forge-std 1.16.2**（仅测试框架；`src/` 的合约本身零外部依赖）。
  固定/安装：`cd contracts && forge install foundry-rs/forge-std@v1.16.2 --no-commit`，
  或以 git submodule 固定。`contracts/lib/` 已纳入版本控制（见 `.gitignore` 注释）。
- 目标机执行 `forge test` 前需 `export PATH="$HOME/.foundry/bin:$PATH"`。