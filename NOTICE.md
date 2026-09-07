# Third-party notices

This repository's own source is licensed per file: the hook contracts and their fee-model
libraries under the Business Source License 1.1, the remainder under MIT. See
[`LICENSE`](LICENSE) for the split and the BUSL parameters, and [`LICENSE-MIT`](LICENSE-MIT) for
the MIT terms. It incorporates and builds on third-party components listed below. This file
records their provenance and the notices their licences require.

Dependencies are consumed as git submodules under `lib/`, so upstream source and its licence
files are fetched from the upstream repositories rather than vendored here. The entries below
cover code that has been **adapted into**, or **derived from**, files in this repository — the
cases where a notice travels with the code.

---

## Repository origin

This repository began as a fork of the **Uniswap v4 hook template**
(`uniswapfoundation/v4-template`), MIT licence, **Copyright (c) 2023 saucepoint**. The template's
scaffolding has since been largely replaced; elements of the original test layout persist. The
deploy tooling carrying the remaining derived material is not included in this repository.

The MIT notice for that work is reproduced in [MIT licence text](#mit-licence-text) below.

---

## MIT-licensed components

**Uniswap v4-core** — Copyright 2023 Universal Navigation Inc.

Imported unmodified and compiled into this project's contracts:

| Component | Used by |
|---|---|
| `libraries/TickMath`, `SwapMath`, `SqrtPriceMath`, `LiquidityMath`, `FullMath`, `BitMath`, `TickBitmap` | `src/lib/SwapSimulator.sol`, `src/lib/HookMath.sol` |
| `libraries/StateLibrary`, `LPFeeLibrary`, `Hooks`, `CustomRevert`, `SafeCast` | `src/` hooks and libraries |
| `types/*` (`PoolKey`, `PoolId`, `Currency`, `BalanceDelta`, `BeforeSwapDelta`, `Slot0`, `PoolOperation`), `interfaces/*` | throughout `src/` and `test/` |
| `libraries/FixedPoint96`, `FixedPoint128`, `ParseBytes`, `TransientStateLibrary` | `src/lib/HookMath.sol`, `src/AscntBaseHook.sol`, test infrastructure |

**Uniswap v4-periphery** — `src/utils/BaseHook.sol` is inherited by `src/AscntBaseHook.sol` and is
therefore compiled into every deployed hook.

**OpenZeppelin Contracts** — `access/Ownable` (`src/AscntGovernance.sol`), `utils/Create2`
(`src/HookFactory.sol`) and `utils/math/SignedMath` (`src/AscntBaseHook.sol`, `src/SimHook.sol`,
`src/lib/HookMath.sol`) are imported unmodified and compiled into this project's contracts.

Adapted (modified) into this repository:

- **`src/lib/SwapSimulator.sol` → `_nextInitializedTickWithinOneWord`** — adapted from v4-core
  `src/libraries/TickBitmap.sol`, changed to read the tick bitmap through `StateLibrary`
  (`extsload`) instead of local storage.

**Uniswap v4-periphery** — Copyright 2023 Universal Navigation Inc.

- **`test/utils/SwapQuoter.sol`** — adapted from `src/libraries/QuoterRevert.sol` and
  `src/base/BaseV4Quoter.sol`. The revert-with-encoded-result mechanism and the `selfOnly`
  self-call pattern are upstream; the adaptation additionally returns the post-swap
  `sqrtPriceX96`.

**Other MIT dependencies** — `foundry-rs/forge-std`, `openzeppelin/uniswap-hooks`, and
`akshatmittal/hookmate` (test scaffolding only). OpenZeppelin Contracts are
Copyright (c) 2016-2025 Zeppelin Group Ltd. Consumed as submodules; not adapted into this
repository's source beyond the imports listed above.

---

## BUSL-1.1 components

Uniswap v4-core is dual-licensed: its arithmetic primitives, types and interfaces are MIT
(above), while the pool singleton and its state machine are **Business Source License 1.1**,
Licensor Universal Navigation Inc. The BUSL set is `PoolManager.sol` and the libraries `Pool`,
`Position`, `CurrencyDelta`, `CurrencyReserves`, `NonzeroDeltaCount` and `Lock`.

This repository does not deploy, fork or redistribute the Uniswap pool singleton. Its hooks are
invoked by the already-deployed canonical `PoolManager`. Three points of contact with
BUSL-licensed material are recorded here for completeness:

1. **`src/lib/SwapSimulator.sol` → `_simulate`** follows the tick-traversal sequence of v4-core
   `src/libraries/Pool.sol` (`Pool.swap`). The correspondence is a correctness requirement: the
   library exists to predict what `Pool.swap` will do, and any divergence in traversal order,
   tick crossing or liquidity-net handling would misprice the fee. The equivalence is asserted
   against the live engine by `test/base/SwapSimulator_QuoterOracle.t.sol`. The arithmetic each
   step performs is the MIT `SwapMath`/`TickMath` set listed above.

2. **`src/SimHook.sol`** imports `Position.calculatePositionKey` from v4-core
   `src/libraries/Position.sol` to derive position keys for the JIT lock. Keys must match
   v4-core's exactly or the lock does not correspond to real positions. Note that Uniswap's own
   MIT-licensed `StateLibrary` also depends on this function.

3. **`test/differential/Phase3_Settle6_Settlement.t.sol`**,
   **`test/invariant/Phase4aProbe.t.sol`**, and **`test/feature/PriceLimitBounds.t.sol`** import
   `Pool` solely to reference its error selectors (`PriceLimitAlreadyExceeded`,
   `PriceLimitOutOfBounds`, `InvalidFeeForExactOut`) when asserting expected reverts. No BUSL
   logic is reproduced, and these are test files only.

BUSL-1.1 converts to MIT on its stated Change Date — 2027-06-15 for v4-core, or earlier per
`v4-core-license-date.uniswap.eth`. Full terms:
<https://github.com/Uniswap/v4-core/blob/main/licenses/BUSL_LICENSE>

---

## MIT licence text

Applies to the components identified as MIT above, with the copyright notices as stated.

```
Permission is hereby granted, free of charge, to any person obtaining a copy of this software
and associated documentation files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or
substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```
