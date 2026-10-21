// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Pangea (PANGEA)
/// @notice A fixed-supply ERC-20 token. The whole supply is minted once, in the constructor, to the
/// deployer. There is no owner, no minter, no pause, no blocklist, no fee and no burn hook: after
/// construction the contract has no privileged function of any kind, and the supply can never grow.
/// @dev The contract name is the launch's Solidity identifier (`PangeaToken`); the token's own name
/// and symbol are returned by `name()` and `symbol()`. The constructor takes no arguments and makes
/// no external call, so it can be deployed on an empty chain by any deployer, including a factory.
contract PangeaToken is ERC20 {
    /// @notice The token's name.
    string public constant TOKEN_NAME = "Pangea";

    /// @notice The token's symbol.
    string public constant TOKEN_SYMBOL = "PANGEA";

    /// @notice Number of decimals, the ERC-20 default used by `decimals()`.
    uint8 public constant DECIMALS = 18;

    /// @notice The whole supply in whole tokens: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice The whole supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** DECIMALS;

    /// @notice Mints the entire fixed supply to the deployer (`msg.sender`).
    /// @dev `_mint` is only reachable from here. Nothing else in the contract can create tokens.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
