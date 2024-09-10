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
                liquidityDelta: 10 ether,
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
                liquidityDelta: 10 ether,
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
                liquidityDelta: 10 ether,
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
        int24 trailingDistance = 50;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        uint256 minOutputAmount = 9.9e18; // 99% of input as minimum output for slippage protection

        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();

        // Place the order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, minOutputAmount);

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
            uint256 orderMinOutputAmount
        ) = hook.trailingOrders(key.toId(), orderId);

        assertEq(inputAmount, amount);
        assertEq(orderTrailingDistance, trailingDistance);
        assertEq(orderZeroForOne, zeroForOne);
        assertEq(orderMinOutputAmount, minOutputAmount);

        // Check that the current tick is set as the lastTrackedTick
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        assertEq(lastTrackedTick, currentTick);

        // Check the balance of ERC-1155 tokens we received
        uint256 positionId = hook.getPositionId(key, orderId);
        uint256 tokenBalance = hook.balanceOf(address(this), positionId);

        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(positionId != 0);
        assertEq(tokenBalance, amount);

        // Check that the order owner is set correctly
        assertEq(hook.orderOwners(orderId), address(this));
    }

    function test_trailingOrderExecution() public {
        // Setup initial conditions
        int24 trailingDistance = 50;
        uint256 amount = 10e18;
        bool zeroForOne = true;
        uint256 minOutputAmount = 9.9e18;
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        console.log("~> ~ file: TrailHookTest.t.sol:185 ~ test_trailingOrderExecution ~ currentTick:", currentTick);

        // Place the trailing order
        uint256 orderId = hook.placeTrailingOrder(key, trailingDistance, zeroForOne, amount, minOutputAmount);
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("~> ~ file: TrailHookTest.t.sol:185 ~ test_trailingOrderExecution ~ currentTick:", currentTick);

        // Record initial balances
        uint256 initialToken0Balance = token0.balanceOfSelf();
        uint256 initialToken1Balance = token1.balanceOfSelf();

        // Perform a series of swaps to move the price upwards
        for (uint256 i = 0; i < 5; i++) {
            swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: 1e18,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                })
            );
        }
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("~> ~ file: TrailHookTest.t.sol:185 ~ test_trailingOrderExecution ~ currentTick:", currentTick);

        // Check that the order is not executed yet
        (uint256 inputAmount,,,,) = hook.trailingOrders(key.toId(), orderId);
        assertEq(inputAmount, amount, "Order should not be executed yet");

        // Perform more swaps to trigger the order execution
        for (uint256 i = 0; i < 5; i++) {
            swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false,
                    amountSpecified: 1e18,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                })
            );
        }
        (, currentTick,,) = manager.getSlot0(key.toId());
        console.log("~> ~ file: TrailHookTest.t.sol:185 ~ test_trailingOrderExecution ~ currentTick:", currentTick);

        // // Check that the order has been executed
        // (inputAmount,,,,) = hook.trailingOrders(key.toId(), orderId);
        // assertEq(inputAmount, 0, "Order should be executed");

        // // Verify token balances have changed
        // uint256 finalToken0Balance = token0.balanceOfSelf();
        // uint256 finalToken1Balance = token1.balanceOfSelf();

        // assertTrue(finalToken0Balance < initialToken0Balance, "Token0 balance should decrease");
        // assertTrue(finalToken1Balance > initialToken1Balance, "Token1 balance should increase");

        // // Check that the ERC-1155 token for the order has been burned
        // uint256 positionId = hook.getPositionId(key, orderId);
        // uint256 tokenBalance = hook.balanceOf(address(this), positionId);
        // assertEq(tokenBalance, 0, "ERC-1155 token should be burned after order execution");

        // // After performing swaps
        // (uint256 remainingAmount,,,,) = hook.trailingOrders(key.toId(), orderId);
        // assertEq(remainingAmount, 0, "Order should be executed");
    }

    // Helper functions
    function setPoolTick(int24 targetTick) public {
        (, int24 currentTick,,) = manager.getSlot0(key.toId());
        bool zeroForOne = targetTick < currentTick;

        // Perform swaps until we reach the target tick
        while ((zeroForOne && currentTick > targetTick) || (!zeroForOne && currentTick < targetTick)) {
            int256 amountSpecified = zeroForOne ? -int256(1e18) : int256(1e18); // Swap a small amount each time

            BalanceDelta delta = swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1 // TODO: review this
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
