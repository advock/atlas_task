//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import { DAppControl } from "src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/SolverOperation.sol";

struct CTFExchangeInfo {
    address conditionToken;
    uint256 amount;
    bool isBuy;
}

contract CTFExchangeDAppControl is DAppControl {
    address public immutable CTF_EXCHANGE;
    address public immutable COLLATERAL_TOKEN;

    error InvalidUserOpData();
    error UserOpNotCTFExchange();
    error InsufficientUserOpValue();
    error InsufficientBalance();

    constructor(
        address atlas,
        address ctfExchange,
        address collateralToken
    )
        DAppControl(
            atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: true,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: false,
                reuseUserOp: true,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: false,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: true,
                trustedOpHash: false,
                invertBidValue: false,
                exPostBids: false,
                allowAllocateValueFailure: false
            })
        )
    {
        CTF_EXCHANGE = ctfExchange;
        COLLATERAL_TOKEN = collateralToken;
    }

    function _preOpsCall(UserOperation calldata userOp) internal virtual override returns (bytes memory) {
        if (userOp.dapp != CTF_EXCHANGE) revert UserOpNotCTFExchange();

        (bool success, bytes memory exchangeData) =
            CONTROL.staticcall(abi.encodePacked(this.decodeUserOpData.selector, userOp.data));

        if (!success) revert InvalidUserOpData();

        CTFExchangeInfo memory exchangeInfo = abi.decode(exchangeData, (CTFExchangeInfo));

        if (exchangeInfo.isBuy) {
            // For buying, transfer collateral from user to this contract
            _transferUserERC20(COLLATERAL_TOKEN, address(this), exchangeInfo.amount);
            SafeTransferLib.safeApprove(COLLATERAL_TOKEN, CTF_EXCHANGE, exchangeInfo.amount);
        } else {
            // For selling, transfer condition tokens from user to this contract
            _transferUserERC20(exchangeInfo.conditionToken, address(this), exchangeInfo.amount);
            SafeTransferLib.safeApprove(exchangeInfo.conditionToken, CTF_EXCHANGE, exchangeInfo.amount);
        }

        return exchangeData;
    }

    function _allocateValueCall(address, uint256 bidAmount, bytes calldata data) internal virtual override {
        CTFExchangeInfo memory exchangeInfo = abi.decode(data, (CTFExchangeInfo));

        // Execute the trade on CTF Exchange
        (bool success,) = CTF_EXCHANGE.call(
            abi.encodeWithSignature(
                "executeTrade(address,uint256,bool)",
                exchangeInfo.conditionToken,
                exchangeInfo.amount,
                exchangeInfo.isBuy
            )
        );

        if (!success) revert InsufficientBalance();

        // Transfer resulting tokens to the user
        if (exchangeInfo.isBuy) {
            uint256 balance = IERC20(exchangeInfo.conditionToken).balanceOf(address(this));
            SafeTransferLib.safeTransfer(exchangeInfo.conditionToken, _user(), balance);
        } else {
            uint256 balance = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
            SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, _user(), balance);
        }
    }

    function _postOpsCall(bool solved, bytes calldata data) internal virtual override {
        if (solved) return; // Trade execution already handled in allocateValue hook

        CTFExchangeInfo memory exchangeInfo = abi.decode(data, (CTFExchangeInfo));

        // Refund tokens to user if the trade wasn't executed
        if (exchangeInfo.isBuy) {
            uint256 balance = IERC20(COLLATERAL_TOKEN).balanceOf(address(this));
            SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, _user(), balance);
        } else {
            uint256 balance = IERC20(exchangeInfo.conditionToken).balanceOf(address(this));
            SafeTransferLib.safeTransfer(exchangeInfo.conditionToken, _user(), balance);
        }
    }

    function getBidFormat(UserOperation calldata) public view virtual override returns (address bidToken) {
        return COLLATERAL_TOKEN;
    }

    function getBidValue(SolverOperation calldata solverOp) public view virtual override returns (uint256) {
        return solverOp.bidAmount;
    }

    // Helper function to decode user operation data
    function decodeUserOpData() public pure returns (CTFExchangeInfo memory exchangeInfo) {
        // Implement the decoding logic based on your CTFExchange's encoding scheme
        // This is a placeholder implementation
        assembly {
            exchangeInfo := mload(0x40)
            mstore(exchangeInfo, calldataload(4)) // conditionToken
            mstore(add(exchangeInfo, 0x20), calldataload(36)) // amount
            mstore(add(exchangeInfo, 0x40), calldataload(68)) // isBuy
        }
    }
}
