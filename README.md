# Pangea (PANGEA)

A fixed-supply ERC-20 token for an IMD custom token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `PangeaToken` (`src/PangeaToken.sol`) |
| Token name | `Pangea` |
| Token symbol | `PANGEA` |
| Decimals | 18 |
| Total supply | 1,000,000,000 PANGEA = `1000000000000000000000000000` minor units |
| Minted to | `msg.sender` of the constructor, once, in the constructor |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, no CBOR metadata |

## What the token does

`PangeaToken` inherits OpenZeppelin v5.1.0 `ERC20` and adds nothing but constants and a constructor.
The constructor mints the whole supply to the deployer and that is the only `_mint` call in the
contract. After construction the contract exposes the standard ERC-20 surface only:
`name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `transfer`, `approve`, `allowance`,
`transferFrom`, and the public constants `TOKEN_NAME`, `TOKEN_SYMBOL`, `DECIMALS`,
`SUPPLY_WHOLE_TOKENS` and `TOTAL_SUPPLY`.

Deliberately absent:

- no owner, `Ownable`, roles or any privileged function;
- no mint after construction, so the supply can never grow;
- no burn function (the supply cannot shrink through the contract either; holders may still send
  tokens to any address they choose);
- no pause, blocklist, freeze, lock, seize or transfer toggle;
- no fee, tax, reflection or burn on transfer: every transfer moves exactly the amount requested;
- no `receive` or `fallback`, so the contract cannot hold ETH;
- no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime (asserted by a test);
- no proxy and no upgrade path: the deployed bytecode is final.

## Assumptions

- The deployer is whoever runs the constructor. In the IMD launch that is the `ProjectFactory`,
  which calls the constructor through `launchCustom`; the factory receives the whole supply and
  pays it out itself (10% to the launch's MerkleDistributor, 80% to the single-sided pool, the
  remaining 10% to the requester's `remainderTo`). The token exempts nobody and taxes nobody, so
  every launch flow arrives whole without the token needing the factory, pool manager or launch
  number as constructor arguments.
- The launch economics, pool parameters (pair IMD, fee 12500, tick spacing 60) and opening price
  are the launch's and are not encoded in the token. The manifest step writes `launch.json`; this
  repository intentionally contains none.
- `decimals()` is the ERC-20 default of 18, matching the brief and the manifest.
- The token has no dependency on any outside contract, oracle or address, so there is nothing
  to configure after launch.

## Deployment parameters

The constructor takes no arguments. The only deployment choice is who sends the creating
transaction, because that address receives the entire supply.

- **IMD launch (the intended path):** the factory deploys the attested creation code of
  `PangeaToken` with no constructor arguments. The manifest's `token.totalSupply` is
  `1000000000000000000000000000` and `token.decimals` is `18`.
- **Manual rehearsal:** `script/DeployPangea.s.sol` wraps `new PangeaToken()` in `deploy()`,
  which the tests call directly, and `run()` wraps it in a broadcast. It reads no environment
  variables. A manual run is for review only; this repository does not authorize transactions and
  no key or wallet is part of it.

```bash
forge build
forge test
forge fmt --check
```

The verifier runs the fuzz tests with
`FOUNDRY_FUZZ_SEED=0x658175eded3b6f98dfda344ce99ba6a15e19f5533a5e937a495582b1fed52f52`; the suite
passes with that seed and with random seeds.

## After launch

There is nothing to set. The contract has no owner and no setter. No action by anyone can change
the name, symbol, decimals, supply or transfer rules.

## Operational responsibilities

- **Holding the supply.** Until the factory pays it out, the whole supply sits on the factory. After
  the launch, the requester's remainder sits at `economics.remainderTo`
  (`0xd0116c7e933029a0abfa388757a3d7a7686ee681`). Whoever controls that key controls 10% of the
  supply; the token offers no recovery if it is lost or compromised.
- **Approvals.** Holders are responsible for the allowances they grant. Unlimited approvals
  (`type(uint256).max`) are honoured and never decremented, as in every OpenZeppelin ERC-20.
- **Tokens sent to the contract itself** or to any address nobody controls are unrecoverable: the
  contract has no rescue function by design.
- **Source verification.** After the launch, verifying the source on the block explorer is the
  deployer's task (`forge verify-contract` with the compiler settings in `foundry.toml`). This
  repository does not deploy or verify anything.
- **Audit.** The tests are not a security audit. The contract is a thin wrapper over a widely
  audited library, but an independent adversarial review is still the appropriate step before
  relying on it for value.

## Repository layout

```
foundry.toml              compiler pins and build settings (solc 0.8.26, bytecode_hash = "none")
remappings.txt            forge-std/ and @openzeppelin/contracts/ remappings
src/PangeaToken.sol       the token
script/DeployPangea.s.sol reviewable deployment entry point (deploy() is unit-tested)
test/PangeaToken.t.sol    behaviour, failure, privilege-surface, launch-flow and fuzz tests
test/DeployPangea.t.sol   tests for the deploy function
lib/forge-std             vendored forge-std v1.9.7 (plain files, no submodule)
lib/openzeppelin          vendored OpenZeppelin Contracts v5.1.0 (contracts/ only, plain files)
```

Dependencies are committed as ordinary files so the project builds with no network.

## Tests

`test/PangeaToken.t.sol` covers:

- metadata, constants and the one-time mint to the deployer (including when the deployer is a
  contract, as the factory is);
- successful transfers (exact amounts, whole balance, zero amount, self-transfer, multi-hop with
  no leakage) and the `Transfer`/`Approval` events;
- failing transfers (insufficient balance by one wei, zero-address receiver);
- allowances: set, overwrite, spend, unlimited, insufficient, zero spender, and that an allowance
  granted to one spender gives nothing to another;
- that no admin-shaped call (`mint`, `setOwner`, `transferOwnership`, `upgradeTo`, `initialize`,
  `unpause`, `setMinter`, `owner`, `renounceOwnership`) succeeds from a stranger or the deployer,
  and that no privileged-shaped call (`pause`, `blacklist`, `freeze`, `lock`, `burnFrom`, `seize`,
  ...) succeeds or moves a holder's balance;
- that unknown selectors and plain ETH revert;
- that the runtime bytecode contains no reachable `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`
  and fits EIP-170;
- the launch flows (factory to distributor to claimant, factory to requester) arriving whole with
  the supply unchanged;
- fuzz: transfer conservation and exactness, over-balance reverts, allowance arithmetic, and
  arbitrary-length transfer chains never changing the supply.

## Security checklist (eth-security reference)

- Access control: no privileged functions exist, so there is nothing to restrict.
- Pausable trade-off: no pause; nobody can freeze holders.
- Reentrancy: the contract makes no external calls.
- Decimals: 18, hard-coded by design for this token only.
- Integer math: the supply is a compile-time constant; no division anywhere.
- Input validation: zero-address sender/receiver/spender are rejected by the OpenZeppelin base.
- Events: every balance and allowance change emits the standard event.
- Proxies, delegatecall, oracles, swaps, signatures: not used.
- Tools run: `forge build`, `forge test` (unit and fuzz with the verifier's seed), `forge fmt --check`.
  Slither and Mythril are not available on this machine and were not run.
