> **Use at your own risk.** These contracts have been through independent security reviews; the reports are under [Security audits](#security-audits). No review guarantees the absence of bugs.
>
> **Licence:** source-available, per file. The protocol, hook contracts and their fee-model libraries are **BUSL-1.1**, converting to GPL-2.0-or-later on **2028-09-05**; everything else — governance, factory, `SafeCast` and the test suite — is **MIT**. See [`LICENSE`](LICENSE), [`LICENSE-MIT`](LICENSE-MIT) and [`NOTICE.md`](NOTICE.md) for third-party provenance.

# Ascnt — Uniswap v4 hook suite for LPs

Ascnt is a Uniswap v4 hook suite that applies market-making pricing logic to make LPs profitable. Hooks are deployed through a shared factory under one governance contract, so further pricing models can ship on the same foundation.

`SimHook`, the first deployed hook, prices every swap by the divergence it creates: flow that pushes the pool away from balance pays more, flow that brings it back trades at a discount, and the rebalancing after a move is auctioned off so a large share of MEV & arbitrage value returns to LPs instead of leaving the pool. Everything runs on-chain from the pool's own state, no oracles or off-chain inputs.

## Build and verify

```bash
git clone --recursive <repo-url>    # submodules are required
forge build
forge test
```

Suite layout and the `make` subsets are described in [`test/README.md`](test/README.md).

## `SimHook`

### How swaps are priced

Each pool keeps a running, signed measure of its **imbalance**: how far recent flow has pushed the price in one direction, decaying over a per-pool window. Before a swap executes, the hook simulates it against live pool state to see what it does to that imbalance, and quotes it accordingly. Swaps that increase the imbalance pay a surcharge that grows with the imbalance they create; swaps that decrease it trade at a discount, so correcting an imbalanced pool competes to be the cheapest trade in the market.

Two properties follow directly:

- **Arbitrage becomes LP income.** After a move, the fee on the correcting trade falls as the imbalance decays — a Dutch auction that arbitrageurs compete for. Competition pushes the arbitrageur's margin down and the pool keeps more of the gap.
- **Sandwiches are deterred.** The front-run pays the surcharge on the imbalance it creates, and the back-run is priced on that same imbalance, so the round trip costs more the further it pushes the pool.

A base fee floors every quote. It ramps up while the pool is idle and eases back only with sustained activity, so the first trade after a quiet spell pays at least the full floor. Quotes are clamped between that floor and the pool's `maxFee`.

A **JIT block-lock** stops liquidity from entering and leaving within a set number of blocks, configurable per pool (recommend choosing values ~1-2 blocks prevents the majority of JIT actors), to skim the fees earned by long-term LPs.

The model draws on the market-making literature: adverse-selection pricing (Glosten & Milgrom, 1985) and inventory risk (Ho & Stoll, 1981) from dealer markets, and from DeFi the LVR framework (Milionis, Moallemi, Roughgarden & Zhang, 2022), directional fees (Nezlobin) and markout-based flow classification. The exact formulas and edge cases are specified in [`docs/invariants.md`](docs/invariants.md) and [`docs/known-issues.md`](docs/known-issues.md); the source is the reference.

Per-pool parameters are set once per pool in `configurePool`. There is no reconfigure path, so a pool's fee parameters can never be changed under its LPs.

| Parameter | Bound | Effect |
| --- | --- | --- |
| `kPips` / `cPips` | `1 … 20e6` (1e6 = 1.0×) | Leg weights: `k` on imbalance-increasing legs, `c` on decreasing. `c <= k` is **not** enforced; the ordering is a deployer choice. |
| `minMinFee` / `maxMinFee` | `minMinFee <= maxMinFee <= maxFee` | Fee floor, ramped from `min` to `max` off `rampAnchor`. |
| `maxFee` | `< MAX_LP_FEE` (max 999_999 pips; 1e6 = 100% is rejected) | Hard clamp on the quoted fee, applied after the directional weighting. |
| `timeDecayLength` | `1 … 1 days` | Window over which the accumulator decays to zero without any swaps. |
| `jitLockBlocks` | `0 … 50_400` (≈7 days) | Blocks a position must age after `addLiquidity` before `removeLiquidity` is permitted. Keyed on v4-core's exact position key; fee-only pokes (`liquidityDelta == 0`) are exempt. The ceiling is headroom far above the few-block locks used in practice. |

## Governance

Authority lives on `AscntGovernance`, one contract shared by every hook and the factory. It holds four authority slots — `owner`, `timelock`, `poolDeployer` (optional) and `pauser` (optional) — plus protocol-wide state: treasury, protocol-fee rate and the pause flag. Every hook reads its authority from this contract, so one rotation propagates to every hook.

- **Owner** — fast lane, no delay; limited to actions that are containable or reversible.
- **Timelock** — slow lane; protocol changes such as role transfers or enabling the protocol fee.
- **PoolDeployer** — launches and configures pools.
- **Pauser** — blocks new deposits, per hook or protocol-wide; exits and swaps can never be paused.

| Action                                                 | Caller                              | Delay / notes                                                   |
| ------------------------------------------------------ | ----------------------------------- | --------------------------------------------------------------- |
| `HookFactory.deployHook`, `setHookDeprecated`          | owner                               | none                                                            |
| `AscntGovernance.setHookFactory`                       | owner                               | none — **one-shot, never rotatable**                            |
| `_beforeInitialize`, `configurePool`                   | owner OR `poolDeployer`             | none — `configurePool` is **one-shot** per pool                 |
| `setAddLiquidityPaused`, `setHookAddLiquidityPaused`   | owner OR `pauser`                   | none (instant lane)                                             |
| `setPauser`                                            | owner                               | none                                                            |
| `setTreasury`, `setProtocolFeeBps`, `removeSubscriber` | `timelock`                          | TimelockController delay                                        |
| `setPoolDeployer`, `transferOwnership`                 | `timelock`                          | TimelockController delay                                        |
| `proposeTimelock`, `cancelTimelockTransfer`            | `timelock`                          | TimelockController delay                                        |
| `acceptTimelock`                                       | the nominated timelock only         | must be originated by the nominee, within 30 days of nomination |
| `AscntGovernance.registerSubscriber`                   | `hookFactory` (inside `deployHook`) | none                                                            |
| `AscntBaseHook.syncProtocolFee`, all views             | anyone                              | permissionless                                                  |

**Protocol fee.** Off by default. Governance can route a slice of each swap's dynamic fee — at most 20% of the LP fee — to a treasury at swap time. It is always taken out of the LP fee, never added on top of the quoted fee. Enabling it takes two timelock actions: set the treasury address, then set the rate.

## Deployments

### Ethereum mainnet

| Contract                           | Address                                                                                                                 | Deploy tx                                                                                                                                |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `AscntGovernance` (root of trust)  | [`0x7a669Dc45A5720074B140754254AFd308B638341`](https://etherscan.io/address/0x7a669Dc45A5720074B140754254AFd308B638341) | [`0x3901…e8c4`](https://etherscan.io/tx/0x39013939cc382d10cc4c90f7b7b5f093e04f385e65251625f9c2a23f99b1e8c4)                              |
| `HookFactory`                      | [`0xE8Da4C784F7D32a1007147756D91888861eA133A`](https://etherscan.io/address/0xE8Da4C784F7D32a1007147756D91888861eA133A) | [`0xf34d…5bdc`](https://etherscan.io/tx/0xf34df90687d2d6b36ad9d95d3e6f37a880782610fc1fce9309f8fa9cd3bcd5bc)                              |
| `TimelockController`               | [`0xc6D4C3E813F2BD4E4281DD490aC8bA112F00E330`](https://etherscan.io/address/0xc6D4C3E813F2BD4E4281DD490aC8bA112F00E330) | [`0xe0a0…48ba`](https://etherscan.io/tx/0xe0a04df9e74b8248533f9fce8bdbf9adf0e7e510c1b6c1052bdc0cdbde9848ba)                              |
| `SimHook`                          | [`0xFEa4c50b6d3BFcB9C6dE4e44be0293c3a916bec4`](https://etherscan.io/address/0xFEa4c50b6d3BFcB9C6dE4e44be0293c3a916bec4) | [`0x71c3…6e49`](https://etherscan.io/tx/0x71c3252f8fab2151d72b39c57394c1f00a7ed9a64e047f33b6e305b0ddc36e49) via `HookFactory.deployHook` |
| `governance.setHookFactory` wiring | —                                                                                                                       | [`0x273a…8808`](https://etherscan.io/tx/0x273a873bfbb171e483f342bbf57b7b1381ee266f27999bd8598793bb6ddc8808)                              |

### Verifying a hook

Everything starts from the canonical `AscntGovernance` for the chain. Take it from the table above, never from a hook.

```solidity
AscntGovernance gov = AscntGovernance(CANONICAL_GOVERNANCE);
require(gov.isCanonicalHook(hook), "not an Ascnt hook");   // deployed by the protocol through its factory
gov.isCanonicalHookDeprecated(hook);                        // advisory retirement signal: stop routing new flow
```

`isCanonicalHook` is true only for hooks the factory deployed itself inside the owner-gated `deployHook`, which also checks that the hook points back at this governance — a lookalike is simply absent from the registry. Deprecation does not stop a pool; if a hook is unsafe for deposits, the pauser blocks new liquidity on it, so integrators need no extra step. A hook's own `isVerified()` / `isDeprecated()` are self-attestations an impostor can fake; use them only after the check above.

## Security audits

| Review   | Date       | Report                                                                                         |
| -------- | ---------- | ---------------------------------------------------------------------------------------------- |
| Olympix  | 2026-08-24 | [`2026-08-24-olympix-bugpocer-scan.pdf`](docs/audits/2026-08-24-olympix-bugpocer-scan.pdf)     |
| Vulsight | 2026-08-27 | [`2026-08-27-vulsight-one-day-review.pdf`](docs/audits/2026-08-27-vulsight-one-day-review.pdf) |
| LeftClaw | 2026-09-04 | [`2026-09-04-leftclaw-680.html`](docs/audits/2026-09-04-leftclaw-680.html)                     |

[`docs/audit-response-2026-09.md`](docs/audit-response-2026-09.md) has the finding-by-finding response.

**Before reporting an issue**, read [`docs/known-issues.md`](docs/known-issues.md). It is the accepted-risk register: every entry is a behaviour that has already been found, analysed and deliberately kept, with the mechanism, the reachability argument and the reason it was not changed. Several look like defects at first read and are not. Where the reasoning is wrong, or an entry understates reachability or impact, that is worth raising — engage with the stated argument rather than re-reporting the behaviour. The properties the code *does* guarantee, each mapped to the enforcing code and the tests that pin it, are in [`docs/invariants.md`](docs/invariants.md).
