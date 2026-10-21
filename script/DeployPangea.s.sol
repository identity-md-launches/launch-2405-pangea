// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {PangeaToken} from "../src/PangeaToken.sol";

/// @title DeployPangea
/// @notice Reviewable deployment entry point for the Pangea token.
/// @dev The IMD launch deploys the token itself through the factory from the attested bytecode; this
/// script exists so the deployment can be reviewed and rehearsed locally. `deploy()` is the unit the
/// tests call directly; `run()` only wraps it in a broadcast. The token takes no constructor
/// arguments, so there is no configuration to read from the environment.
contract DeployPangea is Script {
    /// @notice Deploys a fresh PangeaToken. The whole supply is minted to the caller of this function
    /// (under `run()`, the broadcasting account; under the launch, the factory).
    function deploy() public returns (PangeaToken token) {
        token = new PangeaToken();
    }

    /// @notice Broadcast wrapper around `deploy()` for a manual rehearsal.
    function run() external returns (PangeaToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
