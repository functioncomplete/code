// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ProofMarket} from "../src/ProofMarket.sol";

/// @notice v2 M3 ProofMarket 证明市场部署脚本（Sepolia）
/// @dev 原型参数（白皮书 v1.3 §6.2–6.3 无固定数值，取原合理值）：
///        VOTING_WINDOW = 3600s（提交后 1 小时投票窗口）
///      其余常量在合约内：>2/3 多数、手续费 0.5%、罚没 50/50、MIN_STAKE=0.01 ETH
contract DeployProofMarket is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOY_PRIVATE_KEY");
        vm.startBroadcast(pk);

        ProofMarket pm = new ProofMarket(3600);
        console2.log("PROOFMARKET:", address(pm));
        console2.log("PM_VOTING_WINDOW:", pm.VOTING_WINDOW());
        console2.log("PM_VOTER_NUM:", pm.VOTER_NUM());
        console2.log("PM_VOTER_DEN:", pm.VOTER_DEN());
        console2.log("PM_FEE_BPS:", pm.FEE_BPS());
        console2.log("PM_SLASH_VALIDATOR_BPS:", pm.SLASH_VALIDATOR_BPS());
        console2.log("PM_MIN_STAKE:", pm.MIN_STAKE());
        console2.log("PM_OWNER:", pm.owner());

        vm.stopBroadcast();
    }
}