# Convenience targets for the Ascnt hook test suite.
#
# Compile cost is dominated by via_ir, which is required (SimHook._beforeSwap is
# stack-too-deep without it). The realistic speedup for iteration is forge's
# incremental cache + scoping the test run with --match-path:
#
#   - Edit a single test file → forge recompiles 1 file, runs in ~30s.
#   - Edit SimHook.sol / HookMath.sol → forge recompiles every dependent
#     (~20 files), runs in 3–6 min. Unavoidable.
#   - The targeted `test-*` targets below filter WHICH tests to RUN, but the
#     compile step is the same — they save time when you're iterating on a
#     specific test and don't care about unrelated suite output.
#
# Use `make test` for the full suite before committing.

.PHONY: help build test test-base test-feature test-governance test-timelock \
        test-deploy test-deploy-sim clean

help:
	@echo "Full suite:"
	@echo "  make build              forge build"
	@echo "  make test               forge test (full suite — pre-commit gate)"
	@echo ""
	@echo "Targeted subsets (same compile cost, smaller test output):"
	@echo "  make test-base          test/base/**     (pure-unit tests on libs + AscntBaseHook)"
	@echo "  make test-feature       test/feature/**  (config, pause, JIT, protocol fee, sandwich)"
	@echo "  make test-deploy        test/pool-deployment/** (per-pool pre-deployment validation)"
	@echo "  make test-deploy-sim    test/pool-deployment/simhook/**"
	@echo "  make test-governance    governance + propagation"
	@echo "  make test-timelock      timelock two-lane behaviour"
	@echo ""
	@echo "Misc:"
	@echo "  make clean              forge clean (forces a full recompile next run)"

build:
	forge build

test:
	forge test

test-base:
	forge test --match-path "test/base/*.t.sol"

test-feature:
	forge test --match-path "test/feature/*.t.sol"

test-deploy:
	forge test --match-path "test/pool-deployment/**/*.t.sol"

test-deploy-sim:
	forge test --match-path "test/pool-deployment/simhook/*.t.sol"

test-governance:
	forge test --match-path "test/governance/*.t.sol"

test-timelock:
	forge test --match-path "test/timelock/*.t.sol"

clean:
	forge clean
