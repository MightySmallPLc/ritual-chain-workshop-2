// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RitualChain, IScheduler, IRitualWallet, ITEEServiceRegistry} from "./ritual/RitualChain.sol";

/**
 * @title PredictMarket
 * @notice An autonomous, self-resolving binary prediction market on Ritual Chain (PLC version).
 * Uses TEE executors to safely resolve off-chain oracle data via HTTP/JQ precompiles.
 */
contract PredictMarket {

    enum MarketStatus { Open, Resolving, Settled, Refunded, Cancelled }
    enum CompareOp { GT, GTE, LT, LTE }
    enum Outcome { None, Yes, No }
    enum AttemptCode { None, NoExecutor, HttpFailure, BadStatus, OracleError, BadValue }

    struct Market {
        uint256 id;
        address creator;
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        CompareOp op;
        uint64 closeBlock;
        uint64 resolveBlock;
        uint256 scheduleId;
        uint256 totalYes;
        uint256 totalNo;
        MarketStatus status;
        Outcome outcome;
        uint8 attempts;
        uint256 observedValue;
        string lastError;
    }

    struct MarketSpec {
        string question;
        string oracleUrl;
        string jsonPath;
        uint256 target;
        CompareOp op;
        uint256 bettingSeconds;
        uint256 resolveDelaySeconds;
    }

    struct Attempt {
        uint64 blockNumber;
        address executor;
        AttemptCode code;
        uint256 value;
        string message;
    }

    uint32 public constant MAX_ATTEMPTS = 3;
    uint32 public constant RETRY_INTERVAL_BLOCKS = 200;
    uint32 public constant RESOLVE_GAS_LIMIT = 2_000_000;
    uint32 public constant SCHEDULER_TTL_BLOCKS = 150;
    uint256 public constant HTTP_TTL_BLOCKS = 100;
    uint256 public constant EXECUTOR_PROBES = 8;
    uint256 public constant MIN_MAX_FEE_PER_GAS = 1 gwei;

    uint256 public constant MIN_BETTING_SECONDS = 30;
    uint256 public constant MIN_RESOLVE_DELAY_SECONDS = 15;
    uint256 public constant MAX_MARKET_SECONDS = 1 days;

    uint256 public immutable blockTimeMs;
    uint256 public marketCount;

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => mapping(address => uint256)) public yesStakes;
    mapping(uint256 => mapping(address => uint256)) public noStakes;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    mapping(uint256 => mapping(uint8 => Attempt)) public attempts;

    event MarketOpened(
        uint256 indexed marketId,
        address indexed creator,
        string question,
        uint64 closeBlock,
        uint64 resolveBlock,
        uint256 scheduleId
    );
    event StakePlaced(
        uint256 indexed marketId,
        address indexed bettor,
        bool isYes,
        uint256 amount
    );
    event ResolutionAttempt(
        uint256 indexed marketId,
        uint8 attempt,
        address executor
    );
    event ResolutionFailed(
        uint256 indexed marketId,
        uint8 attempt,
        AttemptCode code,
        string reason
    );
    event MarketClosed(
        uint256 indexed marketId,
        Outcome outcome,
        uint256 observedValue
    );
    event WinningsDisbursed(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event StakeReturned(
        uint256 indexed marketId,
        address indexed claimant,
        uint256 amount
    );
    event MarketCancelled(
        uint256 indexed marketId,
        string reason
    );

    error UnknownMarket();
    error OnlyScheduler();
    error BettingClosed();
    error ZeroStake();
    error NotResolved();
    error NotRefunded();
    error NothingToClaim();
    error AlreadySettled();
    error BadDuration();
    error EmptyString();
    error TransferFailed();
    error NotCreator();
    error CannotCancel();

    constructor(uint256 blockTimeMs_) {
        if (blockTimeMs_ == 0) revert BadDuration();
        blockTimeMs = blockTimeMs_;

        if (RitualChain.SCHEDULER.code.length > 0) {
            IScheduler(RitualChain.SCHEDULER).approveScheduler(
                RitualChain.SCHEDULER
            );
        }
    }

    function createMarket(
        MarketSpec calldata spec
    ) external returns (uint256 marketId) {
        if (bytes(spec.question).length == 0 || bytes(spec.oracleUrl).length == 0 || bytes(spec.jsonPath).length == 0) {
            revert EmptyString();
        }
        if (spec.bettingSeconds < MIN_BETTING_SECONDS || spec.resolveDelaySeconds < MIN_RESOLVE_DELAY_SECONDS ||
            spec.bettingSeconds + spec.resolveDelaySeconds > MAX_MARKET_SECONDS) {
            revert BadDuration();
        }

        uint256 close = block.number + _secondsToBlocks(spec.bettingSeconds);
        uint256 resolve = close + _secondsToBlocks(spec.resolveDelaySeconds);

        marketId = ++marketCount;

        uint256 scheduleId;
        if (RitualChain.SCHEDULER.code.length > 0) {
            scheduleId = _scheduleResolution(marketId, uint64(resolve));
        }

        _markets[marketId] = Market({
            id: marketId,
            creator: msg.sender,
            question: spec.question,
            oracleUrl: spec.oracleUrl,
            jsonPath: spec.jsonPath,
            target: spec.target,
            op: spec.op,
            closeBlock: uint64(close),
            resolveBlock: uint64(resolve),
            scheduleId: scheduleId,
            totalYes: 0,
            totalNo: 0,
            status: MarketStatus.Open,
            outcome: Outcome.None,
            attempts: 0,
            observedValue: 0,
            lastError: ""
        });

        emit MarketOpened(marketId, msg.sender, spec.question, uint64(close), uint64(resolve), scheduleId);
    }

    function bet(uint256 marketId, bool isYes) external payable {
        Market storage m = _market(marketId);
        if (msg.value == 0) revert ZeroStake();
        if (m.status != MarketStatus.Open || block.number >= m.closeBlock) {
            revert BettingClosed();
        }

        if (isYes) {
            yesStakes[marketId][msg.sender] += msg.value;
            m.totalYes += msg.value;
        } else {
            noStakes[marketId][msg.sender] += msg.value;
            m.totalNo += msg.value;
        }

        emit StakePlaced(marketId, msg.sender, isYes, msg.value);
    }

    function cancelMarket(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.creator != msg.sender) revert NotCreator();
        if (m.status != MarketStatus.Open || block.number >= m.closeBlock) revert CannotCancel();

        m.status = MarketStatus.Cancelled;
        if (m.scheduleId != 0 && RitualChain.SCHEDULER.code.length > 0) {
            IScheduler(RitualChain.SCHEDULER).cancel(m.scheduleId);
        }
        emit MarketCancelled(marketId, "creator cancelled");
    }

    function onScheduledResolve(
        uint256 executionIndex,
        uint256 marketId
    ) external {
        if (msg.sender != RitualChain.SCHEDULER) revert OnlyScheduler();

        Market storage m = _market(marketId);
        if (m.status == MarketStatus.Settled || m.status == MarketStatus.Refunded || m.status == MarketStatus.Cancelled) return;

        uint8 attempt = m.attempts + 1;
        m.attempts = attempt;
        m.status = MarketStatus.Resolving;

        address executor = _pickExecutor(marketId, executionIndex);
        emit ResolutionAttempt(marketId, attempt, executor);
        if (executor == address(0)) {
            _fail(m, marketId, attempt, AttemptCode.NoExecutor, "no HTTP executor available");
            return;
        }

        (bool ok, uint256 observed, AttemptCode code, string memory reason) = _readOracle(m, executor);
        if (!ok) {
            _fail(m, marketId, attempt, code, reason);
            return;
        }

        attempts[marketId][attempt] = Attempt({
            blockNumber: uint64(block.number),
            executor: executor,
            code: AttemptCode.None,
            value: observed,
            message: "ok"
        });

        m.observedValue = observed;
        m.outcome = _compare(observed, m.target, m.op) ? Outcome.Yes : Outcome.No;

        uint256 winningPool = m.outcome == Outcome.Yes ? m.totalYes : m.totalNo;
        if (winningPool == 0) {
            _invalidate(m, marketId, "winning side has no stake");
            return;
        }

        m.status = MarketStatus.Settled;
        if (m.scheduleId != 0) {
            IScheduler(RitualChain.SCHEDULER).cancel(m.scheduleId);
        }
        emit MarketClosed(marketId, m.outcome, observed);
    }

    function _fail(
        Market storage m,
        uint256 marketId,
        uint8 attempt,
        AttemptCode code,
        string memory reason
    ) private {
        attempts[marketId][attempt] = Attempt({
            blockNumber: uint64(block.number),
            executor: msg.sender,
            code: code,
            value: 0,
            message: reason
        });
        m.lastError = reason;
        emit ResolutionFailed(marketId, attempt, code, reason);
        if (attempt >= MAX_ATTEMPTS) {
            _invalidate(m, marketId, reason);
        }
    }

    function _invalidate(
        Market storage m,
        uint256 marketId,
        string memory reason
    ) private {
        m.status = MarketStatus.Refunded;
        m.lastError = reason;
        emit MarketClosed(marketId, Outcome.None, 0);
    }

    function claimWinnings(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.status != MarketStatus.Settled) revert NotResolved();
        if (hasClaimed[marketId][msg.sender]) revert AlreadySettled();

        uint256 payout = _payout(m, marketId, msg.sender);
        if (payout == 0) revert NothingToClaim();

        hasClaimed[marketId][msg.sender] = true;
        emit WinningsDisbursed(marketId, msg.sender, payout);
        _pay(msg.sender, payout);
    }

    function claimRefund(uint256 marketId) external {
        Market storage m = _market(marketId);
        if (m.status != MarketStatus.Refunded && m.status != MarketStatus.Cancelled) revert NotRefunded();
        if (hasClaimed[marketId][msg.sender]) revert AlreadySettled();

        uint256 amount = yesStakes[marketId][msg.sender] + noStakes[marketId][msg.sender];
        if (amount == 0) revert NothingToClaim();

        hasClaimed[marketId][msg.sender] = true;
        emit StakeReturned(marketId, msg.sender, amount);
        _pay(msg.sender, amount);
    }

    function _payout(
        Market storage m,
        uint256 marketId,
        address account
    ) private view returns (uint256) {
        bool yesWon = m.outcome == Outcome.Yes;
        uint256 stake = yesWon
            ? yesStakes[marketId][account]
            : noStakes[marketId][account];
        uint256 winningPool = yesWon ? m.totalYes : m.totalNo;
        if (stake == 0 || winningPool == 0) return 0;
        return (stake * (m.totalYes + m.totalNo)) / winningPool;
    }

    function getMarket(uint256 marketId) public view returns (Market memory m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
        if (m.status == MarketStatus.Open && block.number >= m.closeBlock) {
            m.status = MarketStatus.Resolving;
        }
    }

    function getMarkets(uint256 offset, uint256 limit) external view returns (Market[] memory page) {
        if (offset >= marketCount || limit == 0) return new Market[](0);
        uint256 count = limit > marketCount - offset ? marketCount - offset : limit;
        page = new Market[](count);
        for (uint256 i = 0; i < count; i++) {
            page[i] = getMarket(offset + i + 1);
        }
    }

    function stakesOf(
        uint256 marketId,
        address account
    )
        external
        view
        returns (
            uint256 yes,
            uint256 no,
            bool alreadySettled,
            uint256 claimable
        )
    {
        Market storage m = _market(marketId);
        (yes, no, alreadySettled) = (
            yesStakes[marketId][account],
            noStakes[marketId][account],
            hasClaimed[marketId][account]
        );
        if (alreadySettled) return (yes, no, true, 0);

        if (m.status == MarketStatus.Settled) {
            claimable = _payout(m, marketId, account);
        } else if (m.status == MarketStatus.Refunded || m.status == MarketStatus.Cancelled) {
            claimable = yes + no;
        }
    }

    function fundExecution(uint256 lockDurationBlocks) external payable {
        if (msg.value == 0) revert ZeroStake();
        IRitualWallet(RitualChain.RITUAL_WALLET).deposit{value: msg.value}(
            lockDurationBlocks
        );
    }

    function executionBalance() external view returns (uint256) {
        return IRitualWallet(RitualChain.RITUAL_WALLET).balanceOf(address(this));
    }

    function _readOracle(
        Market storage m,
        address executor
    ) private returns (bool ok, uint256 value, AttemptCode code, string memory reason) {
        bytes memory response = _httpGet(m.oracleUrl, executor);
        if (response.length == 0) {
            return (false, 0, AttemptCode.HttpFailure, "HTTP precompile call failed");
        }
        try this.decodeHttpResponse(response) returns (
            uint16 status,
            bytes memory body,
            string memory errorMessage
        ) {
            if (bytes(errorMessage).length != 0) {
                return (false, 0, AttemptCode.OracleError, errorMessage);
            }
            if (status < 200 || status >= 300) {
                return (false, 0, AttemptCode.BadStatus, "non-2xx HTTP status");
            }
            (bool parsed, uint256 parsedValue) = _jqUint(
                m.jsonPath,
                string(body)
            );
            if (!parsed) {
                return (false, 0, AttemptCode.BadValue, "jq uint extraction failed");
            }
            return (true, parsedValue, AttemptCode.None, "");
        } catch {
            return (false, 0, AttemptCode.BadValue, "invalid HTTP response envelope");
        }
    }

    function _httpGet(
        string memory url,
        address executor
    ) private returns (bytes memory response) {
        (bool ok, bytes memory raw) = RitualChain.HTTP_PRECOMPILE.call(
            abi.encode(
                executor,
                new bytes[](0),
                HTTP_TTL_BLOCKS,
                new bytes[](0),
                bytes(""),
                url,
                RitualChain.HTTP_GET,
                new string[](0),
                new string[](0),
                bytes(""),
                uint256(0),
                uint8(0),
                false
            )
        );
        if (!ok) return bytes("");
        return raw;
    }

    function decodeHttpResponse(
        bytes calldata raw
    )
        external
        pure
        returns (uint16 status, bytes memory body, string memory errorMessage)
    {
        (, bytes memory actualOutput) = abi.decode(raw, (bytes, bytes));
        require(actualOutput.length > 0, "async output not settled");
        (status, , , body, errorMessage) = abi.decode(
            actualOutput,
            (uint16, string[], string[], bytes, string)
        );
    }

    function _jqUint(
        string memory query,
        string memory json
    ) private view returns (bool, uint256) {
        (bool ok, bytes memory result) = RitualChain.JQ_PRECOMPILE.staticcall(
            abi.encode(query, json, RitualChain.JQ_OUT_UINT256)
        );
        if (!ok || result.length < 32) return (false, 0);
        return (true, abi.decode(result, (uint256)));
    }

    function _pickExecutor(
        uint256 marketId,
        uint256 executionIndex
    ) private view returns (address) {
        uint256 seed = uint256(
            keccak256(
                abi.encode(block.prevrandao, address(this), marketId, executionIndex)
            )
        );
        (address executor, bool found) = ITEEServiceRegistry(
            RitualChain.TEE_SERVICE_REGISTRY
        ).pickServiceByCapability(
                RitualChain.CAPABILITY_HTTP_CALL,
                true,
                seed,
                EXECUTOR_PROBES
            );
        return found ? executor : address(0);
    }

    function _scheduleResolution(
        uint256 marketId,
        uint64 resolveBlock
    ) private returns (uint256 callId) {
        uint256 maxFeePerGas = tx.gasprice > MIN_MAX_FEE_PER_GAS
            ? tx.gasprice
            : MIN_MAX_FEE_PER_GAS;
        callId = IScheduler(RitualChain.SCHEDULER).schedule(
            abi.encodeCall(this.onScheduledResolve, (0, marketId)),
            RESOLVE_GAS_LIMIT,
            uint32(resolveBlock),
            MAX_ATTEMPTS,
            RETRY_INTERVAL_BLOCKS,
            SCHEDULER_TTL_BLOCKS,
            maxFeePerGas,
            0,
            0,
            address(this)
        );
    }

    function _market(uint256 marketId) private view returns (Market storage m) {
        m = _markets[marketId];
        if (m.closeBlock == 0) revert UnknownMarket();
    }

    function _compare(
        uint256 observed,
        uint256 target,
        CompareOp comparator
    ) private pure returns (bool) {
        if (comparator == CompareOp.GT) return observed > target;
        if (comparator == CompareOp.GTE) return observed >= target;
        if (comparator == CompareOp.LT) return observed < target;
        return observed <= target;
    }

    function _secondsToBlocks(
        uint256 seconds_
    ) private view returns (uint256 blocks) {
        blocks = (seconds_ * 1000) / blockTimeMs;
        if (blocks == 0) blocks = 1;
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, ) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
