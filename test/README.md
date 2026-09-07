# Test Suite Overview

Two axes organise this suite:

1. **General topical suite** — exercises hook *behaviour* across topics (libs, factory, governance, features, gas).
2. **Per-pool deployment suite** — exercises a specific (hook × `BasePoolConfig`) pair end to end, mirroring what a deployment hands to `configurePool`.

## Folder map

The invariant campaign adds a third axis on top: the phase directories (`fuzz/`, `access/`, `differential/`, `invariant/`, `jit/`, `reentrancy/`) each discharge a slice of the invariant catalog.

The IDs in test names and comments are that catalog's entry numbers, by area:

| Prefix | Area | Prefix | Area |
|---|---|---|---|
| `FEE` | fee math and clamping | `JIT` | JIT liquidity block-lock |
| `MID` | midpoint (path) fee pricing | `LIFE` | pool lifecycle and configuration |
| `RAMP` | min-fee floor ramp | `GOV` | governance and authority |
| `ACC` | impact accumulator | `XSUB` | cross-subscriber isolation |
| `SETTLE` | settlement + protocol-fee take | `SIM` | swap simulator vs live engine |

Numbering is the catalog's own, so the IDs appearing here are not contiguous.

| Folder | Purpose | Notes |
|---|---|---|
| `base/` | Pure-unit tests on `src/lib/*` + `AscntBaseHook` + simulator | `HookMath`, `SafeCast`, `Saturation`, `AscntBaseHook`, plus `SwapSimulator.t.sol` (fuzz suites comparing replica vs live engine) and `SwapSimulator_QuoterOracle.t.sol` (oracle drift detection via the `SwapQuoter` swap-and-revert pattern). |
| `factory/` | `HookFactory` — deploy, deprecation, ownership transfer | |
| `governance/` | `AscntGovernance` setters, propagation across hooks, subscriber hardening, canonical-hook provenance | `CanonicalHookProvenance` covers the root-anchored provenance views against the fake-factory / fake-governance / impostor forgery matrix. |
| `timelock/` | Two-lane authority (fast-lane direct vs. slow-lane via `TimelockController`) | |
| `feature/` | Per-protocol-feature integration tests | `JitLock`, `SandwichJit`, `ProtocolFee` (PoolManager-direct path), `ProtocolFeeAccounting`, `ProtocolFee_PositionManager` (v4-periphery `PositionManager` regression net: every LP flow with the protocol fee on), `EmergencyPause`, `ConfigurePoolBounds`, `BeforeInitializeFeeFlag`, `FeeAccuracy` + `MidpointFeeAnchors` (reference port of the fee formula), `MinFeeRampAnchor` (min-fee floor ramp), `MultiPoolIsolation`, `StableTokenFlow`, `StableDepegDrain`. Shared setup in `feature/base/`. |
| `gas/` | Gas comparison + per-tick-crossing measurement | `SwapGasComparison` (vanilla v4 vs SimHook), `StableTickCrossingGas` (per-crossing scaling), `SimHookOverheadByCrossings` (head-to-head with simulator). |
| `pool-deployment/` | Per-pool-shape deployment tests | One `Deploy_*.t.sol` per pool shape, under `pool-deployment/simhook/`, exercising the hook against that shape's config. |
| `fuzz/` | Phase-1 stateless fuzz over the pure math | `calculateDynamicFee` (`Phase1DynamicFee`, `Phase1MidpointFee`), the min-fee floor ramp (`Phase1MinFeeRamp`), `HookMath` lib properties, and the fee-split / take arithmetic (`Phase1SettleSplit`, `Phase1SettleTake`). Driven through the harness's exposed internals. |
| `access/` | Phase-2 access control + governance authority | Authority matrix across all four slots, lifecycle-call gating, the no-kill-switch property, JIT-clock griefing, plus a stateful governance campaign (`Phase2_GovHandler` / `Phase2_GovInvariant`). |
| `differential/` | Phase-3 differential — contract vs independent reference | Shadow re-implementations (`Phase3ShadowMath`) and oracles check the simulator's fee/structure, the accumulator recurrence, the fee-override split, settlement currency selection, and bps coupling. |
| `invariant/` | Phase-4a stateful core campaigns | Foundry invariant runs over the accumulator lifecycle, settlement economics, native-ETH settlement, batched multi-swap unlocks, and the FEE-14 probe. Handlers in `invariant/handlers/`, shared helpers (incl. a multi-swap unlock router) in `invariant/helpers/`. `SimHookInvariant` carries the config-immutability campaign. |
| `jit/` | Phase-4b JIT block-lock | Lock-window boundary + config bounds, cross-position isolation, interaction with the add-liquidity pause, and a stateful lock campaign (`jit/handlers/`). |
| `reentrancy/` | Phase-5 settlement reentrancy + hostile tokens | Fee-on-transfer takes, nested swaps during the take, post-transfer reentrancy, revert-on-transfer DoS (SETTLE-17 claims fallback), plus a stateful campaign. Adversarial tokens and other fixtures in `reentrancy/helpers/`, shared setup in `reentrancy/base/`. |
| `scaffolding/` | Phase-0 smoke tests for the test infrastructure itself | Proves `ImpactOracle`, `ReentrantERC20` and `SimHookHarness` behave to spec before any suite leans on them. |
| `harness/` | `SimHookHarness` | Test-only `SimHook` subclass exposing internals (`exposedCalculateDynamicFee`, transient-stash reads). Adds no callbacks, so its hook-permission bits — and therefore its deployable address — match `SimHook` exactly. |
| `mocks/` | Minimal adversarial / stand-in contracts | `ReentrantERC20` (armed to re-enter once), `MockTimelock`. |
| `lib/` | `BasePoolConfig` + shared concrete pool configs | Single source of truth: `PoolConfigs.sol` carries the generic shapes (ERC20, NativeEth, StablePair, HighLowDecimals, MidDecimals). |
| `utils/` | Shared test scaffolding | `TestUtils`, `SimHookUtils`, `IAscntFeeHook`, `SwapQuoter`, `TestSwapQuoter`, `ImpactOracle`. |

## `utils/` quick reference

- `TestUtils` — pool deploy, addLiquidity, removeLiquidity, swap helpers. Test contract is owner + timelock so both lanes are exercised without TimelockController scaffolding.
- `SimHookUtils` — hook-specific setup (`setupSimHookAndPool`) + `BeforeSwap`/`PoolConfigured` event decoders.
- `IAscntFeeHook` — test-only ABI shim over the public surface of `SimHook`.
- `SwapQuoter` — adapted from Uniswap v4-periphery (MIT): `QuoterRevert.sol` + `BaseV4Quoter.sol`, extended to return post-swap `sqrtPriceX96`. Runs the live engine via swap+revert; used as the oracle for drift detection vs `SwapSimulator`.
- `TestSwapQuoter` — concrete subclass of `SwapQuoter` with an `IUnlockCallback` bridge so the oracle can be invoked from plain test functions.

## Running

```bash
make test                # full suite
make test-base           # test/base/**       pure unit tests (incl. simulator + oracle)
make test-feature        # test/feature/**    per-feature integration
make test-governance     # test/governance/** setters + propagation
make test-timelock       # test/timelock/**   two-lane authority
make test-deploy         # test/pool-deployment/**  per-pool-shape deployment tests
make test-deploy-sim     # test/pool-deployment/simhook/** only
```

`make help` lists these; `make build` and `make clean` wrap `forge build` / `forge clean`. The targets filter which tests *run* — compile cost is the same, so they only save time when iterating on one area. Directories without a target (`fuzz`, `access`, `differential`, `invariant`, `jit`, `reentrancy`, `scaffolding`, `gas`, `factory`) are scoped ad hoc:

```bash
forge test --match-path "test/<dir>/*"
```

Single test by name: `forge test --mt <name> -vvv`.
