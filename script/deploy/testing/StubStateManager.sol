// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {IStateManager} from "../../../src/interfaces/IStateManager.sol";
import {IHyperAccessControl} from "../../../src/interfaces/IHyperAccessControl.sol";
import {ProductState, CycleState, PauseState, StateContext, ProductParams, ModuleId} from "../../../src/libs/Types.sol";

/// @title StubStateManager
/// @notice **TESTING SCAFFOLD ONLY — NOT a deliverable contract.**
///         Implements the per-module pause surface so NAVOracle and the other core-stage contracts
///         can exercise their emergency-pause gates. All lifecycle / vault-registration
///         functions revert `Deferred()`. The real `StateManager` is deployed by the vaults
///         stage, and the `production` deploy profile skips this contract entirely.
contract StubStateManager is IStateManager {
    error Deferred();

    address public immutable accessControl;
    address public vaultFactory;
    mapping(ModuleId => bool) internal _modulePaused;
    mapping(address => bool) internal _registeredVaults;

    constructor(address _accessControl) {
        if (_accessControl == address(0)) revert ZeroAddress();
        accessControl = _accessControl;
    }

    // --- Per-module pause (functional) ---

    function pauseModule(ModuleId id) external override {
        IHyperAccessControl ac = IHyperAccessControl(accessControl);
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
        _modulePaused[id] = true;
        emit ModulePaused(id, msg.sender, block.timestamp);
    }

    function unpauseModule(ModuleId id) external override {
        IHyperAccessControl ac = IHyperAccessControl(accessControl);
        if (!ac.hasRole(ac.GOVERNOR_ROLE(), msg.sender)) revert NotGovernor();
        _modulePaused[id] = false;
        emit ModuleUnpaused(id, msg.sender, block.timestamp);
    }

    function modulePaused(ModuleId id) external view override returns (bool) {
        return _modulePaused[id];
    }

    function requireModuleActive(ModuleId id) external view override {
        if (_modulePaused[id]) revert ModuleIsPaused(id);
    }

    // --- Vault registration (stub — set directly for testing) ---

    function setRegistered(address vault, bool val) external {
        _registeredVaults[vault] = val;
    }

    function registeredVaults(address vault) external view override returns (bool) {
        return _registeredVaults[vault];
    }

    function isVaultRegistered(address vault) external view override returns (bool) {
        return _registeredVaults[vault];
    }

    // --- Deferred lifecycle surface (reverts) ---

    function setVaultFactory(address) external pure override {
        revert Deferred();
    }

    function registerVault(address) external pure override {
        revert Deferred();
    }

    function setProductParams(address, ProductParams calldata) external pure override {
        revert Deferred();
    }

    function recordSubscription(address, address, uint256) external pure override {
        revert Deferred();
    }

    function releaseSubscription(address, address, uint256) external pure override {
        revert Deferred();
    }

    function openSubscription(address) external pure override {
        revert Deferred();
    }

    function finalizeSubscription(address) external pure override {
        revert Deferred();
    }

    function startCycleCalculation(address) external pure override {
        revert Deferred();
    }

    function enterClaiming(address) external pure override {
        revert Deferred();
    }

    function closeProduct(address) external pure override {
        revert Deferred();
    }

    function completeCycle(address) external pure override {
        revert Deferred();
    }

    function isFinalCycle(address) external pure override returns (bool) {
        revert Deferred();
    }

    function pause(address, PauseState) external pure override {
        revert Deferred();
    }

    function unpause(address) external pure override {
        revert Deferred();
    }

    function requireSubscribable(address) external pure override {
        revert Deferred();
    }

    function requireOperable(address) external pure override {
        revert Deferred();
    }

    function requireCycleState(address, CycleState) external pure override {
        revert Deferred();
    }

    function requireActive(address) external pure override {
        revert Deferred();
    }

    function getState(address) external pure override returns (StateContext memory) {
        revert Deferred();
    }

    function getParams(address) external pure override returns (ProductParams memory) {
        revert Deferred();
    }

    function totalSubscribed(address) external pure override returns (uint256) {
        revert Deferred();
    }

    function subscribedByWallet(address, address) external pure override returns (uint256) {
        revert Deferred();
    }

    function currentCycleNumber(address) external pure override returns (uint256) {
        revert Deferred();
    }

    function currentCycleStart(address) external pure override returns (uint256) {
        revert Deferred();
    }

    function getProductState(address) external pure override returns (ProductState) {
        revert Deferred();
    }

    function getCycleState(address) external pure override returns (CycleState) {
        revert Deferred();
    }

    function getPauseState(address) external pure override returns (PauseState) {
        revert Deferred();
    }

    function vaultCount() external pure override returns (uint256) {
        revert Deferred();
    }

    function vaultAt(uint256) external pure override returns (address) {
        revert Deferred();
    }

    function vaultsPaged(uint256, uint256) external pure override returns (address[] memory) {
        revert Deferred();
    }

    function vaultsWithRole(address, uint256, uint256)
        external
        pure
        override
        returns (address[] memory, uint8[] memory)
    {
        revert Deferred();
    }
}
