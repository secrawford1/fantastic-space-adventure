// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

// ============ External Interfaces ============
interface IWPLS {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
}

interface IPulseXPair {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function sync() external;
}

interface IPulseXFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address) external;
    function feeTo() external view returns (address);
}

interface IPulseXRouter {
    function factory() external pure returns (address);
    function WPLS() external pure returns (address);
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, address[] calldata path) 
        external view returns (uint256[] memory amounts);
}

interface ILendingPool {
    function flashLoanSimple(
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes calldata params,
        uint16 referralCode
    ) external;

    function addressesProvider() external view returns (address);
}

interface IFlashLoanReceiver {
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool);
}

interface IBridge {
    function validateRemoteCall(bytes32 txHash) external view returns (bool);
    function processRemoteResponse(bytes32 txHash, bytes memory response) external;
}

interface IValidator {
    function validateOperation(
        bytes32 operationHash,
        bytes calldata params
    ) external view returns (bool);
}

interface ITokenValidator {
    function validateToken(
        address token
    ) external returns (bool valid, string memory reason);
}

interface IRouterSecurity {
    function validateRouter(
        address router
    ) external view returns (bool secure, uint256 securityScore);
}

contract QuantumArbitrage is Ownable, ReentrancyGuard, Pausable, AccessControl, IFlashLoanReceiver {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Base constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_PATH_LENGTH = 4;
    uint256 public constant MIN_PROFIT_BPS = 50; // 0.5%
    uint256 public constant MAX_GAS_PRICE = 500 gwei;
    uint256 public constant MIN_LIQUIDITY = 1000 ether;
    uint256 public constant MAX_SLIPPAGE = 300; // 3%
    uint256 public constant FLASH_LOAN_FEE = 9; // 0.09%
    uint256 public constant GAS_RESERVE_BPS = 2000; // 20%
    uint256 public constant EXECUTION_DELAY = 2; // 2 blocks
    uint256 public constant PRICE_VALIDITY = 30 minutes;
    uint256 private constant STAKING_COOLDOWN = 1 days;
    uint256 private constant MAX_FAILURES_BEFORE_LOCKOUT = 3;
    uint256 private constant BLACKLIST_DURATION = 1 hours;

    // Core addresses - PulseChain Mainnet
    address public constant WPLS = 0xA1077a294dDE1B09bB078844df40758a5D0f9a27;
    address public constant GENESIS_WALLET = 0x168aFfCbcc2f07C6062d23a1d23161f1fD13CA24;
    address public constant PULSEX_FACTORY = 0x29eA7545DEf87022BAdc76323F373EA1e707C523;
    address public constant PULSEX_ROUTER = 0x98bf93ebf5c380C0e6Ae8e192A7e2AE08edAcc02;

    // Role identifiers
    bytes32 public constant TIMELOCK_ADMIN_ROLE = keccak256("TIMELOCK_ADMIN_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN_ROLE");
    bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");

    uint256 private constant CIRCUIT_BREAKER_RESET_TIME = 1 hours;
    uint256 private constant MIN_EMERGENCY_COOLDOWN = 1 hours;
    uint256 private constant MAX_DAILY_TRADES = 100;
    uint256 private constant MAX_POSITION_SIZE_BPS = 500;  // 5%
    bytes4 private constant FLASH_LOAN_SELECTOR = bytes4(keccak256("flashLoan(address,uint256,bytes)"));
    bytes4 private constant ARBITRAGE_SELECTOR = bytes4(keccak256("arbitrage(address[],uint256[],bytes)"));

// ============ Structs ============
    struct SelfFundingConfig {
        uint256 targetLiquidity;
        uint256 minLiquidity;
        uint256 maxLiquidity;
        uint256 reinvestmentRate;
        uint256 emergencyThreshold;
        uint256 lastRebalance;
        bool autoCompound;
    }

    struct FlashLoanData {
        address[] path;
        address[] dexPath;
        uint256 borrowAmount;
        uint256 expectedProfit;
        uint256 minAmountOut;
        uint256[] dexFees;
        bytes32 identifier;
        uint256 deadline;
        address initiator;
        bool isActive;
        uint256 startTime;
        uint256 gasPrice;
    }

    struct Position {
        uint256 entryPrice;
        uint256 size;
        uint256 leverage;
        uint256 margin;
        uint256 liquidationPrice;
        bool isLong;
        uint256 openTime;
        uint256 lastUpdateTime;
    }

    struct CircuitBreaker {
        uint256 priceDeviationLimit;
        uint256 volumeAnomalyThreshold;
        uint256 profitabilityThreshold;
        uint256 gasSpikeTolerance;
        uint256 lastResetTime;
        bool isTriggered;
        string lastTriggerReason;
    }

    struct GasMetrics {
        uint256 blockNumber;
        uint256 baseFee;
        uint256 gasUsed;
        uint256 gasLimit;
        uint256 timestamp;
    }

    struct RouterMetrics {
        uint256 totalVolume;
        uint256 successfulTrades;
        uint256 failedTrades;
        uint256 averageGasUsed;
        uint256 lastUpdateBlock;
        mapping(address => uint256) tokenVolumes;
    }

    struct VolumeMetrics {
        uint256 volume24h;
        uint256 volumeMA7;
        int256 volumeTrend;
        uint256 lastUpdateTime;
        mapping(uint256 => uint256) hourlyVolumes;
    }

    struct PricePoint {
        uint256 price;
        uint256 timestamp;
        uint256 confidence;
    }

    struct OperationQueue {
        bool isPaused;
        uint256 currentSize;
        uint256 maxQueueSize;
        uint256 lastProcessedBlock;
        bytes32[] activeOperations;
        mapping(bytes32 => QueuedOperation) operations;
    }

    struct QueuedOperation {
        bytes32 operationHash;
        uint256 scheduledBlock;
        uint256 maxDelay;
        bool isActive;
        address initiator;
        bytes params;
        uint256 gasPrice;
        uint256 priority;
    }

    struct OperationMetrics {
    uint256 successCount;
    uint256 failureCount;
    uint256 totalGasUsed;
    uint256 lastExecutionBlock;
    }

    struct QueueMetrics {
    uint256 averageGasPerOp;
    uint256 averageProcessingTime;
    uint256 totalProcessed;
    uint256 lastProcessingTime;
    }

    // ============ State Variables ============
    
    // Core state
    bool private _stakeReentryGuard;
    bool private _emergencyLock;
    bool private _maintenanceMode;

    // Core metrics
    uint256 public totalExecutions;
    uint256 public successfulExecutions;
    uint256 public totalGasSpent;
    uint256 public currentGasReserve;
    uint256 public emergencyFund;
    uint256 public totalStaked;
    uint256 public totalProfit;
    uint256 public flastLoanCapacity;
    uint256 public dailyTrades;

    // System tracking
    uint256 public lastUpdateBlock;
    uint256 public lastEmergencyAction;
    uint256 public lastCircuitBreakerReset;
    uint256 public consecutiveFailures;
    uint256 public currentVersion;
    uint256 public lastStakingUpdate;
    uint256 public accumulatedRewardsPerToken;

    // Core components
    SelfFundingConfig public selfFundingConfig;
    CircuitBreaker public circuitBreaker;
    OperationQueue public operationQueue;
    ITokenValidator public tokenValidator;
    IRouterSecurity public routerSecurity;
    QueueMetrics public queueMetrics;
    ILendingPool public lendingPool;

    // Storage arrays
    GasMetrics[10] public gasMetricsBuffer;
    address[] public liquidityPositions;
    address[] public tokenList;
    bytes32[] public activePaths;
    address[] public dexList;

    // Mappings
    mapping(bytes32 => FlashLoanData) public activeFlashLoans;
    mapping(bytes32 => Position) public positions;
    mapping(address => uint256) public flashLoanCount;
    mapping(bytes32 => uint256) public pathFailures;
    mapping(address => uint256) public tokenBlacklist;
    mapping(address => RouterMetrics) public routerMetrics;
    mapping(bytes32 => VolumeMetrics) public volumeMetrics;
    mapping(bytes32 => PricePoint[]) private priceHistory;
    mapping(bytes32 => uint256) public pathSuccessRate;
    mapping(bytes4 => OperationMetrics) private operationTypeMetrics;
    mapping(bytes4 => uint256) private operationBlacklist;
    mapping(address => uint256) public accumulatedRewards;

    struct MetricsTracker {
    uint256 totalVolume;
    uint256 averageGasUsed;
    uint256 totalOperations;
    uint256 lastUpdateBlock;
    }

    MetricsTracker public metrics;

// ============ Events ============
    event ArbitrageExecuted(
        bytes32 indexed identifier,
        address[] path,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 profit,
        uint256 gasUsed,
        bool withFlashLoan,
        uint256 timestamp
    );

    event FlashLoanExecuted(
        bytes32 indexed identifier,
        address asset,
        uint256 amount,
        uint256 fee,
        uint256 profit,
        uint256 timestamp
    );

    event FlashLoanFailed(
        bytes32 indexed identifier,
        string reason,
        bytes errorData,
        uint256 timestamp
    );

    event OpportunityDetected(
        bytes32 indexed identifier,
        address[] path,
        uint256 expectedProfit,
        uint256 confidence,
        uint256 timestamp
    );

    event EmergencyAction(
        string actionType,
        address indexed triggeredBy,
        string reason,
        bytes data,
        uint256 timestamp
    );

    event SystemMetricsUpdated(
        uint256 totalExecutions,
        uint256 successRate,
        uint256 avgGasUsed,
        uint256 totalProfit,
        uint256 timestamp
    );

    event SelfFundingProcessed(
        uint256 totalProfit,
        uint256 flashLoanAllocation,
        uint256 liquidityAllocation,
        uint256 timestamp
    );

    event FlashLoanPoolUpdated(
        uint256 newCapacity,
        uint256 added,
        uint256 timestamp
    );

    event PositionOpened(
        bytes32 indexed pathHash,
        uint256 size,
        uint256 leverage,
        bool isLong,
        uint256 timestamp
    );

    event PositionLiquidated(
        bytes32 indexed pathHash,
        uint256 price,
        uint256 pnl,
        uint256 timestamp
    );

    event OperationQueued(
        bytes32 indexed operationHash,
        uint256 scheduledBlock,
        uint256 maxDelay,
        uint256 timestamp
    );

    event StakingRewardsDistributed(uint256 amount, uint256 rewardPerToken, uint256 timestamp);
    event MarketStateChanged(bytes32 indexed identifier, bytes32 startState, bytes32 endState, uint256 timestamp);
    event EmergencyFundUpdated(uint256 newBalance, uint256 added, uint256 timestamp);
    event QueueProcessed(uint256 processed, uint256 remaining, uint256 timestamp);
    event OperationExecuted(bytes32 indexed operationHash, bool success, string result, uint256 timestamp);
    event OperationMetricsUpdated(bytes4 selector, uint256 successCount, uint256 totalGas, uint256 timestamp);

// ============ Modifiers ============
    modifier onlyOperator() {
        if (!hasRole(OPERATOR_ROLE, msg.sender)) {
            revert UnauthorizedAccess(msg.sender, "Operator role required");
        }
        _;
    }

    modifier whenNotStopped() {
        if (_emergencyLock) {
            revert StateError("System is in emergency stop mode");
        }
        _;
    }

    modifier validatePath(address[] memory path) {
        if (path.length < 2 || path.length > MAX_PATH_LENGTH) {
            revert InvalidPath("Invalid path length", abi.encode(path.length));
        }
        
        for (uint i = 0; i < path.length; i++) {
            if (path[i] == address(0)) {
                revert InvalidPath("Zero address in path", abi.encode(i));
            }
            if (i > 0 && path[i] == path[i-1]) {
                revert InvalidPath("Duplicate tokens", abi.encode(i));
            }
        }
        _;
    }

    modifier checkRateLimit() {
        if (!_checkGlobalRateLimit()) {
            revert StateError("Rate limit exceeded");
        }
        _;
    }

    modifier validateGas() {
        uint256 gasRequired = _estimateRequiredGas();
        if (gasleft() < gasRequired) {
            revert GasError(
                "Insufficient gas",
                gasRequired,
                gasleft()
            );
        }
        _;
    }

    modifier nonReentrantFlashLoan() {
        require(!_stakeReentryGuard, "ReentrancyGuard: reentrant call");
        _stakeReentryGuard = true;
        _;
        _stakeReentryGuard = false;
    }

    modifier ensureDeadline(uint256 deadline) {
        if (block.timestamp > deadline) {
            revert TimingError(
                "Deadline expired",
                deadline,
                block.timestamp
            );
        }
        _;
    }

    modifier validateState() {
        require(_validateSystemHealth(), "System unhealthy");
        require(_validateStateConsistency(), "State inconsistent");
        require(!_detectAnomalies(), "Anomalies detected");
        _;
    }

    modifier onlyMainnet() {
        require(block.chainid == 369, "PulseChain only");
        _;
    }

    modifier onlyActive() {
        require(!_maintenanceMode, "System in maintenance");
        require(!_emergencyLock, "System stopped");
        _;
    }

    // ============ Custom Errors ============
    error UnauthorizedAccess(address caller, string requirement);
    error InvalidPath(string reason, bytes data);
    error ExecutionFailed(string reason, bytes data);
    error CircuitBreakerError(string reason, bytes data);
    error StateError(string reason);
    error GasError(string reason, uint256 required, uint256 available);
    error TimingError(string reason, uint256 required, uint256 current);
    error TokenError(address token, string reason);
    error PositionError(bytes32 pathHash, string reason);
    error ValidationError(string message, string data);
    
    // ============ Constructor & Initialization ============
    /**
    * @notice Distribute staking rewards
    * @param amount Amount to distribute
    */
    function _distributeStakingRewards(uint256 amount) internal {
    if (totalStaked == 0 || amount == 0) return;
    
    // Calculate rewards per token
    uint256 rewardPerToken = (amount * 1e18) / totalStaked;
    
    // Update global metrics
    accumulatedRewardsPerToken += rewardPerToken;
    lastStakingUpdate = block.timestamp;
    
    emit StakingRewardsDistributed(amount, rewardPerToken, block.timestamp);
    }

    /**
    * @notice Extract profitability from operation parameters
    * @param params Operation parameters
    * @return Profitability estimate
    */
    function _extractProfitability(bytes memory params) internal pure returns (uint256) {
    if (params.length < 68) return 0;
    
    // Decode arbitrage parameters
    (address token, uint256 amount) = abi.decode(params, (address, uint256));
        params[4:],
        (address[], uint256[])
    );
    
    if (amounts.length < 2) return 0;
    
    // Calculate expected profit
    uint256 inputAmount = amounts[0];
    uint256 expectedOutput = amounts[amounts.length - 1];
    
    if (expectedOutput <= inputAmount) return 0;
    
    return expectedOutput - inputAmount;
    }

    /**
    * @notice Blacklist operation type
    * @param selector Function selector
    * @param reason Blacklist reason
    */
    function _blacklistOperationType(bytes4 selector, string memory reason) internal {
    // Add to blacklist
    operationBlacklist[selector] = block.timestamp + 1 hours;
    
    // Cancel any pending operations of this type
    for (uint256 i = 0; i < operationQueue.activeOperations.length; i++) {
        bytes32 opHash = operationQueue.activeOperations[i];
        QueuedOperation storage op = operationQueue.operations[opHash];
        
        if (op.isActive && _extractSelector(op.params) == selector) {
            op.isActive = false;
            operationQueue.currentSize--;
        }
    }
    
    emit OperationTypeBlacklisted(selector, reason, block.timestamp);
    }

    event OperationTypeBlacklisted(bytes4 indexed selector, string reason, uint256 timestamp);

    // Initialize lending pool

    constructor() Ownable(msg.sender) {
    // Initialize lending pool
    lendingPool = ILendingPool(PULSEX_ROUTER);
    _initializeAll();
    }

    function _initializeAll() internal {
        // Initialize core components
        _initializeBaseComponents();
        
        // Initialize advanced systems
        _initializeAdvancedSystems();
        
        // Initialize self funding
        _initializeSelfFunding();
        
        // Setup initial roles
        _setupInitialRoles();
        
        // Initialize WPLS interface
        _initializeBaseToken();
        
        // Initialize security
        _initializeSecurity();
    }

    function _initializeBaseComponents() internal {
        _emergencyLock = false;
        _maintenanceMode = false;
        _stakeReentryGuard = false;

        // Initialize lending pool
        lendingPool = ILendingPool(PULSEX_ROUTER);  // Or actual lending pool address

        // Initialize performance tracking
        totalExecutions = 0;
        successfulExecutions = 0;
        totalProfit = 0;

        // Set initial gas reserve
        currentGasReserve = 5 ether;
        emergencyFund = 0;

        // Initialize state
        lastUpdateBlock = block.number;
        currentVersion = 1;
    }


    function _initializeAdvancedSystems() internal {
    // Initialize circuit breaker
    circuitBreaker = CircuitBreaker({
        priceDeviationLimit: 300, // 3%
        volumeAnomalyThreshold: 5000, // 50%
        profitabilityThreshold: 1e15, // 0.001 PLS
        gasSpikeTolerance: 200,
        lastResetTime: block.timestamp,
        isTriggered: false,
        lastTriggerReason: ""
    });

    // Initialize operation queue
    _initializeOperationQueue();
    }

    function _initializeOperationQueue() internal {
    operationQueue.isPaused = false;
    operationQueue.currentSize = 0;
    operationQueue.maxQueueSize = 100;
    operationQueue.lastProcessedBlock = block.number;
    // Don't initialize mappings directly
    }

    function _initializeSelfFunding() internal {
        selfFundingConfig = SelfFundingConfig({
            targetLiquidity: 100 ether,
            minLiquidity: 10 ether,
            maxLiquidity: 1000 ether,
            reinvestmentRate: 7000,    // 70% reinvestment
            emergencyThreshold: 20 ether,
            lastRebalance: block.timestamp,
            autoCompound: true
        });

        flastLoanCapacity = 0;
    }

    function _setupInitialRoles() internal {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(TIMELOCK_ADMIN_ROLE, msg.sender);
    _grantRole(UPGRADE_ROLE, msg.sender);
    _grantRole(OPERATOR_ROLE, msg.sender);
    _grantRole(EMERGENCY_ADMIN_ROLE, msg.sender);
    _grantRole(TREASURY_ROLE, msg.sender);
    }

    function _initializeBaseToken() internal {
        // Approve WPLS for router
        IERC20(WPLS).approve(PULSEX_ROUTER, type(uint256).max);
        
        // Add to token list
        tokenList.push(WPLS);
    }

    function _checkGlobalRateLimit() internal view returns (bool) {
    if (dailyTrades >= MAX_DAILY_TRADES) {
        return false;
    }
    return true;
    }

    function _estimateRequiredGas() internal view returns (uint256) {
    return 300000; // Base gas estimation
    }

    function _validateStateConsistency() internal view returns (bool) {
    require(successfulExecutions <= totalExecutions, "Invalid execution count");
    require(dailyTrades <= MAX_DAILY_TRADES, "Daily trades exceeded");
    require(address(this).balance >= emergencyFund, "Emergency fund invariant");
    return true;
    }

    function _calculatePairPerformance(address router, bytes32 pairHash) internal view returns (uint256) {
    RouterMetrics storage routerMetric = routerMetrics[router];
    if (metrics.totalVolume == 0) return 0;
    return (metrics.successfulTrades * BASIS_POINTS) / 
        (metrics.successfulTrades + metrics.failedTrades);
    }

    function _getPoolSize(address token) internal view returns (uint256) {
    address pair = IPulseXFactory(PULSEX_FACTORY).getPair(token, WPLS);
    if (pair == address(0)) return 0;
    
    (uint112 reserve0, uint112 reserve1,) = IPulseXPair(pair).getReserves();
    return token < WPLS ? uint256(reserve0) : uint256(reserve1);
    }

    function _extractSelector(bytes memory data) internal pure returns (bytes4) {
    if (data.length < 4) return bytes4(0);
    bytes4 selector;
    assembly {
        selector := mload(add(data, 32))
    }
    return selector;
    }

    function _validateFlashLoanOperation(
    QueuedOperation memory operation
    ) internal view returns (bool) {
    (address token, uint256 amount) = abi.decode(params, (address, uint256));
        operation.params[4:],
        (address, uint256)
    );
    return amount > 0 && _validateTokenSecurity(token);
    }

    function _validateArbitrageOperation(
    QueuedOperation memory operation
    ) internal view returns (bool) {
    (address token, uint256 amount) = abi.decode(params, (address, uint256));
        operation.params[4:],
        (address[], uint256[])
    );
    return path.length >= 2 && amounts.length == path.length - 1;
    }

    function _calculatePriceDeviation(
    uint256 price1,
    uint256 price2
    ) internal pure returns (uint256) {
    if (price1 == price2) return 0;
    return price1 > price2 ? 
        ((price1 - price2) * BASIS_POINTS) / price2 :
        ((price2 - price1) * BASIS_POINTS) / price1;
    }

    /**
     * @notice Setup validator interfaces
     * @param _tokenValidator Token validator address
     * @param _routerSecurity Router security validator address
     */
    function setupValidators(
        address _tokenValidator,
        address _routerSecurity
    ) external onlyRole(TIMELOCK_ADMIN_ROLE) {
        require(_tokenValidator != address(0), "Invalid token validator");
        require(_routerSecurity != address(0), "Invalid router validator");
        
        tokenValidator = ITokenValidator(_tokenValidator);
        routerSecurity = IRouterSecurity(_routerSecurity);
    }

// ============ Core Arbitrage Functions ============
    
    struct ArbitrageOpportunity {
        address[] path;
        uint256 inputAmount;
        uint256 expectedOutput;
        uint256 profitPotential;
        address optimalRouter;
        uint96 confidence;
        uint96 gasEstimate;
        uint64 priceImpact;
        bool useFlashLoan;
        bytes32 identifier;
        uint32 timestamp;
        uint256[] splitAmounts;
    }

    struct ExecutionParams {
        uint256 deadline;
        uint256 minOutput;
        uint256 gasPrice;
        bool useFlashLoan;
        uint256[] splits;
        uint256 slippageTolerance;
        bytes32 marketState;
        uint256 maxPriceImpact;
    }

    /**
     * @notice Execute arbitrage opportunity
     * @param opportunity Arbitrage opportunity details
     * @param params Execution parameters
     * @return profit Amount of profit generated
     */
    function executeArbitrage(
        ArbitrageOpportunity calldata opportunity,
        ExecutionParams calldata params
    ) 
        external 
        nonReentrant 
        whenNotStopped
        validatePath(opportunity.path)
        checkRateLimit
        validateGas
        ensureDeadline(params.deadline)
        returns (uint256 profit) 
    {
        // Check risk limits
        require(_checkRiskLimits(opportunity), "Risk limits exceeded");

        // Validate execution environment
        _validateExecutionEnvironment(opportunity, params);

        // Record starting state
        uint256 startGas = gasleft();
        bytes32 startState = _calculateMarketState(opportunity.path);

        // Execute based on strategy
        if (params.useFlashLoan) {
            profit = _executeWithFlashLoan(opportunity, params);
        } else {
            profit = _executeStandardArbitrage(opportunity, params);
        }

        // Process profit if successful
        if (profit > 0) {
            _updateSuccessMetrics(opportunity, profit, startGas - gasleft());
            _processArbitrageProfit(profit);
        }

        // Verify final state
        bytes32 endState = _calculateMarketState(opportunity.path);
        emit MarketStateChanged(
            opportunity.identifier,
            startState,
            endState,
            block.timestamp
        );

        return profit;
    }

    /**
     * @notice Execute arbitrage with flash loan
     * @param opportunity Arbitrage opportunity
     * @param params Execution parameters
     * @return Total profit generated
     */
    function _executeWithFlashLoan(
        ArbitrageOpportunity memory opportunity,
        ExecutionParams memory params
    ) internal returns (uint256) {
        // Calculate flash loan requirements
        uint256 flashLoanFee = (opportunity.inputAmount * FLASH_LOAN_FEE) / BASIS_POINTS;
        uint256 totalRequired = opportunity.inputAmount + flashLoanFee;

        // Generate unique loan identifier
        bytes32 loanId = keccak256(abi.encode(
            opportunity.path,
            opportunity.inputAmount,
            block.timestamp,
            msg.sender
        ));

        // Setup flash loan data
        activeFlashLoans[loanId] = FlashLoanData({
            path: opportunity.path,
            dexPath: new address[](opportunity.path.length - 1),
            borrowAmount: opportunity.inputAmount,
            expectedProfit: opportunity.profitPotential,
            minAmountOut: params.minOutput,
            dexFees: new uint256[](opportunity.path.length - 1),
            identifier: loanId,
            deadline: params.deadline,
            initiator: msg.sender,
            isActive: true,
            startTime: block.timestamp,
            gasPrice: tx.gasprice
        });

        // Execute flash loan
        ILendingPool lendingPool = ILendingPool(opportunity.optimalRouter);
        try lendingPool.flashLoanSimple(
            address(this),
            opportunity.path[0],
            opportunity.inputAmount,
            abi.encode(loanId),
            0
        ) {
            // Calculate actual profit
            uint256 endBalance = IERC20(opportunity.path[0]).balanceOf(address(this));
            uint256 profit = endBalance > totalRequired ? endBalance - totalRequired : 0;

            // Cleanup loan data
            delete activeFlashLoans[loanId];

            return profit;
        } catch (bytes memory error) {
            delete activeFlashLoans[loanId];
            emit FlashLoanFailed(loanId, "Flash loan failed", error, block.timestamp);
            return 0;
        }
    }

    /**
     * @notice Execute standard arbitrage without flash loan
     * @param opportunity Arbitrage opportunity
     * @param params Execution parameters
     * @return Total profit generated
     */
    function _executeStandardArbitrage(
        ArbitrageOpportunity memory opportunity,
        ExecutionParams memory params
    ) internal returns (uint256) {
        // Validate starting balance
        uint256 startBalance = IERC20(opportunity.path[0]).balanceOf(address(this));
        require(startBalance >= opportunity.inputAmount, "Insufficient balance");

        // Execute trades according to split strategy
        uint256 operationProfit = 0;
        uint256 remainingInput = opportunity.inputAmount;

        for (uint256 i = 0; i < params.splits.length; i++) {
            // Calculate split amount
            uint256 splitAmount = (remainingInput * params.splits[i]) / BASIS_POINTS;
            if (splitAmount == 0) continue;

            // Calculate minimum output for split
            uint256 expectedOutput = (opportunity.expectedOutput * splitAmount) / opportunity.inputAmount;
            uint256 minOutput = (expectedOutput * (BASIS_POINTS - params.slippageTolerance)) / BASIS_POINTS;

            // Execute individual trades in path
            uint256 currentAmount = splitAmount;
            for (uint256 j = 0; j < opportunity.path.length - 1; j++) {
                currentAmount = _executeSwap(
                    opportunity.optimalRouter,
                    opportunity.path[j],
                    opportunity.path[j + 1],
                    currentAmount,
                    minOutput
                );

                if (currentAmount == 0) {
                    revert ExecutionFailed("Swap failed", abi.encode(j));
                }
            }

            // Update totals
            totalProfit += currentAmount > splitAmount ? currentAmount - splitAmount : 0;
            remainingInput -= splitAmount;

            // Verify market conditions haven't changed significantly
            if (i < params.splits.length - 1) {
                if (!_validateMarketConditions(opportunity.path, params.marketState)) {
                    break;
                }
            }
        }

        return totalProfit;
    }

    /**
 * @notice Check risk limits for arbitrage opportunity
 * @param opportunity Arbitrage opportunity details
 * @return Whether opportunity meets risk limits
 */
function _checkRiskLimits(
    ArbitrageOpportunity memory opportunity
) internal view returns (bool) {
    // Check path length limits
    if (opportunity.path.length < 2 || opportunity.path.length > MAX_PATH_LENGTH) {
        return false;
    }

    // Check input amount limits
    uint256 maxPosition = _calculateMaxPosition(opportunity.path[0]);
    if (opportunity.inputAmount > maxPosition) {
        return false;
    }

    // Check liquidity depth
    for (uint256 i = 0; i < opportunity.path.length - 1; i++) {
        (uint256 reserveIn, uint256 reserveOut) = _getRouterReserves(
            opportunity.optimalRouter,
            opportunity.path[i],
            opportunity.path[i + 1]
        );

        // Check minimum liquidity
        if (reserveIn < MIN_LIQUIDITY || reserveOut < MIN_LIQUIDITY) {
            return false;
        }

        // Check price impact
        uint256 impact = _calculatePriceImpact(
            opportunity.splitAmounts[i],
            reserveIn,
            reserveOut
        );
        if (impact > MAX_SLIPPAGE) {
            return false;
        }
    }

    // Check profitability vs gas costs
    uint256 gasPrice = Math.min(block.basefee + GAS_RESERVE_BPS, MAX_GAS_PRICE);
    uint256 estimatedGasCost = opportunity.gasEstimate * gasPrice;
    
    // Require minimum profit ratio
    if (opportunity.profitPotential <= estimatedGasCost * 3) {
        return false;
    }

    // Check MEV risk
    uint256 mevRisk = _calculateMEVRiskScore(opportunity.path, opportunity.inputAmount);
    if (mevRisk > 7000) { // 70% risk threshold
        return false;
    }

    // Check router security
    (bool secure, uint256 securityScore) = routerSecurity.validateRouter(opportunity.optimalRouter);
    if (!secure || securityScore < 7000) { // 70% security threshold
        return false;
    }

    // Check token security
    for (uint256 i = 0; i < opportunity.path.length; i++) {
        // Skip if token is whitelisted
        if (isWhitelisted[opportunity.path[i]]) continue;

        // Validate token
        (bool valid, string memory reason) = tokenValidator.validateToken(opportunity.path[i]);
        if (!valid) {
            return false;
        }

        // Check if token is blacklisted
        if (tokenBlacklist[opportunity.path[i]] > block.timestamp) {
            return false;
        }
    }

    // Check flash loan limits if using flash loan
    if (opportunity.useFlashLoan) {
        // Check flash loan capacity
        if (opportunity.inputAmount > flastLoanCapacity) {
            return false;
        }

        // Check flash loan count limits
        if (flashLoanCount[opportunity.path[0]] >= 3) { // Max 3 flash loans per token per block
            return false;
        }
    }

    // Check position concentration
    uint256 totalExposure = _calculateTotalExposure(opportunity.path[0]);
    if (totalExposure + opportunity.inputAmount > maxPosition) {
        return false;
    }

    // All checks passed
    return true;
    }

    /**
    * @notice Calculate maximum position size for token
     * @param token Token address
    * @return Maximum position size
    */
    function _calculateMaxPosition(address token) internal view returns (uint256) {
    uint256 poolSize = _getPoolSize(token);
    return (poolSize * MAX_POSITION_SIZE_BPS) / BASIS_POINTS;
    }

    /**
     * @notice Calculate price impact
    * @param amount Trade amount
    * @param reserveIn Input reserve
    * @param reserveOut Output reserve
    * @return Price impact in basis points
    */
    function _calculatePriceImpact(
    uint256 amount,
    uint256 reserveIn,
    uint256 reserveOut
    ) internal pure returns (uint256) {
    if (reserveIn == 0 || reserveOut == 0) return type(uint256).max;
    
    uint256 constantProduct = reserveIn * reserveOut;
    uint256 newReserveIn = reserveIn + amount;
    uint256 newReserveOut = constantProduct / newReserveIn;
    
    uint256 expectedOutput = (amount * reserveOut) / reserveIn;
    uint256 actualOutput = reserveOut - newReserveOut;
    
    if (actualOutput >= expectedOutput) return 0;
    
    return ((expectedOutput - actualOutput) * BASIS_POINTS) / expectedOutput;
    }

    /**
    * @notice Calculate total token exposure
    * @param token Token address
    * @return Total exposure amount
    */
    function _calculateTotalExposure(address token) internal view returns (uint256) {
    uint256 totalExposure = 0;
    
    // Sum active positions
    for (uint256 i = 0; i < activePaths.length; i++) {
        bytes32 pathHash = activePaths[i];
        FlashLoanData storage loan = activeFlashLoans[pathHash];
        
        if (loan.isActive && loan.path[0] == token) {
            totalExposure += loan.borrowAmount;
        }
    }
    
    // Add queued operations
    for (uint256 i = 0; i < operationQueue.activeOperations.length; i++) {
        bytes32 opHash = operationQueue.activeOperations[i];
        QueuedOperation storage op = operationQueue.operations[opHash];
        
        if (op.isActive) {
            bytes4 selector = _extractSelector(op.params);
            if (selector == FLASH_LOAN_SELECTOR) {
                (address token, uint256 amount) = abi.decode(params, (address, uint256));
                    op.params[4:],
                    (address, uint256)
                );
                if (loanToken == token) {
                    totalExposure += amount;
                }
            }
        }
    }
    
    return totalExposure;
}

    // Add required mappings at contract level
    mapping(address => bool) public isWhitelisted;

    /**
     * @notice Execute single swap
     * @param router Router to use
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Input amount
     * @param minAmountOut Minimum output amount
     * @return Amount received from swap
     */
    function _executeSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) internal returns (uint256) {
        // Safety checks
        require(_validateTokenSecurity(tokenIn), "Input token validation failed");
        require(_validateTokenSecurity(tokenOut), "Output token validation failed");
        require(_validateRouterSecurity(router), "Router validation failed");

        // Record initial balance
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));

        // Approve router
        _safeApprove(tokenIn, router, amountIn);

        // Setup path
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Execute swap
        try IPulseXRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            block.timestamp
        ) {
            // Calculate actual output
            uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
            uint256 outputAmount = balanceAfter - balanceBefore;

            require(outputAmount >= minAmountOut, "Insufficient output");

            // Update metrics
            _updateSwapMetrics(router, tokenIn, tokenOut, amountIn, outputAmount);

            return outputAmount;
        } catch {
            return 0;
        }
    }

    /**
    * @notice Execute arbitrage path
    * @param path Trading path of tokens
    * @param initialAmount Initial amount to trade
    * @param minAmountOut Minimum acceptable output amount
    * @return Whether the arbitrage path was successful
    */
    function _executeArbitragePath(
    address[] memory path,
    uint256 initialAmount,
    uint256 minAmountOut
    ) internal returns (bool) {
    uint256 currentAmount = initialAmount;

    // Execute swaps through the entire path
    for (uint256 i = 0; i < path.length - 1; i++) {
        // Find optimal router for the pair
        address router = _findOptimalRouter(path[i], path[i + 1], currentAmount);

        // Execute swap between tokens
        currentAmount = _executeSwap(
            router,
            path[i],
            path[i + 1],
            currentAmount,
            0 // Use minimal output to pass through path
        );

        // Check if swap failed
        if (currentAmount == 0) {
            return false;
        }
    }

    // Check final output meets minimum requirements
    return currentAmount >= minAmountOut;
    }

    /**
    * @notice Update metrics after successful swap
    * @param router Router address
    * @param tokenIn Input token
    * @param tokenOut Output token
     * @param amountIn Input amount
    * @param amountOut Output amount
    */
    function _updateSwapMetrics(
    address router,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 amountOut
    ) internal {
    // Update router metrics
    RouterMetrics storage routerMetric = routerMetrics[router];
    metrics.totalVolume += amountIn;
    metrics.successfulTrades++;
    
    // Update average gas used
    uint256 gasUsed = GAS_RESERVE_BPS - gasleft();
    metrics.averageGasUsed = _calculateRunningAverage(
        metrics.averageGasUsed,
        gasUsed,
        metrics.successfulTrades
    );
    
    // Update token volumes
    metrics.tokenVolumes[tokenIn] += amountIn;
    metrics.tokenVolumes[tokenOut] += amountOut;
    
    // Update last block
    metrics.lastUpdateBlock = block.number;
    }

    /**
     * @notice Update success metrics after profitable execution
     * @param opportunity Executed opportunity
     * @param profit Amount of profit generated
     * @param gasUsed Gas consumed in execution
     */
    function _updateSuccessMetrics(
        ArbitrageOpportunity memory opportunity,
        uint256 profit,
        uint256 gasUsed
    ) internal {
        // Update execution counts
        totalExecutions++;
        successfulExecutions++;
        
        // Update profit tracking
        totalProfit += profit;
        
        // Update gas metrics
        totalGasSpent += gasUsed;
        
        // Update path metrics
        pathSuccessRate[opportunity.identifier] = _calculateRunningAverage(
            pathSuccessRate[opportunity.identifier],
            BASIS_POINTS,
            pathFailures[opportunity.identifier]
        );

        emit ArbitrageExecuted(
            opportunity.identifier,
            opportunity.path,
            opportunity.inputAmount,
            opportunity.expectedOutput,
            profit,
            gasUsed,
            opportunity.useFlashLoan,
            block.timestamp
        );
    }

    /**
     * @notice Process and distribute arbitrage profit
     * @param profit Amount of profit to process
     */
    function _processArbitrageProfit(uint256 profit) internal {
        if (profit == 0) return;

        // Process for self-funding
        _processFlashLoanProfit(profit);

        // Process for staking rewards if enabled
        if (totalStaked > 0) {
            uint256 stakingReward = (profit * 2000) / BASIS_POINTS; // 20% to staking
            _distributeStakingRewards(stakingReward);
        }

        // Update emergency fund
        uint256 emergencyAllocation = (profit * 1000) / BASIS_POINTS; // 10% to emergency fund
        emergencyFund += emergencyAllocation;
    }

    /**
     * @notice Calculate running average
     * @param currentAvg Current average value
     * @param newValue New value to include
     * @param count Number of items in average
     */
    function _calculateRunningAverage(
        uint256 currentAvg,
        uint256 newValue,
        uint256 count
    ) internal pure returns (uint256) {
        if (count == 0) return newValue;
        return ((currentAvg * count) + newValue) / (count + 1);
    }

    /**
     * @notice Safely approve token spending
     * @param token Token to approve
     * @param spender Address to approve
     * @param amount Amount to approve
     */
    function _safeApprove(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amount);
    }

// ============ Validation Functions ============

    /**
     * @notice Validate execution environment
     * @param opportunity Arbitrage opportunity
     * @param params Execution parameters
     */
    function _validateExecutionEnvironment(
        ArbitrageOpportunity memory opportunity,
        ExecutionParams memory params
    ) internal view {
        // Check circuit breaker
        if (circuitBreaker.isTriggered) {
            if (block.timestamp < lastCircuitBreakerReset + CIRCUIT_BREAKER_RESET_TIME) {
                revert CircuitBreakerTriggered("Circuit breaker active", "");
            }
        }

        // Validate market conditions
        if (!_validateMarketConditions(opportunity.path, params.marketState)) {
            revert StateError("Market conditions changed");
        }

        // Validate gas conditions
        if (!_validateGasConditions(opportunity.gasEstimate)) {
            revert GasError("Unfavorable gas conditions", 0, 0);
        }

        // Validate profitability
        uint256 gasPrice = Math.min(block.basefee + GAS_RESERVE_BPS, MAX_GAS_PRICE);
        uint256 gasCost = opportunity.gasEstimate * gasPrice;
        if (opportunity.profitPotential <= gasCost * 3) { // 3x minimum profit ratio
            revert ValidationError("Insufficient profit ratio", "");
        }
    }

    /**
     * @notice Validate market conditions
     * @param path Token path
     * @param referenceState Reference market state
     * @return Whether conditions are valid
     */
    function _validateMarketConditions(
        address[] memory path,
        bytes32 referenceState
    ) internal view returns (bool) {
        bytes32 currentState = _calculateMarketState(path);
        
        if (currentState != referenceState) {
            // Calculate state deviation
            uint256 deviation = _calculateStateDeviation(currentState, referenceState);
            return deviation <= circuitBreaker.priceDeviationLimit;
        }
        
        return true;
    }

    /**
     * @notice Validate gas conditions
     * @param gasEstimate Estimated gas requirement
     * @return Whether gas conditions are acceptable
     */
    function _validateGasConditions(
        uint256 gasEstimate
    ) internal view returns (bool) {
        // Check if gas price is within limits
        if (block.basefee > MAX_GAS_PRICE) {
            return false;
        }

        // Calculate total gas cost
        uint256 gasPrice = block.basefee + GAS_RESERVE_BPS;
        uint256 totalGasCost = gasEstimate * gasPrice;

        // Check if we have sufficient gas reserve
        if (currentGasReserve < totalGasCost * 2) {
            return false;
        }

        // Check for gas price volatility
        if (_detectGasVolatility()) {
            return false;
        }

        return true;
    }

    /**
     * @notice Validate token security
     * @param token Token to check
     * @return Whether token is secure
     */
    function _validateTokenSecurity(
    address token
    ) internal returns (bool) {
    // Check if token is blacklisted
    if (tokenBlacklist[token] > block.timestamp) {
        return false;
    }

    // Check external validator if available
    if (address(tokenValidator) != address(0)) {
        try tokenValidator.validateToken(token) returns (bool valid, string memory) {
            if (!valid) return false;
        } catch {
            return false;
        }
    }

    // Check trading history
    if (metrics.totalVolume == 0) {  // Use totalVolume from MetricsTracker
        return false;
    }

    return true;
    }

    /**
     * @notice Validate router security
     * @param router Router to validate
     * @return Whether router is secure
     */
    function _validateRouterSecurity(
        address router
    ) internal view returns (bool) {
        // Check if router is verified
        RouterMetrics storage routerMetric = routerMetrics[router];
        if (metrics.lastUpdateBlock == 0) {
            return false;
        }

        // Check external security if available
        if (address(routerSecurity) != address(0)) {
            try routerSecurity.validateRouter(router) returns (bool secure, uint256 score) {
                if (!secure || score < 7000) {
                    return false;
                }
            } catch {
                return false;
            }
        }

        // Check success rate
        if (metrics.totalVolume > 0) {
            uint256 successRate = (metrics.successfulTrades * BASIS_POINTS) / 
                (metrics.successfulTrades + metrics.failedTrades);
            if (successRate < 7000) { // 70% minimum success rate
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Calculate market state
     * @param path Token path
     * @return Current market state hash
     */
    function _calculateMarketState(
        address[] memory path
    ) internal view returns (bytes32) {
        bytes memory stateData;

        // Collect reserves for each pair in path
        for (uint256 i = 0; i < path.length - 1; i++) {
            (uint112 reserve0, uint112 reserve1,) = IPulseXPair(
                IPulseXFactory(PULSEX_FACTORY).getPair(path[i], path[i + 1])
            ).getReserves();

            stateData = abi.encodePacked(
                stateData,
                reserve0,
                reserve1
            );
        }

        return keccak256(stateData);
    }

    /**
     * @notice Calculate state deviation
     * @param currentState Current state hash
     * @param referenceState Reference state hash
     * @return Deviation in basis points
     */
    function _calculateStateDeviation(
        bytes32 currentState,
        bytes32 referenceState
    ) internal pure returns (uint256) {
        if (currentState == referenceState) return 0;
        
        uint256 currentValue = uint256(currentState);
        uint256 referenceValue = uint256(referenceState);
        
        if (currentValue > referenceValue) {
            return ((currentValue - referenceValue) * BASIS_POINTS) / referenceValue;
        } else {
            return ((referenceValue - currentValue) * BASIS_POINTS) / referenceValue;
        }
    }

    /**
     * @notice Detect gas price volatility
     * @return Whether gas is volatile
     */
    function _detectGasVolatility() internal view returns (bool) {
        uint256 volatility = 0;
        uint256 lastBaseFee = block.basefee;

        // Check recent blocks
        for (uint256 i = 0; i < 10; i++) {
            if (lastBaseFee > block.basefee) {
                volatility += ((lastBaseFee - block.basefee) * BASIS_POINTS) / lastBaseFee;
            } else {
                volatility += ((block.basefee - lastBaseFee) * BASIS_POINTS) / block.basefee;
            }
            lastBaseFee = block.basefee;
        }

        return volatility > 2000; // 20% threshold
    }

// ============ Self-Funding Management ============

    /**
     * @notice Process flash loan profits for self-funding
     * @param profit Amount of profit to process
     */
    function _processFlashLoanProfit(uint256 profit) internal {
        if (profit == 0) return;

        // Calculate base reinvestment
        uint256 reinvestAmount = (profit * selfFundingConfig.reinvestmentRate) / BASIS_POINTS;

        // Dynamic adjustment based on current liquidity
        uint256 currentLiquidity = _calculateTotalLiquidity();
        
        if (currentLiquidity < selfFundingConfig.targetLiquidity) {
            // Increase reinvestment when below target
            uint256 deficit = selfFundingConfig.targetLiquidity - currentLiquidity;
            uint256 additionalReinvestment = Math.min(
                profit - reinvestAmount,
                (deficit * 2000) / BASIS_POINTS  // Up to 20% additional
            );
            reinvestAmount += additionalReinvestment;
        } else if (currentLiquidity > selfFundingConfig.maxLiquidity) {
            // Decrease reinvestment when above max
            reinvestAmount = (reinvestAmount * 8000) / BASIS_POINTS;  // 20% reduction
        }

        // Handle emergency fund
        if (emergencyFund < selfFundingConfig.emergencyThreshold) {
            uint256 emergencyAllocation = (reinvestAmount * 2000) / BASIS_POINTS;  // 20% to emergency
            emergencyFund += emergencyAllocation;
            reinvestAmount -= emergencyAllocation;

            emit EmergencyFundUpdated(
                emergencyFund,
                emergencyAllocation,
                block.timestamp
            );
        }

        // Allocate to flash loan pool
        uint256 flashLoanAllocation = (reinvestAmount * 6000) / BASIS_POINTS;  // 60% to flash loans
        _addToFlashLoanPool(flashLoanAllocation);

        // Remaining to liquidity provision
        uint256 liquidityAllocation = reinvestAmount - flashLoanAllocation;
        _addToLiquidityPool(liquidityAllocation);

        emit SelfFundingProcessed(
            profit,
            flashLoanAllocation,
            liquidityAllocation,
            block.timestamp
        );

        // Check for auto-compound
        if (selfFundingConfig.autoCompound) {
            _processAutoCompound();
        }
    }

    /**
     * @notice Add funds to flash loan pool
     * @param amount Amount to add
     */
    function _addToFlashLoanPool(uint256 amount) internal {
        if (amount == 0) return;

        // Convert to WPLS if needed
        if (address(this).balance >= amount) {
            IWPLS(WPLS).deposit{value: amount}();
        }

        // Update flash loan capacity
        flastLoanCapacity += amount;

        emit FlashLoanPoolUpdated(
            flastLoanCapacity,
            amount,
            block.timestamp
        );
    }

    /**
     * @notice Add funds to liquidity pool
     * @param amount Amount to add
     */
    function _addToLiquidityPool(uint256 amount) internal {
        if (amount == 0) return;

        // Convert to WPLS if needed
        if (address(this).balance >= amount) {
            IWPLS(WPLS).deposit{value: amount}();
        }

        // Add liquidity to optimal pools
        address[] memory optimalPools = _findOptimalLiquidityPools();
        uint256 amountPerPool = amount / optimalPools.length;

        for (uint256 i = 0; i < optimalPools.length; i++) {
            _addLiquidityToPool(optimalPools[i], amountPerPool);
        }
    }

    /**
     * @notice Process auto-compound of profits
     */
    function _processAutoCompound() internal {
        if (block.timestamp < selfFundingConfig.lastRebalance + 1 days) return;

        // Collect accumulated fees
        uint256 feeAccumulation = _collectAccumulatedFees();
        if (feeAccumulation > 0) {
            // Reinvest fees
            _processFlashLoanProfit(feeAccumulation);
        }

        // Rebalance pools if needed
        _rebalanceLiquidityPools();

        selfFundingConfig.lastRebalance = block.timestamp;
    }

    /**
     * @notice Calculate total protocol liquidity
     * @return Total liquidity across all pools
     */
    function _calculateTotalLiquidity() internal view returns (uint256) {
        uint256 total = flastLoanCapacity;  // Flash loan pool

        // Add DEX liquidity positions
        for (uint256 i = 0; i < liquidityPositions.length; i++) {
            total += _getLiquidityPositionValue(liquidityPositions[i]);
        }

        // Add available balance
        total += IERC20(WPLS).balanceOf(address(this));
        total += address(this).balance;

        return total;
    }

    /**
     * @notice Find optimal pools for liquidity provision
     * @return Array of pool addresses
     */
    function _findOptimalLiquidityPools() internal view returns (address[] memory) {
        uint256 poolCount = 0;
        address[] memory pools = new address[](dexList.length);

        // Find pools meeting criteria
        for (uint256 i = 0; i < dexList.length; i++) {
            address router = dexList[i];
            RouterMetrics storage routerMetric = routerMetrics[router];

            // Check router performance
            if (metrics.successfulTrades * 100 / (metrics.successfulTrades + metrics.failedTrades) >= 80) {
                pools[poolCount] = router;
                poolCount++;
            }
        }

        // Create right-sized array
        address[] memory optimalPools = new address[](poolCount);
        for (uint256 i = 0; i < poolCount; i++) {
            optimalPools[i] = pools[i];
        }

        return optimalPools;
    }

    /**
     * @notice Add liquidity to specific pool
     * @param pool Pool address
     * @param amount Amount to add
     */
    function _addLiquidityToPool(address pool, uint256 amount) internal {
        if (amount == 0) return;

        // Get pool tokens
        address token0 = IPulseXPair(pool).token0();
        address token1 = IPulseXPair(pool).token1();

        // Calculate optimal amounts
        uint256 amount0 = amount / 2;
        uint256 amount1 = amount - amount0;

        // Add liquidity
        IERC20(WPLS).approve(PULSEX_ROUTER, amount);
        
        try IPulseXRouter(PULSEX_ROUTER).addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            0, // Accept any amount
            0, // Accept any amount
            address(this),
            block.timestamp
        ) {
            // Track position
            liquidityPositions.push(pool);
        } catch {
            // Failed to add liquidity
            return;
        }
    }

    /**
     * @notice Get liquidity position value
     * @param lpToken LP token address
     * @return Position value
     */
    function _getLiquidityPositionValue(address lpToken) internal view returns (uint256) {
        uint256 balance = IERC20(lpToken).balanceOf(address(this));
        if (balance == 0) return 0;

        // Get underlying tokens
        address token0 = IPulseXPair(lpToken).token0();
        address token1 = IPulseXPair(lpToken).token1();

        // Get reserves
        (uint112 reserve0, uint112 reserve1,) = IPulseXPair(lpToken).getReserves();
        uint256 totalSupply = IERC20(lpToken).totalSupply();

        // Calculate share of reserves
        uint256 share0 = (balance * uint256(reserve0)) / totalSupply;
        uint256 share1 = (balance * uint256(reserve1)) / totalSupply;

        // Convert to common denominator (WPLS)
        return share0 + share1;
    }

    /**
     * @notice Collect accumulated protocol fees
     * @return Total fees collected
     */
    function _collectAccumulatedFees() internal returns (uint256) {
        uint256 totalFees = 0;

        // Collect from liquidity positions
        for (uint256 i = 0; i < liquidityPositions.length; i++) {
            address lpToken = liquidityPositions[i];
            IPulseXPair(lpToken).sync(); // Update reserves and collect fees
            
            uint256 balance = IERC20(lpToken).balanceOf(address(this));
            if (balance > 0) {
                totalFees += _getLiquidityPositionValue(lpToken);
            }
        }

        return totalFees;
    }

    /**
     * @notice Rebalance liquidity pools
     */
    function _rebalanceLiquidityPools() internal {
        // Remove liquidity from underperforming pools
        for (uint256 i = 0; i < liquidityPositions.length; i++) {
            address pool = liquidityPositions[i];
            if (_shouldRemoveLiquidity(pool)) {
                _removeLiquidityFromPool(pool);
            }
        }

        // Find new optimal pools
        address[] memory optimalPools = _findOptimalLiquidityPools();

        // Rebalance remaining liquidity
        uint256 availableLiquidity = IERC20(WPLS).balanceOf(address(this));
        if (availableLiquidity > 0) {
            uint256 amountPerPool = availableLiquidity / optimalPools.length;
            for (uint256 i = 0; i < optimalPools.length; i++) {
                _addLiquidityToPool(optimalPools[i], amountPerPool);
            }
        }
    }

    /**
     * @notice Check if liquidity should be removed from pool
     * @param pool Pool address
     * @return Whether liquidity should be removed
     */
    function _shouldRemoveLiquidity(address pool) internal view returns (bool) {
        // Check pool performance
        RouterMetrics storage metrics = routerMetrics[pool];
        if (metrics.successfulTrades == 0) return true;

        uint256 successRate = (metrics.successfulTrades * 100) / 
            (metrics.successfulTrades + metrics.failedTrades);

        return successRate < 80; // Remove if success rate below 80%
    }

    /**
     * @notice Remove liquidity from pool
     * @param pool Pool address
     */
    function _removeLiquidityFromPool(address pool) internal {
        uint256 lpBalance = IERC20(pool).balanceOf(address(this));
        if (lpBalance == 0) return;

        // Get pool tokens
        address token0 = IPulseXPair(pool).token0();
        address token1 = IPulseXPair(pool).token1();

        // Remove liquidity
        IERC20(pool).approve(PULSEX_ROUTER, lpBalance);
        
        try IPulseXRouter(PULSEX_ROUTER).removeLiquidity(
            token0,
            token1,
            lpBalance,
            0, // Accept any amount
            0, // Accept any amount
            address(this),
            block.timestamp
        ) {
            // Remove from tracking
            for (uint256 i = 0; i < liquidityPositions.length; i++) {
                if (liquidityPositions[i] == pool) {
                    liquidityPositions[i] = liquidityPositions[liquidityPositions.length - 1];
                    liquidityPositions.pop();
                    break;
                }
            }
        } catch {
            // Failed to remove liquidity
            return;
        }
    }

// ============ Emergency Systems ============

    /**
     * @notice Activate emergency stop
     * @param reason Reason for emergency stop
     */
    function activateEmergencyStop(
        string calldata reason
    ) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(!_emergencyLock, "Already stopped");
        
        _emergencyLock = true;
        lastEmergencyAction = block.timestamp;

        // Cancel all pending operations
        _cancelActiveOperations();

        // Clear active flash loans
        _clearActiveFlashLoans();

        emit EmergencyAction(
            "STOP",
            msg.sender,
            reason,
            "",
            block.timestamp
        );
    }

    /**
     * @notice Deactivate emergency stop
     * @param reason Reason for deactivation
     */
    function deactivateEmergencyStop(
        string calldata reason
    ) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(_emergencyLock, "Not stopped");
        require(
            block.timestamp >= lastEmergencyAction + MIN_EMERGENCY_COOLDOWN,
            "Emergency cooldown active"
        );

        // Verify system health
        require(_validateSystemHealth(), "System unhealthy");
        require(_validateStateConsistency(), "State inconsistent");
        require(!_detectAnomalies(), "Anomalies detected");

        _emergencyLock = false;

        emit EmergencyAction(
            "RESUME",
            msg.sender,
            reason,
            "",
            block.timestamp
        );
    }

    /**
     * @notice Emergency withdrawal of funds
     * @param tokens Array of token addresses to withdraw
     */
    function emergencyWithdraw(
        address[] calldata tokens
    ) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(_emergencyLock, "Only during emergency");

        // Transfer native currency
        uint256 nativeBalance = address(this).balance;
        if (nativeBalance > 0) {
            (bool success,) = GENESIS_WALLET.call{value: nativeBalance}("");
            require(success, "Native transfer failed");
        }

        // Transfer tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20 token = IERC20(tokens[i]);
            uint256 balance = token.balanceOf(address(this));
            if (balance > 0) {
                token.safeTransfer(GENESIS_WALLET, balance);
            }
        }

        emit EmergencyWithdrawal(
            tokens,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @notice Cancel all active operations
     */
    function _cancelActiveOperations() internal {
        // Cancel active trades
        for (uint256 i = 0; i < activePaths.length; i++) {
            bytes32 pathHash = activePaths[i];
            if (activeFlashLoans[pathHash].isActive) {
                delete activeFlashLoans[pathHash];
            }
        }

        // Clear operation queue
        operationQueue.isPaused = true;
        operationQueue.currentSize = 0;
        delete operationQueue.activeOperations;

        emit OperationsCancelled(block.timestamp);
    }

    /**
     * @notice Clear active flash loans
     */
    function _clearActiveFlashLoans() internal {
        for (uint256 i = 0; i < activePaths.length; i++) {
            bytes32 pathHash = activePaths[i];
            FlashLoanData storage loan = activeFlashLoans[pathHash];
            if (loan.isActive) {
                emit FlashLoanFailed(
                    loan.identifier,
                    "Emergency stop",
                    "",
                    block.timestamp
                );
                delete activeFlashLoans[pathHash];
            }
        }
    }

    /**
     * @notice Trigger circuit breaker
     * @param reason Reason for triggering
     */
    function _triggerCircuitBreaker(
        string memory reason
    ) internal {
        if (circuitBreaker.isTriggered) return;

        circuitBreaker.isTriggered = true;
        circuitBreaker.lastTriggerReason = reason;
        lastCircuitBreakerReset = block.timestamp;

        // Pause new operations
        operationQueue.isPaused = true;

        emit CircuitBreakerTriggered(
            reason,
            msg.sender,
            block.timestamp
        );
    }

    /**
* @notice Execute flash loan operation
*/
function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
) external override returns (bool) {
    // Validate flash loan
    require(msg.sender == address(lendingPool), "Unauthorized");  // Use lowercase lendingPool
    
    // Decode parameters
    (address token, uint256 amount) = abi.decode(params, (address, uint256));
    FlashLoanData storage loan = activeFlashLoans[loanId];
    require(loan.isActive, "Invalid loan");
    
    // Execute arbitrage path
    uint256 repayAmount = amount + premium;
    bool success = _executeArbitragePath(loan.path, amount, loan.minAmountOut);
    
    // Verify profit
    uint256 finalBalance = IERC20(asset).balanceOf(address(this));
    require(finalBalance >= repayAmount, "Insufficient profit");
    
    // Repay flash loan
    IERC20(asset).approve(address(lendingPool), repayAmount);
    
    return true;
    }

    /**
     * @notice Reset circuit breaker
     */
    function resetCircuitBreaker() external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(circuitBreaker.isTriggered, "Not triggered");
        require(
            block.timestamp >= lastCircuitBreakerReset + CIRCUIT_BREAKER_RESET_TIME,
            "Reset cooldown active"
        );

        // Verify conditions have normalized
        require(!_detectAnomalies(), "Anomalies still present");
        require(_validateSystemHealth(), "System unhealthy");

        circuitBreaker.isTriggered = false;
        circuitBreaker.lastTriggerReason = "";
        operationQueue.isPaused = false;

        emit CircuitBreakerReset(block.timestamp);
    }

    /**
     * @notice Validate system health
     * @return Whether system is healthy
     */
    function _validateSystemHealth() internal view returns (bool) {
        // Check balances
        require(
            address(this).balance >= emergencyFund,
            "Emergency fund balance"
        );

        // Check rate limits
        require(
            dailyTrades <= MAX_DAILY_TRADES,
            "Daily trade limit"
        );

        // Check active operations
        for (uint256 i = 0; i < activePaths.length; i++) {
            bytes32 pathHash = activePaths[i];
            FlashLoanData storage loan = activeFlashLoans[pathHash];
            if (loan.isActive) {
                require(
                    loan.deadline > block.timestamp,
                    "Expired loan"
                );
            }
        }

        // Check metrics
        require(
            successfulExecutions <= totalExecutions,
            "Invalid execution count"
        );

        return true;
    }

    /**
     * @notice Detect system anomalies
     * @return Whether anomalies were detected
     */
    function _detectAnomalies() internal view returns (bool) {
        // Check for price anomalies
        if (_detectPriceAnomalies()) return true;

        // Check for volume anomalies 
        if (_detectVolumeAnomalies()) return true;

        // Check for gas anomalies
        if (_detectGasAnomalies()) return true;

        return false;
    }

    /**
     * @notice Detect price anomalies
     */
    function _detectPriceAnomalies() internal view returns (bool) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            bytes32 priceKey = keccak256(abi.encodePacked(tokenList[i]));
            PricePoint[] storage history = priceHistory[priceKey];
            
            if (history.length < 2) continue;

            uint256 latestPrice = history[history.length - 1].price;
            uint256 previousPrice = history[history.length - 2].price;
            
            uint256 deviation = _calculatePriceDeviation(latestPrice, previousPrice);
            if (deviation > circuitBreaker.priceDeviationLimit) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Detect volume anomalies
     */
    function _detectVolumeAnomalies() internal view returns (bool) {
        for (uint256 i = 0; i < tokenList.length; i++) {
            bytes32 volumeKey = keccak256(abi.encodePacked(tokenList[i]));
            VolumeMetrics storage volumeMetric = volumeMetrics[volumeKey];
            
            if (metrics.volume24h == 0) continue;

            // Check for volume drop
            if (metrics.volumeMA7 > 0) {
                uint256 volumeChange = (metrics.volume24h * BASIS_POINTS) / metrics.volumeMA7;
                if (volumeChange < circuitBreaker.volumeAnomalyThreshold) {
                    return true;
                }
            }
        }
        return false;
    }

    /**
     * @notice Detect gas anomalies
     */
    function _detectGasAnomalies() internal view returns (bool) {
        uint256 baselineFee = block.basefee;
        
        // Check recent blocks
        for (uint256 i = 0; i < 10; i++) {
            GasMetrics memory gasMetric = gasMetricsBuffer[i];
            if (metrics.timestamp == 0) continue;
            
            uint256 deviation = (metrics.baseFee > baselineFee) ?
                ((metrics.baseFee - baselineFee) * BASIS_POINTS) / baselineFee :
                ((baselineFee - metrics.baseFee) * BASIS_POINTS) / metrics.baseFee;
                
            if (deviation > circuitBreaker.gasSpikeTolerance) {
                return true;
            }
        }
        return false;
    }

    // ============ Emergency Events ============
    event CircuitBreakerTriggered(
    string reason,
    address indexed trigger,
    uint256 timestamp
    );

    event CircuitBreakerReset(uint256 timestamp);
    
    event OperationsCancelled(uint256 timestamp);
    
    event EmergencyWithdrawal(
        address[] tokens,
        address indexed initiator,
        uint256 timestamp
    );

// ============ Router Optimization ============

    struct RouterOptimization {
        uint256 gasEfficiency;
        uint256 successRate;
        uint256 volumeScore;
        uint256 reliabilityScore;
        uint256 lastOptimization;
        bool isActive;
    }

    mapping(address => RouterOptimization) private routerOptimizations;
    uint256 private constant OPTIMIZATION_INTERVAL = 1 hours;
    uint256 private constant MIN_SUCCESS_RATE = 8000; // 80%

    /**
     * @notice Find optimal router for token pair
     * @param tokenA First token
     * @param tokenB Second token
     * @param amount Trade amount
     * @return Optimal router address
     */
    function _findOptimalRouter(
        address tokenA,
        address tokenB,
        uint256 amount
    ) internal view returns (address) {
        address bestRouter = PULSEX_ROUTER; // Default to main router
        uint256 bestScore = 0;

        for (uint256 i = 0; i < dexList.length; i++) {
            address router = dexList[i];
            RouterOptimization storage optimization = routerOptimizations[router];
            
            if (!optimization.isActive) continue;

            uint256 score = _calculateRouterScore(
                router,
                tokenA,
                tokenB,
                amount
            );

            if (score > bestScore) {
                bestScore = score;
                bestRouter = router;
            }
        }

        return bestRouter;
    }

    /**
     * @notice Calculate router score
     * @param router Router address
     * @param tokenA First token
     * @param tokenB Second token
     * @param amount Trade amount
     * @return Router score
     */
    function _calculateRouterScore(
        address router,
        address tokenA,
        address tokenB,
        uint256 amount
    ) internal view returns (uint256) {
        RouterOptimization storage optimization = routerOptimizations[router];
        RouterMetrics storage routerMetric = routerMetrics[router];

        // Start with base score
        uint256 score = BASIS_POINTS;

        // Gas efficiency (30%)
        score = score * optimization.gasEfficiency / BASIS_POINTS;
        score = (score * 3000) / BASIS_POINTS;

        // Success rate (30%)
        uint256 successRate = metrics.successfulTrades * BASIS_POINTS / 
            (metrics.successfulTrades + metrics.failedTrades);
        score += (successRate * 3000) / BASIS_POINTS;

        // Volume score (20%)
        score += (optimization.volumeScore * 2000) / BASIS_POINTS;

        // Reliability (20%)
        score += (optimization.reliabilityScore * 2000) / BASIS_POINTS;

        // Apply pair-specific adjustments
        score = _applyPairSpecificAdjustments(
            score,
            router,
            tokenA,
            tokenB,
            amount
        );

        return score;
    }

    /**
     * @notice Apply pair-specific score adjustments
     * @param baseScore Initial score
     * @param router Router address
     * @param tokenA First token
     * @param tokenB Second token
     * @param amount Trade amount
     * @return Adjusted score
     */
    function _applyPairSpecificAdjustments(
        uint256 baseScore,
        address router,
        address tokenA,
        address tokenB,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 score = baseScore;

        // Check liquidity depth
        (uint256 reserveA, uint256 reserveB) = _getRouterReserves(router, tokenA, tokenB);
        if (reserveA == 0 || reserveB == 0) return 0;

        // Calculate price impact
        uint256 impact = (amount * BASIS_POINTS) / Math.min(reserveA, reserveB);
        if (impact > MAX_POSITION_SIZE_BPS) {
            return 0;
        }

        // Adjust score based on impact
        score = score * (BASIS_POINTS - impact) / BASIS_POINTS;

        // Check historical performance for pair
        bytes32 pairHash = keccak256(abi.encodePacked(tokenA, tokenB));
        uint256 pairScore = _calculatePairPerformance(router, pairHash);
        score = score * pairScore / BASIS_POINTS;

        return score;
    }

    /**
     * @notice Update router optimization metrics
     * @param router Router address
     */
    function _updateRouterOptimization(address router) internal {
        RouterOptimization storage optimization = routerOptimizations[router];
        if (!optimization.isActive) return;

        if (block.timestamp < optimization.lastOptimization + OPTIMIZATION_INTERVAL) {
            return;
        }

        // Update gas efficiency
        optimization.gasEfficiency = _calculateGasEfficiency(router);

        // Update success rate
        RouterMetrics storage routerMetric = routerMetrics[router];
        uint256 successRate = metrics.successfulTrades * BASIS_POINTS / 
            (metrics.successfulTrades + metrics.failedTrades);
        
        // Check minimum success rate
        if (successRate < MIN_SUCCESS_RATE) {
            optimization.isActive = false;
            return;
        }

        // Update volume score
        optimization.volumeScore = _calculateVolumeScore(router);

        // Update reliability
        optimization.reliabilityScore = _calculateReliabilityScore(router);

        // Update timestamp
        optimization.lastOptimization = block.timestamp;

        emit RouterOptimizationUpdated(
            router,
            optimization.gasEfficiency,
            successRate,
            optimization.volumeScore,
            block.timestamp
        );
    }

    /**
     * @notice Calculate gas efficiency score
     * @param router Router address
     * @return Gas efficiency score
     */
    function _calculateGasEfficiency(address router) internal view returns (uint256) {
        RouterMetrics storage routerMetric = routerMetrics[router];
        if (metrics.averageGasUsed == 0) return 0;

        uint256 baselineGas = 200000; // Baseline gas usage
        if (metrics.averageGasUsed <= baselineGas) {
            return BASIS_POINTS;
        }

        return (baselineGas * BASIS_POINTS) / metrics.averageGasUsed;
    }

    /**
     * @notice Calculate volume score
     * @param router Router address
     * @return Volume score
     */
    function _calculateVolumeScore(address router) internal view returns (uint256) {
        RouterMetrics storage routerMetric = routerMetrics[router];
        if (metrics.totalVolume == 0) return 0;

        // Calculate 24h volume share
        uint256 totalVolume = _calculateTotalRouterVolume();
        if (totalVolume == 0) return 0;

        return (metrics.totalVolume * BASIS_POINTS) / totalVolume;
    }

    /**
     * @notice Calculate reliability score
     * @param router Router address
     * @return Reliability score
     */
    function _calculateReliabilityScore(address router) internal view returns (uint256) {
        RouterMetrics storage routerMetric = routerMetrics[router];
        
        // Calculate uptime
        uint256 uptime = _calculateRouterUptime(router);
        
        // Calculate error rate
        uint256 errorRate = metrics.failedTrades * BASIS_POINTS / 
            (metrics.successfulTrades + metrics.failedTrades);

        // Combine scores (50/50 weight)
        return (uptime * 5000 + (BASIS_POINTS - errorRate) * 5000) / BASIS_POINTS;
    }

    /**
     * @notice Get router reserves
     * @param router Router address
     * @param tokenA First token
     * @param tokenB Second token
     * @return reserveA Reserve of first token
     * @return reserveB Reserve of second token
     */
    function _getRouterReserves(
        address router,
        address tokenA,
        address tokenB
    ) internal view returns (uint256 reserveA, uint256 reserveB) {
        address factory = IPulseXRouter(router).factory();
        address pair = IPulseXFactory(factory).getPair(tokenA, tokenB);
        
        if (pair == address(0)) return (0, 0);

        (uint112 reserve0, uint112 reserve1,) = IPulseXPair(pair).getReserves();
        return tokenA < tokenB ? 
            (uint256(reserve0), uint256(reserve1)) : 
            (uint256(reserve1), uint256(reserve0));
    }

    /**
     * @notice Calculate total router volume
     */
    function _calculateTotalRouterVolume() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < dexList.length; i++) {
            total += routerMetrics[dexList[i]].totalVolume;
        }
        return total;
    }

    /**
     * @notice Calculate router uptime
     * @param router Router address
     * @return Uptime score
     */
    function _calculateRouterUptime(address router) internal view returns (uint256) {
        RouterMetrics storage routerMetric = routerMetrics[router];
        if (metrics.lastUpdateBlock == 0) return 0;

        uint256 activeBlocks = block.number - metrics.lastUpdateBlock;
        uint256 failedBlocks = metrics.failedTrades;

        if (activeBlocks == 0) return BASIS_POINTS;

        return ((activeBlocks - failedBlocks) * BASIS_POINTS) / activeBlocks;
    }

    // ============ Router Events ============
    event RouterOptimizationUpdated(
        address indexed router,
        uint256 gasEfficiency,
        uint256 successRate,
        uint256 volumeScore,
        uint256 timestamp
    );

    // ============ Advanced Security Features ============

    struct SecurityState {
        bool initialized;
        bytes32 lastStateHash;
        uint256 lastValidation;
        mapping(bytes32 => bool) validatedStates;
        uint256 validationCount;
        bool locked;
    }

    SecurityState private securityState;
    uint256 private constant VALIDATION_INTERVAL = 100; // blocks
    uint256 private constant MAX_VALIDATION_DELAY = 1000; // blocks

    struct MEVProtection {
        mapping(bytes32 => uint256) sandwichPatterns;
        mapping(address => uint256) frontrunningScore;
        uint256 lastBlockAnalyzed;
        uint256 detectionThreshold;
        mapping(bytes32 => bool) knownAttacks;
        bool isActive;
    }

    MEVProtection private mevProtection;
    uint256 private constant MEV_DETECTION_WINDOW = 10; // blocks
    uint256 private constant MEV_SCORE_THRESHOLD = 7000; // 70%

    /**
     * @notice Initialize security systems
     */
    function _initializeSecurity() internal {
        require(!securityState.initialized, "Already initialized");

        securityState.initialized = true;
        securityState.lastStateHash = _calculateInitialStateHash();
        securityState.lastValidation = block.number;
        securityState.validationCount = 0;
        securityState.locked = false;

        mevProtection.lastBlockAnalyzed = block.number;
        mevProtection.detectionThreshold = 3;
        mevProtection.isActive = true;
    }

    /**
     * @notice Calculate initial state hash
     */
    function _calculateInitialStateHash() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            address(this),
            block.chainid,
            block.timestamp,
            msg.sender
        ));
    }

    /**
     * @notice Validate contract state
     * @return Whether state is valid
     */
    function _validateState() internal returns (bool) {
        require(!securityState.locked, "Security state locked");
        
        // Check validation frequency
        require(
            block.number <= securityState.lastValidation + MAX_VALIDATION_DELAY,
            "Validation overdue"
        );

        // Calculate current state
        bytes32 currentState = _calculateCurrentState();

        // Verify state transition
        if (securityState.lastStateHash != bytes32(0)) {
            require(
                securityState.validatedStates[currentState],
                "Invalid state transition"
            );
        }

        // Update state
        securityState.locked = true;
        
        securityState.lastStateHash = currentState;
        securityState.lastValidation = block.number;
        securityState.validationCount++;
        
        securityState.locked = false;

        emit StateValidated(
            currentState,
            block.number,
            block.timestamp
        );

        return true;
    }

    /**
     * @notice Calculate current contract state
     */
    function _calculateCurrentState() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            securityState.lastStateHash,
            totalExecutions,
            successfulExecutions,
            totalProfit,
            flastLoanCapacity,
            emergencyFund,
            block.number,
            block.timestamp
        ));
    }

    /**
     * @notice Register valid state transition
     * @param newState New state hash
     */
    function _registerStateTransition(bytes32 newState) internal {
        require(!securityState.locked, "Security state locked");
        securityState.validatedStates[newState] = true;
    }

    /**
     * @notice Detect MEV attacks
     * @param path Trading path
     * @param amount Trade amount
     * @return Whether MEV attack detected
     */
    function _detectMEVAttack(
        address[] memory path,
        uint256 amount
    ) internal returns (bool) {
        if (!mevProtection.isActive) return false;

        // Check for sandwich patterns
        if (_detectSandwichPattern(path, amount)) {
            return true;
        }

        // Check for frontrunning
        if (_detectFrontrunning(path)) {
            return true;
        }

        // Record transaction pattern
        _recordTransactionPattern(path, amount);

        return false;
    }

    /**
     * @notice Detect sandwich attack pattern
     * @param path Trading path
     * @param amount Trade amount
     * @return Whether sandwich pattern detected
     */
    function _detectSandwichPattern(
        address[] memory path,
        uint256 amount
    ) internal view returns (bool) {
        bytes32 pattern = keccak256(abi.encodePacked(
            path,
            amount,
            block.number
        ));

        // Check recent blocks for similar patterns
        uint256 patternCount = 0;
        
        for (uint256 i = 1; i <= MEV_DETECTION_WINDOW; i++) {
            bytes32 blockPattern = keccak256(abi.encodePacked(
                blockhash(block.number - i),
                path,
                amount
            ));

            if (mevProtection.sandwichPatterns[blockPattern] > 0) {
                patternCount++;
            }
        }

        return patternCount >= mevProtection.detectionThreshold;
    }

    /**
     * @notice Detect frontrunning attempt
     * @param path Trading path
     * @return Whether frontrunning detected
     */
    function _detectFrontrunning(
        address[] memory path
    ) internal view returns (bool) {
        for (uint256 i = 0; i < path.length; i++) {
            if (mevProtection.frontrunningScore[path[i]] >= MEV_SCORE_THRESHOLD) {
                return true;
            }
        }
        return false;
    }

    /**
     * @notice Record transaction pattern
     * @param path Trading path
     * @param amount Trade amount
     */
    function _recordTransactionPattern(
        address[] memory path,
        uint256 amount
    ) internal {
        bytes32 pattern = keccak256(abi.encodePacked(
            path,
            amount,
            block.number
        ));

        mevProtection.sandwichPatterns[pattern] = block.number;

        // Update frontrunning scores
        for (uint256 i = 0; i < path.length; i++) {
            mevProtection.frontrunningScore[path[i]]++;
        }
    }

    /**
     * @notice Calculate MEV risk score
     * @param path Trading path
     * @param amount Trade amount
     * @return Risk score in basis points
     */
    function _calculateMEVRiskScore(
        address[] memory path,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 riskScore = 0;

        // Path length risk (longer paths have higher risk)
        riskScore += path.length * 1000; // 10% per hop

        // Amount size risk
        for (uint256 i = 0; i < path.length; i++) {
            uint256 poolSize = _getPoolSize(path[i]);
            if (poolSize > 0) {
                uint256 sizeRisk = (amount * BASIS_POINTS) / poolSize;
                riskScore = Math.max(riskScore, sizeRisk);
            }
        }

        // Historical attack patterns
        for (uint256 i = 0; i < path.length; i++) {
            uint256 attackScore = mevProtection.frontrunningScore[path[i]];
            riskScore = Math.max(riskScore, attackScore);
        }

        return Math.min(riskScore, BASIS_POINTS);
    }

    /**
     * @notice Clear old MEV data
     */
    function _cleanupMEVData() internal {
        // Clear old sandwich patterns
        bytes32[] memory oldPatterns = new bytes32[](100); // Maximum cleanup batch
        uint256 count = 0;

        // Find old patterns
        for (uint256 i = 0; i < MEV_DETECTION_WINDOW; i++) {
            bytes32 pattern = keccak256(abi.encodePacked(
                blockhash(block.number - i),
                block.timestamp
            ));
            
            if (mevProtection.sandwichPatterns[pattern] < block.number - MEV_DETECTION_WINDOW) {
                oldPatterns[count] = pattern;
                count++;
                if (count >= 100) break;
            }
        }

        // Delete old patterns
        for (uint256 i = 0; i < count; i++) {
            delete mevProtection.sandwichPatterns[oldPatterns[i]];
        }

        // Reset frontrunning scores periodically
        if (block.number >= mevProtection.lastBlockAnalyzed + 1000) {
            for (uint256 i = 0; i < tokenList.length; i++) {
                mevProtection.frontrunningScore[tokenList[i]] = 0;
            }
            mevProtection.lastBlockAnalyzed = block.number;
        }
    }

    /**
     * @notice Advanced signature verification with replay protection
     * @param hash Message hash
     * @param signature Signature bytes
     * @return Whether signature is valid
     */
    function _verifySignature(
        bytes32 hash,
        bytes memory signature
    ) internal view returns (bool) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length != 65) {
            return false;
        }

        assembly {
            r := mload(add(signature, 32))
            s := mload(add(signature, 64))
            v := byte(0, mload(add(signature, 96)))
        }

        if (v < 27) {
            v += 27;
        }

        address signer = ecrecover(hash, v, r, s);
        if (signer == address(0)) {
            return false;
        }

        return hasRole(OPERATOR_ROLE, signer);
    }

    // ============ Events ============
    event StateValidated(
        bytes32 indexed stateHash,
        uint256 blockNumber,
        uint256 timestamp
    );

    event MEVAttackDetected(
        bytes32 indexed pattern,
        address[] path,
        uint256 amount,
        uint256 riskScore,
        uint256 timestamp
    );

    // ============ Queue Management ============

    struct QueueConfig {
        uint256 maxSize;
        uint256 maxDelay;
        uint256 minGasLimit;
        uint256 processingCooldown;
        bool requiresSignature;
    }

    QueueConfig private queueConfig;
    uint256 private lastQueueProcess;

    /**
     * @notice Initialize queue configuration
     */
    function _initializeQueue() internal {
        queueConfig = QueueConfig({
            maxSize: 100,
            maxDelay: 50,  // blocks
            minGasLimit: 100000,
            processingCooldown: 1,  // blocks
            requiresSignature: true
        });
        
        operationQueue.maxQueueSize = queueConfig.maxSize;
    }

    /**
     * @notice Queue new operation
     * @param params Operation parameters
     * @param maxDelay Maximum execution delay
     * @return operationId Operation identifier
     */
    function queueOperation(
        bytes memory params,
        uint256 maxDelay
    ) public onlyRole(OPERATOR_ROLE) returns (bytes32) {
        require(!operationQueue.isPaused, "Queue is paused");
        require(operationQueue.currentSize < queueConfig.maxSize, "Queue full");
        require(maxDelay <= queueConfig.maxDelay, "Delay too long");

        // Generate operation ID
        bytes32 operationId = keccak256(abi.encodePacked(
            params,
            block.number,
            msg.sender,
            block.timestamp
        ));

        // Create operation
        operationQueue.operations[operationId] = QueuedOperation({
            operationHash: operationId,
            scheduledBlock: block.number + maxDelay,
            maxDelay: maxDelay,
            isActive: true,
            initiator: msg.sender,
            params: params,
            gasPrice: tx.gasprice,
            priority: _calculateOperationPriority(params)
        });

        // Update queue state
        operationQueue.activeOperations.push(operationId);
        operationQueue.currentSize++;

        emit OperationQueued(
            operationId,
            block.number + maxDelay,
            maxDelay,
            block.timestamp
        );

        return operationId;
    }

    /**
     * @notice Process operation queue
     * @return processedCount Number of operations processed
     */
    function processQueue() external nonReentrant returns (uint256) {
        require(
            block.number >= lastQueueProcess + queueConfig.processingCooldown,
            "Processing cooldown active"
        );

        if (operationQueue.isPaused || operationQueue.currentSize == 0) {
            return 0;
        }

        // Verify system state
        require(_validateSystemHealth(), "System unhealthy");
        require(!_detectAnomalies(), "Anomalies detected");

        uint256 processedCount = 0;
        uint256 startGas = gasleft();

        // Get prioritized operations
        bytes32[] memory prioritizedOps = _prioritizeOperations();

        for (uint256 i = 0; i < prioritizedOps.length; i++) {
            // Check remaining gas
            if (gasleft() < queueConfig.minGasLimit) {
                break;
            }

            bytes32 opHash = prioritizedOps[i];
            QueuedOperation storage op = operationQueue.operations[opHash];
            
            if (!op.isActive) continue;

            if (_isOperationEligible(op)) {
                bool success = _executeQueuedOperation(opHash);
                if (success) {
                    processedCount++;
                }
            }
        }

        // Update state
        lastQueueProcess = block.number;
        _updateQueueMetrics(processedCount, startGas - gasleft());

        emit QueueProcessed(
            processedCount,
            operationQueue.currentSize,
            block.timestamp
        );

        return processedCount;
    }

    /**
     * @notice Prioritize operations for processing
     * @return Array of prioritized operation hashes
     */
    function _prioritizeOperations() internal view returns (bytes32[] memory) {
        uint256 count = operationQueue.activeOperations.length;
        if (count == 0) return new bytes32[](0);

        // Create sorting array
        bytes32[] memory sortedOps = new bytes32[](count);
        uint256 activeCount = 0;

        // Filter active operations
        for (uint256 i = 0; i < count; i++) {
            bytes32 opHash = operationQueue.activeOperations[i];
            if (operationQueue.operations[opHash].isActive) {
                sortedOps[activeCount] = opHash;
                activeCount++;
            }
        }

        // Sort by priority
        _sortOperations(sortedOps, 0, activeCount - 1);

        // Create right-sized array
        bytes32[] memory prioritizedOps = new bytes32[](activeCount);
        for (uint256 i = 0; i < activeCount; i++) {
            prioritizedOps[i] = sortedOps[i];
        }

        return prioritizedOps;
    }

    /**
     * @notice Sort operations by priority
     * @param ops Operation array
     * @param left Start index
     * @param right End index
     */
    function _sortOperations(
        bytes32[] memory ops,
        uint256 left,
        uint256 right
    ) internal view {
        if (left >= right) return;

        // Use quicksort
        uint256 pivot = _partition(ops, left, right);
        if (pivot > 0) _sortOperations(ops, left, pivot - 1);
        _sortOperations(ops, pivot + 1, right);
    }

    /**
     * @notice Partition helper for quicksort
     * @param ops Operation array
     * @param left Start index
     * @param right End index
     * @return Pivot index
     */
    function _partition(
        bytes32[] memory ops,
        uint256 left,
        uint256 right
    ) internal view returns (uint256) {
        bytes32 pivot = ops[right];
        uint256 i = left;

        for (uint256 j = left; j < right; j++) {
            if (_compareOperations(ops[j], pivot)) {
                bytes32 temp = ops[i];
                ops[i] = ops[j];
                ops[j] = temp;
                i++;
            }
        }

        ops[right] = ops[i];
        ops[i] = pivot;
        return i;
    }

    /**
     * @notice Compare operations by priority
     * @param op1 First operation hash
     * @param op2 Second operation hash
     * @return Whether op1 has higher priority
     */
    function _compareOperations(
        bytes32 op1,
        bytes32 op2
    ) internal view returns (bool) {
        QueuedOperation storage operation1 = operationQueue.operations[op1];
        QueuedOperation storage operation2 = operationQueue.operations[op2];

        // Compare priority first
        if (operation1.priority != operation2.priority) {
            return operation1.priority > operation2.priority;
        }

        // Then scheduled block
        if (operation1.scheduledBlock != operation2.scheduledBlock) {
            return operation1.scheduledBlock < operation2.scheduledBlock;
        }

        // Finally gas price
        return operation1.gasPrice > operation2.gasPrice;
    }

    /**
     * @notice Check if operation is eligible for execution
     * @param operation Operation to check
     * @return Whether operation is eligible
     */
    function _isOperationEligible(
        QueuedOperation memory operation
    ) internal view returns (bool) {
        // Check timing
        if (block.number < operation.scheduledBlock) return false;
        if (block.number > operation.scheduledBlock + operation.maxDelay) return false;

        // Check gas price conditions
        if (block.basefee > operation.gasPrice * 12 / 10) { // 20% tolerance
            return false;
        }

        // Check operation-specific conditions
        bytes4 selector = _extractSelector(operation.params);
        
        if (selector == FLASH_LOAN_SELECTOR) {
            return _validateFlashLoanOperation(operation);
        } else if (selector == ARBITRAGE_SELECTOR) {
            return _validateArbitrageOperation(operation);
        }

        return true;
    }

    /**
     * @notice Execute queued operation
     * @param operationHash Operation identifier
     * @return success Whether execution was successful
     */
    function _executeQueuedOperation(
        bytes32 operationHash
    ) internal returns (bool) {
        QueuedOperation storage operation = operationQueue.operations[operationHash];
        
        // Record gas metrics
        uint256 startGas = gasleft();
        
        // Execute operation
        bool success;
        bytes memory result;
        (success, result) = address(this).call(operation.params);

        // Update metrics
        if (success) {
            _updateExecutionMetrics(operation, startGas - gasleft());
        } else {
            _handleExecutionFailure(operation, result);
        }

        // Cleanup operation
        operation.isActive = false;
        operationQueue.currentSize--;

        emit OperationExecuted(
            operationHash,
            success,
            success ? "Success" : string(result),
            block.timestamp
        );

        return success;
    }

    /**
     * @notice Update execution metrics
     * @param operation Executed operation
     * @param gasUsed Gas consumed
     */
    function _updateExecutionMetrics(
    QueuedOperation memory operation,
    uint256 gasUsed
    ) internal {
    // Update gas metrics
    bytes4 selector = _extractSelector(operation.params);
    metrics.averageGasUsed = _calculateRunningAverage(
        metrics.averageGasUsed,
        gasUsed,
        metrics.totalOperations
    );
    metrics.totalOperations++;
    metrics.lastUpdateBlock = block.number;

    // Update success rate for operation type
    OperationMetrics storage opMetrics = operationTypeMetrics[selector];
    opMetrics.successCount++;
    opMetrics.totalGasUsed += gasUsed;
    opMetrics.lastExecutionBlock = block.number;

    emit OperationMetricsUpdated(
        selector,
        opMetrics.successCount,
        opMetrics.totalGasUsed,
        block.timestamp
    );
    }

    /**
     * @notice Handle operation execution failure
     * @param operation Failed operation
     * @param error Error data
     */
    function _handleExecutionFailure(
        QueuedOperation memory operation,
        bytes memory error
    ) internal {
        // Parse error reason
        string memory reason = _parseRevertReason(error);

        // Update failure metrics
        bytes4 selector = _extractSelector(operation.params);
        OperationMetrics storage opMetric = operationTypeMetrics[selector];

        metrics.failureCount++;
        
        // Check for blacklisting
        if (metrics.failureCount >= MAX_FAILURES_BEFORE_LOCKOUT) {
            _blacklistOperationType(selector, reason);
        }

        emit OperationFailed(
            operation.operationHash,
            selector,
            reason,
            block.timestamp
        );
    }

    /**
     * @notice Calculate operation priority
     * @param params Operation parameters
     * @return Priority score
     */
    function _calculateOperationPriority(
        bytes memory params
    ) internal view returns (uint256) {
        // Base priority
        uint256 priority = 5000;

        // Analyze operation type
        bytes4 selector = _extractSelector(params);
        
        // Priority boosts based on operation type
        if (selector == FLASH_LOAN_SELECTOR) {
            priority += 2000; // Flash loans get high priority
        } else if (selector == ARBITRAGE_SELECTOR) {
            uint256 profitability = _extractProfitability(params);
            priority += (profitability * 1000) / BASIS_POINTS; // Scale with profit
        }

        return priority;
    }

    /**
     * @notice Update queue metrics
     * @param processedCount Number of operations processed
     * @param gasUsed Gas consumed
     */
    function _updateQueueMetrics(
        uint256 processedCount,
        uint256 gasUsed
    ) internal {
        // Update performance metrics
        if (processedCount > 0) {
            queueMetrics.averageGasPerOp = _calculateRunningAverage(
                queueMetrics.averageGasPerOp,
                gasUsed / processedCount,
                queueMetrics.totalProcessed
            );
            queueMetrics.totalProcessed += processedCount;
        }

        // Update timing metrics
        uint256 processingTime = block.timestamp - queueMetrics.lastProcessingTime;
        queueMetrics.averageProcessingTime = _calculateRunningAverage(
            queueMetrics.averageProcessingTime,
            processingTime,
            queueMetrics.totalProcessed
        );
        queueMetrics.lastProcessingTime = block.timestamp;

        emit QueueMetricsUpdated(
            queueMetrics.averageGasPerOp,
            queueMetrics.averageProcessingTime,
            operationQueue.currentSize,
            block.timestamp
        );
    }

    // ============ Queue Control Functions ============

    /**
     * @notice Pause operation queue
     * @param reason Pause reason
     */
    function pauseQueue(
        string calldata reason
    ) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(!operationQueue.isPaused, "Already paused");
        
        operationQueue.isPaused = true;
        emit QueueStateChanged(true, reason, block.timestamp);
    }

    /**
     * @notice Resume operation queue
     * @param reason Resume reason
     */
    function resumeQueue(
        string calldata reason
    ) external onlyRole(EMERGENCY_ADMIN_ROLE) {
        require(operationQueue.isPaused, "Not paused");
        require(_validateSystemHealth(), "System unhealthy");

        operationQueue.isPaused = false;
        emit QueueStateChanged(false, reason, block.timestamp);
    }

    // ============ Events ============

    event QueueStateChanged(
        bool isPaused,
        string reason,
        uint256 timestamp
    );

    event QueueMetricsUpdated(
        uint256 averageGasPerOp,
        uint256 averageProcessingTime,
        uint256 queueSize,
        uint256 timestamp
    );

    event OperationFailed(
        bytes32 indexed operationHash,
        bytes4 selector,
        string reason,
        uint256 timestamp
    );
    // ============ Storage Management ============

    /**
     * @notice Clean old storage data
     */
    function cleanStorageData() external onlyRole(OPERATOR_ROLE) {
        // Clean old MEV data
        _cleanupMEVData();

        // Clean old price history
        _cleanupPriceHistory();

        // Clean old operation data
        _cleanupOperationData();

        emit StorageCleaned(block.timestamp);
    }

    /**
     * @notice Cleanup old price history
     */
    function _cleanupPriceHistory() internal {
        for (uint256 i = 0; i < tokenList.length; i++) {
            bytes32 priceKey = keccak256(abi.encodePacked(tokenList[i]));
            PricePoint[] storage history = priceHistory[priceKey];
            
            if (history.length > 100) { // Keep last 100 points
                // Create new array with recent history
                PricePoint[] memory newHistory = new PricePoint[](100);
                for (uint256 j = 0; j < 100; j++) {
                    newHistory[j] = history[history.length - 100 + j];
                }
                
                // Clear storage array
                delete priceHistory[priceKey];
                
                // Repopulate with recent history
                for (uint256 j = 0; j < 100; j++) {
                    priceHistory[priceKey].push(newHistory[j]);
                }
            }
        }
    }

    /**
     * @notice Cleanup old operation data
     */
    function _cleanupOperationData() internal {
        bytes32[] memory completedOps = new bytes32[](operationQueue.activeOperations.length);
        uint256 count = 0;

        // Find completed operations
        for (uint256 i = 0; i < operationQueue.activeOperations.length; i++) {
            bytes32 opHash = operationQueue.activeOperations[i];
            if (!operationQueue.operations[opHash].isActive) {
                completedOps[count] = opHash;
                count++;
            }
        }

        // Remove completed operations
        for (uint256 i = 0; i < count; i++) {
            delete operationQueue.operations[completedOps[i]];
        }
    }

    // ============ View Functions ============

    /**
     * @notice Get contract metrics
     */
    function getMetrics() external view returns (
        uint256 executions,
        uint256 successful,
        uint256 profit,
        uint256 gasReserve,
        uint256 emergency,
        uint256 staked
    ) {
        return (
            totalExecutions,
            successfulExecutions,
            totalProfit,
            currentGasReserve,
            emergencyFund,
            totalStaked
        );
    }

    /**
     * @notice Get queue status
     */
    function getQueueStatus() external view returns (
        bool isPaused,
        uint256 size,
        uint256 maxSize,
        uint256 lastProcessed
    ) {
        return (
            operationQueue.isPaused,
            operationQueue.currentSize,
            operationQueue.maxQueueSize,
            operationQueue.lastProcessedBlock
        );
    }

    /**
     * @notice Get router metrics
     */
    function getRouterMetrics(address router) external view returns (
        uint256 volume,
        uint256 successCount,
        uint256 failCount,
        uint256 avgGas
    ) {
        RouterMetrics storage routerMetric = routerMetrics[router];
        return (
            metrics.totalVolume,
            metrics.successfulTrades,
            metrics.failedTrades,
            metrics.averageGasUsed
        );
    }

    // ============ Native Currency Handling ============
    
    receive() external payable {
        emit NativeReceived(msg.sender, msg.value, block.timestamp);
    }

    fallback() external payable {
        emit NativeReceived(msg.sender, msg.value, block.timestamp);
    }

    /**
     * @notice Withdraw native currency
     * @param amount Amount to withdraw
     */
    function withdrawNative(
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        require(amount <= address(this).balance - emergencyFund, "Exceeds available");
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
        emit NativeWithdrawn(msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Withdraw tokens
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function withdrawToken(
        address token,
        uint256 amount
    ) external onlyRole(TREASURY_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
        emit TokenWithdrawn(token, msg.sender, amount, block.timestamp);
    }

    // ============ Required Interface Functions ============

    /**
     * @notice Get flash loan receiver address
     */
    function ADDRESSES_PROVIDER() external pure returns (address) {
        return PULSEX_ROUTER;
    }

    /**
     * @notice Get lending pool address
     */
    function LENDING_POOL() external pure returns (address) {
        return PULSEX_ROUTER;
    }

    /**
    * @notice Parse revert reason from error data
    * @param error Error data
    * @return Parsed reason string
    */
    function _parseRevertReason(bytes memory error) internal pure returns (string memory) {
    if (error.length < 68) return "Unknown error";
    
    // Extract the revert string
    bytes memory reason = new bytes(error.length - 68);
    for(uint i = 0; i < reason.length; i++) {
        reason[i] = error[i + 68];
    }
    
    return string(reason);
    }

    // ============ Events ============

    event StorageCleaned(uint256 timestamp);
    
    event NativeReceived(
        address indexed sender,
        uint256 amount,
        uint256 timestamp
    );
    
    event NativeWithdrawn(
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );
    
    event TokenWithdrawn(
        address indexed token,
        address indexed recipient,
        uint256 amount,
        uint256 timestamp
    );
}