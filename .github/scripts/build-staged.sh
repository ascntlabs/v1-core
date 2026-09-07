#!/usr/bin/env bash
# Staged, batched compile. solc keeps every contract it has generated in memory until the run
# ends, so the peak footprint is set by how many contracts share one invocation, not by the
# total: a single `forge build` of this tree peaks near 14 GB, one invocation per test directory
# peaks at 3.5 GB (test/feature, the largest). Stage 1 builds src/ and its library dependencies;
# stage 2 builds script/ and each test/ subdirectory in its own invocation, skipping the others;
# stage 3 is a full `forge build --sizes`, which finds everything cached, prints contract sizes
# and fails on any contract over the EIP-170 limit. Same artifacts as a single `forge build`
# (two layout-sensitive test contracts differ by a few bytes; see the gas job's tolerance).
# Used by .github/workflows/ci.yml; runnable locally from the repo root.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

log() { echo "[build-staged $(date +%T)] $*"; }

dirs=(script)
for d in test/*/; do dirs+=("${d%/}"); done

log "stage 1: src + libs"
forge build --skip test --skip script

for target in "${dirs[@]}"; do
  skips=()
  for d in "${dirs[@]}"; do [ "$d" = "$target" ] || skips+=(--skip "$d/**"); done
  log "stage 2: $target"
  forge build "${skips[@]}"
done

log "stage 3: full build --sizes (everything cached)"
forge build --sizes
