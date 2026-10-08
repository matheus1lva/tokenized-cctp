// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CCTPStrategy} from "../CCTPStrategy.sol";
import {IAggregatorV3} from "../interfaces/oracles/IAggregatorV3.sol";
import {OracleLib} from "../libraries/OracleLib.sol";
import {OracleCCTPMessages} from "../libraries/OracleCCTPMessages.sol";

/// @title OracleCCTPStrategy (Ethereum hub)
/// @notice CCTPStrategy for a remote sleeve that holds a priced asset
///         (e.g. TESOURO on Base). Accepts the extended remote report
///         (totalAssets, timestamp, price, oracleUpdatedAt), rejects stale
///         reports, optionally cross-checks the price against a hub-side
///         oracle and can ask the remote to send USDC back.
/// @dev Rejections revert, so the CCTP nonce is not consumed: the relayer
///      can simply deliver a newer report later.
contract OracleCCTPStrategy is CCTPStrategy {
    event RemoteReportAccepted(
        uint256 totalAssets,
        uint256 timestamp,
        uint256 price,
        uint256 oracleUpdatedAt
    );

    event RemoteWithdrawalRequested(uint256 amount, uint256 timestamp);

    event UpdatedHubPriceOracle(address indexed oracle);

    event UpdatedReportParams(
        uint256 maxReportAge,
        uint256 maxOracleAge,
        uint256 maxPriceDeviationBps
    );

    event UpdatedMaxRemoteExposure(uint256 maxRemoteExposure);

    /// @notice Decimals of the price carried in remote reports.
    uint8 public immutable REPORT_PRICE_DECIMALS;

    /// @notice Optional hub-side oracle quoting the same pair as the remote
    ///         oracle (e.g. TESOURO/USD). Zero disables the deviation check.
    IAggregatorV3 public hubPriceOracle;

    /// @notice Max age (hub clock) of the remote report timestamp.
    uint256 public maxReportAge;

    /// @notice Max age (hub clock) of the remote oracle observation.
    uint256 public maxOracleAge;

    /// @notice Max |remote - hub| / hub price deviation, in bps.
    uint256 public maxPriceDeviationBps;

    /// @notice Hub-side cap on remoteAssets + idle (mirrors the remote ceiling).
    uint256 public maxRemoteExposure;

    /// @notice Last accepted remote oracle price and observation time.
    uint256 public lastReportedPrice;
    uint256 public lastReportedOracleUpdatedAt;

    constructor(
        address _asset,
        string memory _name,
        address _tokenMessenger,
        address _messageTransmitter,
        uint32 _remoteDomain,
        uint256 _remoteChainId,
        address _remoteCounterpart,
        address _depositer,
        uint8 _reportPriceDecimals
    )
        CCTPStrategy(
            _asset,
            _name,
            _tokenMessenger,
            _messageTransmitter,
            _remoteDomain,
            _remoteChainId,
            _remoteCounterpart,
            _depositer
        )
    {
        require(_reportPriceDecimals <= 36, "InvalidDecimals");
        REPORT_PRICE_DECIMALS = _reportPriceDecimals;

        maxReportAge = 1 days;
        maxOracleAge = 26 hours; // RedStone 24h heartbeat + CCTP latency
        maxPriceDeviationBps = 200; // 2%
        maxRemoteExposure = type(uint256).max;

        // Priced sleeves can legitimately report losses.
        _setLossLimitRatio(300); // 3%
    }

    /*//////////////////////////////////////////////////////////////
                            MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function setHubPriceOracle(address _oracle) external onlyManagement {
        hubPriceOracle = IAggregatorV3(_oracle);
        emit UpdatedHubPriceOracle(_oracle);
    }

    function setReportParams(
        uint256 _maxReportAge,
        uint256 _maxOracleAge,
        uint256 _maxPriceDeviationBps
    ) external onlyManagement {
        require(_maxReportAge > 0 && _maxOracleAge > 0, "Zero");
        require(_maxPriceDeviationBps <= MAX_BPS, "TooHigh");
        maxReportAge = _maxReportAge;
        maxOracleAge = _maxOracleAge;
        maxPriceDeviationBps = _maxPriceDeviationBps;
        emit UpdatedReportParams(
            _maxReportAge,
            _maxOracleAge,
            _maxPriceDeviationBps
        );
    }

    function setMaxRemoteExposure(
        uint256 _maxRemoteExposure
    ) external onlyManagement {
        maxRemoteExposure = _maxRemoteExposure;
        emit UpdatedMaxRemoteExposure(_maxRemoteExposure);
    }

    /*//////////////////////////////////////////////////////////////
                        HUB -> REMOTE REQUESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ask the remote strategy to bridge `_amount` USDC back.
    /// @dev The remote queues it in `pendingWithdrawal`; its keeper then
    ///      calls processPendingWithdrawal(). A relayer must deliver this
    ///      message on the remote chain (Circle attestation + receiveMessage).
    function requestRemoteWithdrawal(uint256 _amount) external onlyKeepers {
        require(_amount > 0, "ZeroAmount");
        require(_amount <= remoteAssets, "TooMuch");

        MESSAGE_TRANSMITTER.sendMessage(
            uint32(uint256(REMOTE_ID)),
            _addressToBytes32(REMOTE_COUNTERPART),
            bytes32(0),
            FINALITY_THRESHOLD_FINALIZED,
            OracleCCTPMessages.encodeWithdrawRequest(_amount, block.timestamp)
        );

        emit RemoteWithdrawalRequested(_amount, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        REMOTE -> HUB REPORTS
    //////////////////////////////////////////////////////////////*/

    function handleReceiveFinalizedMessage(
        uint32 _sourceDomain,
        bytes32 _sender,
        uint32 _finalityThresholdExecuted,
        bytes calldata _messageBody
    ) external virtual override returns (bool) {
        require(
            msg.sender == address(MESSAGE_TRANSMITTER),
            "InvalidTransmitter"
        );
        require(_sourceDomain == uint32(uint256(REMOTE_ID)), "InvalidDomain");
        require(
            _sender == _addressToBytes32(REMOTE_COUNTERPART),
            "InvalidSender"
        );
        require(_messageBody.length > 0, "EmptyMessage");
        require(
            _finalityThresholdExecuted >= FINALITY_THRESHOLD_FINALIZED,
            "InvalidFinalityThreshold"
        );

        (
            uint256 totalAssets,
            uint256 timestamp,
            uint256 price,
            uint256 oracleUpdatedAt
        ) = OracleCCTPMessages.decodeReport(_messageBody);

        _validateReport(timestamp, price, oracleUpdatedAt);

        // Only record the price if the report is newer than the watermark.
        if (timestamp > lastRemoteAssetsReport) {
            lastReportedPrice = price;
            lastReportedOracleUpdatedAt = oracleUpdatedAt;
            emit RemoteReportAccepted(
                totalAssets,
                timestamp,
                price,
                oracleUpdatedAt
            );
        }

        _handleIncomingMessage(totalAssets, timestamp);

        return true;
    }

    function _validateReport(
        uint256 _timestamp,
        uint256 _price,
        uint256 _oracleUpdatedAt
    ) internal view virtual {
        require(_price > 0, "BadPrice");
        require(_oracleUpdatedAt <= _timestamp, "InvalidOracleTimestamp");
        require(
            OracleLib.isFresh(_timestamp, maxReportAge),
            "StaleReport"
        );
        require(
            OracleLib.isFresh(_oracleUpdatedAt, maxOracleAge),
            "StaleReportPrice"
        );

        IAggregatorV3 _hubOracle = hubPriceOracle;
        if (address(_hubOracle) == address(0)) return;

        (uint256 hubPrice, ) = OracleLib.readPrice(_hubOracle, maxOracleAge);
        uint256 remote18 = _to18(_price, REPORT_PRICE_DECIMALS);
        uint256 hub18 = _to18(hubPrice, _hubOracle.decimals());
        uint256 diff = remote18 > hub18 ? remote18 - hub18 : hub18 - remote18;
        require(
            diff * MAX_BPS <= hub18 * maxPriceDeviationBps,
            "PriceDeviation"
        );
    }

    function _to18(
        uint256 _value,
        uint8 _decimals
    ) internal pure returns (uint256) {
        if (_decimals == 18) return _value;
        if (_decimals < 18) return _value * 10 ** (18 - _decimals);
        return _value / 10 ** (_decimals - 18);
    }

    /*//////////////////////////////////////////////////////////////
                            LIMITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Depositer-only, and capped so remoteAssets + idle stays
    ///         under `maxRemoteExposure` (set it to the remote USD ceiling).
    function availableDepositLimit(
        address _owner
    ) public view virtual override returns (uint256) {
        uint256 limit = super.availableDepositLimit(_owner);
        if (limit == 0) return 0;
        uint256 current = remoteAssets + balanceOfAsset();
        uint256 room = maxRemoteExposure > current
            ? maxRemoteExposure - current
            : 0;
        return Math.min(limit, room);
    }
}
