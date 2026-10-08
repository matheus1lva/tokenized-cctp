// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";

import {IAggregatorV3} from "../interfaces/oracles/IAggregatorV3.sol";
import {IOracleSwapRouter} from "../interfaces/swappers/IOracleSwapRouter.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/// @title OraclePricedHoldStrategy (Ethereum, local)
/// @notice Generic USDC -> TOKEN buy-and-hold sleeve valued by an
///         AggregatorV3 feed (e.g. Ondo SPYon / QQQon with Chainlink
///         "SPYon / USD (Ondo API)" and "QQQon / USD (Ondo API)").
/// @dev Freshness guard: equity feeds are 24/5 with a 24h heartbeat. When
///      the feed is older than `maxStaleness`, deposits are closed, withdraws
///      are limited to idle USDC and report() reverts, so nobody can enter
///      or exit at a stale (weekend) price. No borrow, no loop.
///
///      TODO(router): `router` is an IOracleSwapRouter adapter (e.g. a
///      Uniswap pool or Ondo GM mint/redeem wrapper). None is verified; with
///      router == 0 the strategy just holds USDC.
contract OraclePricedHoldStrategy is BaseHealthCheck {
    using SafeERC20 for ERC20;

    event UpdatedRouter(address indexed router);
    event UpdatedSlippageBps(uint256 slippageBps);
    event UpdatedMaxStaleness(uint256 maxStaleness);

    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice Token held (e.g. SPYon).
    ERC20 public immutable TOKEN;

    /// @notice TOKEN / USD feed.
    IAggregatorV3 public immutable ORACLE;

    uint256 internal immutable TOKEN_SCALE;
    uint256 internal immutable ORACLE_SCALE;
    uint256 internal immutable ASSET_SCALE;

    IOracleSwapRouter public router;

    uint256 public slippageBps;

    uint256 public maxStaleness;

    constructor(
        address _asset,
        string memory _name,
        address _token,
        address _oracle,
        address _router
    ) BaseHealthCheck(_asset, _name) {
        require(_token != address(0) && _oracle != address(0), "ZeroAddress");
        require(_token != _asset, "InvalidToken");

        TOKEN = ERC20(_token);
        ORACLE = IAggregatorV3(_oracle);
        TOKEN_SCALE = 10 ** ERC20(_token).decimals();
        ORACLE_SCALE = 10 ** IAggregatorV3(_oracle).decimals();
        ASSET_SCALE = 10 ** ERC20(_asset).decimals();

        router = IOracleSwapRouter(_router);
        slippageBps = 100; // 1%
        maxStaleness = 26 hours; // 24h heartbeat + buffer

        // Equity sleeves move; allow configurable drawdowns per report.
        _setLossLimitRatio(500); // 5%
    }

    /*//////////////////////////////////////////////////////////////
                            MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function setRouter(address _router) external onlyManagement {
        router = IOracleSwapRouter(_router);
        emit UpdatedRouter(_router);
    }

    function setSlippageBps(uint256 _slippageBps) external onlyManagement {
        require(_slippageBps <= MAX_SLIPPAGE_BPS, "TooHigh");
        slippageBps = _slippageBps;
        emit UpdatedSlippageBps(_slippageBps);
    }

    function setMaxStaleness(uint256 _maxStaleness) external onlyManagement {
        require(_maxStaleness > 0, "ZeroStaleness");
        maxStaleness = _maxStaleness;
        emit UpdatedMaxStaleness(_maxStaleness);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function latestPrice()
        public
        view
        returns (uint256 price, uint256 updatedAt)
    {
        return OracleLib.readPrice(ORACLE, maxStaleness);
    }

    function isPriceFresh() public view returns (bool ok) {
        (ok, , ) = OracleLib.tryReadPrice(ORACLE, maxStaleness);
    }

    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfToken() public view returns (uint256) {
        return TOKEN.balanceOf(address(this));
    }

    /// @notice USDC value of TOKEN held (reverts if the feed is stale).
    function valueOfToken() public view returns (uint256) {
        uint256 bal = balanceOfToken();
        if (bal == 0) return 0;
        (uint256 price, ) = latestPrice();
        return _tokenToAsset(bal, price);
    }

    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (!isPriceFresh()) return 0;
        return super.availableDepositLimit(_owner);
    }

    function availableWithdrawLimit(
        address /*_owner*/
    ) public view virtual override returns (uint256) {
        if (!isPriceFresh()) return balanceOfAsset();
        return type(uint256).max;
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal virtual override {
        if (address(router) == address(0) || _amount == 0) return;
        (uint256 price, ) = latestPrice();
        uint256 minOut = (_assetToToken(_amount, price, Math.Rounding.Down) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        _swap(address(asset), address(TOKEN), _amount, minOut);
    }

    function _freeFunds(uint256 _amount) internal virtual override {
        _sellForAssets(_amount);
    }

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        _totalAssets = balanceOfAsset() + valueOfToken();
    }

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        _sellForAssets(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _sellForAssets(uint256 _amount) internal returns (uint256) {
        if (_amount == 0 || balanceOfToken() == 0) return 0;
        require(address(router) != address(0), "NoRouter");
        (uint256 price, ) = latestPrice();
        uint256 toSell = Math.min(
            balanceOfToken(),
            _assetToToken(_amount, price, Math.Rounding.Up)
        );
        if (toSell == 0) return 0;
        uint256 minOut = (_tokenToAsset(toSell, price) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        return _swap(address(TOKEN), address(asset), toSell, minOut);
    }

    function _swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minOut
    ) internal returns (uint256 received) {
        uint256 before = ERC20(_tokenOut).balanceOf(address(this));
        ERC20(_tokenIn).forceApprove(address(router), _amountIn);
        router.swap(_tokenIn, _tokenOut, _amountIn, _minOut, address(this));
        ERC20(_tokenIn).forceApprove(address(router), 0);
        received = ERC20(_tokenOut).balanceOf(address(this)) - before;
        require(received >= _minOut, "Slippage");
    }

    function _tokenToAsset(
        uint256 _tokens,
        uint256 _price
    ) internal view returns (uint256) {
        return
            Math.mulDiv(
                _tokens,
                _price * ASSET_SCALE,
                TOKEN_SCALE * ORACLE_SCALE
            );
    }

    function _assetToToken(
        uint256 _assets,
        uint256 _price,
        Math.Rounding _rounding
    ) internal view returns (uint256) {
        return
            Math.mulDiv(
                _assets,
                TOKEN_SCALE * ORACLE_SCALE,
                _price * ASSET_SCALE,
                _rounding
            );
    }
}
