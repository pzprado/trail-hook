// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

// @author: PPrado
// @title: TrailHook

/**
 * For placing trailing orders, we need:
 * 1. Pool the order is for (PoolKey)
 * 2. Which token to sell (or buy)
 * 3. Amount of tokens to sell (or buy)
 * 4. Trailing distance (in ticks or percentage)
 * 5. Initial reference price (usually the current market price)
 * 6. Direction of the order (sell or buy)
 */
contract TrailHook is BaseHook, ERC1155 {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using FixedPointMathLib for uint256;

    struct TrailingOrder {
        uint256 inputAmount;
        int24 trailingDistance;
        int24 lastTrackedTick;
        bool zeroForOne;
        uint256 minOutputAmount; // New field for slippage protection
    }

    // Storage
    mapping(PoolId poolId => int24 lastTick) public lastTicks;
    mapping(PoolId poolId => mapping(uint256 orderId => TrailingOrder)) public trailingOrders;
    mapping(uint256 orderId => address owner) public orderOwners;

    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    uint256 public nextOrderId = 1;

    // Events
    event TrailingOrderPlaced(
        uint256 indexed orderId, address indexed owner, int24 trailingDistance, uint256 inputAmount, bool zeroForOne
    );
    event TrailingOrderExecuted(uint256 indexed orderId, int24 executionTick, uint256 outputAmount);
    event TrailingOrderCancelled(uint256 indexed orderId);
    event LastTrackedTickUpdated(uint256 indexed orderId, int24 newLastTrackedTick);

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();
    error Unauthorized();

    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // TRUE
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true, // TRUE
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        updateAndExecuteTrailingOrders(key, currentTick, lastTick);

        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // Core Hook External Functions
    function placeTrailingOrder(
        PoolKey calldata key,
        int24 trailingDistance,
        bool zeroForOne,
        uint256 inputAmount,
        uint256 minOutputAmount
    ) external returns (uint256 orderId) {
        orderId = nextOrderId++;
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());

        trailingOrders[key.toId()][orderId] = TrailingOrder({
            inputAmount: inputAmount,
            trailingDistance: trailingDistance,
            lastTrackedTick: currentTick,
            zeroForOne: zeroForOne,
            minOutputAmount: minOutputAmount
        });

        orderOwners[orderId] = msg.sender;

        // Mint claim tokens to user equal to their `inputAmount`
        uint256 positionId = getPositionId(key, orderId);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Transfer tokens to the contract
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        emit TrailingOrderPlaced(orderId, msg.sender, trailingDistance, inputAmount, zeroForOne);
    }

    function cancelTrailingOrder(PoolKey calldata key, uint256 orderId) external {
        if (orderOwners[orderId] != msg.sender) revert Unauthorized();

        TrailingOrder memory order = trailingOrders[key.toId()][orderId];
        if (order.inputAmount == 0) revert InvalidOrder();

        delete trailingOrders[key.toId()][orderId];
        delete orderOwners[orderId];

        uint256 positionId = getPositionId(key, orderId);
        uint256 positionTokens = balanceOf(msg.sender, positionId);

        claimTokensSupply[positionId] -= positionTokens;
        _burn(msg.sender, positionId, positionTokens);

        // Return input tokens to the user
        Currency token = order.zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, order.inputAmount);

        emit TrailingOrderCancelled(orderId);
    }

    function redeem(PoolKey calldata key, uint256 orderId, uint256 inputAmountToClaimFor) external {
        uint256 positionId = getPositionId(key, orderId);

        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        TrailingOrder memory order = trailingOrders[key.toId()][orderId];
        Currency token = order.zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    // Internal Functions
    function updateAndExecuteTrailingOrders(PoolKey calldata key, int24 currentTick, int24 lastTick) internal {
        PoolId poolId = key.toId();
        uint256 orderId = 1;

        while (orderId < nextOrderId) {
            TrailingOrder storage order = trailingOrders[poolId][orderId];

            if (order.inputAmount == 0) {
                orderId++;
                continue;
            }

            bool shouldExecute = false;

            if (order.zeroForOne) {
                // For zeroForOne (selling token0), we execute when price goes up
                if (currentTick > order.lastTrackedTick) {
                    order.lastTrackedTick = currentTick;
                    emit LastTrackedTickUpdated(orderId, currentTick);
                } else if (currentTick <= order.lastTrackedTick - order.trailingDistance) {
                    shouldExecute = true;
                }
            } else {
                // For !zeroForOne (selling token1), we execute when price goes down
                if (currentTick < order.lastTrackedTick) {
                    order.lastTrackedTick = currentTick;
                    emit LastTrackedTickUpdated(orderId, currentTick);
                } else if (currentTick >= order.lastTrackedTick + order.trailingDistance) {
                    shouldExecute = true;
                }
            }

            if (shouldExecute) {
                executeOrder(key, orderId, order);
            }

            orderId++;
        }
    }

    function executeOrder(PoolKey calldata key, uint256 orderId, TrailingOrder storage order) internal {
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: order.zeroForOne,
                amountSpecified: -int256(order.inputAmount),
                sqrtPriceLimitX96: 0 // Market execution
            })
        );

        uint256 outputAmount = order.zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));
        require(outputAmount >= order.minOutputAmount, "Slippage tolerance exceeded");

        uint256 positionId = getPositionId(key, orderId);

        claimableOutputTokens[positionId] += outputAmount;

        emit TrailingOrderExecuted(orderId, order.lastTrackedTick, outputAmount);

        // Clear the order after execution
        delete trailingOrders[key.toId()][orderId];
        delete orderOwners[orderId];
    }

    function swapAndSettleBalances(PoolKey calldata key, IPoolManager.SwapParams memory params)
        internal
        returns (BalanceDelta)
    {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency);
        currency.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

    // Helper Functions
    function getPositionId(PoolKey calldata key, uint256 orderId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), orderId)));
    }
}
