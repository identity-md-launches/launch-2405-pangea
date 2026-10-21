// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployPangea} from "../script/DeployPangea.s.sol";
import {PangeaToken} from "../src/PangeaToken.sol";

contract DeployPangeaTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    function test_deployMintsWholeSupplyToTheDeployingAccount() public {
        DeployPangea script = new DeployPangea();
        // The script contract is the deployer here, exactly as the factory is at launch.
        PangeaToken token = script.deploy();
        assertEq(token.name(), "Pangea");
        assertEq(token.symbol(), "PANGEA");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_deployTwiceGivesTwoIndependentTokens() public {
        DeployPangea script = new DeployPangea();
        PangeaToken first = script.deploy();
        PangeaToken second = script.deploy();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(first.balanceOf(address(script)), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(address(script)), EXPECTED_SUPPLY);
    }
}
