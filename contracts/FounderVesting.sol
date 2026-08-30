// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideToken.sol";

/// @title Upside Xa Founder Vesting
/// @notice Manages founder token allocations with a 180-day cliff
///         followed by 25% release every 6 months (fully vested at ~2.5 years).
///
/// Timeline from grant date:
///   Day 0         — Tokens granted (locked)
///   Day 180       — Cliff ends, 0% available (vesting begins)
///   Day 180 + 6mo — 25% available
///   Day 180 + 12mo — 50% available
///   Day 180 + 18mo — 75% available
///   Day 180 + 24mo — 100% available
///
/// Usage:
///   1. Admin calls addFounder(address, amount) to register each founder
///   2. Admin mints reserve tokens to this contract via token.mintReserve(thisContract, totalAmount)
///   3. Founders call claim() to withdraw vested tokens on schedule

contract FounderVesting {

    // =========================================================================
    // STRUCTS
    // =========================================================================

    struct Grant {
        uint256 totalAmount;     // Total tokens allocated to this founder
        uint256 claimed;         // Tokens already claimed
        uint256 grantTimestamp;  // When the grant was created
        bool exists;             // Whether this grant exists
    }

    // =========================================================================
    // CONSTANTS
    // =========================================================================

    uint256 public constant CLIFF_DURATION = 180 days;
    uint256 public constant VESTING_PERIOD = 182 days;  // ~6 months
    uint256 public constant TOTAL_PERIODS = 4;          // 4 x 25% = 100%
    uint256 public constant RELEASE_PER_PERIOD_BPS = 2500; // 25% in basis points

    // =========================================================================
    // STATE
    // =========================================================================

    UpsideToken public tokenContract;
    address public admin;
    
    mapping(address => Grant) public grants;
    address[] public founders;
    uint256 public totalAllocated;
    uint256 public totalClaimed;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event FounderAdded(address indexed founder, uint256 amount, uint256 grantTimestamp);
    event FounderRemoved(address indexed founder, uint256 unvestedAmount);
    event TokensClaimed(address indexed founder, uint256 amount, uint256 totalClaimed);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor(address _tokenContract) {
        require(_tokenContract != address(0), "Invalid token address");
        tokenContract = UpsideToken(_tokenContract);
        admin = msg.sender;
    }

    // =========================================================================
    // ADMIN FUNCTIONS
    // =========================================================================

    /// @notice Register a founder with a token allocation
    /// @param founder The founder's wallet address
    /// @param amount The total UPC tokens to vest
    function addFounder(address founder, uint256 amount) external onlyAdmin {
        require(founder != address(0), "Invalid address");
        require(amount > 0, "Amount must be > 0");
        require(!grants[founder].exists, "Founder already registered");

        grants[founder] = Grant({
            totalAmount: amount,
            claimed: 0,
            grantTimestamp: block.timestamp,
            exists: true
        });

        founders.push(founder);
        totalAllocated += amount;

        emit FounderAdded(founder, amount, block.timestamp);
    }

    /// @notice Revoke an unvested grant (only recovers unvested portion)
    /// @param founder The founder's address to revoke
    function revokeGrant(address founder) external onlyAdmin {
        require(grants[founder].exists, "No grant found");

        uint256 vested = _vestedAmount(founder);
        uint256 unvested = grants[founder].totalAmount - vested;
        
        // Reduce allocation by unvested amount only
        totalAllocated -= unvested;
        
        // Update grant to reflect only the vested portion
        grants[founder].totalAmount = vested;

        emit FounderRemoved(founder, unvested);
    }

    /// @notice Transfer admin rights
    /// @param newAdmin The new admin address
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid address");
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    // =========================================================================
    // FOUNDER FUNCTIONS
    // =========================================================================

    /// @notice Claim available vested tokens
    function claim() external {
        require(grants[msg.sender].exists, "No grant found");

        uint256 available = claimable(msg.sender);
        require(available > 0, "Nothing to claim");

        grants[msg.sender].claimed += available;
        totalClaimed += available;

        // Transfer tokens from this contract to the founder
        require(
            tokenContract.transfer(msg.sender, available),
            "Transfer failed"
        );

        emit TokensClaimed(msg.sender, available, grants[msg.sender].claimed);
    }

    // =========================================================================
    // VIEW FUNCTIONS
    // =========================================================================

    /// @notice Calculate how many tokens a founder can claim right now
    /// @param founder The founder's address
    /// @return The amount of tokens available to claim
    function claimable(address founder) public view returns (uint256) {
        if (!grants[founder].exists) return 0;
        uint256 vested = _vestedAmount(founder);
        return vested - grants[founder].claimed;
    }

    /// @notice Calculate total vested amount for a founder (claimed + unclaimed)
    /// @param founder The founder's address
    /// @return The total vested amount
    function vestedAmount(address founder) external view returns (uint256) {
        return _vestedAmount(founder);
    }

    /// @notice Get the next vesting unlock date for a founder
    /// @param founder The founder's address
    /// @return timestamp The next unlock timestamp (0 if fully vested)
    function nextUnlockDate(address founder) external view returns (uint256 timestamp) {
        if (!grants[founder].exists) return 0;
        
        Grant memory g = grants[founder];
        uint256 cliffEnd = g.grantTimestamp + CLIFF_DURATION;
        
        if (block.timestamp < cliffEnd) {
            // Still in cliff — next unlock is end of cliff + first period
            return cliffEnd + VESTING_PERIOD;
        }
        
        uint256 timeSinceCliff = block.timestamp - cliffEnd;
        uint256 periodsElapsed = timeSinceCliff / VESTING_PERIOD;
        
        if (periodsElapsed >= TOTAL_PERIODS) {
            return 0; // Fully vested
        }
        
        return cliffEnd + ((periodsElapsed + 1) * VESTING_PERIOD);
    }

    /// @notice Get details about a founder's grant
    /// @param founder The founder's address
    /// @return total Total allocated tokens
    /// @return claimed Already claimed tokens
    /// @return available Currently claimable tokens
    /// @return vested Total vested (claimed + claimable)
    /// @return locked Not yet vested tokens
    function getGrantDetails(address founder) external view returns (
        uint256 total,
        uint256 claimed,
        uint256 available,
        uint256 vested,
        uint256 locked
    ) {
        Grant memory g = grants[founder];
        vested = _vestedAmount(founder);
        return (
            g.totalAmount,
            g.claimed,
            vested - g.claimed,
            vested,
            g.totalAmount - vested
        );
    }

    /// @notice Get the number of registered founders
    function founderCount() external view returns (uint256) {
        return founders.length;
    }

    /// @notice Get the token balance held by this contract
    function contractBalance() external view returns (uint256) {
        return tokenContract.balanceOf(address(this));
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    /// @dev Calculate total vested amount based on elapsed time
    function _vestedAmount(address founder) internal view returns (uint256) {
        Grant memory g = grants[founder];
        if (!g.exists) return 0;

        uint256 cliffEnd = g.grantTimestamp + CLIFF_DURATION;

        // Before cliff ends — nothing vested
        if (block.timestamp < cliffEnd) {
            return 0;
        }

        uint256 timeSinceCliff = block.timestamp - cliffEnd;
        uint256 periodsElapsed = timeSinceCliff / VESTING_PERIOD;

        // Cap at total periods
        if (periodsElapsed >= TOTAL_PERIODS) {
            return g.totalAmount;
        }

        // Each period releases 25%
        return (g.totalAmount * periodsElapsed * RELEASE_PER_PERIOD_BPS) / 10000;
    }
}
