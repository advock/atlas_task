//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

interface IDAppIntegration {
    function initializeGovernance(address controller) external;

    function addSignatory(address controller, address signatory) external;

    function removeSignatory(address controller, address signatory) external;

    function integrateDApp(address controller, address dappControl) external;

    function disableDApp(address controller, address dappControl) external;

    function nextGovernanceNonce(address governanceSignatory) external view returns (uint256 nextNonce);
}