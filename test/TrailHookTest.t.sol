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
        uint256 minOutputAmount = 9.7e18; // 97% of input as minimum output for slippage protection
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();

        // Place the order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, minOutputAmount, startTick);

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
            uint256 orderMinOutputAmount,
            int24 orderStartTick,
            bool isActive
        ) = hook.trailingOrders(key.toId(), orderId);

        // assertEq(inputAmount, amount);
        // assertEq(orderTrailingDistance, trailingDistance);
        assertEq(orderZeroForOne, zeroForOne);
        assertEq(orderMinOutputAmount, minOutputAmount);
        assertEq(orderStartTick, startTick);
        assertTrue(isActive);

        // Check that the current tick is set as the lastTrackedTick
        (, currentTick,,) = manager.getSlot0(key.toId());
        assertEq(lastTrackedTick, currentTick);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

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
        uint256 minOutputAmount = 9.9e18;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        int24 startTick = currentTick; // Start immediately for this test

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, minOutputAmount, startTick);

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

        (,, int24 lastTrackedTick,,,,) = hook.trailingOrders(key.toId(), orderId);
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

        (,, lastTrackedTick,,,,) = hook.trailingOrders(key.toId(), orderId);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("Last tracked tick:", lastTrackedTick);
        console.log("Current tick:", currentTick);
        console.log("Current distance:", lastTrackedTick - currentTick);

        // Check that the order is not executed yet
        (uint256 inputAmount,,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, amount, "Order should not be executed yet");

        uint256 positionId = hook.getPositionId(key, orderId);

        uint256 claimableOutputTokens = hook.claimableOutputTokens(positionId);
        console.log("claimableOutputTokens: %18e", claimableOutputTokens);

        uint256 hookToken0Balance = token0.balanceOf(address(hook));
        uint256 hookToken1Balance = token1.balanceOf(address(hook));
        console.log(" hookToken0Balance: %18e", hookToken0Balance);
        console.log(" hookToken1Balance: %18e", hookToken1Balance);

        //*****
        // Part 3: Move the tick down and trigger the order
        //******
        console.log("-----------------------------");
        console.log("|  Part 3: move tick down    |");
        console.log("|  and trigger order         |");
        console.log("-----------------------------");

        setPoolTick(260);

        // Check that the order has been executed
        (inputAmount,,,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, 0, "Order should be executed");

        // Check that the hook contract has the expected number of token0 tokens ready to redeem
        positionId = hook.getPositionId(key, orderId);

        claimableOutputTokens = hook.claimableOutputTokens(positionId);

        hookToken0Balance = token0.balanceOf(address(hook));
        hookToken1Balance = token1.balanceOf(address(hook));

        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(
            claimableOutputTokens,
            hookContractToken1Balance,
            "Hook contract should have the expected number of token1 tokens ready to redeem"
        );

        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOfSelf();
        hook.redeem(key, orderId, inputAmount);
        uint256 newToken1Balance = token1.balanceOfSelf();

        // // Verify token balances have changed
        // uint256 finalToken0Balance = token0.balanceOfSelf();
        // uint256 finalToken1Balance = token1.balanceOfSelf();

        // assertTrue(finalToken0Balance < initialToken0Balance, "Token0 balance should decrease");
        // assertTrue(finalToken1Balance > initialToken1Balance, "Token1 balance should increase");

        // Check that the ERC-1155 token for the order has been burned
        // uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        // assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");

        // // After performing swaps
        // (uint256 remainingAmount,,,,) = hook.trailingOrders(key.toId(), orderId);
        // assertEq(remainingAmount, 0, "Order should be executed");
    }

    // function test_delayedTrailingOrder() public {
    //     int24 trailingDistance = 50;
    //     uint256 amount = 10e18;
    //     bool zeroForOne = false; // Buying token0 with token1
    //     uint256 minOutputAmount = 9.9e18;
    //     (, int24 currentTick,,) = manager.getSlot0(key.toId());
    //     int24 startTick = currentTick + 100; // Start 100 ticks above current price

    //     // Place the delayed trailing order
    //     uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, minOutputAmount, startTick);

    //     // Check that the order is not active yet
    //     (,,,,,, bool isActive) = hook.trailingOrders(key.toId(), orderId);
    //     assertFalse(isActive, "Order should not be active yet");

    //     // Record initial balances
    //     uint256 initialToken0Balance = token0.balanceOfSelf();
    //     uint256 initialToken1Balance = token1.balanceOfSelf();

    //     // Perform swaps to move the price up to the start tick
    //     while (currentTick < startTick) {
    //         swap(
    //             key,
    //             IPoolManager.SwapParams({
    //                 zeroForOne: false,
    //                 amountSpecified: -1e18,
    //                 sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
    //             })
    //         );
    //         (, currentTick,,) = manager.getSlot0(key.toId());
    //     }

    //     // Simulate the afterSwap hook call
    //     hook.afterSwap(
    //         address(0),
    //         key,
    //         IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0}),
    //         BalanceDelta.wrap(0),
    //         ""
    //     );

    //     // Check that the order is now active
    //     (,,,,,, isActive) = hook.trailingOrders(key.toId(), orderId);
    //     assertTrue(isActive, "Order should be active now");

    //     // Perform more swaps to test the trailing logic
    //     for (uint256 i = 0; i < 5; i++) {
    //         swap(
    //             key,
    //             IPoolManager.SwapParams({
    //                 zeroForOne: true,
    //                 amountSpecified: 1e18,
    //                 sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
    //             })
    //         );
    //         hook.afterSwap(
    //             address(0),
    //             key,
    //             IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}),
    //             BalanceDelta.wrap(0),
    //             ""
    //         );
    //     }

    //     // Check if the order has been executed
    //     (uint256 remainingAmount,,,,,,) = hook.trailingOrders(key.toId(), orderId);
    //     assertEq(remainingAmount, 0, "Order should be executed");

    //     // Verify token balances have changed
    //     assertTrue(token0.balanceOfSelf() > amount, "Token0 balance should increase");
    //     assertTrue(token1.balanceOfSelf() < initialToken1Balance, "Token1 balance should decrease");

    //     // Check that the ERC-1155 token for the order has been burned
    //     uint256 positionId = hook.getPositionId(key, orderId);
    //     uint256 tokenBalance = hook.balanceOf(address(this), positionId);
    //     assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");
    // }

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

    function simulateSwap(bool zeroForOne) public {
        // Simulate a swap by calling the afterSwap function of the hook
        hook.afterSwap(
            address(0),
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0),
            ""
        );
    }
}
