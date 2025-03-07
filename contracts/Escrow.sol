/**
 * Based on the tutorial found here: https://developer.kleros.io/en/latest/index.html
 * SPDX-License-Identifier: MIT
 */
pragma solidity ^0.8.28;

import "./interfaces/IArbitrable.sol";
import "./interfaces/IArbitrator.sol";
import "./interfaces/IEvidence.sol";

contract Escrow is IArbitrable, IEvidence {
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

    struct TX {
        address payable payer;
        address payable payee;
        IArbitrator arbitrator;
        Status status;
        uint256 value;
        uint256 disputeID;
        uint256 createdAt;
        uint256 reclaimedAt;
        uint256 payerFeeDeposit;
        uint256 payeeFeeDeposit;
        uint256 reclamationPeriod;
        uint256 arbitrationFeeDepositPeriod;
    }

    uint256 constant numberOfRulingOptions = 2; // Notice that option 0 is reserved for RefusedToArbitrate.
    TX[] public txs;
    mapping(uint256 => uint256) disputeIDtoTXID;

    error InvalidStatus();
    error ReleasedTooEarly();
    error NotPayer();
    error NotArbitrator();
    error PayeeDepositStillPending();
    error ReclaimedTooLate();
    error InsufficientPayment(uint256 _available, uint256 _required);
    error InvalidRuling(uint256 _ruling, uint256 _numberOfChoices);
    error ThirdPartyNotAllowed();

    function newTransaction(
        address payable _payee,
        IArbitrator _arbitrator,
        string memory _metaevidence,
        uint256 _reclamationPeriod,
        uint256 _arbitrationFeeDepositPeriod
    ) public payable returns (uint256 txID) {
        emit MetaEvidence(txs.length, _metaevidence);
        txs.push(
            TX({
                payer: payable(msg.sender),
                payee: _payee,
                arbitrator: _arbitrator,
                status: Status.Initial,
                value: msg.value,
                disputeID: 0,
                createdAt: block.timestamp,
                reclaimedAt: 0,
                payerFeeDeposit: 0,
                payeeFeeDeposit: 0,
                reclamationPeriod: _reclamationPeriod,
                arbitrationFeeDepositPeriod: _arbitrationFeeDepositPeriod
            })
        );

        txID = txs.length;
    }

    function releaseFunds(uint256 _txID) public {
        TX storage transaction = txs[_txID];

        if (transaction.status != Status.Initial) {
            revert InvalidStatus();
        }

        if (
            msg.sender != transaction.payer &&
            block.timestamp - transaction.createdAt <=
            transaction.reclamationPeriod
        ) {
            revert ReleasedTooEarly();
        }

        transaction.status = Status.Resolved;
        (bool sent, ) = transaction.payee.call{value: transaction.value}("");
        require(sent, "Failed to send Ether");
    }

    function reclaimFunds(uint256 _txID) public payable {
        TX storage transaction = txs[_txID];

        if (
            transaction.status != Status.Initial &&
            transaction.status != Status.Reclaimed
        ) {
            revert InvalidStatus();
        }

        if (msg.sender != transaction.payer) {
            revert NotPayer();
        }

        if (transaction.status == Status.Reclaimed) {
            if (
                block.timestamp - transaction.reclaimedAt <=
                transaction.arbitrationFeeDepositPeriod
            ) {
                revert PayeeDepositStillPending();
            }

            transaction.status = Status.Resolved;
            (bool sent, ) = transaction.payer.call{
                value: transaction.value + transaction.payerFeeDeposit
            }("");
            require(sent, "Failed to send Ether");
        } else {
            if (
                block.timestamp - transaction.createdAt >
                transaction.reclamationPeriod
            ) {
                revert ReclaimedTooLate();
            }

            uint256 requiredAmount = transaction.arbitrator.arbitrationCost("");
            if (msg.value < requiredAmount) {
                revert InsufficientPayment(msg.value, requiredAmount);
            }

            transaction.payerFeeDeposit = msg.value;
            transaction.reclaimedAt = block.timestamp;
            transaction.status = Status.Reclaimed;
        }
    }

    function depositArbitrationFeeForPayee(uint256 _txID) public payable {
        TX storage transaction = txs[_txID];

        if (transaction.status != Status.Reclaimed) {
            revert InvalidStatus();
        }

        transaction.payeeFeeDeposit = msg.value;
        transaction.disputeID = transaction.arbitrator.createDispute{
            value: msg.value
        }(numberOfRulingOptions, "");
        transaction.status = Status.Disputed;
        disputeIDtoTXID[transaction.disputeID] = _txID;

        emit Dispute(
            transaction.arbitrator,
            transaction.disputeID,
            _txID,
            _txID
        );
    }

    function rule(uint256 _disputeId, uint256 _ruling) public override {
        uint256 txID = disputeIDtoTXID[_disputeId];
        TX storage transaction = txs[txID];

        if (msg.sender != address(transaction.arbitrator)) {
            revert NotArbitrator();
        }

        if (transaction.status != Status.Disputed) {
            revert InvalidStatus();
        }

        if (_ruling > numberOfRulingOptions) {
            revert InvalidRuling(_ruling, numberOfRulingOptions);
        }

        transaction.status = Status.Resolved;

        if (_ruling == uint256(RulingOptions.PayerWins)) {
            (bool sent, ) = transaction.payer.call{
                value: transaction.value + transaction.payerFeeDeposit
            }("");
            require(sent, "Failed to send Ether");
        } else if (_ruling == uint256(RulingOptions.PayeeWins)) {
            (bool sent, ) = transaction.payee.call{
                value: transaction.value + transaction.payeeFeeDeposit
            }("");
            require(sent, "Failed to send Ether");
        }

        emit Ruling(transaction.arbitrator, _disputeId, _ruling);
    }

    function submitEvidence(uint256 _txID, string memory _evidence) public {
        TX storage transaction = txs[_txID];

        if (transaction.status == Status.Resolved) {
            revert InvalidStatus();
        }

        if (
            msg.sender != transaction.payer && msg.sender != transaction.payee
        ) {
            revert ThirdPartyNotAllowed();
        }

        emit Evidence(transaction.arbitrator, _txID, msg.sender, _evidence);
    }

    function remainingTimeToReclaim(
        uint256 _txID
    ) public view returns (uint256) {
        TX storage transaction = txs[_txID];

        if (transaction.status != Status.Initial) {
            revert InvalidStatus();
        }

        return
            (block.timestamp - transaction.createdAt) >
                transaction.reclamationPeriod
                ? 0
                : (transaction.createdAt +
                    transaction.reclamationPeriod -
                    block.timestamp);
    }

    function remainingTimeToDepositArbitrationFee(
        uint256 _txID
    ) public view returns (uint256) {
        TX storage transaction = txs[_txID];

        if (transaction.status != Status.Reclaimed) {
            revert InvalidStatus();
        }

        return
            (block.timestamp - transaction.reclaimedAt) >
                transaction.arbitrationFeeDepositPeriod
                ? 0
                : (transaction.reclaimedAt +
                    transaction.arbitrationFeeDepositPeriod -
                    block.timestamp);
    }
}
