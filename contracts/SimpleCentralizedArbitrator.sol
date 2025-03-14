/**
 * Based on the tutorial found here: https://developer.kleros.io/en/latest/index.html
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.8.28;

import "./interfaces/IArbitrator.sol";

contract SimpleCentralizedArbitrator is IArbitrator {
    struct Dispute {
        IArbitrable arbitrated;
        uint256 choices;
        uint256 ruling;
        DisputeStatus status;
    }

    address public owner = msg.sender;
    Dispute[] public disputes;

    error NotOwner();
    error InsufficientPayment(uint256 _available, uint256 _required);
    error InvalidRuling(uint256 _ruling, uint256 _numberOfChoices);
    error InvalidStatus(DisputeStatus _current, DisputeStatus _expected);

    function createDispute(
        uint256 _choices,
        bytes memory _extraData
    ) public payable override returns (uint256 disputeID) {
        uint256 requiredAmount = arbitrationCost(_extraData);

        if (msg.value < requiredAmount) {
            revert InsufficientPayment(msg.value, requiredAmount);
        }

        disputes.push(
            Dispute({
                arbitrated: IArbitrable(msg.sender),
                choices: _choices,
                ruling: 0,
                status: DisputeStatus.Waiting
            })
        );

        disputeID = disputes.length - 1;
        emit DisputeCreation(disputeID, IArbitrable(msg.sender));
    }

    function rule(uint256 _disputeID, uint256 _ruling) public {
        if (msg.sender != owner) {
            revert NotOwner();
        }

        Dispute storage dispute = disputes[_disputeID];

        if (_ruling > dispute.choices) {
            revert InvalidRuling(_ruling, dispute.choices);
        }

        if (dispute.status != DisputeStatus.Waiting) {
            revert InvalidStatus(dispute.status, DisputeStatus.Waiting);
        }

        dispute.ruling = _ruling;
        dispute.status = DisputeStatus.Solved;
        dispute.arbitrated.rule(_disputeID, _ruling);
        (bool sent, ) = msg.sender.call{value: arbitrationCost("")}("");
        require(sent, "Failed to send Ether");
    }

    function appeal(
        uint256 _disputeID,
        bytes memory _extraData
    ) public payable override {
        uint256 requiredAmount = appealCost(_disputeID, _extraData);
        if (msg.value < requiredAmount) {
            revert InsufficientPayment(msg.value, requiredAmount);
        }
    }

    function disputeStatus(
        uint256 _disputeID
    ) public view override returns (DisputeStatus status) {
        status = disputes[_disputeID].status;
    }

    function currentRuling(
        uint256 _disputeID
    ) public view override returns (uint256 ruling) {
        ruling = disputes[_disputeID].ruling;
    }

    function arbitrationCost(
        bytes memory _extraData
    ) public pure override returns (uint256) {
        return 0.1 ether; //Simplified for this tutorial
    }

    function appealCost(
        uint256 _disputeID,
        bytes memory _extraData
    ) public pure override returns (uint256) {
        return 2 ** 250; // An unaffordable amount which practically avoids appeals.
    }

    function appealPeriod(
        uint256 _disputeID
    ) public pure override returns (uint256 start, uint256 end) {
        return (0, 0); //Again, simplified as we don't have appeals
    }
}
