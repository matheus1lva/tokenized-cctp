// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaseOracleRemoteStrategy} from "./BaseOracleRemoteStrategy.sol";
import {IAggregatorV3} from "../interfaces/oracles/IAggregatorV3.sol";
import {OracleLib} from "../libraries/OracleLib.sol";

/// @title TesouroRemoteStrategy (Base)
/// @notice Holds Etherfuse TESOURO on Base, funded with USDC bridged from the
///         Ethereum hub via CCTP, with a hard USD exposure ceiling and an
///         optional BRL/USD stop.
/// @dev Ceiling: buys are capped so the oracle value of TESOURO held never
///      goes above `maxUsdExposure`. Idle USDC that cannot be deployed is
///      bridged back to the hub on report/tend. If price appreciation (or a
///      lower ceiling) pushes the position above the ceiling by more than
///      `ceilingBufferBps`, tend sells the surplus and bridges it back.
///
///      FX stop: if BRL/USD (Chainlink) falls more than `fxStopBps` below
///      `fxReferencePrice`, anyone can call `fxUnwind()`, which sells
///      TESOURO to USDC (in chunks of `fxUnwindChunk`), bridges it to the hub
///      and blocks new buys until governance calls `resetFxStop()`.
///
///      TODO(router): the swap route (Curve TESOURO/BRZ on Base, then
///      BRZ -> USDC) is NOT verified. `router` must be an adapter
///      implementing IOracleSwapRouter, set at deploy or via setRouter().
contract TesouroRemoteStrategy is BaseOracleRemoteStrategy {
    event UpdatedMaxUsdExposure(uint256 maxUsdExposure);

    event UpdatedCeilingBufferBps(uint256 ceilingBufferBps);

    event UpdatedFxParams(
        uint256 fxStopBps,
        uint256 fxMaxStaleness,
        uint256 fxUnwindChunk
    );

    event UpdatedFxReference(uint256 fxReferencePrice);

    event FxStopSet(bool fxStopped);

    event FxUnwound(uint256 heldSold, uint256 assetsBridged, uint256 fxPrice);

    event CeilingTrimmed(uint256 assetsFreed);

    /// @notice BRL/USD oracle. Zero disables the FX stop.
    IAggregatorV3 public immutable FX_ORACLE;

    /// @notice Max USD (asset units, USDC 6 decimals) of TESOURO to hold.
    uint256 public maxUsdExposure;

    /// @notice Tolerance above the ceiling before tend trims the position.
    uint256 public ceilingBufferBps;

    /// @notice BRL/USD drawdown vs reference that arms the stop (bps).
    uint256 public fxStopBps;

    /// @notice Reference BRL/USD price (FX_ORACLE decimals).
    uint256 public fxReferencePrice;

    /// @notice Max age of the BRL/USD answer.
    uint256 public fxMaxStaleness;

    /// @notice Max TESOURO sold per fxUnwind() call (thin Curve pool).
    uint256 public fxUnwindChunk;

    /// @notice Once set, no new TESOURO is bought until governance resets.
    bool public fxStopped;

    constructor(
        address _asset,
        address _governance,
        address _tokenMessenger,
        address _messageTransmitter,
        uint32 _sourceDomain,
        address _remoteCounterpart,
        address _tesouro,
        address _tesouroUsdOracle,
        address _brlUsdOracle,
        address _router
    )
        BaseOracleRemoteStrategy(
            _asset,
            _governance,
            _tokenMessenger,
            _messageTransmitter,
            _sourceDomain,
            _remoteCounterpart,
            _tesouro,
            _tesouroUsdOracle,
            _router
        )
    {
        maxUsdExposure = 75_000 * ASSET_SCALE; // $75k
        ceilingBufferBps = 200; // 2%
        fxStopBps = 1_000; // 10%
        fxMaxStaleness = 2 hours; // Chainlink BRL/USD Base heartbeat is 1h
        fxUnwindChunk = type(uint256).max;

        FX_ORACLE = IAggregatorV3(_brlUsdOracle);
        if (_brlUsdOracle != address(0)) {
            (fxReferencePrice, ) = OracleLib.readPrice(
                FX_ORACLE,
                fxMaxStaleness
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function setMaxUsdExposure(
        uint256 _maxUsdExposure
    ) external onlyGovernance {
        maxUsdExposure = _maxUsdExposure;
        emit UpdatedMaxUsdExposure(_maxUsdExposure);
    }

    function setCeilingBufferBps(
        uint256 _ceilingBufferBps
    ) external onlyGovernance {
        require(_ceilingBufferBps <= MAX_BPS, "TooHigh");
        ceilingBufferBps = _ceilingBufferBps;
        emit UpdatedCeilingBufferBps(_ceilingBufferBps);
    }

    function setFxParams(
        uint256 _fxStopBps,
        uint256 _fxMaxStaleness,
        uint256 _fxUnwindChunk
    ) external onlyGovernance {
        require(_fxStopBps > 0 && _fxStopBps < MAX_BPS, "InvalidBps");
        require(_fxMaxStaleness > 0 && _fxUnwindChunk > 0, "Zero");
        fxStopBps = _fxStopBps;
        fxMaxStaleness = _fxMaxStaleness;
        fxUnwindChunk = _fxUnwindChunk;
        emit UpdatedFxParams(_fxStopBps, _fxMaxStaleness, _fxUnwindChunk);
    }

    /// @notice Set the BRL/USD reference to the current oracle answer.
    function resetFxReference() external onlyGovernance {
        _resetFxReference();
    }

    /// @notice Manually arm/disarm the stop. Disarming also resets the
    ///         reference to the current BRL/USD price.
    function setFxStopped(bool _fxStopped) external onlyGovernance {
        fxStopped = _fxStopped;
        if (!_fxStopped && address(FX_ORACLE) != address(0)) {
            _resetFxReference();
        }
        emit FxStopSet(_fxStopped);
    }

    /// @notice Alias: resume buying after an FX stop and re-anchor the reference.
    function resetFxStop() external onlyGovernance {
        fxStopped = false;
        if (address(FX_ORACLE) != address(0)) _resetFxReference();
        emit FxStopSet(false);
    }

    function _resetFxReference() internal {
        require(address(FX_ORACLE) != address(0), "NoFxOracle");
        (uint256 price, ) = OracleLib.readPrice(FX_ORACLE, fxMaxStaleness);
        fxReferencePrice = price;
        emit UpdatedFxReference(price);
    }

    /*//////////////////////////////////////////////////////////////
                            FX STOP
    //////////////////////////////////////////////////////////////*/

    /// @notice True if BRL/USD dropped more than fxStopBps vs reference.
    /// @dev Returns false when the FX oracle is unset or stale.
    function fxStopTriggered() public view returns (bool) {
        if (address(FX_ORACLE) == address(0) || fxReferencePrice == 0) {
            return false;
        }
        (bool ok, uint256 price, ) = OracleLib.tryReadPrice(
            FX_ORACLE,
            fxMaxStaleness
        );
        if (!ok) return false;
        return
            price * MAX_BPS < fxReferencePrice * (MAX_BPS - fxStopBps);
    }

    /// @notice Sell TESOURO to USDC and bridge it to the hub.
    /// @dev Permissionless while the stop condition holds, or while a stop
    ///      is already in progress (`fxStopped`) so the unwind can be done in
    ///      chunks over several blocks. Buys stay blocked until governance
    ///      calls resetFxStop().
    function fxUnwind() external isReady {
        require(fxStopped || fxStopTriggered(), "FxNotTriggered");
        if (!fxStopped) {
            fxStopped = true;
            emit FxStopSet(true);
        }

        (uint256 price, ) = latestPrice();
        uint256 toSell = Math.min(balanceOfHeld(), fxUnwindChunk);
        if (toSell > 0) _sellHeld(toSell, price);

        uint256 idle = balanceOfAsset();
        if (idle > 0) {
            _bridgeAssets(idle);
            _reducePending(idle);
        }

        uint256 fxPrice;
        if (address(FX_ORACLE) != address(0)) {
            (, fxPrice, ) = OracleLib.tryReadPrice(FX_ORACLE, fxMaxStaleness);
        }
        emit FxUnwound(toSell, idle, fxPrice);

        _sendReport();
    }

    /*//////////////////////////////////////////////////////////////
                            CEILING
    //////////////////////////////////////////////////////////////*/

    /// @notice USDC that can still be deployed without crossing the ceiling.
    /// @dev Informational for keepers/hub config; deposits arrive by CCTP mint.
    function availableDepositLimit() public view returns (uint256) {
        return _maxBuy();
    }

    /// @notice Oracle value held above the ceiling (0 if under).
    function exposureAboveCeiling() public view returns (uint256) {
        uint256 deployed = valueOfDeployedAssets();
        return deployed > maxUsdExposure ? deployed - maxUsdExposure : 0;
    }

    function _maxBuy() internal view override returns (uint256) {
        if (fxStopped || isShutdown) return 0;
        uint256 deployed = valueOfDeployedAssets();
        return deployed >= maxUsdExposure ? 0 : maxUsdExposure - deployed;
    }

    /// @dev Idle USDC above the room left under the ceiling. With a router
    ///      set, report() has already pushed what fits, so whatever is still
    ///      idle beyond the room is bounced. Without a router the strategy
    ///      just holds USDC up to the ceiling. USDC reserved for a pending hub
    ///      request that gets bounced here also reduces that request.
    function _excessIdle() internal view override returns (uint256) {
        if (isShutdown) return 0;
        uint256 idle = balanceOfAsset();
        uint256 deployed = valueOfDeployedAssets();
        uint256 cap = fxStopped ? 0 : maxUsdExposure;
        uint256 room = cap > deployed ? cap - deployed : 0;
        return idle > room ? idle - room : 0;
    }

    function _overCeiling() internal view returns (bool) {
        uint256 deployed = valueOfDeployedAssets();
        return
            deployed * MAX_BPS > maxUsdExposure * (MAX_BPS + ceilingBufferBps);
    }

    /*//////////////////////////////////////////////////////////////
                                TEND
    //////////////////////////////////////////////////////////////*/

    /// @dev Push idle under the ceiling, trim above ceiling + buffer, bounce
    ///      excess USDC to the hub and report if anything was bridged.
    function _tend(uint256 _idleAssets) internal override {
        super._tend(_idleAssets);

        // Only move funds cross-chain when a fresh report can follow in the
        // same tx, so the hub never double counts bridged USDC.
        if (block.timestamp <= lastReport) return;

        if (_overCeiling()) {
            uint256 freed = _pullFunds(exposureAboveCeiling());
            emit CeilingTrimmed(freed);
        }

        if (_returnExcess() > 0) {
            lastReport = block.timestamp;
            _sendReport();
        }
    }

    function _tendTrigger() internal view override returns (bool) {
        if (isShutdown) return false;
        if (!isPriceFresh()) return false;
        if (balanceOfAsset() > amountToTend) return true;
        return _overCeiling();
    }
}
