// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHealthCheck, ERC20} from "@periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {PendleSwapper} from "@periphery/swappers/PendleSwapper.sol";
import {IPMarket, IStandardizedYield, IPPrincipalToken, IPYieldToken} from "@periphery/interfaces/Pendle/IPendle.sol";

import {IPendlePYLpOracle} from "../interfaces/pendle/IPendlePYLpOracle.sol";

/// @title PendlePTHoldStrategy (Ethereum, local)
/// @notice Buys one Pendle PT with USDC and holds it to maturity. No loop,
///         no borrow, no roll. Valued with Pendle's PY/LP oracle TWAP
///         (`getPtToAssetRate`). After expiry, tend() redeems PT to USDC.
/// @dev Reuses Yearn's periphery PendleSwapper for buy/sell/redeem.
///      Requirements on the chosen market (checked/assumed):
///       - USDC is a valid SY token in/out (checked in the constructor),
///       - the SY accounting asset is USD at 1:1 with USDC (ASSUMED; pick a
///         USDC-denominated PT, otherwise valuation is wrong),
///       - the market oracle cardinality is initialised for `twapDuration`
///         (check `getOracleState` off-chain before deploying).
///      For rolling PTs see jrfrantz/PendlePtCompounderStrategy; this one is
///      intentionally minimal.
contract PendlePTHoldStrategy is BaseHealthCheck, PendleSwapper {
    event UpdatedSlippageBps(uint256 slippageBps);
    event UpdatedTwapDuration(uint32 twapDuration);

    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    address public immutable MARKET;
    ERC20 public immutable PT;
    IPendlePYLpOracle public immutable PT_ORACLE;

    uint256 internal immutable PT_SCALE;
    uint256 internal immutable ASSET_SCALE;

    uint32 public twapDuration;

    uint256 public slippageBps;

    constructor(
        address _asset,
        string memory _name,
        address _market,
        address _ptOracle,
        address _pendleRouter
    ) BaseHealthCheck(_asset, _name) {
        require(
            _market != address(0) && _ptOracle != address(0),
            "ZeroAddress"
        );

        (IStandardizedYield _sy, IPPrincipalToken _pt, ) = IPMarket(_market)
            .readTokens();
        require(!IPMarket(_market).isExpired(), "Expired");
        require(_contains(_sy.getTokensIn(), _asset), "!tokenIn");
        require(_contains(_sy.getTokensOut(), _asset), "!tokenOut");

        MARKET = _market;
        PT = ERC20(address(_pt));
        PT_ORACLE = IPendlePYLpOracle(_ptOracle);
        PT_SCALE = 10 ** ERC20(address(_pt)).decimals();
        ASSET_SCALE = 10 ** ERC20(_asset).decimals();

        if (_pendleRouter != address(0)) pendleRouter = _pendleRouter;
        _setMarket(address(_pt), _market);

        twapDuration = 900; // 15 min
        slippageBps = 50; // 0.5%
    }

    /*//////////////////////////////////////////////////////////////
                            MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function setSlippageBps(uint256 _slippageBps) external onlyManagement {
        require(_slippageBps <= MAX_SLIPPAGE_BPS, "TooHigh");
        slippageBps = _slippageBps;
        emit UpdatedSlippageBps(_slippageBps);
    }

    function setTwapDuration(uint32 _twapDuration) external onlyManagement {
        require(_twapDuration > 0, "Zero");
        twapDuration = _twapDuration;
        emit UpdatedTwapDuration(_twapDuration);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function isExpired() public view returns (bool) {
        return IPMarket(MARKET).isExpired();
    }

    /// @notice PT -> accounting asset rate (1e18).
    function ptRate() public view returns (uint256) {
        return PT_ORACLE.getPtToAssetRate(MARKET, twapDuration);
    }

    function balanceOfAsset() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function balanceOfPt() public view returns (uint256) {
        return PT.balanceOf(address(this));
    }

    function valueOfPt() public view returns (uint256) {
        uint256 bal = balanceOfPt();
        if (bal == 0) return 0;
        return _ptToAsset(bal, ptRate());
    }

    /// @notice No new PT after expiry.
    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        if (isExpired()) return 0;
        return super.availableDepositLimit(_owner);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _deployFunds(uint256 _amount) internal virtual override {
        if (_amount == 0 || isExpired()) return;
        uint256 minPt = (_assetToPt(_amount, ptRate(), Math.Rounding.Down) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        _pendleSwapFrom(address(asset), address(PT), _amount, minPt);
    }

    function _freeFunds(uint256 _amount) internal virtual override {
        _sellPtForAssets(_amount);
    }

    function _harvestAndReport()
        internal
        virtual
        override
        returns (uint256 _totalAssets)
    {
        _totalAssets = balanceOfAsset() + valueOfPt();
    }

    /// @dev After maturity redeem everything to USDC.
    function _tend(uint256) internal virtual override {
        if (!isExpired()) return;
        uint256 bal = balanceOfPt();
        if (bal == 0) return;
        uint256 minOut = (_ptToAsset(bal, ptRate()) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        _pendleSwapFrom(address(PT), address(asset), bal, minOut);
    }

    function _tendTrigger() internal view virtual override returns (bool) {
        return isExpired() && balanceOfPt() > 0;
    }

    function _emergencyWithdraw(uint256 _amount) internal virtual override {
        _sellPtForAssets(_amount);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _sellPtForAssets(uint256 _amount) internal {
        if (_amount == 0) return;
        uint256 rate = ptRate();
        uint256 toSell = Math.min(
            balanceOfPt(),
            _assetToPt(_amount, rate, Math.Rounding.Up)
        );
        if (toSell == 0) return;
        uint256 minOut = (_ptToAsset(toSell, rate) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        _pendleSwapFrom(address(PT), address(asset), toSell, minOut);
    }

    function _ptToAsset(
        uint256 _pt,
        uint256 _rate
    ) internal view returns (uint256) {
        return Math.mulDiv(_pt, _rate * ASSET_SCALE, PT_SCALE * 1e18);
    }

    function _assetToPt(
        uint256 _assets,
        uint256 _rate,
        Math.Rounding _rounding
    ) internal view returns (uint256) {
        return
            Math.mulDiv(
                _assets,
                PT_SCALE * 1e18,
                _rate * ASSET_SCALE,
                _rounding
            );
    }

    function _contains(
        address[] memory _list,
        address _item
    ) internal pure returns (bool) {
        for (uint256 i; i < _list.length; ++i) {
            if (_list[i] == _item) return true;
        }
        return false;
    }
}
