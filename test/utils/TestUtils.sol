// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

import {ArtifactDeployers} from "./ArtifactDeployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookFlags} from "../../script/utils/HookFlags.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCurrencyMetadata} from "v4-periphery/src/libraries/SafeCurrencyMetadata.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {AscntGovernance} from "../../src/AscntGovernance.sol";

contract TestUtils is Test, ArtifactDeployers {
    /// @notice Shared governance contract used by deployed hooks. Test contract is owner + timelock
    ///         so unit tests can call both fast-lane and slow-lane setters directly.
    AscntGovernance public governance;

    /// @dev Mirrors `SimHook.MAX_FEE` (internal, not readable off-chain): the hook-wide `maxFee` ceiling.
    uint24 internal constant HOOK_MAX_FEE = 500_000;

    /// @dev Lets `address(this)` satisfy `AscntGovernance`'s timelock duck-type check (the test
    ///      contract acts as the timelock). Non-zero delay = a "valid" timelock.
    function getMinDelay() external pure returns (uint256) {
        return 1 days;
    }

    struct LiquidityValues {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        uint160 sqrtPriceLower;
        uint160 sqrtPriceUpper;
        uint256 priceLower;
        uint256 priceUpper;
        uint256 amount0;
        uint256 amount1;
    }

    struct SwapValues {
        bool zeroForOne;
        int128 amount0;
        int128 amount1;
        uint160 sqrtPriceX96Before;
        uint160 sqrtPriceX96After;
        int24 tickBefore;
        int24 tickAfter;
    }

    PoolId public poolId;
    bool public isNativeEth;
    uint8 public decimals0;
    uint8 public decimals1;

    function hookFlags() public pure virtual returns (uint160) {
        return HookFlags.simHookMask();
    }

    function deployCoreAndHookCustomDecimals(
        string memory hookName,
        string memory token0Symbol,
        string memory token1Symbol,
        uint8 token0Decimals,
        uint8 token1Decimals,
        bool nativeEth
    ) public returns (address hookAddress) {
        decimals0 = token0Decimals;
        decimals1 = token1Decimals;
        isNativeEth = nativeEth;

        // setup v4 and tokens
        deployArtifactManagerAndRouters();
        deployMintAndApprove2CurrenciesCustomDecimals(token0Symbol, token1Symbol, token0Decimals, token1Decimals);

        // use the sorted local currencies; key is not set yet at this point
        address sortedAddress0 = Currency.unwrap(currency0);
        address sortedAddress1 = Currency.unwrap(currency1);
        uint8 sortedDecimals0 = SafeCurrencyMetadata.currencyDecimals(sortedAddress0);
        uint8 sortedDecimals1 = SafeCurrencyMetadata.currencyDecimals(sortedAddress1);

        // ensure currency ordering is correct, this should never happen due to require statement in deployMintAndApprove2CurrenciesCustomDecimals
        assertEq(sortedDecimals0, decimals0, "deployed decimals0 does not match input");
        assertEq(sortedDecimals1, decimals1, "deployed decimals1 does not match input");

        // Deploy a fresh AscntGovernance for each test: test contract is owner + timelock so
        // unit tests can call both fast-lane and slow-lane setters directly without scaffolding
        // a real TimelockController. Initial pauser and poolDeployer are address(0); tests that
        // exercise those paths set them explicitly via the (timelock-gated) setters.
        governance = AscntGovernance(
            deployCode(
                "src/AscntGovernance.sol:AscntGovernance",
                abi.encode(address(this), address(this), address(0), address(0))
            )
        );

        // Wire the test contract as the canonical factory so it can call `registerSubscriber`
        // on the hook below — in production this is done by `HookFactory.deployHook`.
        governance.setHookFactory(address(this));

        hookAddress = address(uint160(hookFlags()));
        deployCodeTo(hookName, abi.encode(manager, governance), hookAddress);

        // Subscribe the hook to receive protocolFeeBps push updates, mirroring what
        // `HookFactory.deployHook` does in production.
        governance.registerSubscriber(hookAddress);

        return hookAddress;
    }

    function deployPool(
        IHooks hook,
        int24 targetTick,
        int24 tickSpacing,
        bool logging
    ) public returns (int24 initialTick, uint160 initialSqrtPriceX96) {
        uint160 targetSqrtPriceX96 = TickMath.getSqrtPriceAtTick(targetTick);

        currency0 = isNativeEth ? CurrencyLibrary.ADDRESS_ZERO : currency0;

        // deploy pool w/ native ETH
        (key, poolId) =
            initPool(currency0, currency1, hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, targetSqrtPriceX96);

        address sortedAddress0 = Currency.unwrap(key.currency0);
        address sortedAddress1 = Currency.unwrap(key.currency1);
        string memory sortedSymbol0 = SafeCurrencyMetadata.currencySymbol(sortedAddress0, "ETH");
        string memory sortedSymbol1 = SafeCurrencyMetadata.currencySymbol(sortedAddress1, "ERROR no symbol found");
        uint8 sortedDecimals0 = SafeCurrencyMetadata.currencyDecimals(sortedAddress0);
        uint8 sortedDecimals1 = SafeCurrencyMetadata.currencyDecimals(sortedAddress1);

        // fetch data
        (initialSqrtPriceX96, initialTick,,) = StateLibrary.getSlot0(manager, poolId);

        assertEq(initialSqrtPriceX96, targetSqrtPriceX96);
        assertEq(initialTick, targetTick);

        // for logging readability
        (uint256 initialPrice, uint256 initialIntegerPricePerToken0, uint256 initialFractionalPricePerEth) =
            convertSqrtPriceX96ToHumanReadablePrice(initialSqrtPriceX96);

        // logs
        if (logging == true) {
            if (isNativeEth) {
                console.log("Deploying pool with native ETH...");
                console.log("Token0: ETH");
                console.log("decimals0:", decimals0);
                console.log("Token1:", sortedSymbol1);
                console.log("decimals1:", sortedDecimals1);
                console.log("initialTick:", initialTick);
                console.log("initialSqrtPriceX96:", initialSqrtPriceX96);
                console.log("initialPrice: ", initialPrice);
                console.log(
                    "initialPrice: %s.%s %s/ETH",
                    initialIntegerPricePerToken0,
                    initialFractionalPricePerEth,
                    sortedSymbol1
                );
            } else {
                console.log("Deploying pool with ERC20 token pair...");
                console.log("Token0:", sortedSymbol0);
                console.log("decimals0:", sortedDecimals0);
                console.log("Token1:", sortedSymbol1);
                console.log("decimals1:", sortedDecimals1);
                console.log("initialTick:", initialTick);
                console.log("initialSqrtPriceX96:", initialSqrtPriceX96);
                console.log("initialPrice: ", initialPrice);
                string memory pair = string.concat(sortedSymbol1, "/", sortedSymbol0);
                console.log("initialPrice: %s.%s %s", initialIntegerPricePerToken0, initialFractionalPricePerEth, pair);
            }
            console.log("\n");
        }

        return (initialTick, initialSqrtPriceX96);
    }

    function addLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0In,
        uint160 initialSqrtPriceX96,
        bool logging
    ) public returns (LiquidityValues memory liquidityValues) {
        uint160 sqrtPriceLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpper = TickMath.getSqrtPriceAtTick(tickUpper);

        // calc liquidity
        uint128 liquidityIn = LiquidityAmounts.getLiquidityForAmount0(sqrtPriceLower, sqrtPriceUpper, amount0In);

        // calc individual token amounts
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(initialSqrtPriceX96, sqrtPriceLower, sqrtPriceUpper, liquidityIn);

        // setup liquidity params
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityIn)),
            salt: bytes32(0) // one position per range in these helpers; the salt-keyed JIT lock has its own tests
        });

        // fetch state data BEFORE
        (uint128 liquidityBefore,,) = StateLibrary.getPositionInfo(
            manager, poolId, address(modifyLiquidityRouter), tickLower, tickUpper, bytes32(0)
        );

        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);

        // add liquidity; extra value covers hook return deltas (e.g. JIT fee withholding)
        modifyLiquidityRouter.modifyLiquidity{value: amount0 + amount1 + 1}(key, liquidityParams, ZERO_BYTES);

        // fetch state data AFTER
        (uint128 liquidityAfter,,) = StateLibrary.getPositionInfo(
            manager, poolId, address(modifyLiquidityRouter), tickLower, tickUpper, bytes32(0)
        );

        (uint160 sqrtPriceX96After, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);
        // calc change in liquidity
        uint128 changeInLiquidity = liquidityAfter - liquidityBefore;

        // for logging readability
        (uint256 priceLower, uint256 integerPriceLower, uint256 fractionalPriceLower) =
            convertSqrtPriceX96ToHumanReadablePrice(sqrtPriceLower);
        (uint256 priceUpper, uint256 integerPriceUpper, uint256 fractionalPriceUpper) =
            convertSqrtPriceX96ToHumanReadablePrice(sqrtPriceUpper);
        // logs
        if (logging == true) {
            console.log("Adding liquidity...");
            console.log("tickLower:", tickLower);
            console.log("tickUpper:", tickUpper);
            console.log("initialSqrtPriceX96:", initialSqrtPriceX96);
            console.log("sqrtPriceLower:", sqrtPriceLower);
            console.log("sqrtPriceUpper:", sqrtPriceUpper);
            console.log("priceLower: %s.%s token1/token0", integerPriceLower, fractionalPriceLower);
            console.log("priceUpper: %s.%s token1/token0", integerPriceUpper, fractionalPriceUpper);
            console.log("amount0:", amount0);
            console.log("amount1:", amount1);
            console.log("\n");
        }

        // assertions
        assertGt(amount0, 0, "amount0 must be greater than 0");
        assertGt(amount1, 0, "amount1 must be greater than 0");
        assertLt(tickLower, tickUpper);
        assertEq(tickLower % key.tickSpacing, 0);
        assertEq(tickUpper % key.tickSpacing, 0);
        assertLt(sqrtPriceLower, sqrtPriceUpper);
        assertGt(liquidityIn, 0);
        assertGt(liquidityAfter, liquidityBefore);
        assertApproxEqAbs(uint256(liquidityIn), uint256(changeInLiquidity), 1);
        // Note: delta amounts may differ from calculated amounts when the hook's
        // afterAddLiquidity callback returns a non-zero delta (e.g. JIT fee withholding).
        assertEq(sqrtPriceX96After, sqrtPriceX96Before);
        assertEq(tickAfter, tickBefore);

        // update data struct
        liquidityValues = LiquidityValues({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidityIn)),
            sqrtPriceLower: sqrtPriceLower,
            sqrtPriceUpper: sqrtPriceUpper,
            priceLower: priceLower,
            priceUpper: priceUpper,
            amount0: amount0,
            amount1: amount1
        });

        return liquidityValues;
    }

    function removeLiquidity(
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityToRemove
    ) public returns (BalanceDelta delta, Vm.Log[] memory logs) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: -liquidityToRemove,
            salt: bytes32(0)
        });

        vm.recordLogs();
        delta = modifyLiquidityRouter.modifyLiquidity(key, params, ZERO_BYTES);
        logs = vm.getRecordedLogs();
    }

    function swap(
        bool zeroForOne,
        int256 amountSpecified,
        bool logging
    ) public returns (SwapValues memory swapValues, Vm.Log[] memory logs) {
        // environment params
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // config swap params
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1 // Set limit based on swap direction
        });

        // fetch state data BEFORE swap
        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = StateLibrary.getSlot0(manager, poolId);

        // start recording logs for event parsing
        vm.recordLogs();

        // swap
        BalanceDelta delta;
        uint256 ethValue = SignedMath.abs(amountSpecified) + 1;

        if (zeroForOne && isNativeEth) {
            delta = swapRouter.swap{value: ethValue}(key, swapParams, testSettings, ZERO_BYTES);
        } else {
            delta = swapRouter.swap(key, swapParams, testSettings, ZERO_BYTES);
        }

        // get recorded logs
        logs = vm.getRecordedLogs();

        // fetch state data AFTER swap
        (uint160 sqrtPriceX96After, int24 tickAfter,,) = StateLibrary.getSlot0(manager, poolId);

        (, uint256 integerPriceBefore, uint256 fractionalPriceBefore) =
            convertSqrtPriceX96ToHumanReadablePrice(sqrtPriceX96Before);
        (, uint256 integerPriceAfter, uint256 fractionalPriceAfter) =
            convertSqrtPriceX96ToHumanReadablePrice(sqrtPriceX96After);

        // update data struct
        swapValues = SwapValues({
            zeroForOne: zeroForOne,
            amount0: delta.amount0(),
            amount1: delta.amount1(),
            sqrtPriceX96Before: sqrtPriceX96Before,
            sqrtPriceX96After: sqrtPriceX96After,
            tickBefore: tickBefore,
            tickAfter: tickAfter
        });

        if (logging == true) {
            console.log("Swapping...");
            console.log("zeroForOne:", zeroForOne);
            console.log("amountSpecified:", amountSpecified);
            console.log("amount0:", delta.amount0() / int256(10 ** decimals0));
            console.log("amount1:", delta.amount1() / int256(10 ** decimals1));
            console.log("sqrtPriceX96Before:", sqrtPriceX96Before);
            console.log("sqrtPriceX96After:", sqrtPriceX96After);
            console.log("priceBefore: %s.%s token1/token0", integerPriceBefore, fractionalPriceBefore);
            console.log("priceAfter: %s.%s token1/token0", integerPriceAfter, fractionalPriceAfter);
            console.log("tickBefore:", tickBefore);
            console.log("tickAfter:", tickAfter);
            console.log("\n");
        }

        return (swapValues, logs);
    }

    function convertSqrtPriceX96ToHumanReadablePrice(uint160 sqrtPriceX96)
        public
        view
        returns (uint256 price, uint256 integerPrice, uint256 fractionalPrice)
    {
        uint256 scalingFactor = 10 ** decimals0;

        price = FullMath.mulDiv(
            FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96), scalingFactor, FixedPoint96.Q96
        );

        if (decimals1 > decimals0) {
            price = price / (10 ** (decimals1 - decimals0));
        } else if (decimals0 > decimals1) {
            price = price * (10 ** (decimals0 - decimals1));
        }

        integerPrice = price / scalingFactor;
        fractionalPrice = price % scalingFactor;

        return (price, integerPrice, fractionalPrice);
    }

    function deployMintAndApprove2CurrenciesCustomDecimals(
        string memory token0Symbol,
        string memory token1Symbol,
        uint8 token0Decimals,
        uint8 token1Decimals
    ) internal returns (Currency, Currency) {
        Currency _currency0;
        Currency _currency1;

        if (isNativeEth) {
            _currency0 = CurrencyLibrary.ADDRESS_ZERO;
            _currency1 = deployMintAndApproveCurrencyCustomDecimals(token1Symbol, token1Decimals);
        } else {
            // Loop until we get correct address ordering (currency0 < currency1) 50/50 chance
            for (uint256 i = 1; i < 100; i++) {
                _currency0 = deployMintAndApproveCurrencyCustomDecimals(token0Symbol, token0Decimals);
                _currency1 = deployMintAndApproveCurrencyCustomDecimals(token1Symbol, token1Decimals);

                if (Currency.unwrap(_currency0) < Currency.unwrap(_currency1)) {
                    console.log("Correct order achieved after", i, "tries");
                    break; // Correct order achieved
                }
                require(i < 99, "Failed to deploy currencies with correct address ordering");
            }
        }

        (currency0, currency1) =
            SortTokens.sort(MockERC20(Currency.unwrap(_currency0)), MockERC20(Currency.unwrap(_currency1)));
        return (currency0, currency1);
    }

    function deployMintAndApproveCurrencyCustomDecimals(
        string memory name,
        uint8 decimals
    ) internal returns (Currency currency) {
        MockERC20 token = deployTokenCustomDecimals(2 ** 255, name, decimals);

        address[9] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor()),
            address(actionsRouter)
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            token.approve(toApprove[i], Constants.MAX_UINT256);
        }

        return Currency.wrap(address(token));
    }

    function deployTokenCustomDecimals(
        uint256 totalSupply,
        string memory name,
        uint8 decimals
    ) internal returns (MockERC20 token) {
        token = MockERC20(
            deployCode(
                "lib/uniswap-hooks/lib/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol:MockERC20",
                abi.encode(name, name, decimals)
            )
        );
        token.mint(address(this), totalSupply);
    }
}
