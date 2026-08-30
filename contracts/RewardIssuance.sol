// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideXaTypes.sol";
import "./UpsideToken.sol";

/// @title Upside Xa Reward Issuance Engine
/// @notice Converts quality scores into token rewards.
///
/// How it works:
/// 1. Admin creates a period (monthly cycle) with a coin allocation
/// 2. Oracle submits scores as ideas are assessed (0–1000 scale)
/// 3. Admin finalizes the period — no more scores accepted
/// 4. Users claim rewards — proportional to their scores vs total
///
/// Formula: reward = (user_total_score / period_total_score) × period_allocation

contract RewardIssuance {
    using UpsideXaTypes for *;

    // =========================================================================
    // STORAGE TYPES
    // =========================================================================

    struct Period {
        uint32  periodId;
        uint256 allocation;
        uint256 totalScore;
        uint32  participantCount;
        uint32  submissionCount;
        uint256 startsAt;
        uint256 endsAt;
        UpsideXaTypes.PeriodStatus status;
    }

    // =========================================================================
    // STATE
    // =========================================================================

    uint32 public nextPeriodId = 1;
    mapping(uint32 => Period) public periods;

    // Score tracking
    mapping(uint32 => mapping(address => uint256)) public userPeriodScores;
    mapping(uint32 => mapping(uint64 => bool)) public submittedIdeas;
    mapping(uint32 => mapping(uint32 => address)) public periodParticipants;

    // Claim tracking
    mapping(uint32 => mapping(address => bool)) public claims;

    // Access control
    address public admin;
    address public oracle;
    address public tokenContract;
    address public governanceContract;
    bool    public paused;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event PeriodCreated(uint32 periodId, uint256 allocation, uint256 startsAt, uint256 endsAt);
    event ScoreSubmitted(address indexed user, uint32 periodId, uint64 ideaId, uint32 score);
    event PeriodFinalized(uint32 periodId, uint256 totalScore, uint32 participantCount);
    event RewardClaimed(address indexed user, uint32 periodId, uint256 reward);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyOracle() { require(msg.sender == oracle, "Not oracle"); _; }
    modifier whenNotPaused() { require(!paused, "Paused"); _; }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    // PERIOD MANAGEMENT (Admin)
    // =========================================================================

    function createPeriod(
        uint256 allocation,
        uint256 startsAt,
        uint256 endsAt
    ) external onlyAdmin returns (uint32) {
        require(endsAt > startsAt, "Invalid time range");

        uint32 periodId = nextPeriodId++;

        periods[periodId] = Period({
            periodId: periodId,
            allocation: allocation,
            totalScore: 0,
            participantCount: 0,
            submissionCount: 0,
            startsAt: startsAt,
            endsAt: endsAt,
            status: UpsideXaTypes.PeriodStatus.Active
        });

        emit PeriodCreated(periodId, allocation, startsAt, endsAt);
        return periodId;
    }

    function finalizePeriod(uint32 periodId) external onlyAdmin {
        Period storage period = periods[periodId];
        require(period.periodId != 0, "Period not found");
        require(period.status == UpsideXaTypes.PeriodStatus.Active, "Already finalized");
        require(period.totalScore > 0, "No scores in period");

        period.status = UpsideXaTypes.PeriodStatus.Completed;

        emit PeriodFinalized(periodId, period.totalScore, period.participantCount);
    }

    // =========================================================================
    // SCORE SUBMISSION (Oracle only)
    // =========================================================================

    /// @notice Submit a quality score for a user's idea.
    ///         Score must be 0–1000 (representing 0.000–1.000).
    function submitScore(
        uint32 periodId,
        address user,
        uint64 ideaId,
        uint32 score
    ) public whenNotPaused onlyOracle {
        require(score <= UpsideXaTypes.SCORE_PRECISION, "Score out of range");

        Period storage period = periods[periodId];
        require(period.periodId != 0, "Period not found");
        require(period.status == UpsideXaTypes.PeriodStatus.Active, "Period not active");
        require(!submittedIdeas[periodId][ideaId], "Duplicate idea ID");

        submittedIdeas[periodId][ideaId] = true;

        // Track participant if first submission
        uint256 currentScore = userPeriodScores[periodId][user];
        if (currentScore == 0) {
            periodParticipants[periodId][period.participantCount] = user;
            period.participantCount++;
        }

        userPeriodScores[periodId][user] = currentScore + score;
        period.totalScore += score;
        period.submissionCount++;

        emit ScoreSubmitted(user, periodId, ideaId, score);
    }

    /// @notice Batch submit scores (gas efficient for multiple ideas).
    function submitScoresBatch(
        uint32 periodId,
        address[] calldata users,
        uint64[] calldata ideaIds,
        uint32[] calldata scores
    ) external {
        require(users.length == ideaIds.length && ideaIds.length == scores.length, "Array mismatch");
        for (uint256 i = 0; i < users.length; i++) {
            submitScore(periodId, users[i], ideaIds[i], scores[i]);
        }
    }

    // =========================================================================
    // REWARD CLAIMING
    // =========================================================================

    /// @notice Calculate a user's reward for a completed period (read-only preview).
    function calculateReward(uint32 periodId, address user) public view returns (uint256) {
        Period storage period = periods[periodId];
        require(period.status == UpsideXaTypes.PeriodStatus.Completed, "Period not completed");

        uint256 userScore = userPeriodScores[periodId][user];
        if (userScore == 0) return 0;

        // reward = (userScore × allocation) / totalScore
        return (userScore * period.allocation) / period.totalScore;
    }

    /// @notice Claim reward tokens for a completed period.
    ///         Calls the token contract's mintWithLock to issue locked tokens.
    function claimReward(uint32 periodId) external whenNotPaused returns (uint256) {
        require(!claims[periodId][msg.sender], "Already claimed");

        uint256 reward = calculateReward(periodId, msg.sender);
        require(reward > 0, "Nothing to claim");

        claims[periodId][msg.sender] = true;

        // Mint tokens with lock directly to user
        if (tokenContract != address(0)) {
            UpsideToken(tokenContract).mintWithLock(msg.sender, reward);
        }

        emit RewardClaimed(msg.sender, periodId, reward);
        return reward;
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    function getPeriod(uint32 periodId) external view returns (Period memory) {
        return periods[periodId];
    }

    function getUserScore(uint32 periodId, address user) external view returns (uint256) {
        return userPeriodScores[periodId][user];
    }

    function hasClaimed(uint32 periodId, address user) external view returns (bool) {
        return claims[periodId][user];
    }

    function periodCount() external view returns (uint32) {
        return nextPeriodId - 1;
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setOracle(address _oracle) external {
        require(msg.sender == admin || msg.sender == governanceContract, "Not authorized");
        oracle = _oracle;
    }
    function setTokenContract(address _token) external onlyAdmin { tokenContract = _token; }
    function setGovernanceContract(address _gov) external onlyAdmin { governanceContract = _gov; }
   function setPaused(bool _paused) external {
        require(msg.sender == admin || msg.sender == governanceContract, "Not admin or governance");
        paused = _paused;
    }
    function transferAdmin(address newAdmin) external onlyAdmin { admin = newAdmin; }
}
