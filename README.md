# Morpheus Capital checkpoint-sniping PoC

Pinned Ethereum-mainnet-fork Foundry PoC against block `25,869,553`.

## Run

```bash
forge install foundry-rs/forge-std@v1.16.2 --no-git
ETH_RPC_URL=<archive-ethereum-rpc> forge test --match-contract CheckpointSnipingPoC -vv
```

Expected: `9 passed; 0 failed`.

Core proof:

```bash
ETH_RPC_URL=<archive-ethereum-rpc> forge test \
  --match-contract CheckpointSnipingPoC \
  --match-test test_usdcCapitalCurveAndExactBoundary -vv
```

This test compares identical control and attack branches. At exact checkpoint boundary, `10,000,000 USDC` captures `2,398.944745679791993916 MOR`; incumbents lose `2,398.084741771249246802 MOR`; only `0.403049665152166666 MOR` is emitted while attacker is staked. Full principal returns after seven days and production claim/mint-message path succeeds.

Repeatability and lower-capital proof:

```bash
ETH_RPC_URL=<archive-ethereum-rpc> forge test \
  --match-contract CheckpointSnipingPoC \
  --match-test test_usdcThreeCycleFreshLockCapitalEfficiency -vv
```

This test reuses same `1,000,000 USDC` principal across three complete cycles, returns principal after each seven-day withdrawal lock, preserves `5,718.815860219835674517 MOR` cumulative capture, proves `5,718.555616179066090734 MOR` incumbent loss, and completes production claim after fresh 365-day claim lock expiry.

Fork time advances beyond pinned Chainlink rounds. `_refreshChainlinkTimestamps()` preserves each real feed answer and mocks only its timestamp to avoid a fork-warp-only stale-oracle revert. No protocol storage, privileged account, token price, or reward amount is mocked.
