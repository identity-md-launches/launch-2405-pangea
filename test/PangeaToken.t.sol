// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PangeaToken} from "../src/PangeaToken.sol";

/// @notice A stand-in for the launch factory: deploys the token so the supply lands on a contract
/// address, then forwards it the way the factory does (distributor, pool, requester).
contract FactoryStub {
    PangeaToken public token;

    function launch() external returns (PangeaToken) {
        token = new PangeaToken();
        return token;
    }

    function move(address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract PangeaTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    PangeaToken internal token;
    address internal deployer = address(this);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);

    function setUp() public {
        token = new PangeaToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Metadata and supply
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Pangea");
        assertEq(token.symbol(), "PANGEA");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Pangea");
        assertEq(token.TOKEN_SYMBOL(), "PANGEA");
        assertEq(token.DECIMALS(), 18);
    }

    function test_constantsMatchTheRequestedSupply() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_mintsWholeSupplyToDeployerOnce() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "total supply");
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, "deployer balance");
    }

    function test_deploymentEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), ALICE, EXPECTED_SUPPLY);
        vm.prank(ALICE);
        PangeaToken fresh = new PangeaToken();
        assertEq(fresh.balanceOf(ALICE), EXPECTED_SUPPLY);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_supplyMintsToWhoeverDeploysIncludingAContract() public {
        FactoryStub factory = new FactoryStub();
        PangeaToken launched = factory.launch();
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(address(factory)), EXPECTED_SUPPLY, "factory holds the whole supply");
        assertEq(launched.balanceOf(address(this)), 0, "the test harness received nothing");
    }

    function test_eachDeploymentIsIndependent() public {
        PangeaToken second = new PangeaToken();
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertTrue(address(second) != address(token));
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: success
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        uint256 amount = 1_234e18;
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, ALICE, amount);
        assertTrue(token.transfer(ALICE, amount));
        assertEq(token.balanceOf(ALICE), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        assertTrue(token.transfer(ALICE, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(ALICE), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        assertTrue(token.transfer(ALICE, 0));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferToSelfKeepsBalance() public {
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferChainArrivesWhole() public {
        uint256 amount = 777e18;
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(BOB);
        token.transfer(CAROL, amount);
        assertEq(token.balanceOf(CAROL), amount, "no fee or burn on the way");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers: failure
    // ---------------------------------------------------------------------------------------------

    function test_transferRevertsOnInsufficientBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transfer(BOB, 1);
    }

    function test_transferRevertsOneWeiOverBalance() public {
        token.transfer(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100, 101));
        vm.prank(ALICE);
        token.transfer(BOB, 101);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances: success and failure
    // ---------------------------------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, ALICE, 50e18);
        assertTrue(token.approve(ALICE, 50e18));
        assertEq(token.allowance(deployer, ALICE), 50e18);
    }

    function test_approveOverwritesPreviousAllowance() public {
        token.approve(ALICE, 50e18);
        token.approve(ALICE, 20e18);
        assertEq(token.allowance(deployer, ALICE), 20e18);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowance() public {
        token.approve(ALICE, 50e18);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(deployer, BOB, 30e18));
        assertEq(token.balanceOf(BOB), 30e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 30e18);
        assertEq(token.allowance(deployer, ALICE), 20e18);
    }

    function test_transferFromWithInfiniteAllowanceDoesNotDecrement() public {
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, 30e18);
        assertEq(token.allowance(deployer, ALICE), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, 1);
    }

    function test_transferFromRevertsAboveAllowance() public {
        token.approve(ALICE, 10);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 10, 11));
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, 11);
    }

    function test_transferFromRevertsWhenOwnerLacksBalance() public {
        vm.prank(ALICE);
        token.approve(BOB, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 100));
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 100);
    }

    function test_allowanceDoesNotLetSpenderMoveOwnTokensFromOthers() public {
        // An allowance from the deployer to ALICE says nothing about BOB.
        token.approve(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        vm.prank(BOB);
        token.transferFrom(deployer, BOB, 1);
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged surface: nothing mints, pauses, freezes or seizes
    // ---------------------------------------------------------------------------------------------

    function test_noAdminCallIncreasesSupplyOrMovesBalances() public {
        address attacker = address(0xBEEF);
        string[12] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)",
            "owner()",
            "renounceOwnership()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            // The deployer, the most plausibly trusted address, has no such power either.
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        token.transfer(ALICE, 1_000e18);
        string[13] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "burn(uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ALICE, true);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        // The deployer cannot pull from a holder without an allowance.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(ALICE, deployer, 1);
        assertEq(token.balanceOf(ALICE), 1_000e18, "the holder still holds everything");
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 500e18), "the holder can still transfer");
        assertEq(token.balanceOf(BOB), 500e18);
    }

    function test_unknownSelectorAndPlainEtherRevert() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "no fallback");
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool paid,) = address(token).call{value: 1 ether}("");
        assertFalse(paid, "no receive");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "EIP-170");
        bool reachable = true;
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op == 0x5B) reachable = true;
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            if (reachable) {
                assertTrue(op != 0xF4, "DELEGATECALL");
                assertTrue(op != 0xF2, "CALLCODE");
                assertTrue(op != 0xFF, "SELFDESTRUCT");
            }
            if (op == 0x00 || op == 0x56 || op == 0xF3 || op == 0xFD || op == 0xFE || op == 0xFF) reachable = false;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Launch flows: the factory forwards the supply whole and the supply never changes
    // ---------------------------------------------------------------------------------------------

    function test_launchSharesArriveWholeAndClaimWhole() public {
        FactoryStub factory = new FactoryStub();
        PangeaToken launched = factory.launch();
        address distributor = address(0xD157);
        address claimant = address(0xC1A1);
        address requester = address(0xd0116C7E933029a0abfa388757a3d7a7686ee681);

        uint256 swarm = (EXPECTED_SUPPLY * 1_000) / 10_000;
        uint256 pool = (EXPECTED_SUPPLY * 8_000) / 10_000;
        uint256 remainder = EXPECTED_SUPPLY - swarm - pool;

        assertTrue(factory.move(distributor, swarm));
        assertEq(launched.balanceOf(distributor), swarm, "swarm share arrived whole");
        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, swarm));
        assertEq(launched.balanceOf(claimant), swarm, "claim arrived whole");
        assertEq(launched.balanceOf(distributor), 0);

        assertTrue(factory.move(requester, remainder));
        assertEq(launched.balanceOf(requester), remainder, "remainder arrived whole");
        assertEq(launched.balanceOf(address(factory)), pool, "the pool share is what is left");
        assertEq(launched.totalSupply(), EXPECTED_SUPPLY, "the launch flows did not change the supply");
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndIsExact(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        token.transfer(ALICE, amount);
    }

    function testFuzz_transferFromRespectsAllowanceExactly(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        token.approve(ALICE, allowance);
        vm.prank(ALICE);
        if (spend > allowance) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowance, spend)
            );
            token.transferFrom(deployer, BOB, spend);
        } else {
            assertTrue(token.transferFrom(deployer, BOB, spend));
            assertEq(token.balanceOf(BOB), spend);
            assertEq(token.allowance(deployer, ALICE), allowance - spend);
            assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        }
    }

    function testFuzz_manyHopsNeverChangeSupply(uint8 hops, uint256 seed) public {
        address current = deployer;
        uint256 amount = bound(seed, 1, EXPECTED_SUPPLY);
        for (uint256 i = 0; i < hops; i++) {
            address next = address(uint160(uint256(keccak256(abi.encode(seed, i))) | 1));
            vm.prank(current);
            token.transfer(next, amount);
            assertEq(token.balanceOf(current), current == deployer ? EXPECTED_SUPPLY - amount : 0);
            current = next;
        }
        assertEq(token.balanceOf(current), hops == 0 ? EXPECTED_SUPPLY : amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
