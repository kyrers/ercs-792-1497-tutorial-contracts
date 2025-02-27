/**
 * Based on the tutorial found here: https://developer.kleros.io/en/latest/index.html
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.8.28;

import "./interfaces/IArbitrable.sol";
import "./interfaces/IArbitrator.sol";

contract SimpleEscrow is IArbitrable {
    enum Status {
        Initial,
        Reclaimed,
        Disputed,
        Resolved
    }

    enum RulingOptions {
        RefusedToArbitrate,
        PayerWins,
        PayeeWins
    }

    uint256 public constant reclamationPeriod = 3 minutes; // Timeframe is short on purpose to be able to test it quickly. Not for production use.
    uint256 public constant arbitrationFeeDepositPeriod = 3 minutes; // Timeframe is short on purpose to be able to test it quickly. Not for production use.
    uint256 constant numberOfRulingOptions = 2; // Notice that option 0 is reserved for RefusedToArbitrate.
    uint256 public value;
    uint256 public createdAt;
    uint256 public reclaimedAt;
    Status public status;
    address payable public payer = payable(msg.sender);
    address payable public payee;
    IArbitrator public arbitrator;
    string public agreement;

    error InvalidStatus();
    error ReleasedTooEarly();
    error NotPayer();
    error NotArbitrator();
    error PayeeDepositStillPending();
    error ReclaimedTooLate();
    error InsufficientPayment(uint256 _available, uint256 _required);
    error InvalidRuling(uint256 _ruling, uint256 _numberOfChoices);

    constructor(
        address payable _payee,
        IArbitrator _arbitrator,
        string memory _agreement
    ) payable {
        value = msg.value;
        payee = _payee;
        arbitrator = _arbitrator;
        agreement = _agreement;
        createdAt = block.timestamp;
    }

    function releaseFunds() public {
        if (status != Status.Initial) {
            revert InvalidStatus();
        }

        if (
            msg.sender != payer &&
            block.timestamp - createdAt <= reclamationPeriod
        ) {
            revert ReleasedTooEarly();
        }

        status = Status.Resolved;
        (bool sent, ) = payee.call{value: value}("");
        require(sent, "Failed to send Ether");
    }

    function reclaimFunds() public payable {
        if (status != Status.Initial && status != Status.Reclaimed) {
            revert InvalidStatus();
        }

        if (msg.sender != payer) {
            revert NotPayer();
        }

        if (status == Status.Reclaimed) {
            if (block.timestamp - reclaimedAt <= arbitrationFeeDepositPeriod) {
                revert PayeeDepositStillPending();
            }

            status = Status.Resolved;
            (bool sent, ) = payer.call{value: address(this).balance}("");
            require(sent, "Failed to send Ether");
        } else {
            if (block.timestamp - createdAt > reclamationPeriod) {
                revert ReclaimedTooLate();
            }

            uint256 requiredAmount = arbitrator.arbitrationCost("");
            if (msg.value < requiredAmount) {
                revert InsufficientPayment(msg.value, requiredAmount);
            }

            reclaimedAt = block.timestamp;
            status = Status.Reclaimed;
        }
    }

    function depositArbitrationFeeForPayee() public payable {
        if (status != Status.Reclaimed) {
            revert InvalidStatus();
        }

        status = Status.Disputed;
        arbitrator.createDispute{value: msg.value}(numberOfRulingOptions, "");
    }

    function rule(uint256 _disputeId, uint256 _ruling) public override {
        if (msg.sender != address(arbitrator)) {
            revert NotArbitrator();
        }

        if (status != Status.Disputed) {
            revert InvalidStatus();
        }

        if (_ruling > numberOfRulingOptions) {
            revert InvalidRuling(_ruling, numberOfRulingOptions);
        }

        status = Status.Resolved;

        if (_ruling == uint256(RulingOptions.PayerWins)) {
            (bool sent, ) = payer.call{value: address(this).balance}("");
            require(sent, "Failed to send Ether");
        } else if (_ruling == uint256(RulingOptions.PayeeWins)) {
            (bool sent, ) = payee.call{value: address(this).balance}("");
            require(sent, "Failed to send Ether");
        }

        emit Ruling(arbitrator, _disputeId, _ruling);
    }

    function remainingTimeToReclaim() public view returns (uint256) {
        if (status != Status.Initial) {
            revert InvalidStatus();
        }

        return
            (block.timestamp - createdAt) > reclamationPeriod
                ? 0
                : (createdAt + reclamationPeriod - block.timestamp);
    }

    function remainingTimeToDepositArbitrationFee()
        public
        view
        returns (uint256)
    {
        if (status != Status.Reclaimed) {
            revert InvalidStatus();
        }

        return
            (block.timestamp - reclaimedAt) > arbitrationFeeDepositPeriod
                ? 0
                : (reclaimedAt + arbitrationFeeDepositPeriod - block.timestamp);
    }
}
