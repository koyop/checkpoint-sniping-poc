# Morpheus Capital checkpoint-sniping PoC

Pinned Ethereum-mainnet-fork Foundry PoC against block `25,869,553`.

## Run

```bash
forge install foundry-rs/forge-std@v1.16.2 --no-git
ETH_RPC_URL=<archive-ethereum-rpc> forge test --match-contract CheckpointSnipingPoC -vv
```

Expected: `7 passed; 0 failed`.

Core proof:

```bash
ETH_RPC_URL=<archive-ethereum-rpc> forge test \
  --match-contract CheckpointSnipingPoC \
  --match-test test_usdcCapitalCurveAndExactBoundary -vv
```

This test compares identical control and attack branches. At exact checkpoint boundary, `10,000,000 USDC` captures `2,398.944745679791993916 MOR`; incumbents lose `2,398.084741771249246802 MOR`; only `0.403049665152166666 MOR` is emitted while attacker is staked. Full principal returns after seven days and production claim/mint-message path succeeds.

Fork time advances beyond pinned Chainlink rounds. `_refreshChainlinkTimestamps()` preserves each real feed answer and mocks only its timestamp to avoid a fork-warp-only stale-oracle revert. No protocol storage, privileged account, token price, or reward amount is mocked.
