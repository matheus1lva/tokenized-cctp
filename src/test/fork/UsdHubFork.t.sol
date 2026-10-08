// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";

import {TesouroRemoteStrategyFactory} from "../../remote/TesouroRemoteStrategyFactory.sol";
import {TesouroRemoteStrategy} from "../../remote/TesouroRemoteStrategy.sol";
import {OraclePricedHoldStrategy} from "../../local/OraclePricedHoldStrategy.sol";
import {CCTPHelpers} from "../../libraries/CCTPHelpers.sol";
import {TesouroAddresses} from "../../libraries/TesouroAddresses.sol";
import {IAggregatorV3} from "../../interfaces/oracles/IAggregatorV3.sol";

/// @notice Checks the hardcoded Base addresses against live state.
/// @dev Skipped when BASE_RPC_URL is not set.
contract TesouroBaseForkTest is Test {
    bool internal skipFork;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipFork = true; // no RPC: tests return early
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_fork_baseAddressesAndRemoteDeploy() public {
        if (skipFork) return;
        IAggregatorV3 tesouroFeed = IAggregatorV3(
            TesouroAddresses.BASE_REDSTONE_TESOURO_USD
        );
        IAggregatorV3 brlFeed = IAggregatorV3(
            TesouroAddresses.BASE_CHAINLINK_BRL_USD
        );
        assertEq(tesouroFeed.decimals(), 8);
        assertEq(brlFeed.decimals(), 8);
        assertEq(brlFeed.description(), "BRL / USD");

        address governance = address(0xA11CE);
        address hub = address(0x1234);
        TesouroRemoteStrategyFactory f = new TesouroRemoteStrategyFactory(
            governance,
            CCTPHelpers.BASE_USDC,
            CCTPHelpers.TOKEN_MESSENGER,
            CCTPHelpers.MESSAGE_TRANSMITTER
        );

        vm.prank(governance);
        TesouroRemoteStrategy r = TesouroRemoteStrategy(
            f.deployRemoteStrategy(
                CCTPHelpers.ETHEREUM_DOMAIN,
                hub,
                TesouroRemoteStrategyFactory.RemoteParams({
                    tesouro: TesouroAddresses.BASE_TESOURO,
                    tesouroUsdOracle: TesouroAddresses.BASE_REDSTONE_TESOURO_USD,
                    brlUsdOracle: TesouroAddresses.BASE_CHAINLINK_BRL_USD,
                    router: address(0)
                })
            )
        );

        assertEq(r.HELD_TOKEN().decimals(), 6);
        assertEq(r.HELD_TOKEN().symbol(), "TESOURO");
        assertGt(r.fxReferencePrice(), 0);
        assertTrue(r.isPriceFresh());
        (uint256 price, ) = r.latestPrice();

        // 1,000 TESOURO valued at the live RedStone price.
        deal(TesouroAddresses.BASE_TESOURO, address(r), 1_000e6);
        assertEq(r.valueOfDeployedAssets(), (1_000e6 * price) / 1e8);
        assertEq(r.maxUsdExposure(), 75_000e6);
    }
}

/// @notice Checks the Ondo tokens + Chainlink feeds on Ethereum.
/// @dev Skipped when ETH_RPC_URL is not set.
contract OndoHoldForkTest is Test {
    bool internal skipFork;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            skipFork = true; // no RPC: tests return early
            return;
        }
        vm.createSelectFork(rpc);
    }

    function test_fork_ondoFeeds() public {
        if (skipFork) return;
        _check(
            TesouroAddresses.ETH_SPYON,
            TesouroAddresses.ETH_CHAINLINK_SPYON_USD,
            "SPYon / USD (Ondo API)"
        );
        _check(
            TesouroAddresses.ETH_QQQON,
            TesouroAddresses.ETH_CHAINLINK_QQQON_USD,
            "QQQon / USD (Ondo API)"
        );
    }

    function _check(
        address _token,
        address _feed,
        string memory _description
    ) internal {
        assertEq(IAggregatorV3(_feed).description(), _description);
        OraclePricedHoldStrategy s = new OraclePricedHoldStrategy(
            CCTPHelpers.ETHEREUM_USDC,
            "hold",
            _token,
            _feed,
            address(0)
        );
        assertEq(s.TOKEN().decimals(), 18);
        if (!s.isPriceFresh()) return; // weekend / feed gap
        (uint256 price, ) = s.latestPrice();
        deal(_token, address(s), 1e18);
        // 1 token at an 8-decimal price -> 6-decimal USDC value
        assertEq(s.valueOfToken(), price / 100);
    }
}
