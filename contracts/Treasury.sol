// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Upside Xa Treasury
/// @notice Multi-signature treasury for managing reserve funds and burn payouts.
///
/// Requires 2-of-3 signers to approve any withdrawal.
/// Tracks fund allocations by category and supports native DOT transfers.
///
/// Flow: Signer creates proposal → 2nd signer approves → funds released.

contract Treasury {

    // =========================================================================
    // TYPES
    // =========================================================================

    enum ProposalStatus { Pending, Approved, Executed, Cancelled }

    struct Proposal {
        uint32 proposalId;
        address recipient;
        uint256 amount;
        string  description;
        address proposedBy;
        uint8   approvalCount;
        ProposalStatus status;
        uint256 createdAt;
    }

    // =========================================================================
    // STATE
    // =========================================================================

    address[3] public signers;
    mapping(address => bool) public isSigner;

    uint32 public nextProposalId = 1;
    mapping(uint32 => Proposal) public proposals;
    mapping(uint32 => mapping(address => bool)) public hasApproved;

    // Fund tracking
    uint256 public totalAllocated;
    uint256 public totalWithdrawn;
    mapping(string => uint256) public categoryAllocations;

    address public governanceContract;

    // =========================================================================
    // EVENTS
    // =========================================================================

    event FundsReceived(address indexed from, uint256 amount);
    event ProposalCreated(uint32 proposalId, address recipient, uint256 amount, string description);
    event ProposalApproved(uint32 proposalId, address approvedBy, uint8 totalApprovals);
    event ProposalExecuted(uint32 proposalId, address recipient, uint256 amount);
    event ProposalCancelled(uint32 proposalId);
    event AllocationUpdated(string category, uint256 amount);

    // =========================================================================
    // MODIFIERS
    // =========================================================================

    modifier onlySigner() {
        require(isSigner[msg.sender], "Not a signer");
        _;
    }

    modifier onlySignerOrGovernance() {
        require(isSigner[msg.sender] || msg.sender == governanceContract, "Not authorized");
        _;
    }

    // =========================================================================
    // CONSTRUCTOR
    // =========================================================================

    /// @notice Deploy with 3 multi-sig signers. Requires 2-of-3 for withdrawals.
    constructor(address signer1, address signer2, address signer3) {
        require(
            signer1 != signer2 && signer2 != signer3 && signer1 != signer3,
            "Signers must be unique"
        );
        require(
            signer1 != address(0) && signer2 != address(0) && signer3 != address(0),
            "Zero address"
        );

        signers[0] = signer1;
        signers[1] = signer2;
        signers[2] = signer3;

        isSigner[signer1] = true;
        isSigner[signer2] = true;
        isSigner[signer3] = true;
    }

    /// @notice Accept native DOT deposits.
    receive() external payable {
        emit FundsReceived(msg.sender, msg.value);
    }

    // =========================================================================
    // PROPOSALS
    // =========================================================================

    /// @notice Create a withdrawal proposal.
    function createProposal(
        address recipient,
        uint256 amount,
        string calldata description
    ) external onlySigner returns (uint32) {
        require(recipient != address(0), "Zero address");
        require(amount > 0, "Amount must be > 0");
        require(amount <= address(this).balance, "Insufficient treasury balance");

        uint32 proposalId = nextProposalId++;

        proposals[proposalId] = Proposal({
            proposalId: proposalId,
            recipient: recipient,
            amount: amount,
            description: description,
            proposedBy: msg.sender,
            approvalCount: 1,  // Creator auto-approves
            status: ProposalStatus.Pending,
            createdAt: block.timestamp
        });

        hasApproved[proposalId][msg.sender] = true;

        emit ProposalCreated(proposalId, recipient, amount, description);
        return proposalId;
    }

    /// @notice Approve a pending proposal. Executes automatically at 2 approvals.
    function approveProposal(uint32 proposalId) external onlySigner {
        Proposal storage prop = proposals[proposalId];
        require(prop.proposalId != 0, "Proposal not found");
        require(prop.status == ProposalStatus.Pending, "Not pending");
        require(!hasApproved[proposalId][msg.sender], "Already approved");

        hasApproved[proposalId][msg.sender] = true;
        prop.approvalCount++;

        emit ProposalApproved(proposalId, msg.sender, prop.approvalCount);

        // 2-of-3 threshold met → execute
        if (prop.approvalCount >= 2) {
            _executeProposal(proposalId);
        }
    }

    /// @notice Cancel a pending proposal (only the creator can cancel).
    function cancelProposal(uint32 proposalId) external {
        Proposal storage prop = proposals[proposalId];
        require(prop.proposalId != 0, "Proposal not found");
        require(prop.status == ProposalStatus.Pending, "Not pending");
        require(msg.sender == prop.proposedBy, "Not proposer");

        prop.status = ProposalStatus.Cancelled;
        emit ProposalCancelled(proposalId);
    }

    // =========================================================================
    // FUND MANAGEMENT
    // =========================================================================

    /// @notice Set category allocation tracking (informational, not enforced).
    function setAllocation(string calldata category, uint256 amount) external onlySignerOrGovernance {
        categoryAllocations[category] = amount;
        emit AllocationUpdated(category, amount);
    }

    // =========================================================================
    // QUERIES
    // =========================================================================

    function getProposal(uint32 proposalId) external view returns (Proposal memory) {
        return proposals[proposalId];
    }

    function treasuryBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function proposalCount() external view returns (uint32) {
        return nextProposalId - 1;
    }

    // =========================================================================
    // ADMIN
    // =========================================================================

    function setGovernanceContract(address _gov) external onlySigner {
        governanceContract = _gov;
    }

    /// @notice Replace a signer (requires 2-of-3 via proposal mechanism, or governance).
    function replaceSigner(address oldSigner, address newSigner) external onlySignerOrGovernance {
        require(isSigner[oldSigner], "Not current signer");
        require(!isSigner[newSigner], "Already a signer");
        require(newSigner != address(0), "Zero address");

        isSigner[oldSigner] = false;
        isSigner[newSigner] = true;

        for (uint8 i = 0; i < 3; i++) {
            if (signers[i] == oldSigner) {
                signers[i] = newSigner;
                break;
            }
        }
    }

    // =========================================================================
    // INTERNAL
    // =========================================================================

    function _executeProposal(uint32 proposalId) internal {
        Proposal storage prop = proposals[proposalId];
        require(address(this).balance >= prop.amount, "Insufficient balance");

        prop.status = ProposalStatus.Executed;
        totalWithdrawn += prop.amount;

        (bool success, ) = prop.recipient.call{value: prop.amount}("");
        require(success, "Transfer failed");

        emit ProposalExecuted(proposalId, prop.recipient, prop.amount);
    }
}
