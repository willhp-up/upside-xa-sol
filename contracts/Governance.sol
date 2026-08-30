// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./UpsideToken.sol";
import "./RewardIssuance.sol";
import "./BurnMechanism.sol";
import "./IdeaStaking.sol";

/// @title Upside Xa Governance
/// @notice System-wide control centre for the Upside Xa ecosystem.
///
/// Responsibilities:
/// - Emergency pause across all contracts
/// - Oracle address management (propagated to issuance + staking)
/// - Contract registry (linking all 6 contracts together)
/// - System parameter updates
/// - Dynamic pool formula parameters

contract Governance {

    // =========================================================================
    // STATE
    // =========================================================================

    address public tokenContract;
    address public issuanceContract;
    address payable public burnContract;
    address public treasuryContract;
    address public ideaStakingContract;

    address public admin;
    address public oracle;
    bool    public systemPaused;

    // Dynamic pool formula: poolAllocation = baseAllocation * performanceMultiplier / 10000
    uint256 public baseAllocation;
    uint256 public performanceMultiplierBps = 10_000; // 100%

    uint32 public parameterChangeCount;
    mapping(uint32 => ParameterChange) public parameterChanges;

    struct ParameterChange {
        string  paramName;
        uint256 oldValue;
        uint256 newValue;
        uint256 changedAt;
        address changedBy;
    }

    // =========================================================================
    // EVENTS
    // =========================================================================

    event SystemPaused(address by);
    event SystemUnpaused(address by);
    event OracleUpdated(address oldOracle, address newOracle);
    event ContractRegistered(string name, address contractAddress);
    event ParameterUpdated(string name, uint256 oldValue, uint256 newValue);
    event EmergencyAction(string action, address by);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlyAdmin() { require(msg.sender == admin, "Not admin"); _; }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    constructor() {
        admin = msg.sender;
    }

    // =========================================================================
    // CONTRACT REGISTRY
    // =========================================================================

    /// @notice Register all ecosystem contract addresses.
    function registerContracts(
        address _token,
        address _issuance,
        address _burn,
        address _treasury,
        address _ideaStaking
    ) external onlyAdmin {
        tokenContract = _token;
        issuanceContract = _issuance;
        burnContract = payable(_burn);
        treasuryContract = _treasury;
        ideaStakingContract = _ideaStaking;

        emit ContractRegistered("token", _token);
        emit ContractRegistered("issuance", _issuance);
        emit ContractRegistered("burn", _burn);
        emit ContractRegistered("treasury", _treasury);
        emit ContractRegistered("ideaStaking", _ideaStaking);
    }

    // =========================================================================
    // EMERGENCY PAUSE
    // =========================================================================

    function emergencyPause() external onlyAdmin {
        systemPaused = true;

        if (tokenContract != address(0)) {
            UpsideToken(tokenContract).setPaused(true);
        }
        if (issuanceContract != address(0)) {
            RewardIssuance(issuanceContract).setPaused(true);
        }
        if (burnContract != address(0)) {
            BurnMechanism(payable(burnContract)).setPaused(true);
        }
        if (ideaStakingContract != address(0)) {
            IdeaStaking(ideaStakingContract).setPaused(true);
        }

        emit SystemPaused(msg.sender);
        emit EmergencyAction("PAUSE_ALL", msg.sender);
    }

    function emergencyUnpause() external onlyAdmin {
        systemPaused = false;

        if (tokenContract != address(0)) {
            UpsideToken(tokenContract).setPaused(false);
        }
        if (issuanceContract != address(0)) {
            RewardIssuance(issuanceContract).setPaused(false);
        }
        if (burnContract != address(0)) {
            BurnMechanism(payable(burnContract)).setPaused(false);
        }
        if (ideaStakingContract != address(0)) {
            IdeaStaking(ideaStakingContract).setPaused(false);
        }

        emit SystemUnpaused(msg.sender);
        emit EmergencyAction("UNPAUSE_ALL", msg.sender);
    }

    // =========================================================================
    // ORACLE MANAGEMENT
    // =========================================================================

    /// @notice Update oracle address across issuance and staking contracts.
    function setOracle(address newOracle) external onlyAdmin {
        require(newOracle != address(0), "Zero address");

        address oldOracle = oracle;
        oracle = newOracle;

        if (issuanceContract != address(0)) {
            RewardIssuance(issuanceContract).setOracle(newOracle);
        }
        if (ideaStakingContract != address(0)) {
            IdeaStaking(ideaStakingContract).setOracle(newOracle);
        }

        emit OracleUpdated(oldOracle, newOracle);
    }

    // =========================================================================
    // SYSTEM PARAMETERS
    // =========================================================================

    function setBaseAllocation(uint256 _baseAllocation) external onlyAdmin {
        _recordChange("baseAllocation", baseAllocation, _baseAllocation);
        baseAllocation = _baseAllocation;
    }

    function setPerformanceMultiplier(uint256 _multiplierBps) external onlyAdmin {
        require(_multiplierBps <= 20_000, "Max 200%");
        _recordChange("performanceMultiplierBps", performanceMultiplierBps, _multiplierBps);
        performanceMultiplierBps = _multiplierBps;
    }

    function calculateDynamicAllocation() external view returns (uint256) {
        return (baseAllocation * performanceMultiplierBps) / 10_000;
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Zero address");
        admin = newAdmin;
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    function getParameterChange(uint32 changeId) external view returns (ParameterChange memory) {
        return parameterChanges[changeId];
    }

    function getContractAddresses() external view returns (
        address token,
        address issuance,
        address burn,
        address treasury,
        address ideaStaking
    ) {
        return (tokenContract, issuanceContract, burnContract, treasuryContract, ideaStakingContract);
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    function _recordChange(string memory paramName, uint256 oldVal, uint256 newVal) internal {
        parameterChanges[parameterChangeCount] = ParameterChange({
            paramName: paramName,
            oldValue: oldVal,
            newValue: newVal,
            changedAt: block.timestamp,
            changedBy: msg.sender
        });
        parameterChangeCount++;
        emit ParameterUpdated(paramName, oldVal, newVal);
    }
}
