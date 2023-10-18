//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

import {IExecutionEnvironment} from "../interfaces/IExecutionEnvironment.sol";

import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";

import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

import {DAppVerification} from "./DAppVerification.sol";
import {Permit69} from "../common/Permit69.sol";

import "../types/SolverCallTypes.sol";
import "../types/UserCallTypes.sol";
import {DAppConfig} from "../types/DAppApprovalTypes.sol";
import "../types/EscrowTypes.sol";
import "../types/LockTypes.sol";
import {FastLaneErrorsEvents} from "../types/Emissions.sol";

import {EscrowBits} from "../libraries/EscrowBits.sol";
import {CallBits} from "../libraries/CallBits.sol";
import {SafetyBits} from "../libraries/SafetyBits.sol";

import "forge-std/Test.sol";

abstract contract Escrow is ERC20, Permit69, DAppVerification, FastLaneErrorsEvents {
    using ECDSA for bytes32;
    using EscrowBits for uint256;
    using CallBits for uint32;
    using SafetyBits for EscrowKey;

    uint32 public immutable escrowDuration;

    // NOTE: these storage vars / maps should only be accessible by *signed* solver transactions
    // and only once per solver per block (to avoid user-solver collaborative exploits)
    // EOA Address => solver escrow data
    mapping(address => SolverEscrow) internal _escrowData;
    mapping(address => SolverWithdrawal) internal _withdrawalData;

    constructor(
        string memory _tokenName,
        string memory _tokenSymbol,
        uint8 _tokenDecimals,
        uint32 _escrowDuration,
        address _simulator
    ) ERC20(_tokenName, _tokenSymbol, _tokenDecimals) Permit69(_simulator) {
        escrowDuration = _escrowDuration;
    }

    modifier checkEscrowDuration(address owner) {
        require(block.number >= uint256(_escrowData[owner].lastAccessed) + uint256(escrowDuration), "ERR-E080 TooEarly");
        _;
    }

    ///////////////////////////////////////////////////
    /// ERC20 OVERRIDES                             ///
    ///////////////////////////////////////////////////

    function transfer(address to, uint256 amount) public override checkEscrowDuration(msg.sender) returns (bool) {
        balanceOf[msg.sender] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        _escrowData[msg.sender].total -= amount;
        _escrowData[to].total += amount;

        emit Transfer(msg.sender, to, amount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        checkEscrowDuration(from)
        returns (bool)
    {
        uint256 allowed = allowance[from][msg.sender]; // Saves gas for limited approvals.

        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;

        balanceOf[from] -= amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf[to] += amount;
        }

        _escrowData[from].total -= amount;
        _escrowData[to].total += amount;

        emit Transfer(from, to, amount);

        return true;
    }

    ///////////////////////////////////////////////////
    /// EXTERNAL FUNCTIONS FOR SOLVER INTERACTION ///
    ///////////////////////////////////////////////////

    // Deposit ETH and get atlETH in return.
    function deposit() external payable onlyWhenUnlocked returns (uint256 newBalance) {
        _mint(msg.sender, msg.value);
        _escrowData[msg.sender].total += msg.value;
        newBalance = _escrowData[msg.sender].total;
    }

    // Redeem atlETH for ETH.
    function withdraw(uint256 amount)
        external
        onlyWhenUnlocked
        checkEscrowDuration(msg.sender)
        returns (uint256 newBalance)
    {
        require(balanceOf[msg.sender] >= amount, "ERR-E078 InsufficientBalance");
        _burn(msg.sender, amount);
        SafeTransferLib.safeTransferETH(msg.sender, amount);
        _escrowData[msg.sender].total -= amount;
        newBalance = balanceOf[msg.sender];
    }

    function nextSolverNonce(address solverSigner) external view returns (uint256 nextNonce) {
        nextNonce = uint256(_escrowData[solverSigner].nonce) + 1;
    }

    function solverEscrowBalance(address solverSigner) external view returns (uint256 balance) {
        balance = uint256(_escrowData[solverSigner].total);
    }

    function solverLastActiveBlock(address solverSigner) external view returns (uint256 lastBlock) {
        lastBlock = uint256(_escrowData[solverSigner].lastAccessed);
    }

    ///////////////////////////////////////////////////
    /// EXTERNAL FUNCTIONS FOR BUNDLER INTERACTION  ///
    ///////////////////////////////////////////////////

    ///////////////////////////////////////////////////
    ///             INTERNAL FUNCTIONS              ///
    ///////////////////////////////////////////////////
    function _executePreOpsCall(UserOperation calldata userOp, address environment, bytes32 lockBytes)
        internal
        returns (bool success, bytes memory preOpsData)
    {
        preOpsData = abi.encodeWithSelector(IExecutionEnvironment.preOpsWrapper.selector, userOp);
        preOpsData = abi.encodePacked(preOpsData, lockBytes);
        (success, preOpsData) = environment.call{value: msg.value}(preOpsData);
        if (success) {
            preOpsData = abi.decode(preOpsData, (bytes));
        }
    }

    function _executeUserOperation(UserOperation calldata userOp, address environment, bytes32 lockBytes)
        internal
        returns (bool success, bytes memory userData)
    {
        userData = abi.encodeWithSelector(IExecutionEnvironment.userWrapper.selector, userOp);
        userData = abi.encodePacked(userData, lockBytes);
        // TODO: Handle msg.value quirks
        (success, userData) = environment.call(userData);
        // require(success, "ERR-E002 UserFail");
        if (success) {
            userData = abi.decode(userData, (bytes));
        }
    }

    function _executeSolverOperation(
        SolverOperation calldata solverOp,
        bytes memory dAppReturnData,
        address environment,
        EscrowKey memory key
    ) internal returns (bool auctionWon, EscrowKey memory) {
        // Set the gas baseline
        uint256 gasWaterMark = gasleft();

        // Verify the transaction.
        (uint256 result, uint256 gasLimit, SolverEscrow memory solverEscrow) = _verify(solverOp, gasWaterMark, false);

        SolverOutcome outcome;
        uint256 escrowSurplus;

        // If there are no errors, attempt to execute
        if (result.canExecute()) {
            // Open the solver lock
            key = key.holdSolverLock(solverOp.solver);

            // Execute the solver call
            (outcome, escrowSurplus) = _solverOpWrapper(gasLimit, environment, solverOp, dAppReturnData, key.pack());

            unchecked {
                solverEscrow.total += uint128(escrowSurplus);
            }

            result |= 1 << uint256(outcome);

            if (result.executedWithError()) {
                result |= 1 << uint256(SolverOutcome.ExecutionCompleted);
            } else if (result.executionSuccessful()) {
                // first successful solver call that paid what it bid
                auctionWon = true; // cannot be reached if bool is already true
                result |= 1 << uint256(SolverOutcome.ExecutionCompleted);
                key = key.turnSolverLockPayments(environment);
            }

            // Update the solver's escrow balances and the accumulated refund
            if (result.updateEscrow()) {
                key.gasRefund += uint32(_update(solverOp, solverEscrow, gasWaterMark, result));
            }

            // emit event
            emit SolverTxResult(
                solverOp.solver, solverOp.from, true, outcome == SolverOutcome.Success, solverEscrow.nonce, result
            );
        } else {
            // emit event
            emit SolverTxResult(solverOp.solver, solverOp.from, false, false, solverEscrow.nonce, result);
        }

        return (auctionWon, key);
    }

    // TODO: who should pay gas cost of MEV Payments?
    // TODO: Should payment failure trigger subsequent solver calls?
    // (Note that balances are held in the execution environment, meaning
    // that payment failure is typically a result of a flaw in the
    // DAppControl contract)
    function _allocateValue(
        DAppConfig calldata dConfig,
        uint256 winningBidAmount,
        bytes memory returnData,
        address environment,
        bytes32 lockBytes
    ) internal returns (bool success) {
        // process dApp payments
        bytes memory data = abi.encodeWithSelector(
            IExecutionEnvironment.allocateValue.selector, dConfig.bidToken, winningBidAmount, returnData
        );
        data = abi.encodePacked(data, lockBytes);
        (success,) = environment.call(data);
        if (!success) {
            emit MEVPaymentFailure(dConfig.to, dConfig.callConfig, dConfig.bidToken, winningBidAmount);
        }
    }

    function _executePostOpsCall(bytes memory returnData, address environment, bytes32 lockBytes)
        internal
        returns (bool success)
    {
        bytes memory postOpsData = abi.encodeWithSelector(IExecutionEnvironment.postOpsWrapper.selector, returnData);
        postOpsData = abi.encodePacked(postOpsData, lockBytes);
        (success,) = environment.call{value: msg.value}(postOpsData);
    }

    function _update(
        SolverOperation calldata solverOp,
        SolverEscrow memory solverEscrow,
        uint256 gasWaterMark,
        uint256 result
    ) internal returns (uint256 gasRebate) {
        unchecked {
            uint256 gasUsed = gasWaterMark - gasleft();

            if (result & EscrowBits._FULL_REFUND != 0) {
                gasRebate = gasUsed + (solverOp.data.length * CALLDATA_LENGTH_PREMIUM);
            } else if (result & EscrowBits._CALLDATA_REFUND != 0) {
                gasRebate = (solverOp.data.length * CALLDATA_LENGTH_PREMIUM);
            } else if (result & EscrowBits._NO_USER_REFUND != 0) {
                // pass
            } else {
                revert("ERR-SE72 UncoveredResult");
            }

            if (gasRebate != 0) {
                // Calculate what the solver owes
                gasRebate *= tx.gasprice;

                gasRebate = gasRebate > solverEscrow.total ? solverEscrow.total : gasRebate;

                solverEscrow.total -= uint128(gasRebate);

                // NOTE: This will cause an error if you are simulating with a gasPrice of 0
                gasRebate /= tx.gasprice;

                // save the escrow data back into storage
                _escrowData[solverOp.from] = solverEscrow;

                // Check if need to save escrowData due to nonce update but not gasRebate
            } else if (result & EscrowBits._NO_NONCE_UPDATE == 0) {
                _escrowData[solverOp.from].nonce = solverEscrow.nonce;
            }
        }
    }

    function _verify(SolverOperation calldata solverOp, uint256 gasWaterMark, bool auctionAlreadyComplete)
        internal
        view
        returns (uint256 result, uint256 gasLimit, SolverEscrow memory solverEscrow)
    {
        // verify solver's signature
        if (_verifySignature(solverOp)) {
            // verify the solver has correct usercalldata and the solver escrow checks
            (result, gasLimit, solverEscrow) = _verifySolverOperation(solverOp);
        } else {
            (result, gasLimit) = (1 << uint256(SolverOutcome.InvalidSignature), 0);
            // solverEscrow returns null
        }

        result = _solverOpPreCheck(result, gasWaterMark, tx.gasprice, solverOp.maxFeePerGas, auctionAlreadyComplete);
    }

    function _getSolverHash(SolverOperation calldata solverOp) internal pure returns (bytes32 solverHash) {
        return keccak256(
            abi.encode(
                SOLVER_TYPE_HASH,
                solverOp.from,
                solverOp.to,
                solverOp.value,
                solverOp.gas,
                solverOp.maxFeePerGas,
                solverOp.nonce,
                solverOp.deadline,
                solverOp.solver,
                solverOp.control,
                solverOp.userOpHash,
                solverOp.bidToken,
                solverOp.bidAmount,
                keccak256(solverOp.data)
            )
        );
    }

    function getSolverPayload(SolverOperation calldata solverOp) public view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getSolverHash(solverOp));
    }

    function _verifySignature(SolverOperation calldata solverOp) internal view returns (bool) {
        address signer = _hashTypedDataV4(_getSolverHash(solverOp)).recover(solverOp.signature);
        return signer == solverOp.from;
    }

    function _verifySolverOperation(SolverOperation calldata solverOp)
        internal
        view
        returns (uint256 result, uint256 gasLimit, SolverEscrow memory solverEscrow)
    {
        solverEscrow = _escrowData[solverOp.from];

        // TODO big unchecked block - audit/review carefully
        unchecked {
            if (solverOp.to != address(this)) {
                result |= 1 << uint256(SolverOutcome.InvalidTo);
            }

            if (solverOp.nonce <= uint256(solverEscrow.nonce)) {
                result |= 1 << uint256(SolverOutcome.InvalidNonceUnder);
            } else if (solverOp.nonce > uint256(solverEscrow.nonce) + 1) {
                result |= 1 << uint256(SolverOutcome.InvalidNonceOver);

                // TODO: reconsider the jump up for gapped nonces? Intent is to mitigate dmg
                // potential inflicted by a hostile solver/builder.
                solverEscrow.nonce = uint32(solverOp.nonce);
            } else {
                ++solverEscrow.nonce;
            }

            if (solverEscrow.lastAccessed >= uint64(block.number)) {
                result |= 1 << uint256(SolverOutcome.PerBlockLimit);
            } else {
                solverEscrow.lastAccessed = uint64(block.number);
            }

            gasLimit = (100) * (solverOp.gas < EscrowBits.SOLVER_GAS_LIMIT ? solverOp.gas : EscrowBits.SOLVER_GAS_LIMIT)
                / (100 + EscrowBits.SOLVER_GAS_BUFFER) + EscrowBits.FASTLANE_GAS_BUFFER;

            uint256 gasCost = (tx.gasprice * gasLimit) + (solverOp.data.length * CALLDATA_LENGTH_PREMIUM * tx.gasprice);

            // see if solver's escrow can afford tx gascost
            if (gasCost > solverEscrow.total - _withdrawalData[solverOp.from].escrowed) {
                // charge solver for calldata so that we can avoid vampire attacks from solver onto user
                result |= 1 << uint256(SolverOutcome.InsufficientEscrow);
            }

            // Verify that we can lend the solver their tx value
            if (solverOp.value > address(this).balance - (gasLimit * tx.gasprice)) {
                result |= 1 << uint256(SolverOutcome.CallValueTooHigh);
            }

            // subtract out the gas buffer since the solver's metaTx won't use it
            gasLimit -= EscrowBits.FASTLANE_GAS_BUFFER;
        }
    }

    function _solverOpWrapper(
        uint256 gasLimit,
        address environment,
        SolverOperation calldata solverOp,
        bytes memory dAppReturnData,
        bytes32 lockBytes
    ) internal returns (SolverOutcome, uint256) {
        // address(this) = Atlas/Escrow
        // msg.sender = tx.origin

        // Get current Ether balance
        uint256 currentBalance = address(this).balance;
        bool success;

        bytes memory data = abi.encodeWithSelector(
            IExecutionEnvironment(environment).solverMetaTryCatch.selector,
            gasLimit,
            currentBalance,
            solverOp,
            dAppReturnData
        );

        data = abi.encodePacked(data, lockBytes);

        // Account for ETH borrowed by solver - repay with repayBorrowedEth() below
        _accData.ethBorrowed[solverOp.solver] += solverOp.value;

        (success, data) = environment.call{value: solverOp.value}(data);

        // Check all borrowed ETH was repaid during solver call from Execution Env
        if (_accData.ethBorrowed[solverOp.solver] != 0) {
            revert FastLaneErrorsEvents.SolverMsgValueUnpaid();
        }

        if (success) {
            return (SolverOutcome.Success, address(this).balance - currentBalance);
        }
        bytes4 errorSwitch = bytes4(data);

        if (errorSwitch == SolverBidUnpaid.selector) {
            return (SolverOutcome.BidNotPaid, 0);
        } else if (errorSwitch == SolverMsgValueUnpaid.selector) {
            return (SolverOutcome.CallValueTooHigh, 0);
        } else if (errorSwitch == IntentUnfulfilled.selector) {
            return (SolverOutcome.IntentUnfulfilled, 0);
        } else if (errorSwitch == SolverOperationReverted.selector) {
            return (SolverOutcome.CallReverted, 0);
        } else if (errorSwitch == SolverFailedCallback.selector) {
            return (SolverOutcome.CallbackFailed, 0);
        } else if (errorSwitch == AlteredControlHash.selector) {
            return (SolverOutcome.InvalidControlHash, 0);
        } else if (errorSwitch == PreSolverFailed.selector) {
            return (SolverOutcome.PreSolverFailed, 0);
        } else if (errorSwitch == PostSolverFailed.selector) {
            return (SolverOutcome.IntentUnfulfilled, 0);
        } else {
            return (SolverOutcome.CallReverted, 0);
        }
    }

    receive() external payable {}

    fallback() external payable {
        revert(); // no untracked balance transfers plz. (not that this fully stops it)
    }

    // BITWISE STUFF
    function _solverOpPreCheck(
        uint256 result,
        uint256 gasWaterMark,
        uint256 txGasPrice,
        uint256 maxFeePerGas,
        bool auctionAlreadyComplete
    ) internal pure returns (uint256) {
        if (auctionAlreadyComplete) {
            result |= 1 << uint256(SolverOutcome.LostAuction);
        }

        if (gasWaterMark < EscrowBits.VALIDATION_GAS_LIMIT + EscrowBits.SOLVER_GAS_LIMIT) {
            // Make sure to leave enough gas for dApp validation calls
            result |= 1 << uint256(SolverOutcome.UserOutOfGas);
        }

        if (txGasPrice > maxFeePerGas) {
            result |= 1 << uint256(SolverOutcome.GasPriceOverCap);
        }

        return result;
    }
}
