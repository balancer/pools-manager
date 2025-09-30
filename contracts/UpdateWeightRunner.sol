// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@prb/math/contracts/PRBMathSD59x18.sol";
import "./OracleWrapper.sol";
import "./interfaces/IQuantAMMWeightedPool.sol";
import "./interfaces/IUpdateRule.sol";
import "./interfaces/IUpdateWeightRunner.sol";
import "./rules/UpdateRule.sol";

import "./QuantAMMWeightedPool.sol";

import { IWeightedPool } from "@balancer-labs/v3-interfaces/contracts/pool-weighted/IWeightedPool.sol";

/*
ARCHITECTURE DESIGN NOTES

The update weight runner is a singleton contract that is responsible for running all weight updates. It is a singleton contract as it is responsible for managing the update rule state of all pools.

The update weight runner is responsible for:
- Managing the state of all update rules
- Managing the state of all pools related to update rules
- Managing the state of all oracles related to update rules
- Managing the state of all quantAMM weight runners
- Managing the state of the ETH/USD oracle - important for exit fee calculations
- Managing the state of all approved oracles
- Managing the state of all oracle staleness thresholds
- Managing the state of all pool last run times
- Managing the state of all pool rule settings
- Managing the state of all pool primary oracles
- Managing the state of all pool backup oracles
- Managing the state of all pool rules

As all QuantAMM pools are based on the TFMM approach, core aspects of running a periodic strategy
update are shared. This allows for appropriate centralisation of the process in a single update weight
runner.
What benefits are achieved by such centralisation? Efficiency of external contract calls is a great benefit
however security should always come before efficiency. A single runner allows for a gated approach
where pool contracts can be built, however only when registered with the quantammAdmin and update weight
runner can they be considered to be ”approved” and running within the QuantAMM umbrella.
Centralised common logic also allows for ease of protecting the interaction between quantammAdmin and update
weight runner, while reducing the pool specific code that will require n number of audits per n pools
designs. Such logic includes a single heavily tested implementation for oracle fall backs, triggering of
updates and guard rails.


 */

/// @title UpdateWeightRunner singleton contract that is responsible for running all weight updates

contract UpdateWeightRunner is IUpdateWeightRunner {
    //CODEHAWKS INFO /s/336 remove Ownable2Step as it is not used anymore
    event OracleAdded(address indexed oracleAddress);
    event OracleRemved(address indexed oracleAddress);
    event SetWeightManual(
        address indexed caller,
        address indexed pool,
        int256[] weights,
        uint40 lastInterpolationTimePossible,
        uint40 lastUpdateTime
    );
    event SetIntermediateValuesManually(
        address indexed caller,
        address indexed pool,
        int256[] newMovingAverages,
        int256[] newParameters,
        uint numberOfAssets
    );
    event SwapFeeTakeSet(uint256 oldSwapFee, uint256 newSwapFee);
    event UpliftFeeTakeSet(uint256 oldSwapFee, uint256 newSwapFee);
    event UpdatePerformed(address indexed caller, address indexed pool);
    event UpdatePerformedQuantAMM(address indexed caller, address indexed pool);
    event SetApprovedActionsForPool(address indexed caller, address indexed pool, uint256 actions);
    event ETHUSDOracleSet(address ethUsdOracle);
    event PoolLastRunSet(address poolAddress, uint40 time);
    event PoolRuleSetAdminOverride(address admin, address poolAddress, address ruleAddress);
    event CalculateWeightsRequest(
        int256[] currentWeights,
        int256[] data,
        address pool,
        int256[][] ruleParameters,
        uint64[] lambda,
        uint64 epsilonMax,
        uint64 absoluteWeightGuardRail
    );

    event CalculateWeightsResponse(int256[] updatedWeights);

    ///@dev Emitted when the weights of the pool are updated
    event WeightsUpdated(
        address indexed poolAddress,
        address updateOwner,
        int256[] weights,
        uint40 lastInterpolationTimePossible,
        uint40 lastUpdateTime
    );

    /// @notice main eth oracle that could be used to determine value of pools and assets.
    /// @dev this could be used for things like uplift only withdrawal fee hooks
    OracleWrapper public ethOracle;

    /// @notice Mask to check if a pool is allowed to perform an update, some might only want to get data
    uint256 private constant MASK_POOL_PERFORM_UPDATE = 1;

    /// @notice Mask to check if a pool is allowed to get data
    uint256 private constant MASK_POOL_GET_DATA = 2;

    /// @notice Mask to check if a pool owner can update weights
    uint256 private constant MASK_POOL_OWNER_UPDATES = 8;

    /// @notice Mask to check if a pool is allowed to perform admin updates
    uint256 private constant MASK_POOL_QUANTAMM_ADMIN_UPDATES = 16;

    /// @notice Mask to check if a pool is allowed to perform direct weight update from a rule
    uint256 private constant MASK_POOL_RULE_DIRECT_SET_WEIGHT = 32;

    constructor(address _quantammAdmin, address _ethOracle) {
        require(_quantammAdmin != address(0), "Admin cannot be default address");
        require(_ethOracle != address(0), "eth oracle cannot be default address");

        quantammAdmin = _quantammAdmin;
        ethOracle = OracleWrapper(_ethOracle);
    }

    address public immutable quantammAdmin;

    /// @notice key is pool address, value is rule settings for running the pool
    mapping(address => PoolRuleSettings) public poolRuleSettings;

    /// @notice Mapping of pool primary oracles keyed by pool address. Happy path oracles in the same order as the constituent assets
    mapping(address => address[]) public poolOracles;

    /// @notice Mapping of pool backup oracles keyed by pool address for each asset in the pool (in order of priority)
    mapping(address => address[][]) public poolBackupOracles;

    /// @notice The % of the total swap fee that is allocated to the protocol for running costs.
    uint256 public quantAMMSwapFeeTake = 0.5e18;

    function setQuantAMMSwapFeeTake(uint256 _quantAMMSwapFeeTake) external override {
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        require(_quantAMMSwapFeeTake <= 1e18, "Swap fee must be less than 100%");
        uint256 oldSwapFee = quantAMMSwapFeeTake;
        quantAMMSwapFeeTake = _quantAMMSwapFeeTake;

        emit SwapFeeTakeSet(oldSwapFee, _quantAMMSwapFeeTake);
    }

    function getQuantAMMSwapFeeTake() external view override returns (uint256) {
        return quantAMMSwapFeeTake;
    }

    /// @notice Set the quantAMM uplift fee % amount allocated to the protocol for running costs
    /// @param _quantAMMUpliftFeeTake The new uplift fee % amount allocated to the protocol for running costs
    function setQuantAMMUpliftFeeTake(uint256 _quantAMMUpliftFeeTake) external {
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        require(_quantAMMUpliftFeeTake <= 1e18, "Uplift fee must be less than 100%");
        uint256 oldSwapFee = quantAMMSwapFeeTake;
        quantAMMSwapFeeTake = _quantAMMUpliftFeeTake;

        emit UpliftFeeTakeSet(oldSwapFee, _quantAMMUpliftFeeTake);
    }

    /// @notice Get the quantAMM uplift fee % amount allocated to the protocol for running costs
    function getQuantAMMUpliftFeeTake() external view returns (uint256) {
        return quantAMMSwapFeeTake;
    }

    function getQuantAMMAdmin() external view override returns (address) {
        return quantammAdmin;
    }

    /// @notice Get the happy path primary oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getOptimisedPoolOracle(address _poolAddress) public view returns (address[] memory oracles) {
        return poolOracles[_poolAddress];
    }

    /// @notice Get the backup oracles for the constituents of a pool
    /// @param _poolAddress Address of the pool
    function getPoolOracleAndBackups(address _poolAddress) public view returns (address[][] memory oracles) {
        return poolBackupOracles[_poolAddress];
    }

    /// @notice Get the rule settings for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRuleSettings(address _poolAddress) public view returns (PoolRuleSettings memory oracles) {
        return poolRuleSettings[_poolAddress];
    }

    /// @notice Get the actions a pool has been approved for
    /// @param _poolAddress Address of the pool
    function getPoolApprovedActions(address _poolAddress) public view returns (uint256) {
        return approvedPoolActions[_poolAddress];
    }

    /// @notice List of approved oracles that can be used for updating weights.
    mapping(address => bool) public approvedOracles;

    /// @notice Mapping of actions approved for a pool by the QuantAMM protocol team.
    mapping(address => uint256) public approvedPoolActions;

    /// @notice mapping keyed of oracle address to staleness threshold in seconds. Created for gas efficincy.
    mapping(address => uint) public ruleOracleStalenessThreshold;

    /// @notice Mapping of pools to rules
    mapping(address => IUpdateRule) public rules;

    /// @notice Get the rule for a pool
    /// @param _poolAddress Address of the pool
    function getPoolRule(address _poolAddress) public view returns (IUpdateRule rule) {
        return rules[_poolAddress];
    }

    /// @notice Add a new oracle to the available oracles
    /// @param _oracle Oracle to add
    function addOracle(OracleWrapper _oracle) external {
        address oracleAddress = address(_oracle);
        require(oracleAddress != address(0), "Invalid oracle address");
        require(msg.sender == quantammAdmin, "ONLYADMIN");

        if (!approvedOracles[oracleAddress]) {
            approvedOracles[oracleAddress] = true;
        } else {
            revert("Oracle already added");
        }
        emit OracleAdded(oracleAddress);
    }

    /// @notice Removes an existing oracle from the approved oracles
    /// @param _oracleToRemove The oracle to remove
    function removeOracle(OracleWrapper _oracleToRemove) external {
        //CODEHAWKS INFO /s/491 /s/492 requires ordering
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        approvedOracles[address(_oracleToRemove)] = false;
        emit OracleRemved(address(_oracleToRemove));
    }

    /// @notice Set the actions a pool is approved for
    /// @param _pool Pool to set actions for
    function setApprovedActionsForPool(address _pool, uint256 _actions) external {
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        require(_actions != approvedPoolActions[_pool], "DUPEACTION");
        approvedPoolActions[_pool] = _actions;
        emit SetApprovedActionsForPool(msg.sender, _pool, _actions);
    }

    /// @notice Set the rule for a pool, called by the pool creator
    /// @param _poolSettings Settings for the pool
    /// @param _pool Pool to set the rule for
    /// @dev CODEHAWKS M-02
    function setRuleForPoolAdminInitialise(
        IQuantAMMWeightedPool.PoolSettings memory _poolSettings,
        address _pool
    ) external {
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        require(_pool != address(0), "Invalid pool address");
        require(IQuantAMMWeightedPool(_pool).getWithinFixWindow(), "Pool now immutable");

        require(address(rules[_pool]) == address(0), "Rule already set");
        require(_poolSettings.oracles.length > 0, "Empty oracles array");
        require(poolOracles[_pool].length == 0, "pool rule already set");
        //needed to prevent 2 step amend

        //CODEHAWKS INFO /s/700
        require(_poolSettings.updateInterval > 0, "Update interval must be greater than 0");

        _setRuleForPool(_poolSettings, _pool);

        emit PoolRuleSetAdminOverride(msg.sender, _pool, address(_poolSettings.rule));
    }

    /// @notice Set a rule for a pool, called by the pool
    /// @param _poolSettings Settings for the pool
    function setRuleForPool(IQuantAMMWeightedPool.PoolSettings memory _poolSettings) external {
        require(address(rules[msg.sender]) == address(0), "Rule already set");
        require(_poolSettings.oracles.length > 0, "Empty oracles array");
        require(poolOracles[msg.sender].length == 0, "pool rule already set");

        //CODEHAWKS INFO /s/700
        require(_poolSettings.updateInterval > 0, "Update interval must be greater than 0");
        _setRuleForPool(_poolSettings, msg.sender);
    }

    function _setRuleForPool(IQuantAMMWeightedPool.PoolSettings memory _poolSettings, address pool) internal {
        for (uint i; i < _poolSettings.oracles.length; ++i) {
            require(_poolSettings.oracles[i].length > 0, "Empty oracles array");
            for (uint j; j < _poolSettings.oracles[i].length; ++j) {
                if (!approvedOracles[_poolSettings.oracles[i][j]]) {
                    revert("Not approved oracled used");
                }
            }
        }

        address[] memory optimisedHappyPathOracles = new address[](_poolSettings.oracles.length);
        for (uint i; i < _poolSettings.oracles.length; ++i) {
            optimisedHappyPathOracles[i] = _poolSettings.oracles[i][0];
        }
        poolOracles[pool] = optimisedHappyPathOracles;
        poolBackupOracles[pool] = _poolSettings.oracles;
        rules[pool] = _poolSettings.rule;
        poolRuleSettings[pool] = PoolRuleSettings({
            lambda: _poolSettings.lambda,
            epsilonMax: _poolSettings.epsilonMax,
            absoluteWeightGuardRail: _poolSettings.absoluteWeightGuardRail,
            ruleParameters: _poolSettings.ruleParameters,
            timingSettings: PoolTimingSettings({ updateInterval: _poolSettings.updateInterval, lastPoolUpdateRun: 0 }),
            poolManager: _poolSettings.poolManager
        });
    }

    /// @notice Run the update for the provided rule. Last update must be performed more than or equal (CODEHAWKS INFO /2/228) to updateInterval seconds ago.
    function performUpdate(address _pool) public {
        //Main external access point to trigger an update
        address rule = address(rules[_pool]);
        require(rule != address(0), "Pool not registered");

        PoolRuleSettings memory settings = poolRuleSettings[_pool];

        require(
            block.timestamp - settings.timingSettings.lastPoolUpdateRun >= settings.timingSettings.updateInterval,
            "Update not allowed"
        );

        uint256 poolRegistryEntry = approvedPoolActions[_pool];
        if (poolRegistryEntry & MASK_POOL_PERFORM_UPDATE > 0) {
            _performUpdateAndGetData(_pool, settings);

            // emit event for easier tracking of updates and to allow for easier querying of updates
            emit UpdatePerformed(msg.sender, _pool);
        } else {
            revert("Pool not approved to perform update");
        }
    }

    /// @notice Change the ETH/USD oracle
    /// @param _ethUsdOracle The new oracle address to use for ETH/USD
    function setETHUSDOracle(address _ethUsdOracle) public {
        require(msg.sender == quantammAdmin, "ONLYADMIN");
        //CODEHAWKS INFO /s/158
        require(_ethUsdOracle != address(0), "INVETHUSDORACLE");
        ethOracle = OracleWrapper(_ethUsdOracle);
        emit ETHUSDOracleSet(_ethUsdOracle);
    }

    /// @notice Sets the timestamp of when an update was last run for a pool. Can by used as a breakgrass measure to retrigger an update.
    /// @param _poolAddress the target pool address
    /// @param _time the time to initialise the last update run to
    function InitialisePoolLastRunTime(address _poolAddress, uint40 _time) external {
        uint256 poolRegistryEntry = approvedPoolActions[_poolAddress];

        //current breakglass settings allow pool creator trigger. This is subject to review
        if (poolRegistryEntry & MASK_POOL_OWNER_UPDATES > 0) {
            require(msg.sender == poolRuleSettings[_poolAddress].poolManager, "ONLYMANAGER");
        } else if (poolRegistryEntry & MASK_POOL_QUANTAMM_ADMIN_UPDATES > 0) {
            require(msg.sender == quantammAdmin, "ONLYADMIN");
        } else {
            revert("No permission to set last run time");
        }

        poolRuleSettings[_poolAddress].timingSettings.lastPoolUpdateRun = _time;
        emit PoolLastRunSet(_poolAddress, _time);
    }

    /// @notice Wrapper for if someone wants to get the oracle data the rule is using from an external source
    /// @param _pool Pool to get data for
    function getData(address _pool) public view virtual returns (int256[] memory outputData) {
        return _getData(_pool, false);
    }

    /// @notice Get the data for a pool from the oracles and return it in the same order as the assets in the pool
    /// @param _pool Pool to get data for
    /// @param internalCall Internal call flag to detect if the function was called internally for emission and permissions
    function _getData(address _pool, bool internalCall) private view returns (int256[] memory outputData) {
        require(internalCall || (approvedPoolActions[_pool] & MASK_POOL_GET_DATA > 0), "Not allowed to get data");
        //optimised == happy path, optimised into a different array to save gas
        address[] memory optimisedOracles = poolOracles[_pool];
        uint oracleLength = optimisedOracles.length;
        uint numAssetOracles;
        outputData = new int256[](oracleLength);
        uint oracleStalenessThreshold = IQuantAMMWeightedPool(_pool).getOracleStalenessThreshold();

        for (uint i; i < oracleLength; ) {
            // Asset is base asset
            OracleData memory oracleResult;

            require(approvedOracles[address(optimisedOracles[i])], "Oracle not approved");

            try OracleWrapper(optimisedOracles[i]).getData() returns (int216 data, uint40 timestamp) {
                oracleResult.data = data;
                oracleResult.timestamp = timestamp;
            } catch {
                oracleResult.data = 0;
                oracleResult.timestamp = 0;
            }

            if (oracleResult.timestamp > block.timestamp - oracleStalenessThreshold) {
                outputData[i] = oracleResult.data;
            } else {
                unchecked {
                    numAssetOracles = poolBackupOracles[_pool][i].length;
                }

                //CODEHAWKS M-11 throw if no backup
                if (numAssetOracles == 1) {
                    revert("No fresh oracle values available");
                }

                for (uint j = 1 /*0 already done via optimised poolOracles*/; j < numAssetOracles; ) {
                    require(approvedOracles[address(poolBackupOracles[_pool][i][j])], "Oracle not approved");

                    try OracleWrapper(poolBackupOracles[_pool][i][j]).getData() returns (
                        int216 data,
                        uint40 timestamp
                    ) {
                        oracleResult.data = data;
                        oracleResult.timestamp = timestamp;
                    } catch {
                        oracleResult.data = 0;
                        oracleResult.timestamp = 0;
                    }

                    if (oracleResult.timestamp > block.timestamp - oracleStalenessThreshold) {
                        // Oracle has fresh values
                        break;
                    } else if (j == numAssetOracles - 1) {
                        // All oracle results for this data point are stale. Should rarely happen in practice with proper backup oracles.

                        revert("No fresh oracle values available");
                    }
                    unchecked {
                        ++j;
                    }
                }
                outputData[i] = oracleResult.data;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _getUpdatedWeightsAndOracleData(
        address _pool,
        int256[] memory _currentWeights,
        PoolRuleSettings memory _ruleSettings
    ) private returns (int256[] memory updatedWeights, int256[] memory data) {
        data = _getData(_pool, true);

        emit CalculateWeightsRequest(
            _currentWeights,
            data,
            _pool,
            _ruleSettings.ruleParameters,
            _ruleSettings.lambda,
            _ruleSettings.epsilonMax,
            _ruleSettings.absoluteWeightGuardRail
        );

        updatedWeights = rules[_pool].CalculateNewWeights(
            _currentWeights,
            data,
            _pool,
            _ruleSettings.ruleParameters,
            _ruleSettings.lambda,
            _ruleSettings.epsilonMax,
            _ruleSettings.absoluteWeightGuardRail
        );

        emit CalculateWeightsResponse(updatedWeights);

        poolRuleSettings[_pool].timingSettings.lastPoolUpdateRun = uint40(block.timestamp);
    }

    /// @notice Perform the update for a pool and get the new data
    /// @param _poolAddress Pool to update
    /// @param _ruleSettings Settings for the rule to use for the update (lambda, epsilonMax, absolute guard rails, ruleParameters)
    function _performUpdateAndGetData(address _poolAddress, PoolRuleSettings memory _ruleSettings) private {
        //CODEHAWKS INFO /s/405
        uint256[] memory currentWeightsUnsigned = IWeightedPool(_poolAddress).getNormalizedWeights();
        int256[] memory currentWeights = new int256[](currentWeightsUnsigned.length);

        for (uint i; i < currentWeights.length; ) {
            currentWeights[i] = int256(currentWeightsUnsigned[i]);

            unchecked {
                i++;
            }
        }

        (int256[] memory updatedWeights, ) = _getUpdatedWeightsAndOracleData(
            _poolAddress,
            currentWeights,
            _ruleSettings
        );

        _calculateMultiplerAndSetWeights(
            CalculateMuliplierAndSetWeightsLocal({
                currentWeights: currentWeights,
                updatedWeights: updatedWeights,
                updateInterval: int256(int40(_ruleSettings.timingSettings.updateInterval)),
                absoluteWeightGuardRail18: int256(int64(_ruleSettings.absoluteWeightGuardRail)),
                poolAddress: _poolAddress
            })
        );
    }

    struct CalculateMuliplierAndSetWeightsLocal {
        int256[] currentWeights;
        int256[] updatedWeights;
        int256 updateInterval;
        int256 absoluteWeightGuardRail18;
        address poolAddress;
    }

    /// @notice Flatten the weights and multipliers into a single array
    /// @param firstFourWeightsAndMultipliers The first four weights and multipliers w,w,w,w,m,m,m,m
    /// @param secondFourWeightsAndMultipliers The second four weights and multipliers w,w,w,w,m,m,m,m
    /// @return The flattened weights and multipliers w,w,w,w,w,w,w,w,m,m,m,m,m,m,m,m
    function flattenDynamicDataWeightAndMutlipliers(
        int256[] memory firstFourWeightsAndMultipliers,
        int256[] memory secondFourWeightsAndMultipliers
    ) internal pure returns (int256[] memory) {
        int256[] memory flattenedWeightsAndMultipliers = new int256[](16);

        //as dynamic data always returns 2, 8 elem arrays (populated with 0s if it is not an 8 token pool)
        //we can make the assumptions made below about array lengths.
        for (uint i = 0; i < 4; i++) {
            flattenedWeightsAndMultipliers[i] = firstFourWeightsAndMultipliers[i];
            flattenedWeightsAndMultipliers[i + 4] = secondFourWeightsAndMultipliers[i];
            flattenedWeightsAndMultipliers[i + 8] = firstFourWeightsAndMultipliers[i + 4];
            flattenedWeightsAndMultipliers[i + 12] = secondFourWeightsAndMultipliers[i + 4];
        }

        return flattenedWeightsAndMultipliers;
    }

    /// @dev The multipler is the amount per block to add/remove from the last successful weight update.
    /// @notice Calculate the multiplier and set the weights for a pool.
    /// @param local Local data for the function
    function _calculateMultiplerAndSetWeights(CalculateMuliplierAndSetWeightsLocal memory local) internal {
        uint weightAndMultiplierLength = local.currentWeights.length * 2;
        // the base pool needs both the target weights and the per block multipler per asset
        int256[] memory targetWeightsAndBlockMultiplier = new int256[](weightAndMultiplierLength);

        int256 currentLastInterpolationPossible = type(int256).max;

        for (uint i; i < local.currentWeights.length; ) {
            targetWeightsAndBlockMultiplier[i] = local.currentWeights[i];

            // this would be the simple scenario if we did not have to worry about guard rails
            int256 blockMultiplier = (local.updatedWeights[i] - local.currentWeights[i]) / local.updateInterval;

            targetWeightsAndBlockMultiplier[i + local.currentWeights.length] = blockMultiplier;

            int256 upperGuardRail = (PRBMathSD59x18.fromInt(1) -
                (
                    PRBMathSD59x18.mul(
                        PRBMathSD59x18.fromInt(int256(local.currentWeights.length - 1)),
                        local.absoluteWeightGuardRail18
                    )
                ));

            unchecked {
                //This is your worst case scenario, usually you expect (and have DR) that at your next interval you
                //get another update. However what if you don't, you can carry on interpolating until you hit a rail
                //This calculates the first blocktime which one of your constituents hits the rail and that is your max
                //interpolation weight
                //There are also economic reasons for this detailed in the whitepaper design notes.
                //In an event of a chain halt, the pool will still be able to interpolate weights,
                //there are reasons for or against this being better than stopping at the update interval blocktime.
                int256 weightBetweenTargetAndMax;
                int256 blockTimeUntilGuardRailHit;
                if (blockMultiplier > int256(0)) {
                    weightBetweenTargetAndMax = upperGuardRail - local.currentWeights[i];
                    //the updated weight should never be above guard rail. final check as block multiplier
                    //will be even worse if
                    //not using .div so that the 18dp is removed
                    blockTimeUntilGuardRailHit = weightBetweenTargetAndMax / blockMultiplier;
                } else if (blockMultiplier == int256(0)) {
                    blockTimeUntilGuardRailHit = type(int256).max;
                } else {
                    weightBetweenTargetAndMax = local.currentWeights[i] - local.absoluteWeightGuardRail18;

                    //not using .div so that the 18dp is removed
                    //abs block multiplier
                    blockTimeUntilGuardRailHit = weightBetweenTargetAndMax / int256(uint256(-1 * blockMultiplier));
                }

                if (blockTimeUntilGuardRailHit < currentLastInterpolationPossible) {
                    //-1 to avoid any round issues at boundry. Cheaper than seeing if there will be and then doing -1
                    currentLastInterpolationPossible = blockTimeUntilGuardRailHit;
                }

                ++i;
            }
        }

        uint40 lastTimestampThatInterpolationWorks = uint40(type(uint40).max);

        //L01 possible if multiplier is 0
        if (currentLastInterpolationPossible < int256(type(int40).max) - int256(int40(uint40(block.timestamp)))) {
            //next expected update + time beyond that
            lastTimestampThatInterpolationWorks = uint40(
                int40(currentLastInterpolationPossible + int40(uint40(block.timestamp)))
            );
        }

        //the main point of interaction between the update weight runner and the quantammAdmin is here
        IQuantAMMWeightedPool(local.poolAddress).setWeights(
            targetWeightsAndBlockMultiplier,
            local.poolAddress,
            lastTimestampThatInterpolationWorks
        );

        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory dynamicData = IQuantAMMWeightedPool(
            local.poolAddress
        ).getQuantAMMWeightedPoolDynamicData();

        //L-04 similar possibility with set weights as set rule for pool.
        emit WeightsUpdated(
            local.poolAddress,
            msg.sender,
            flattenDynamicDataWeightAndMutlipliers(
                dynamicData.firstFourWeightsAndMultipliers,
                dynamicData.secondFourWeightsAndMultipliers
            ),
            lastTimestampThatInterpolationWorks,
            uint40(block.timestamp)
        );
    }

    /// @notice Ability to set weights from a rule without calculating new weights being triggered for approved configured pools
    /// @param params Local data for the function
    /// @dev requested for use in zk rules where weights are calculated with circuit and this is only called post verifier call
    function calculateMultiplierAndSetWeightsFromRule(CalculateMuliplierAndSetWeightsLocal memory params) external {
        //some level of protocol oversight required here that no rule is approved where this function is not called inapproriately
        require(msg.sender == address(rules[params.poolAddress]), "ONLYRULECANSETWEIGHTS");

        //CODEHAWKS M-02 redeployment of update weight runners means really it is a better
        //design to have pool creator trusted managed pools as a separate factory and weight runner
        uint256 poolRegistryEntry = approvedPoolActions[params.poolAddress];
        require(poolRegistryEntry & MASK_POOL_RULE_DIRECT_SET_WEIGHT > 0, "FUNCTIONNOTAPPROVEDFORPOOL");

        //why do we still need to calculate the multiplier and why not just set the weights like in the manual override?
        //the reason is we enforce clamp weights for all base rules however that still requires the catch all
        //pre update interval guardrail reach check. This is the only place where this is enforced
        //it also centralises logic for weight vectors, just like normal rules, zk rules do not to duplicate logic somewhere else.
        _calculateMultiplerAndSetWeights(params);
    }

    /// @notice Breakglass function to allow the admin or the pool manager to set the quantammAdmins weights manually
    /// @param _weights the new weights
    /// @param _poolAddress the target pool
    /// @param _lastInterpolationTimePossible the last time that the interpolation will work
    /// @param _numberOfAssets the number of assets in the pool
    function setWeightsManually(
        int256[] calldata _weights,
        address _poolAddress,
        uint40 _lastInterpolationTimePossible,
        uint _numberOfAssets
    ) external {
        //CODEHAWKS M-02 redeployment of update weight runners means really it is a better
        //design to have pool creator trusted managed pools as a separate factory and weight runner
        uint256 poolRegistryEntry = approvedPoolActions[_poolAddress];
        if (poolRegistryEntry & MASK_POOL_OWNER_UPDATES > 0) {
            require(msg.sender == poolRuleSettings[_poolAddress].poolManager, "ONLYMANAGER");
        } else if (poolRegistryEntry & MASK_POOL_QUANTAMM_ADMIN_UPDATES > 0) {
            require(msg.sender == quantammAdmin, "ONLYADMIN");
        } else {
            revert("No permission to set weight values");
        }

        //though we try to keep manual overrides as open as possible for unknown unknows
        //given how the math library works weights it is easiest to define weights as 18dp
        //even though technically G3M works of the ratio between them so it is not strictly necessary
        //CYFRIN L-02
        for (uint i; i < _weights.length; i++) {
            if (i < _numberOfAssets) {
                //CODEHAWKS M-08 change to weighted math underlying limits
                require(_weights[i] >= 0.01e18, "Below min allowed weight");
                require(_weights[i] <= 0.99e18, "Above max allowed weight");
            }
        }

        IQuantAMMWeightedPool(_poolAddress).setWeights(_weights, _poolAddress, _lastInterpolationTimePossible);
        IQuantAMMWeightedPool.QuantAMMWeightedPoolDynamicData memory dynamicData = IQuantAMMWeightedPool(_poolAddress)
            .getQuantAMMWeightedPoolDynamicData();

        emit SetWeightManual(
            msg.sender,
            _poolAddress,
            flattenDynamicDataWeightAndMutlipliers(
                dynamicData.firstFourWeightsAndMultipliers,
                dynamicData.secondFourWeightsAndMultipliers
            ),
            _lastInterpolationTimePossible,
            uint40(block.timestamp)
        );
    }

    /// @notice Breakglass function to allow the admin or the pool manager to set the intermediate values of the rule manually
    /// @param _poolAddress the target pool
    /// @param _newMovingAverages manual new moving averages
    /// @param _newParameters manual new parameters
    /// @param _numberOfAssets number of assets in the pool
    function setIntermediateValuesManually(
        address _poolAddress,
        int256[] memory _newMovingAverages,
        int256[] memory _newParameters,
        uint _numberOfAssets
    ) external {
        uint256 poolRegistryEntry = approvedPoolActions[_poolAddress];

        //Who can trigger these very powerful breakglass features is under review
        if (poolRegistryEntry & MASK_POOL_OWNER_UPDATES > 0) {
            require(msg.sender == poolRuleSettings[_poolAddress].poolManager, "ONLYMANAGER");
        } else if (poolRegistryEntry & MASK_POOL_QUANTAMM_ADMIN_UPDATES > 0) {
            require(msg.sender == quantammAdmin, "ONLYADMIN");
        } else {
            revert("No permission to set intermediate values");
        }

        IUpdateRule rule = rules[_poolAddress];

        // utilises the base function so that manual updates go through the standard process
        rule.initialisePoolRuleIntermediateValues(_poolAddress, _newMovingAverages, _newParameters, _numberOfAssets);

        emit SetIntermediateValuesManually(
            msg.sender,
            _poolAddress,
            _newMovingAverages,
            _newParameters,
            _numberOfAssets
        );
    }
}
