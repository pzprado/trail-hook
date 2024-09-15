// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

// Our contracts
import {TrailHook} from "../src/TrailHook.sol";

contract TrailHookTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;

    TrailHook hook;

    function setUp() public {
        //*****
        // Part 1: Deployments
        //******

        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our hook
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo("TrailHook.sol", abi.encode(manager, ""), hookAddress);
        hook = TrailHook(hookAddress);

        //*****
        // Part 2: Approvals and pool initialization
        //******

        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(hook), type(uint256).max);

        // Initialize a pool with these two tokens
        (key,) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1, ZERO_BYTES);

        // Add initial liquidity to the pool
        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1000 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function test_placeOrder() public {
        //*****
        // Part 1: Create position
        //******

        // Place a zeroForOne trailing order
        // for 10e18 token0 tokens
        // with a trailing distance of 50 ticks
        /// @notice: trailingDistance is the distance from the current tick that the order will trail
        /// E.g. if the current tick is 200 and trailingDistance is 50
        int24 trailingDistance = 60;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();

        // Place the order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOfSelf();

        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // the tickLower should be 60 since we placed an order at tick 100
        // assertEq(tickLower, 60);

        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);

        // Check the details of the placed order
        (
            uint256 inputAmount,
            int24 orderTrailingDistance,
            int24 lastTrackedTick,
            bool orderZeroForOne,
            int24 orderStartTick,
            bool isActive
        ) = hook.trailingOrders(key.toId(), orderId);

        // assertEq(inputAmount, amount);
        // assertEq(orderTrailingDistance, trailingDistance);
        assertEq(orderZeroForOne, zeroForOne);
        assertEq(orderStartTick, startTick);
        assertTrue(isActive);

        // Check that the current tick is set as the lastTrackedTick
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertEq(lastTrackedTick, currentTick);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, orderId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(positionId != 0);
        // assertEq(tokenBalance, amount);

        // Check that the order owner is set correctly
        assertEq(hook.orderOwners(orderId), address(this));
    }

    function test_trailingOrderExecution() public {
        // Setup initial conditions
        int24 trailingDistance = 180;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // // Check position token
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        (, currentTick,,) = manager.getSlot0(key.toId());

        // Record initial balances
        uint256 initialToken0Balance = token0.balanceOfSelf();
        uint256 initialToken1Balance = token1.balanceOfSelf();

        //*****
        // Part 1: Move the tick up
        //*****
        console.log("-----------------------------");
        console.log("|  Part 1: move tick up     |");
        console.log("-----------------------------");

        setPoolTick(440);

        (,, int24 lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        //*****
        // Part 2: Move the tick down
        //******
        console.log("-----------------------------");
        console.log("|  Part 2: move tick down   |");
        console.log("-----------------------------");

        setPoolTick(320);

        (,, lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        // Check that the order is not executed yet
        (uint256 inputAmount,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, amount, "Order should not be executed yet");

        uint256 hookToken0Balance = token0.balanceOf(address(hook));
        uint256 hookToken1Balance = token1.balanceOf(address(hook));

        //*****
        // Part 3: Move the tick down and trigger the order
        //******
        console.log("-----------------------------");
        console.log("|  Part 3: move tick down    |");
        console.log("|  and trigger order         |");
        console.log("-----------------------------");

        setPoolTick(260);

        // Check that the order has been executed and the hook contract has the expected number of token1 tokens ready to redeem
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 newHookToken0Balance = token0.balanceOf(address(hook));
        uint256 newHookToken1Balance = token1.balanceOf(address(hook));
        assertTrue(newHookToken0Balance < hookToken0Balance, "Order should be executed");
        assertEq(newHookToken0Balance, 0, "Order should be executed");
        assertTrue(newHookToken1Balance > hookToken1Balance, "Order should be executed");
        assertEq(newHookToken1Balance, claimableOutputTokens, "There should be output tokens to claim");

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        // Ensure we can redeem the token1
        hook.redeem(key, orderId, 10e18);
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);

        // Check that the ERC-1155 token for the order has been burned
        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");
    }

    function test_delayedTrailingOrder() public {
        //*****
        // This sets a start trailing in the future
        //*****

        // Setup initial conditions
        int24 trailingDistance = 180;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick + 400; // Start in the future

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // // Check position token
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        (, currentTick,,) = manager.getSlot0(key.toId());

        // Record initial balances
        uint256 initialToken0Balance = token0.balanceOfSelf();
        uint256 initialToken1Balance = token1.balanceOfSelf();

        //*****
        // Part 1: Move the tick up
        //*****
        console.log("-----------------------------");
        console.log("|  Part 1: move tick up     |");
        console.log("-----------------------------");

        setPoolTick(440);

        (,, int24 lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        //*****
        // Part 2: Move the tick down
        //******
        console.log("-----------------------------");
        console.log("|  Part 2: move tick down   |");
        console.log("-----------------------------");

        setPoolTick(320);

        (,, lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        // Check that the order is not executed yet
        (uint256 inputAmount,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, amount, "Order should not be executed yet");

        uint256 hookToken0Balance = token0.balanceOf(address(hook));
        uint256 hookToken1Balance = token1.balanceOf(address(hook));

        //*****
        // Part 3: Move the tick down and trigger the order
        //******
        console.log("-----------------------------");
        console.log("|  Part 3: move tick down    |");
        console.log("|  and trigger order         |");
        console.log("-----------------------------");

        setPoolTick(260);

        // Check that the order has been executed and the hook contract has the expected number of token1 tokens ready to redeem
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 newHookToken0Balance = token0.balanceOf(address(hook));
        uint256 newHookToken1Balance = token1.balanceOf(address(hook));
        assertTrue(newHookToken0Balance < hookToken0Balance, "Order should be executed");
        assertEq(newHookToken0Balance, 0, "Order should be executed");
        assertTrue(newHookToken1Balance > hookToken1Balance, "Order should be executed");
        assertEq(newHookToken1Balance, claimableOutputTokens, "There should be output tokens to claim");

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        // Ensure we can redeem the token1
        hook.redeem(key, orderId, 10e18);
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);

        // Check that the ERC-1155 token for the order has been burned
        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");
    }

    function testFail_delayedTrailingOrder() public {
        //*****
        // This sets a start trailing in the future that never gets actived
        // (same as the delayed trailing order test, but with higher start tick value)
        //*****

        // Setup initial conditions
        int24 trailingDistance = 180;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick + 500; // Start in the future

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // // Check position token
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        (, currentTick,,) = manager.getSlot0(key.toId());

        // Record initial balances
        uint256 initialToken0Balance = token0.balanceOfSelf();
        uint256 initialToken1Balance = token1.balanceOfSelf();

        //*****
        // Part 1: Move the tick up
        //*****
        console.log("-----------------------------");
        console.log("|  Part 1: move tick up     |");
        console.log("-----------------------------");

        setPoolTick(440);

        (,, int24 lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        //*****
        // Part 2: Move the tick down
        //******
        console.log("-----------------------------");
        console.log("|  Part 2: move tick down   |");
        console.log("-----------------------------");

        setPoolTick(320);

        (,, lastTrackedTick,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        // Check that the order is not executed yet
        (uint256 inputAmount,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, amount, "Order should not be executed yet");

        uint256 hookToken0Balance = token0.balanceOf(address(hook));
        uint256 hookToken1Balance = token1.balanceOf(address(hook));

        //*****
        // Part 3: Move the tick down and trigger the order
        //******
        console.log("-----------------------------");
        console.log("|  Part 3: move tick down    |");
        console.log("|  and trigger order         |");
        console.log("-----------------------------");

        setPoolTick(260);

        // Check that the order has been executed and the hook contract has the expected number of token1 tokens ready to redeem
        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        uint256 newHookToken0Balance = token0.balanceOf(address(hook));
        uint256 newHookToken1Balance = token1.balanceOf(address(hook));
        assertTrue(newHookToken0Balance < hookToken0Balance, "Order should be executed");
        assertEq(newHookToken0Balance, 0, "Order should be executed");
        assertTrue(newHookToken1Balance > hookToken1Balance, "Order should be executed");
        assertEq(newHookToken1Balance, claimableOutputTokens, "There should be output tokens to claim");

        uint256 originalToken1Balance = token1.balanceOf(address(this));
        // Ensure we can redeem the token1
        hook.redeem(key, orderId, 10e18);
        uint256 newToken1Balance = token1.balanceOf(address(this));
        assertEq(newToken1Balance - originalToken1Balance, claimableOutputTokens);

        // Check that the ERC-1155 token for the order has been burned
        tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");
    }

    function test_cancelOrder() public {
        // Setup initial conditions
        int24 trailingDistance = 180;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // Note the original balance of token0
        uint256 originalBalance = token0.balanceOfSelf();

        // Cancel the order
        hook.cancelTrailingOrder(key, orderId);

        // Check that the order has been cancelled
        (uint256 inputAmount,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, 0, "Order should be cancelled");

        // Check that the tokens have been returned
        uint256 newBalance = token0.balanceOfSelf();
        assertEq(newBalance, originalBalance + amount, "Tokens should be returned after cancellation");

        // Check that the ERC-1155 token for the order has been burned
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0, "ERC-1155 token should be burned after cancellation");
    }

    function test_partialRedeem() public {
        // Setup initial conditions
        int24 trailingDistance = 180;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // Move the tick to trigger the order
        setPoolTick(currentTick - 200);

        // Redeem half of the amount
        uint256 halfAmount = amount / 2;
        uint256 originalBalance = token1.balanceOfSelf();
        hook.redeem(key, orderId, halfAmount);

        // Check the new balance
        uint256 newBalance = token1.balanceOfSelf();
        assertTrue(newBalance > originalBalance, "Should have received some token1");

        // Try to redeem the other half
        hook.redeem(key, orderId, halfAmount);

        // Check the final balance
        uint256 finalBalance = token1.balanceOfSelf();
        assertTrue(finalBalance > newBalance, "Should have received more token1");

        // Check that the ERC-1155 token for the order has been fully burned
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        assertEq(tokenBalance, 0, "ERC-1155 token should be fully burned after complete redemption");
    }

    function test_tickSpacingAlignment() public {
        // Setup initial conditions
        int24 trailingDistance = 181; // Not aligned with tick spacing
        uint256 amount = 10e18;
        bool zeroForOne = true;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick + 61; // Not aligned with tick spacing

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, startTick);

        // Check that the order has been aligned correctly
        (, int24 orderTrailingDistance,,, int24 orderStartTick,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(orderTrailingDistance, 180, "Trailing distance should be aligned to tick spacing");
        assertEq(orderStartTick, currentTick + 60, "Start tick should be aligned to tick spacing");
    }

    // Helper functions
    function setPoolTick(int24 targetTick) public {
        (, int24 currentTick,,) = manager.getSlot0(key.toId());

        bool zeroForOne = targetTick < currentTick;
        // Perform swaps until we reach the target tick
        while ((zeroForOne && currentTick > targetTick) || (!zeroForOne && currentTick < targetTick)) {
            int256 amountSpecified = -int256(1e18); // Swap a small amount each time
            BalanceDelta delta = swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                })
            );

            // Update current tick
            (, currentTick,,) = manager.getSlot0(key.toId());
        }
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params) internal returns (BalanceDelta delta) {
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        delta = swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    }
}
