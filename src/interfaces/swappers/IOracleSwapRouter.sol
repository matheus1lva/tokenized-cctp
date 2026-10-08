// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Minimal swap adapter used by the oracle priced strategies.
/// @dev Implementations wrap a concrete route (e.g. Curve TESOURO/BRZ then
///      BRZ -> USDC on Base, or a Uniswap pool for Ondo tokens on Ethereum).
///      The adapter pulls `_amountIn` of `_tokenIn` from msg.sender via
///      transferFrom and must send at least `_minAmountOut` of `_tokenOut`
///      to `_receiver`. Strategies never trust the return value alone and
///      re-check their own balance deltas against `_minAmountOut`.
interface IOracleSwapRouter {
    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver
    ) external returns (uint256 _amountOut);
}
