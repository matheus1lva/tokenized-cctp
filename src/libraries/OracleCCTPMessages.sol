// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Message formats exchanged between OracleCCTPStrategy (hub) and
///         BaseOracleRemoteStrategy (remote) over CCTP `sendMessage`.
/// @dev Remote -> hub report (128 bytes):
///        abi.encode(totalAssets, timestamp, price, oracleUpdatedAt)
///      Hub -> remote withdraw request (96 bytes):
///        abi.encode(MSG_WITHDRAW_REQUEST, amount, timestamp)
///      The legacy repo format (totalAssets, timestamp) is 64 bytes and is
///      intentionally NOT accepted by the oracle hub, so a misconfigured
///      counterpart cannot silently skip the price checks.
library OracleCCTPMessages {
    uint256 internal constant REPORT_LENGTH = 128;
    uint256 internal constant WITHDRAW_REQUEST_LENGTH = 96;

    uint8 internal constant MSG_WITHDRAW_REQUEST = 1;

    function encodeReport(
        uint256 _totalAssets,
        uint256 _timestamp,
        uint256 _price,
        uint256 _oracleUpdatedAt
    ) internal pure returns (bytes memory) {
        return abi.encode(_totalAssets, _timestamp, _price, _oracleUpdatedAt);
    }

    function decodeReport(
        bytes calldata _body
    )
        internal
        pure
        returns (
            uint256 totalAssets,
            uint256 timestamp,
            uint256 price,
            uint256 oracleUpdatedAt
        )
    {
        require(_body.length == REPORT_LENGTH, "InvalidReportLength");
        (totalAssets, timestamp, price, oracleUpdatedAt) = abi.decode(
            _body,
            (uint256, uint256, uint256, uint256)
        );
    }

    function encodeWithdrawRequest(
        uint256 _amount,
        uint256 _timestamp
    ) internal pure returns (bytes memory) {
        return abi.encode(MSG_WITHDRAW_REQUEST, _amount, _timestamp);
    }

    function decodeWithdrawRequest(
        bytes calldata _body
    ) internal pure returns (uint256 amount, uint256 timestamp) {
        require(
            _body.length == WITHDRAW_REQUEST_LENGTH,
            "InvalidRequestLength"
        );
        uint8 messageType;
        (messageType, amount, timestamp) = abi.decode(
            _body,
            (uint8, uint256, uint256)
        );
        require(messageType == MSG_WITHDRAW_REQUEST, "UnknownMessage");
    }
}
