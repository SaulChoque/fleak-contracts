// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title FleakEscrow - Minimal custodial escrow for Fleak flakes.
/// @notice Tracks deposits per flake and lets a trusted oracle resolve outcomes.
contract FleakEscrow {
    enum State {
        None,
        Active,
        Resolved,
        Refunding
    }

    struct Flake {
        address creator;
        State state;
        uint40 createdAt;
        uint40 resolvedAt;
        uint40 cancelledAt;
        address winner;
        uint16 feeBps;
        address feeRecipient;
        uint256 totalStake;
        uint256 lifetimeStake;
        uint256 distributedPayout;
        uint256 distributedFee;
        uint256 refundedAmount;
    }

    struct FlakeView {
        address creator;
        State state;
        address winner;
        uint16 feeBps;
        address feeRecipient;
        uint256 lifetimeStake;
        uint256 currentStake;
        uint256 distributedPayout;
        uint256 distributedFee;
        uint256 refundedAmount;
        uint40 createdAt;
        uint40 resolvedAt;
        uint40 cancelledAt;
    }

    event FlakeCreated(uint256 indexed flakeId, address indexed creator, uint16 feeBps, address feeRecipient);
    event StakeAdded(
        uint256 indexed flakeId, address indexed sender, address indexed participant, uint256 amount, uint256 totalStake
    );
    event FlakeResolved(
        uint256 indexed flakeId, address indexed winner, uint256 payout, uint256 fee, uint256 resolvedAt
    );
    event FlakeRefundOpened(uint256 indexed flakeId, uint256 openedAt);
    event RefundClaimed(uint256 indexed flakeId, address indexed participant, uint256 amount);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FeeRecipientUpdated(uint256 indexed flakeId, address indexed newFeeRecipient);

    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%

    mapping(uint256 => Flake) private _flakes;
    mapping(uint256 => address[]) private _participants;
    mapping(uint256 => mapping(address => bool)) private _isParticipant;
    mapping(uint256 => mapping(address => uint256)) private _stakes;
    mapping(uint256 => mapping(address => bool)) private _refundClaimed;

    address public oracle;
    address private _owner;

    modifier onlyOwner() {
        require(msg.sender == _owner, "NotOwner");
        _;
    }

    modifier onlyOracle() {
        require(msg.sender == oracle, "NotOracle");
        _;
    }

    modifier nonReentrant() {
        require(_guard == _NOT_ENTERED, "ReentrantCall");
        _guard = _ENTERED;
        _;
        _guard = _NOT_ENTERED;
    }

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _guard = _NOT_ENTERED;

    constructor(address initialOracle) {
        require(initialOracle != address(0), "OracleZero");
        _owner = msg.sender;
        oracle = initialOracle;
        emit OwnershipTransferred(address(0), msg.sender);
        emit OracleUpdated(address(0), initialOracle);
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "OwnerZero");
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function setOracle(address newOracle) external onlyOwner {
        require(newOracle != address(0), "OracleZero");
        emit OracleUpdated(oracle, newOracle);
        oracle = newOracle;
    }

    function updateFlakeFeeRecipient(uint256 flakeId, address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), "FeeRecipZero");
        Flake storage flake = _flakes[flakeId];
        require(flake.state != State.None, "FlakeMissing");
        flake.feeRecipient = newFeeRecipient;
        emit FeeRecipientUpdated(flakeId, newFeeRecipient);
    }

    function createFlake(
        uint256 flakeId,
        address[] calldata expectedParticipants,
        uint16 feeBps,
        address feeRecipient,
        address initialStakeRecipient
    ) external payable nonReentrant {
        require(_flakes[flakeId].state == State.None, "FlakeExists");
        require(feeBps <= MAX_FEE_BPS, "FeeTooHigh");

        address resolvedFeeRecipient = feeRecipient == address(0) ? _owner : feeRecipient;
        Flake storage flake = _flakes[flakeId];
        flake.creator = msg.sender;
        flake.state = State.Active;
        flake.createdAt = uint40(block.timestamp);
        flake.feeBps = feeBps;
        flake.feeRecipient = resolvedFeeRecipient;

        for (uint256 i = 0; i < expectedParticipants.length; i++) {
            address participant = expectedParticipants[i];
            require(participant != address(0), "ParticipantZero");
            require(!_isParticipant[flakeId][participant], "DuplicateParticipant");
            _isParticipant[flakeId][participant] = true;
            _participants[flakeId].push(participant);
        }

        if (msg.value > 0) {
            address beneficiary = initialStakeRecipient == address(0) ? msg.sender : initialStakeRecipient;
            require(beneficiary != address(0), "StakeBenefZero");
            _increaseStake(flakeId, msg.sender, beneficiary, msg.value);
        }

        emit FlakeCreated(flakeId, msg.sender, feeBps, resolvedFeeRecipient);
    }

    function stake(uint256 flakeId, address beneficiary) external payable nonReentrant returns (uint256 newStake) {
        Flake storage flake = _flakes[flakeId];
        require(flake.state == State.Active, "NotActive");
        require(msg.value > 0, "NoValue");

        address participant = beneficiary == address(0) ? msg.sender : beneficiary;
        require(participant != address(0), "StakeBenefZero");
        return _increaseStake(flakeId, msg.sender, participant, msg.value);
    }

    function resolveFlake(uint256 flakeId, address winner) external onlyOracle nonReentrant {
        Flake storage flake = _flakes[flakeId];
        require(flake.state == State.Active, "NotActive");
        require(winner != address(0), "WinnerZero");

        uint256 total = flake.totalStake;
        flake.state = State.Resolved;
        flake.winner = winner;
        flake.resolvedAt = uint40(block.timestamp);

        uint256 feeAmount = (total * flake.feeBps) / BPS_DENOMINATOR;
        uint256 payout = total - feeAmount;
        flake.distributedFee = feeAmount;
        flake.distributedPayout = payout;
        flake.totalStake = 0;

        if (payout > 0) {
            _sendValue(winner, payout);
        }
        if (feeAmount > 0) {
            _sendValue(flake.feeRecipient, feeAmount);
        }

        emit FlakeResolved(flakeId, winner, payout, feeAmount, block.timestamp);
    }

    function openRefunds(uint256 flakeId) external onlyOracle nonReentrant {
        Flake storage flake = _flakes[flakeId];
        require(flake.state == State.Active, "NotActive");
        flake.state = State.Refunding;
        flake.cancelledAt = uint40(block.timestamp);
        emit FlakeRefundOpened(flakeId, block.timestamp);
    }

    function withdrawRefund(uint256 flakeId) external nonReentrant returns (uint256 amount) {
        Flake storage flake = _flakes[flakeId];
        require(flake.state == State.Refunding, "NotRefunding");

        uint256 stakeAmount = _stakes[flakeId][msg.sender];
        require(stakeAmount > 0, "NoStake");
        require(!_refundClaimed[flakeId][msg.sender], "Refunded");

        _refundClaimed[flakeId][msg.sender] = true;
        flake.totalStake -= stakeAmount;
        flake.refundedAmount += stakeAmount;
        _sendValue(msg.sender, stakeAmount);

        emit RefundClaimed(flakeId, msg.sender, stakeAmount);
        return stakeAmount;
    }

    function getFlake(uint256 flakeId) external view returns (FlakeView memory viewData) {
        Flake storage flake = _flakes[flakeId];
        require(flake.state != State.None, "FlakeMissing");
        viewData = FlakeView({
            creator: flake.creator,
            state: flake.state,
            winner: flake.winner,
            feeBps: flake.feeBps,
            feeRecipient: flake.feeRecipient,
            lifetimeStake: flake.lifetimeStake,
            currentStake: flake.totalStake,
            distributedPayout: flake.distributedPayout,
            distributedFee: flake.distributedFee,
            refundedAmount: flake.refundedAmount,
            createdAt: flake.createdAt,
            resolvedAt: flake.resolvedAt,
            cancelledAt: flake.cancelledAt
        });
    }

    function getParticipants(uint256 flakeId)
        external
        view
        returns (address[] memory participants, uint256[] memory stakes, bool[] memory refunds)
    {
        Flake storage flake = _flakes[flakeId];
        require(flake.state != State.None, "FlakeMissing");

        address[] storage stored = _participants[flakeId];
        uint256 length = stored.length;
        participants = new address[](length);
        stakes = new uint256[](length);
        refunds = new bool[](length);

        for (uint256 i = 0; i < length; i++) {
            address participant = stored[i];
            participants[i] = participant;
            stakes[i] = _stakes[flakeId][participant];
            refunds[i] = _refundClaimed[flakeId][participant];
        }
    }

    function stakeOf(uint256 flakeId, address participant) external view returns (uint256) {
        return _stakes[flakeId][participant];
    }

    function isParticipant(uint256 flakeId, address participant) external view returns (bool) {
        return _isParticipant[flakeId][participant];
    }

    function isRefundClaimed(uint256 flakeId, address participant) external view returns (bool) {
        return _refundClaimed[flakeId][participant];
    }

    function _increaseStake(uint256 flakeId, address sender, address participant, uint256 amount)
        private
        returns (uint256 newStake)
    {
        if (!_isParticipant[flakeId][participant]) {
            _isParticipant[flakeId][participant] = true;
            _participants[flakeId].push(participant);
        }

        uint256 updatedStake = _stakes[flakeId][participant] + amount;
        _stakes[flakeId][participant] = updatedStake;

        Flake storage flake = _flakes[flakeId];
        flake.totalStake += amount;
        flake.lifetimeStake += amount;

        emit StakeAdded(flakeId, sender, participant, amount, flake.totalStake);
        return updatedStake;
    }

    function _sendValue(address receiver, uint256 amount) private {
        (bool success,) = receiver.call{value: amount}("");
        require(success, "TransferFailed");
    }

    receive() external payable {
        revert("DirectTransferUnsupported");
    }

    fallback() external payable {
        revert("DirectTransferUnsupported");
    }
}
