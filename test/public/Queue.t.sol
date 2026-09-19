// SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Queue} from "../../src/asset-management/settlement/Queue.sol";
import {IQueue} from "../../src/interfaces/IQueue.sol";
import {QueueType} from "../../src/libs/Types.sol";

// Minimal mock StateManager that whitelists specific vault addresses.
contract MockStateManager {
    mapping(address => bool) public registeredVaults;

    function registerVault(address vault) external {
        registeredVaults[vault] = true;
    }
}

// Minimal mock vault that wraps Queue calls (since Queue checks msg.sender == vault), and
// exposes `settlement()` so Queue.dequeue's `IBaseVault(vault).settlement()` gate can be tested.
contract MockVault {
    Queue internal queue;
    address public settlement;

    constructor(address _queue) {
        queue = Queue(_queue);
    }

    function setSettlement(address _settlement) external {
        settlement = _settlement;
    }

    function enqueue(QueueType queueType, uint256 requestId, address owner, uint256 amount) external {
        queue.enqueue(address(this), queueType, requestId, owner, amount);
    }

    function remove(QueueType queueType, uint256 requestId) external {
        queue.remove(address(this), queueType, requestId);
    }
}

contract QueueTest is Test {
    MockStateManager internal sm;
    Queue internal queue;
    MockVault internal vault;

    address internal settlement = makeAddr("settlement");
    address internal alice = makeAddr("alice");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        sm = new MockStateManager();
        queue = new Queue(address(sm));

        // Register vault.
        vault = new MockVault(address(queue));
        sm.registerVault(address(vault));

        // Bind the vault's settlement contract (Queue.dequeue is now gated to
        // IBaseVault(vault).settlement(), not a global SETTLEMENT_ROLE).
        vault.setSettlement(settlement);
    }

    // -----------------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------------

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(IQueue.ZeroAddress.selector);
        new Queue(address(0));
    }

    // -----------------------------------------------------------------------
    // enqueue
    // -----------------------------------------------------------------------

    function test_enqueue_succeeds() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
        assertEq(queue.depth(address(vault), QueueType.REDEEM), 1);
    }

    function test_enqueue_revertsIfCallerNotVault() public {
        // Unregistered address calling enqueue directly should revert.
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IQueue.UnregisteredVault.selector, attacker));
        queue.enqueue(attacker, QueueType.REDEEM, 1, alice, 100e18);
    }

    function test_enqueue_storesOrderHash() public {
        uint256 ts = block.timestamp;
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        assertTrue(queue.verifyOrder(address(vault), QueueType.REDEEM, 1, alice, 100e18, ts));
    }

    function test_enqueue_emitsEvent() public {
        bytes32 expectedHash = keccak256(abi.encode(uint256(1), alice, uint256(100e18), block.timestamp));

        vm.expectEmit(true, true, true, true, address(queue));
        emit IQueue.RequestQueued(address(vault), QueueType.REDEEM, 1, 0, expectedHash, block.timestamp);

        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
    }

    function test_enqueue_multipleRequests() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);

        assertEq(queue.depth(address(vault), QueueType.REDEEM), 2);
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 2));
    }

    function test_enqueue_depositAndRedeemQueuesAreIndependent() public {
        // Same requestId can coexist in both queues without collision.
        vault.enqueue(QueueType.DEPOSIT, 1, alice, 50e18);
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        assertTrue(queue.isInQueue(address(vault), QueueType.DEPOSIT, 1));
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
        assertEq(queue.depth(address(vault), QueueType.DEPOSIT), 1);
        assertEq(queue.depth(address(vault), QueueType.REDEEM), 1);

        vault.remove(QueueType.DEPOSIT, 1);

        assertFalse(queue.isInQueue(address(vault), QueueType.DEPOSIT, 1));
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
    }

    // -----------------------------------------------------------------------
    // dequeue
    // -----------------------------------------------------------------------

    function test_dequeue_removesHeadInFIFO() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(settlement);
        queue.dequeue(address(vault), QueueType.REDEEM, ids);

        assertFalse(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 2));
        assertEq(queue.depth(address(vault), QueueType.REDEEM), 1);
    }

    function test_dequeue_revertsIfOutOfOrder() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 2; // trying to dequeue non-head

        vm.prank(settlement);
        vm.expectRevert(
            abi.encodeWithSelector(IQueue.OutOfOrderDequeue.selector, address(vault), QueueType.REDEEM, 1, 2)
        );
        queue.dequeue(address(vault), QueueType.REDEEM, ids);
    }

    function test_dequeue_revertsForNonSettlement() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(attacker);
        vm.expectRevert(IQueue.NotSettlement.selector);
        queue.dequeue(address(vault), QueueType.REDEEM, ids);
    }

    function test_dequeue_emitsEvent() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.expectEmit(true, true, true, true, address(queue));
        emit IQueue.RequestDequeued(address(vault), QueueType.REDEEM, 1, 1, block.timestamp);

        vm.prank(settlement);
        queue.dequeue(address(vault), QueueType.REDEEM, ids);
    }

    function test_dequeue_skipsTombstones() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);
        vault.enqueue(QueueType.REDEEM, 3, alice, 300e18);

        // Cancel request 1 (tombstone at head).
        vault.remove(QueueType.REDEEM, 1);

        // Dequeue should now successfully process request 2 (skipping tombstone).
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;

        vm.prank(settlement);
        queue.dequeue(address(vault), QueueType.REDEEM, ids);

        assertFalse(queue.isInQueue(address(vault), QueueType.REDEEM, 2));
        assertTrue(queue.isInQueue(address(vault), QueueType.REDEEM, 3));
    }

    // -----------------------------------------------------------------------
    // remove (cancel)
    // -----------------------------------------------------------------------

    function test_remove_tombstonesSlot() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.remove(QueueType.REDEEM, 1);

        assertFalse(queue.isInQueue(address(vault), QueueType.REDEEM, 1));
    }

    function test_remove_revertsIfNotInQueue() public {
        vm.expectRevert(abi.encodeWithSelector(IQueue.NotInQueue.selector, address(vault), QueueType.REDEEM, 999));
        vault.remove(QueueType.REDEEM, 999);
    }

    function test_remove_emitsEvent() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);

        vm.expectEmit(true, true, true, true, address(queue));
        emit IQueue.RequestCancelledFromQueue(address(vault), QueueType.REDEEM, 1, block.timestamp);

        vault.remove(QueueType.REDEEM, 1);
    }

    // -----------------------------------------------------------------------
    // peek / depth / verifyOrder
    // -----------------------------------------------------------------------

    function test_peek_returnsHead() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);

        IQueue.QueueSlot memory slot = queue.peek(address(vault), QueueType.REDEEM);
        assertEq(slot.requestId, 1);
    }

    function test_depth_includesTombstones() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        vault.enqueue(QueueType.REDEEM, 2, alice, 200e18);
        vault.remove(QueueType.REDEEM, 1);

        // Tombstone still counts in depth.
        assertEq(queue.depth(address(vault), QueueType.REDEEM), 2);
    }

    function test_verifyOrder_returnsFalseForUnknownRequest() public view {
        assertFalse(queue.verifyOrder(address(vault), QueueType.REDEEM, 999, alice, 100e18, block.timestamp));
    }

    function test_verifyOrder_returnsFalseForWrongParams() public {
        vault.enqueue(QueueType.REDEEM, 1, alice, 100e18);
        // Wrong amount.
        assertFalse(queue.verifyOrder(address(vault), QueueType.REDEEM, 1, alice, 999e18, block.timestamp));
    }
}
