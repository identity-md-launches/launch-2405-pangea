// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {PangeaToken} from "../src/PangeaToken.sol";

/// @notice Drives PangeaToken with bounded random calls from a fixed set of actors and keeps a ghost
/// ledger of what every balance and allowance must be. Expected failures are attempted too, and each
/// one must revert with the exact error and leave the state untouched. Anything unexpected is
/// recorded in `violations` (the handler itself never reverts, so nothing is silently discarded).
contract PangeaHandler is Test {
    PangeaToken public immutable token;

    address[] internal actors;
    /// @dev Every address that has ever held a balance: actors, the token itself, outsiders.
    address[] internal holders;
    mapping(address => bool) internal isHolder;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    uint256 public violations;
    string public lastViolation;

    uint256 public okTransfers;
    uint256 public okTransferFroms;
    uint256 public okApprovals;
    uint256 public expectedReverts;
    uint256 public fullBalanceMoves;

    constructor(PangeaToken token_, address[] memory actors_) {
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors_.length; ++i) {
            _track(actors_[i]);
            ghostBalance[actors_[i]] = token_.balanceOf(actors_[i]);
        }
        _track(address(token_));
    }

    // ---------------------------------------------------------------------------------------------
    // Successful paths
    // ---------------------------------------------------------------------------------------------

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        _doTransfer(from, to, amount);
    }

    /// @dev The whole balance in one call: the edge where an off-by-one would show.
    function transferAll(uint256 fromSeed, uint256 toSeed) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        _doTransfer(from, to, ghostBalance[from]);
        ++fullBalanceMoves;
    }

    /// @dev To an address outside the actor set, including the token contract itself.
    function transferOut(uint256 fromSeed, address to, uint256 amount) external {
        address from = _actor(fromSeed);
        if (to == address(0)) to = address(token);
        amount = bound(amount, 0, ghostBalance[from]);
        _track(to);
        _doTransfer(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool infinite) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        if (infinite) amount = type(uint256).max;
        vm.prank(owner);
        try token.approve(spender, amount) returns (bool ok) {
            if (!ok) _violate("approve returned false");
            ghostAllowance[owner][spender] = amount;
            ++okApprovals;
        } catch {
            _violate("approve reverted");
        }
        _checkAllowance(owner, spender);
    }

    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        uint256 cap = allowed < ghostBalance[owner] ? allowed : ghostBalance[owner];
        amount = bound(amount, 0, cap);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) returns (bool ok) {
            if (!ok) _violate("transferFrom returned false");
            ghostBalance[owner] -= amount;
            ghostBalance[to] += amount;
            if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
            ++okTransferFroms;
        } catch {
            _violate("transferFrom within allowance and balance reverted");
        }
        _checkBalance(owner);
        _checkBalance(to);
        _checkAllowance(owner, spender);
    }

    // ---------------------------------------------------------------------------------------------
    // Failure paths: each must revert with the exact error and change nothing
    // ---------------------------------------------------------------------------------------------

    function transferTooMuch(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[from];
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount);
        vm.prank(from);
        try token.transfer(to, amount) {
            _violate("transfer above balance succeeded");
        } catch (bytes memory reason) {
            _expectReason(reason, expected, "transfer above balance: wrong error");
        }
        _checkBalance(from);
        _checkBalance(to);
    }

    function transferToZero(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, ghostBalance[from]);
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        vm.prank(from);
        try token.transfer(address(0), amount) {
            _violate("transfer to zero succeeded");
        } catch (bytes memory reason) {
            _expectReason(reason, expected, "transfer to zero: wrong error");
        }
        _checkBalance(from);
    }

    function transferFromOverAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 allowed = ghostAllowance[owner][spender];
        if (allowed == type(uint256).max) return; // an unlimited allowance cannot be exceeded
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            _violate("transferFrom above allowance succeeded");
        } catch (bytes memory reason) {
            _expectReason(reason, expected, "transferFrom above allowance: wrong error");
        }
        _checkBalance(owner);
        _checkBalance(to);
        _checkAllowance(owner, spender);
    }

    function transferFromOverBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 balance = ghostBalance[owner];
        uint256 amount = balance + bound(excess, 1, type(uint256).max - balance);
        uint256 allowed = ghostAllowance[owner][spender];
        // Allowance is checked before balance: only exercise the balance error when the allowance covers it.
        if (allowed < amount) return;
        bytes memory expected =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount);
        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            _violate("transferFrom above balance succeeded");
        } catch (bytes memory reason) {
            _expectReason(reason, expected, "transferFrom above balance: wrong error");
        }
        _checkBalance(owner);
        _checkBalance(to);
        _checkAllowance(owner, spender);
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        bytes memory expected = abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0));
        vm.prank(owner);
        try token.approve(address(0), amount) {
            _violate("approve to zero spender succeeded");
        } catch (bytes memory reason) {
            _expectReason(reason, expected, "approve zero spender: wrong error");
        }
    }

    /// @dev Calls that would exist on a token with a privileged hand. None may succeed or move anything.
    function privilegedCall(uint256 callerSeed, uint256 victimSeed, uint256 which, uint256 amount) external {
        address caller = _actor(callerSeed);
        address victim = _actor(victimSeed);
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", caller, amount),
            abi.encodeWithSignature("burn(uint256)", amount),
            abi.encodeWithSignature("burnFrom(address,uint256)", victim, amount),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", victim),
            abi.encodeWithSignature("transferOwnership(address)", caller),
            abi.encodeWithSignature("increaseAllowance(address,uint256)", caller, amount),
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                victim,
                caller,
                amount,
                type(uint256).max,
                uint8(27),
                bytes32(0),
                bytes32(0)
            )
        ];
        bytes memory data = calls[bound(which, 0, calls.length - 1)];
        vm.prank(caller);
        (bool ok,) = address(token).call(data);
        if (ok) _violate("a privileged-shaped call succeeded");
        ++expectedReverts;
        _checkBalance(caller);
        _checkBalance(victim);
        _checkAllowance(victim, caller);
    }

    // ---------------------------------------------------------------------------------------------
    // Views for the invariants
    // ---------------------------------------------------------------------------------------------

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _doTransfer(address from, address to, uint256 amount) internal {
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            if (!ok) _violate("transfer returned false");
            ghostBalance[from] -= amount;
            ghostBalance[to] += amount;
            ++okTransfers;
        } catch {
            _violate("transfer within balance reverted");
        }
        _checkBalance(from);
        _checkBalance(to);
    }

    function _expectReason(bytes memory reason, bytes memory expected, string memory what) internal {
        ++expectedReverts;
        if (keccak256(reason) != keccak256(expected)) _violate(what);
    }

    function _checkBalance(address who) internal {
        if (token.balanceOf(who) != ghostBalance[who]) _violate("balance diverged from the ghost ledger");
    }

    function _checkAllowance(address owner, address spender) internal {
        if (token.allowance(owner, spender) != ghostAllowance[owner][spender]) {
            _violate("allowance diverged from the ghost ledger");
        }
    }

    function _violate(string memory what) internal {
        ++violations;
        lastViolation = what;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _track(address who) internal {
        if (!isHolder[who]) {
            isHolder[who] = true;
            holders.push(who);
        }
    }
}

/// @notice Invariants over random call sequences: the supply is fixed, every unit is held by a tracked
/// address and matches the ghost ledger, nothing ever lands on the zero address, the token never
/// holds ETH, and no failure path ever succeeds or changes state.
contract PangeaTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    PangeaToken internal token;
    PangeaHandler internal handler;

    function setUp() public {
        // A contract deployer, as the launch factory is.
        token = new PangeaToken();

        address[] memory actors = new address[](5);
        actors[0] = address(this);
        actors[1] = address(0xA11CE);
        actors[2] = address(0xB0B);
        actors[3] = address(0xCA201);
        actors[4] = address(0xD157);

        // Spread the supply unevenly so both large and tiny balances are in play from the start.
        token.transfer(actors[1], EXPECTED_SUPPLY / 2);
        token.transfer(actors[2], EXPECTED_SUPPLY / 10);
        token.transfer(actors[3], 1);

        handler = new PangeaHandler(token, actors);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "the supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSumToSupplyAndMatchLedger() public view {
        uint256 sum;
        uint256 n = handler.holderCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.holderAt(i);
            uint256 balance = token.balanceOf(who);
            assertEq(balance, handler.ghostBalance(who), "balance diverged from the ghost ledger");
            assertLe(balance, EXPECTED_SUPPLY, "a single balance exceeds the supply");
            sum += balance;
        }
        assertEq(sum, token.totalSupply(), "tokens appeared or vanished outside the tracked holders");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesMatchLedger() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actorAt(i);
                address spender = handler.actorAt(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.ghostAllowance(owner, spender),
                    "allowance diverged from the ghost ledger"
                );
            }
        }
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_nothingOnZeroAddressAndNoEther() public view {
        assertEq(token.balanceOf(address(0)), 0, "tokens reached the zero address");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_noHandlerViolation() public view {
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    function invariant_metadataNeverChanges() public view {
        assertEq(token.name(), "Pangea");
        assertEq(token.symbol(), "PANGEA");
        assertEq(token.decimals(), 18);
    }
}
