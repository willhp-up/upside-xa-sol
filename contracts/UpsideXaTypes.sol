// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Upside Xa — Shared Types & Constants
/// @notice Common data structures and constants used across all contracts.

library UpsideXaTypes {

    // =========================================================================
    // SYSTEM CONSTANTS
    // =========================================================================

    uint256 constant TOTAL_SUPPLY = 5_000_000 * 1e18;
    uint256 constant ISSUANCE_POOL = 4_000_000 * 1e18;
    uint256 constant RESERVE_POOL = 1_000_000 * 1e18;

    uint8   constant TOKEN_DECIMALS = 18;
    uint256 constant ONE_COIN = 1e18;
    uint256 constant LOCK_PERIOD = 90 days;

    uint256 constant MAX_BURN_PERCENT_BPS = 2500;   // 25%
    uint256 constant BPS_DENOMINATOR = 10_000;
    uint256 constant SCORE_PRECISION = 1000;         // 0–1000 → 0.000–1.000

    // Issuance schedule
    uint256 constant YEAR1_H1_ALLOCATION = 600_000 * 1e18;
    uint256 constant YEAR1_H2_ALLOCATION = 1_400_000 * 1e18;
    uint256 constant YEAR2_ALLOCATION = 1_200_000 * 1e18;
    uint256 constant YEAR3_ALLOCATION = 600_000 * 1e18;
    uint256 constant YEAR4_PLUS_ALLOCATION = 200_000 * 1e18;

    // =========================================================================
    // ENUMS
    // =========================================================================

    enum PeriodStatus { Active, Finalizing, Completed }
    enum BurnEventStatus { Scheduled, Open, Processing, Completed }

    // Stake types matching the API
    enum StakeType { Self, Endorsement, Community }
    enum StakeStatus { Active, Scored, Settled, Slashed }

    // Decay statuses matching the API
    enum DecayStatus { Active, Inactive, Decaying, Suspended, Burned, ReauthPending }

    // =========================================================================
    // DATA STRUCTURES
    // =========================================================================

    struct TimeLock {
        uint256 amount;
        uint256 mintedAt;
        uint256 unlocksAt;
    }

    struct BurnEvent {
        uint32  eventId;
        uint256 distributionPool;
        uint256 totalBurned;
        uint256 valuePerCoin;
        uint256 opensAt;
        uint256 closesAt;
        BurnEventStatus status;
    }

    /// @notice On-chain stake record (mirrors API Stake model)
    struct StakeRecord {
        uint64     stakeId;        // Matches API stake _id
        address    user;
        uint64     ideaId;         // Off-chain idea reference
        StakeType  stakeType;
        uint256    amount;         // UPC staked (in wei)
        uint256    stakedAt;
        StakeStatus status;
        uint256    returnAmount;   // Set on settlement (0 if slashed)
        uint256    burnAmount;     // Set on settlement (slashed portion)
        uint256    settledAt;
    }
}
