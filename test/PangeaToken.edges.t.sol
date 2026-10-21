// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PangeaToken} from "../src/PangeaToken.sol";

/// @notice Edge cases the main suite does not pin: self-spending, the zero address on every side of
/// transferFrom, the full supply through an allowance, tokens sent to the token itself, and fuzzed
/// failure paths that must leave every balance and allowance as they were.
contract PangeaTokenEdgesTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    PangeaToken internal token;
    address internal deployer = address(this);

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    function setUp() public {
        token = new PangeaToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Pinned edges
    // ---------------------------------------------------------------------------------------------

    function test_supplyFitsComfortablyInUint256() public view {
        // 1e27 is about 2^89.7: no balance arithmetic on this supply can approach overflow.
        assertLt(token.totalSupply(), uint256(type(uint96).max));
    }

    function test_freshAccountsStartEmpty() public view {
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(deployer, ALICE), 0);
    }

    function test_transferFromSelfStillNeedsAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, ALICE, 1);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_transferFromSelfWithAllowanceSpendsIt() public {
        token.approve(deployer, 10);
        assertTrue(token.transferFrom(deployer, ALICE, 4));
        assertEq(token.allowance(deployer, deployer), 6);
        assertEq(token.balanceOf(ALICE), 4);
    }

    function test_transferFromZeroAmountWithoutAllowanceSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transferFrom(deployer, BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(deployer, ALICE), 0);
    }

    function test_transferFromToZeroAddressReverts() public {
        token.approve(ALICE, 100);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        token.transferFrom(deployer, address(0), 1);
        assertEq(token.allowance(deployer, ALICE), 100, "a reverted transferFrom spent no allowance");
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        // Nobody can hold an allowance from the zero address, so the allowance check stops it first.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(address(0), BOB, 1);
    }

    function test_approveFromZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        vm.prank(address(0));
        token.approve(ALICE, 1);
    }

    function test_transferFromTheZeroAddressReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        vm.prank(address(0));
        token.transfer(ALICE, 0);
    }

    function test_wholeSupplyThroughExactAllowance() public {
        token.approve(ALICE, EXPECTED_SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(deployer, BOB, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(BOB), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.allowance(deployer, ALICE), 0);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_infiniteAllowanceStillBoundedByBalance() public {
        token.transfer(ALICE, 50);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 50, 51));
        vm.prank(BOB);
        token.transferFrom(ALICE, BOB, 51);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
    }

    function test_approveZeroRevokes() public {
        token.approve(ALICE, 100);
        token.approve(ALICE, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, 1);
    }

    function test_transferFromEmitsTransferButNoApproval() public {
        token.approve(ALICE, 100);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, 40);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event");
        assertEq(logs[0].topics[0], IERC20.Transfer.selector);
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(deployer))));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(BOB))));
        assertEq(abi.decode(logs[0].data, (uint256)), 40);
    }

    function test_tokensSentToTheTokenAreStuck() public {
        token.transfer(address(token), 1_000);
        assertEq(token.balanceOf(address(token)), 1_000);
        // The contract has no function that can move its own balance.
        (bool ok,) = address(token).call(abi.encodeWithSignature("rescue(address,uint256)", deployer, 1_000));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("withdraw(address,uint256)", address(token), 1_000));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1_000);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_noPermitOrAllowanceHelpers() public {
        // Plain ERC-20 surface only: no EIP-2612 permit, no increase/decrease helpers.
        (bool ok,) = address(token).call(abi.encodeWithSignature("nonces(address)", deployer));
        assertFalse(ok, "nonces");
        (ok,) = address(token).call(abi.encodeWithSignature("DOMAIN_SEPARATOR()"));
        assertFalse(ok, "DOMAIN_SEPARATOR");
        (ok,) = address(token).call(abi.encodeWithSignature("increaseAllowance(address,uint256)", ALICE, 1));
        assertFalse(ok, "increaseAllowance");
        (ok,) = address(token).call(abi.encodeWithSignature("decreaseAllowance(address,uint256)", ALICE, 1));
        assertFalse(ok, "decreaseAllowance");
        assertEq(token.allowance(deployer, ALICE), 0);
    }

    function test_cannotSendEtherWithTransfer() public {
        vm.deal(deployer, 1 ether);
        (bool ok,) = address(token).call{value: 1}(abi.encodeCall(token.transfer, (ALICE, 1)));
        assertFalse(ok, "transfer is not payable");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(address(token).balance, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Fuzzed failure paths: a revert changes nothing
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_overBalanceTransferChangesNothing(uint256 held, uint256 excess, address to) public {
        held = bound(held, 0, EXPECTED_SUPPLY);
        if (to == address(0)) to = BOB;
        token.transfer(ALICE, held);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        uint256 toBefore = token.balanceOf(to);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
        vm.prank(ALICE);
        token.transfer(to, amount);

        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(to), toBefore);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_overAllowanceTransferFromChangesNothing(uint256 allowed, uint256 excess) public {
        allowed = bound(allowed, 0, type(uint256).max - 1);
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        token.approve(ALICE, allowed);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowed, amount)
        );
        vm.prank(ALICE);
        token.transferFrom(deployer, BOB, amount);

        assertEq(token.allowance(deployer, ALICE), allowed);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_approveIsExactAndOverwrites(address spender, uint256 first, uint256 second) public {
        if (spender == address(0)) spender = ALICE;
        token.approve(spender, first);
        assertEq(token.allowance(deployer, spender), first);
        token.approve(spender, second);
        assertEq(token.allowance(deployer, spender), second);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY, "approve moves nothing");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromEitherSucceedsExactlyOrRevertsCleanly(uint256 held, uint256 allowed, uint256 amount)
        public
    {
        held = bound(held, 0, EXPECTED_SUPPLY);
        allowed = bound(allowed, 0, EXPECTED_SUPPLY * 2);
        amount = bound(amount, 0, EXPECTED_SUPPLY * 2);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowed);

        vm.prank(BOB);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, BOB, allowed, amount)
            );
            token.transferFrom(ALICE, BOB, amount);
            assertEq(token.balanceOf(ALICE), held);
            assertEq(token.allowance(ALICE, BOB), allowed);
        } else if (amount > held) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, amount));
            token.transferFrom(ALICE, BOB, amount);
            assertEq(token.balanceOf(ALICE), held);
            assertEq(token.allowance(ALICE, BOB), allowed);
        } else {
            assertTrue(token.transferFrom(ALICE, BOB, amount));
            assertEq(token.balanceOf(ALICE), held - amount);
            assertEq(token.balanceOf(BOB), amount);
            assertEq(token.allowance(ALICE, BOB), allowed - amount);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_selfTransferIsANoOp(address who, uint256 held, uint256 amount) public {
        if (who == address(0) || who == deployer) who = ALICE;
        held = bound(held, 0, EXPECTED_SUPPLY);
        amount = bound(amount, 0, held);
        token.transfer(who, held);
        vm.prank(who);
        assertTrue(token.transfer(who, amount));
        assertEq(token.balanceOf(who), held);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - held);
    }
}
