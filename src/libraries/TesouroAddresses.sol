// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/// @notice Addresses used by the USD hub / TESOURO deployment.
/// @dev Every address here was checked on-chain on 2026-10-08 (see
///      docs/USD_HUB_TESOURO.md for the exact source of each one).
///      Swap routes are deliberately NOT listed: no TESOURO/BRZ/USDC route
///      was verified, so the router stays a constructor/env argument.
library TesouroAddresses {
    /*//////////////////////////////////////////////////////////////
                                BASE (8453)
    //////////////////////////////////////////////////////////////*/

    /// @notice Etherfuse TESOURO, 6 decimals (name/symbol/decimals read via cast).
    address internal constant BASE_TESOURO =
        0x7ceE47e7B7CD04CF984e8Dd86C42595B5771A9B2;

    /// @notice RedStone "Price Feed for TESOURO" (TESOURO/USD, 8 decimals).
    /// @dev Listed in redstone-oracles-monorepo relayer manifest
    ///      baseMultiFeed.json (heartbeat 24h, deviation 0.1%).
    address internal constant BASE_REDSTONE_TESOURO_USD =
        0xb67047eDF6204F4C81333248dA71F8387050790C;

    /// @notice Chainlink BRL / USD on Base (8 decimals, heartbeat 1h, 0.1%).
    address internal constant BASE_CHAINLINK_BRL_USD =
        0x0b0E64c05083FdF9ED7C5D3d8262c4216eFc9394;

    /*//////////////////////////////////////////////////////////////
                              ETHEREUM (1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Ondo "SPDR S&P 500 ETF (Ondo Tokenized)" SPYon, 18 decimals.
    address internal constant ETH_SPYON =
        0xFeDC5f4a6c38211c1338aa411018DFAf26612c08;

    /// @notice Ondo "Invesco QQQ (Ondo Tokenized)" QQQon, 18 decimals.
    address internal constant ETH_QQQON =
        0x0e397938C1Aa0680954093495B70A9F5e2249aBa;

    /// @notice Chainlink "SPYon / USD (Ondo API)" proxy, 8 decimals, 24/5.
    address internal constant ETH_CHAINLINK_SPYON_USD =
        0x6EcC1b902dB35eAFE95332443802774Fd1D72576;

    /// @notice Chainlink "QQQon / USD (Ondo API)" proxy, 8 decimals, 24/5.
    address internal constant ETH_CHAINLINK_QQQON_USD =
        0xE5DF423251c67D85B2D70787Af76069d96BC4D4C;

    /// @notice Pendle Router V4 (pendle-core-v2-public deployments/1-core.json).
    address internal constant ETH_PENDLE_ROUTER =
        0x888888888889758F76e7103c6CbF23ABbF58F946;

    /// @notice Pendle pyYtLpOracle (pendle-core-v2-public deployments/1-core.json).
    address internal constant ETH_PENDLE_PY_LP_ORACLE =
        0x5542be50420E88dd7D5B4a3D488FA6ED82F6DAc2;

    /// @notice Yearn V3 VaultFactory 3.0.4 (TokenizedStrategy.FACTORY()).
    address internal constant ETH_YEARN_VAULT_FACTORY =
        0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
}
