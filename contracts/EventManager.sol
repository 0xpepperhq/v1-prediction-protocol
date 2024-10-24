// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IPepperBaseTokenV1} from "./interfaces/IPepperBaseTokenV1.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Event} from "./Event.sol";
import {Governance} from "./Governance.sol";

contract EventManager is ReentrancyGuard {
    string public constant VERSION = "0.1.1";
    address public protocolFeeRecipient;
    address[] public allEvents;

    IPepperBaseTokenV1 public protocolToken;

    // Mapping from event address to collateral amount
    mapping(address => uint256) public collateralBalances; // Key: eventAddress
    mapping(address => bool) public isCollateralLocked; // Key: eventAddress
    mapping(address => int256) public creatorsReputation; // Key: creator

    // Governance contract
    Governance public governance;

    // Mapping from creator to their events
    mapping(address => address[]) public creatorEvents;

    // Mapping to track if forfeited collateral is claimed
    mapping(address => mapping(address => bool)) public forfeitedCollateralClaims; // eventAddress => user => claimed

    // Mapping to store the amount of collateral forfeited per event
    mapping(address => uint256) public forfeitedCollateralAmounts; // eventAddress => amount

    // Mapping to track dispute resolutions
    mapping(address => bool) public disputeOutcomeChanged; // eventAddress => outcomeChanged

    event CollateralLocked(address indexed eventAddress, uint256 amount);
    event CollateralReleased(address indexed eventAddress, uint256 amount);
    event CollateralForfeited(address indexed eventAddress, uint256 amount);
    event EventCreated(address indexed eventAddress, address indexed creator, uint256 eventId);
    event EventClosed(address indexed eventAddress);
    event CollateralIncreased(address indexed eventAddress, uint256 amount);
    event CollateralClaimed(address indexed eventAddress, address indexed creator, uint256 amount);
    event DisputeResolved(address indexed eventAddress, uint256 finalOutcome);
    event ForfeitedCollateralClaimed(address indexed eventAddress, address indexed user, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == governance.owner(), "Only owner can call");
        _;
    }

    modifier onlyApprovedAdmin() {
        require(governance.approvedAdmins(msg.sender), "Only approved admin can call");
        _;
    }

    modifier onlyEventCreator(address _eventAddress) {
        require(msg.sender == Event(_eventAddress).creator(), "Only event creator can call");
        _;
    }

    constructor(address _protocolToken, address _governance, address _protocolFeeRecipient) {
        require(_protocolToken != address(0), "Invalid protocol token address");
        require(_governance != address(0), "Invalid governance address");
        require(_protocolFeeRecipient != address(0), "Invalid fee recipient address");

        protocolFeeRecipient = _protocolFeeRecipient;
        protocolToken = IPepperBaseTokenV1(_protocolToken);
        governance = Governance(_governance);
    }

    /**
     * @notice Creates a new event.
     */
    function createEvent(
        string memory _title,
        string memory _description,
        string memory _category,
        string[] memory _outcomes,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _collateralAmount
    ) external nonReentrant returns (address eventAddress, uint256 eventId) {
        require(_collateralAmount > 0, "Collateral amount must be greater than zero");
        require(_collateralAmount <= 1e24, "Collateral amount exceeds maximum limit"); // Example maximum
        require(_startTime >= block.timestamp + 2 hours, "Start time must be at least 2 hours in the future");
        require(_endTime > _startTime, "End time must be after start time");
        require(_outcomes.length >= 2 && _outcomes.length <= 10, "Invalid number of outcomes");
        require(bytes(_title).length > 0, "Title cannot be empty");
        require(bytes(_description).length > 0, "Description cannot be empty");
        require(bytes(_category).length > 0, "Category cannot be empty");
        require(creatorsReputation[msg.sender] > -30, "Creator can not create events due to low reputation");

        // Initialize creator's trust multiplier if not set
        initializeCreatorsReputation(msg.sender);

        // Deploy a new Event contract
        eventId = allEvents.length;
        Event newEvent = new Event(
            eventId,
            _title,
            _description,
            _category,
            _outcomes,
            _startTime,
            _endTime,
            msg.sender,
            _collateralAmount,
            address(this),
            address(protocolToken)
        );

        eventAddress = address(newEvent);

        // Transfer collateral from the creator to the EventManager for this event
        lockCollateral(eventAddress, msg.sender, _collateralAmount);

        allEvents.push(eventAddress);
        creatorEvents[msg.sender].push(eventAddress);

        emit EventCreated(eventAddress, msg.sender, eventId);
    }

    /**
     * @notice Returns all open events.
     */
    function getAllOpenEvents() external view returns (address[] memory) {
        uint256 openEventCount = 0;

        for (uint256 i = 0; i < allEvents.length; i++) {
            if (Event(allEvents[i]).status() == Event.EventStatus.Open) {
                openEventCount++;
            }
        }

        address[] memory openEvents = new address[](openEventCount);
        uint256 index = 0;
        for (uint256 i = 0; i < allEvents.length; i++) {
            if (Event(allEvents[i]).status() == Event.EventStatus.Open) {
                openEvents[index] = allEvents[i];
                index++;
            }
        }

        // sort by creator reputation descending
        address[] memory sortedEvents = new address[](openEventCount);
        for (uint256 i = 0; i < openEvents.length; i++) {
            sortedEvents[i] = openEvents[i];
            for (uint256 j = i + 1; j < openEvents.length; j++) {
                if (creatorsReputation[Event(openEvents[j]).creator()] >
                    creatorsReputation[Event(sortedEvents[i]).creator()]) {
                    address temp = sortedEvents[i];
                    sortedEvents[i] = openEvents[j];
                    sortedEvents[j] = temp;
                }
            }
        }

        return sortedEvents;
    }

    /**
     * @notice Returns all events created by a specific creator.
     */
    function getAllCreatorEvents(address creator) external view returns (address[] memory) {
        return creatorEvents[creator];
    }

    /**
     * @notice Returns the address of an event by its ID.
     */
    function getEvent(uint256 eventId) external view returns (address eventAddress) {
        require(eventId < allEvents.length, "Invalid event ID");
        return allEvents[eventId];
    }

    /**
     * @notice Closes an event.
     * @param _eventAddress The address of the event contract.
     */
    function closeEvent(address _eventAddress) internal {
        Event eventContract = Event(_eventAddress);

        // Ensure the event is resolved
        require(
            eventContract.status() == Event.EventStatus.Resolved,
            "Event is not resolved"
        );

        if (eventContract.status() == Event.EventStatus.Resolved) {
            eventContract.closeEvent();
        }

        emit EventClosed(_eventAddress);
    }

    /**
     * @notice Locks collateral for a specific event.
     */
    function lockCollateral(address _eventAddress, address _creator, uint256 _amount) internal {
        require(protocolToken.balanceOf(_creator) >= _amount, "Insufficient balance for collateral");
        require(
            protocolToken.allowance(_creator, address(this)) >= _amount,
            "Insufficient allowance for collateral"
        );
        require(!isCollateralLocked[_eventAddress], "Collateral already locked for this event");

        // Transfer collateral tokens from the creator to this contract
        protocolToken.transferFrom(_creator, address(this), _amount);

        collateralBalances[_eventAddress] += _amount;
        isCollateralLocked[_eventAddress] = true;

        emit CollateralLocked(_eventAddress, _amount);
    }

    /**
     * @notice Increases the locked collateral for a specific event.
     */
    function increaseCollateral(address _eventAddress, uint256 _amount) public onlyEventCreator(_eventAddress) nonReentrant {
        require(isCollateralLocked[_eventAddress], "No collateral locked for this event");
        require(_amount > 0, "Amount must be greater than zero");
        require(_amount <= 1e24, "Amount exceeds maximum limit"); // Example maximum

        // Transfer additional collateral tokens from the creator to this contract
        protocolToken.transferFrom(msg.sender, address(this), _amount);
        collateralBalances[_eventAddress] += _amount;

        emit CollateralIncreased(_eventAddress, _amount);
    }

    /**
     * @notice Allows the event creator to claim the locked collateral after the event is resolved.
     */
    function claimCollateral(address _eventAddress) external onlyEventCreator(_eventAddress) nonReentrant {
        Event _event = Event(_eventAddress);
        require(block.timestamp > _event.disputeDeadline(), "Dispute period not over");

        // Ensure the event is resolved or canceled
        require(
            _event.status() == Event.EventStatus.Resolved || _event.status() == Event.EventStatus.Cancelled,
            "Event is not resolved or canceled"
        );

        if (_event.status() == Event.EventStatus.Resolved) {
            require(_event.disputeStatus() != Event.DisputeStatus.Disputed, "Event is disputed");
            // Transfer fee to governance and creator
            bool winningOutcomeChanged = disputeOutcomeChanged[_eventAddress];
            _event.payFees(protocolFeeRecipient, winningOutcomeChanged);
        }

        // If no one bet on winning outcome, refund bets instead of burning loot
        if (_event.status() == Event.EventStatus.Resolved && _event.outcomeStakes(_event.winningOutcome()) == 0) {
            _event.refundAllBets();
        }

        // Release collateral to the creator
        releaseCollateral(_eventAddress);

        emit CollateralClaimed(_eventAddress, msg.sender, collateralBalances[_eventAddress]);
    }

    /**
     * @notice Allows the event creator to cancel an open event.
     */
    function cancelEvent(address _eventAddress) external onlyEventCreator(_eventAddress) nonReentrant {
        Event _event = Event(_eventAddress);
        require(_event.status() == Event.EventStatus.Open, "Can only cancel open events");
        require(block.timestamp < _event.startTime() - 1 hours, "Cannot cancel event within 1 hour of start time");

        _event.cancelEvent();

        // Release collateral back to the creator
        releaseCollateral(_eventAddress);
    }

    /**
     * @notice Allows governance to resolve a dispute.
     */
    function resolveDispute(address _eventAddress, uint256 _finalOutcome) external onlyApprovedAdmin nonReentrant {
        Event _event = Event(_eventAddress);
        require(_event.disputeStatus() == Event.DisputeStatus.Disputed, "Event is not disputed");

        uint256 initialOutcome = _event.winningOutcome();

        // Update the dispute status in the Event contract before proceeding
        _event.resolveDispute(_finalOutcome);

        bool winningOutcomeChanged = _finalOutcome != initialOutcome;
        disputeOutcomeChanged[_eventAddress] = winningOutcomeChanged;

        // Now you can safely release or forfeit collateral
        if (winningOutcomeChanged) {
            // reduce reputation by 50% or by 10, whichever is greater
            int256 reputation = creatorsReputation[_event.creator()];
            int256 decreaseAmount = reputation / 2;
            if (decreaseAmount < 10) {
                decreaseAmount = 10;
            }

            creatorsReputation[_event.creator()] = reputation - decreaseAmount;

            // Forfeit collateral
            forfeitCollateral(_eventAddress);

            emit DisputeResolved(_eventAddress, _finalOutcome);
        } else {
            // Transfer dispute contributions accordingly
            _event.collectDisputeContributionsForCreator();

            emit DisputeResolved(_eventAddress, _finalOutcome);
        }
    }

    /**
     * @notice Forfeits the event's collateral in case of a valid dispute.
     */
    function forfeitCollateral(address _eventAddress) internal {
        require(isCollateralLocked[_eventAddress], "No collateral to forfeit for this event");
        uint256 amount = collateralBalances[_eventAddress];
        require(amount > 0, "No collateral balance for this event");

        // Update state before external calls
        collateralBalances[_eventAddress] = 0;
        isCollateralLocked[_eventAddress] = false;

        // Calculate distributions
        uint256 toDisputingUsers = (amount * 80) / 100;
        uint256 toProtocol = (amount * 10) / 100;
        uint256 toBurn = amount - toDisputingUsers - toProtocol; // Remaining amount

        // Store the forfeited collateral amount for disputing users
        forfeitedCollateralAmounts[_eventAddress] = toDisputingUsers;

        // Transfer protocol fee
        protocolToken.transfer(protocolFeeRecipient, toProtocol);

        // Burn tokens by sending to zero address
        protocolToken.burn(toBurn);

        // Close the event
        closeEvent(_eventAddress);

        emit CollateralForfeited(_eventAddress, amount);
    }

    /**
     * @notice Releases collateral back to the event creator.
     */
    function releaseCollateral(address _eventAddress) internal {
        Event eventContract = Event(_eventAddress);
        uint256 amount = collateralBalances[_eventAddress];

        require(
            eventContract.disputeStatus() != Event.DisputeStatus.Disputed,
            "Cannot release collateral during dispute"
        );
        require(isCollateralLocked[_eventAddress], "No collateral to release for this event");
        require(amount > 0, "No collateral balance for this event");

        // Update state before external calls
        collateralBalances[_eventAddress] = 0;
        isCollateralLocked[_eventAddress] = false;

        // Transfer collateral back to the creator
        protocolToken.transfer(eventContract.creator(), amount);

        if (eventContract.status() == Event.EventStatus.Resolved) {
            closeEvent(_eventAddress);
        }

        emit CollateralReleased(_eventAddress, amount);
    }

    /**
     * @notice Initializes the trust multiplier for a creator.
     */
    function initializeCreatorsReputation(address creator) internal {
        if (creatorsReputation[creator] == int256(0)) {
            creatorsReputation[creator] = 1;
        }
    }

    /**
     * @notice Allows governance to update the protocol fee recipient.
     */
    function setProtocolFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "Invalid address");
        protocolFeeRecipient = _newRecipient;
    }

    /**
     * @notice Allows governance to transfer governance rights.
     * Implement timelock or multi-signature as needed.
     */
    function transferGovernance(address _newGovernance) external onlyOwner {
        require(_newGovernance != address(0), "Invalid address");
        governance = Governance(_newGovernance);
    }

    /**
     * @notice Increases the creator's trust multiplier.
     * @param creator The address of the creator.
     * @param amount The amount to increase the multiplier by.
     */
    function increaseCreatorsReputation(address creator, uint256 amount) public onlyOwner {
        initializeCreatorsReputation(creator);
        int256 reputation = creatorsReputation[creator] + int256(amount);
        creatorsReputation[creator] = reputation;
    }

    /**
     * @notice Decreases the creator's trust multiplier.
     * @param creator The address of the creator.
     * @param amount The amount to decrease the multiplier by.
     */
    function decreaseCreatorsReputation(address creator, uint256 amount) public onlyOwner {
        initializeCreatorsReputation(creator);
        int256 reputation = creatorsReputation[creator] - int256(amount);
        require(reputation > type(int256).min, "Underflow error");
        creatorsReputation[creator] = reputation;
    }

    /**
     * @notice Allows users to claim their share of forfeited collateral.
     * @param _eventAddress The address of the event.
     */
    function claimForfeitedCollateral(address _eventAddress) external nonReentrant {
        Event eventContract = Event(_eventAddress);
        require(eventContract.disputeStatus() == Event.DisputeStatus.Resolved, "Dispute not resolved");
        require(forfeitedCollateralAmounts[_eventAddress] > 0, "No collateral forfeited");

        uint256 userContribution = eventContract.disputingUsers(msg.sender);
        require(userContribution > 0, "No contribution to dispute");
        require(!forfeitedCollateralClaims[_eventAddress][msg.sender], "Already claimed");

        uint256 totalContributions = eventContract.totalDisputeContributions();
        require(totalContributions > 0, "Total dispute contributions must be greater than zero");

        uint256 amount = (forfeitedCollateralAmounts[_eventAddress] * userContribution) / totalContributions;
        require(amount > 0, "No collateral to claim");

        // Mark as claimed before transferring
        forfeitedCollateralClaims[_eventAddress][msg.sender] = true;

        // Transfer the user's share
        protocolToken.transfer(msg.sender, amount);

        emit ForfeitedCollateralClaimed(_eventAddress, msg.sender, amount);
    }

    /**
     * @notice Allows the protocol to collect unclaimed forfeited collateral after a certain period.
     * @param _eventAddress The address of the event.
     */
    function collectUnclaimedCollateral(address _eventAddress) external onlyOwner nonReentrant {
        Event eventContract = Event(_eventAddress);
        require(block.timestamp > eventContract.disputeDeadline() + 30 days, "Collection period not reached");
        require(forfeitedCollateralAmounts[_eventAddress] > 0, "No collateral to collect");

        uint256 unclaimedAmount = forfeitedCollateralAmounts[_eventAddress];
        forfeitedCollateralAmounts[_eventAddress] = 0;

        // Transfer unclaimed collateral to the protocol fee recipient
        protocolToken.transfer(protocolFeeRecipient, unclaimedAmount);
    }

    /**
     * @notice Notifies the EventManager of dispute resolution outcome.
     * @param _eventAddress The address of the event.
     * @param outcomeChanged Indicates if the winning outcome changed due to the dispute.
     */
    function notifyDisputeResolution(address _eventAddress, bool outcomeChanged) external {
        require(msg.sender == _eventAddress, "Only event contract can notify");
        disputeOutcomeChanged[_eventAddress] = outcomeChanged;
    }
}
