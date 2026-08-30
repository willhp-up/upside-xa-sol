// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideXaTypes.sol";

/// @title Upside Xa Token (UPC)
/// @notice ERC-20 compatible token for the Upside Xa reward system on Polkadot Hub.
///
/// Key features:
/// 1. Fixed supply cap: 5,000,000 UPC max
/// 2. Time locks: 90-day lock on minted tokens
/// 3. Role-based minting: only issuance contract can mint
/// 4. Role-based burning: only burn mechanism can burn
/// 5. Dual balance: total vs available (unlocked)

contract UpsideToken {
    using UpsideXaTypes for *;

    // =========================================================================
    // STATE
    // =========================================================================

    string public constant name = "Upside Xa";
    string public constant symbol = "UPC";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public totalMinted;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => UpsideXaTypes.TimeLock[]) private _locks;

    address public admin;
    address public issuanceContract;
    address public burnContract;
    address public governanceContract;
    bool    public paused;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event TokensMinted(address indexed to, uint256 value, uint256 unlocksAt);
    event TokensBurned(address indexed from, uint256 value);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }
    modifier onlyAdminOrGovernance() {
        require(msg.sender == admin || msg.sender == governanceContract, "Not admin or governance");
        _;
    }
    modifier onlyIssuance() { require(msg.sender == issuanceContract, "Not issuance contract"); _; }
    modifier onlyBurnContract() { require(msg.sender == burnContract, "Not burn contract"); _; }
    modifier onlyAdminOrBurnContract() { require(msg.sender == admin || msg.sender == burnContract, "Not admin or burn contract"); _; }
    modifier whenNotPaused() { require(!paused, "Contract paused"); _; }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    // ERC-20 QUERIES
    // =========================================================================

    function maxSupply() external pure returns (uint256) { return UpsideXaTypes.TOTAL_SUPPLY; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) external view returns (uint256) { return _allowances[owner][spender]; }

    function availableBalanceOf(address account) public view returns (uint256) {
        uint256 total = _balances[account];
        uint256 locked = lockedBalanceOf(account);
        return total > locked ? total - locked : 0;
    }

    function lockedBalanceOf(address account) public view returns (uint256) {
        uint256 locked = 0;
        UpsideXaTypes.TimeLock[] storage userLocks = _locks[account];
        for (uint256 i = 0; i < userLocks.length; i++) {
            if (block.timestamp < userLocks[i].unlocksAt) {
                locked += userLocks[i].amount;
            }
        }
        return locked;
    }

    function getLocks(address account) external view returns (UpsideXaTypes.TimeLock[] memory) {
        UpsideXaTypes.TimeLock[] storage userLocks = _locks[account];
        uint256 count = 0;
        for (uint256 i = 0; i < userLocks.length; i++) {
            if (block.timestamp < userLocks[i].unlocksAt) count++;
        }
        UpsideXaTypes.TimeLock[] memory active = new UpsideXaTypes.TimeLock[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < userLocks.length; i++) {
            if (block.timestamp < userLocks[i].unlocksAt) {
                active[idx] = userLocks[i];
                idx++;
            }
        }
        return active;
    }

    // =========================================================================
    // ERC-20 STATE-CHANGING
    // =========================================================================

    function transfer(address to, uint256 value) external whenNotPaused returns (bool) {
        _transferAvailable(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external whenNotPaused returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external whenNotPaused returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= value, "Insufficient allowance");
        _transferAvailable(from, to, value);
        _allowances[from][msg.sender] = currentAllowance - value;
        return true;
    }

    // =========================================================================
    // MINTING
    // =========================================================================

    /// @notice Mint tokens with 90-day lock (issuance contract only).
    function mintWithLock(address to, uint256 value) external whenNotPaused onlyIssuance {
        _mint(to, value);
        uint256 unlocksAt = block.timestamp + UpsideXaTypes.LOCK_PERIOD;
        _locks[to].push(UpsideXaTypes.TimeLock({ amount: value, mintedAt: block.timestamp, unlocksAt: unlocksAt }));
        emit TokensMinted(to, value, unlocksAt);
    }

    /// @notice Mint to reserve (no lock, admin only).
    function mintReserve(address to, uint256 value) external onlyAdmin {
        _mint(to, value);
    }

    // =========================================================================
    // BURNING
    // =========================================================================

    /// @notice Burn from a user's available balance (burn contract only).
    function burnFrom(address from, uint256 value) external whenNotPaused onlyBurnContract {
        require(availableBalanceOf(from) >= value, "Insufficient available balance");
        _balances[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
        emit TokensBurned(from, value);
    }

    /// @notice Admin burn for decay mechanism — burns from total balance (including locked).
    ///         Only used when decay has fully suspended a user's account.
    function adminBurn(address from, uint256 value) external onlyAdminOrBurnContract {
        require(_balances[from] >= value, "Insufficient balance");
        _balances[from] -= value;
        totalSupply -= value;
        emit Transfer(from, address(0), value);
        emit TokensBurned(from, value);
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setIssuanceContract(address _contract) external onlyAdminOrGovernance { issuanceContract = _contract; }
    function setBurnContract(address _contract) external onlyAdminOrGovernance { burnContract = _contract; }
    function setGovernanceContract(address _contract) external onlyAdmin { governanceContract = _contract; }
    function transferAdmin(address newAdmin) external onlyAdmin { admin = newAdmin; }
    function setPaused(bool _paused) external onlyAdminOrGovernance { paused = _paused; }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    function _mint(address to, uint256 value) internal {
        uint256 newTotalMinted = totalMinted + value;
        require(newTotalMinted <= UpsideXaTypes.TOTAL_SUPPLY, "Supply cap exceeded");
        _balances[to] += value;
        totalSupply += value;
        totalMinted = newTotalMinted;
        emit Transfer(address(0), to, value);
    }

    function _transferAvailable(address from, address to, uint256 value) internal {
        require(availableBalanceOf(from) >= value, "Insufficient available balance");
        _balances[from] -= value;
        _balances[to] += value;
        emit Transfer(from, to, value);
    }
}
