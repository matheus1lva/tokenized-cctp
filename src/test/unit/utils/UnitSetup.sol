// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {OracleCCTPStrategy} from "../../../origin/OracleCCTPStrategy.sol";
import {TesouroRemoteStrategy} from "../../../remote/TesouroRemoteStrategy.sol";
import {MockERC20, MockAggregator, MockMessageTransmitter, MockTokenMessenger, MockSwapRouter, MockVaultFactory} from "../mocks/Mocks.sol";

/// @notice Mock-only setup (no RPC). Ethereum and Base are simulated in the
///         same EVM with two sets of CCTP mocks; tests relay messages and
///         mint bridged USDC by hand.
contract UnitSetup is Test {
    address internal constant TOKENIZED_STRATEGY =
        0xD377919FA87120584B21279a491F82D5265A139c;

    uint32 internal constant ETHEREUM_DOMAIN = 0;
    uint32 internal constant BASE_DOMAIN = 6;
    uint32 internal constant FINALIZED = 2_000;

    address internal governance = address(0xA11CE);
    address internal keeper = address(0xBEEF);
    address internal remoteKeeper = address(0xB0B);
    address internal depositor = address(0xD0D0); // the Yearn vault
    address internal stranger = address(0xBAD);

    // "Ethereum"
    MockERC20 internal usdcEth;
    MockMessageTransmitter internal ethTransmitter;
    MockTokenMessenger internal ethMessenger;

    // "Base"
    MockERC20 internal usdcBase;
    MockERC20 internal tesouro;
    MockAggregator internal tesouroOracle; // TESOURO/USD 8 dec
    MockAggregator internal brlOracle; // BRL/USD 8 dec
    MockMessageTransmitter internal baseTransmitter;
    MockTokenMessenger internal baseMessenger;
    MockSwapRouter internal router;

    OracleCCTPStrategy internal hub;
    ITokenizedStrategy internal hubVault; // ERC4626 view of the hub
    TesouroRemoteStrategy internal remote;

    // $0.25 per TESOURO, BRL/USD 0.20
    int256 internal constant TESOURO_PRICE = 25_000_000;
    int256 internal constant BRL_PRICE = 20_000_000;

    function setUp() public virtual {
        vm.warp(1_790_000_000);

        _etchTokenizedStrategy();

        usdcEth = new MockERC20("USD Coin", "USDC", 6);
        ethTransmitter = new MockMessageTransmitter();
        ethMessenger = new MockTokenMessenger(address(ethTransmitter));

        usdcBase = new MockERC20("USD Coin", "USDC", 6);
        tesouro = new MockERC20("Etherfuse TESOURO", "TESOURO", 6);
        tesouroOracle = new MockAggregator(8, "TESOURO / USD", TESOURO_PRICE);
        brlOracle = new MockAggregator(8, "BRL / USD", BRL_PRICE);
        baseTransmitter = new MockMessageTransmitter();
        baseMessenger = new MockTokenMessenger(address(baseTransmitter));
        router = new MockSwapRouter();
        _setRouterPrice(TESOURO_PRICE);

        // Remote is deployed first, at nonce n; hub at nonce n + 1.
        address predictedHub = computeCreateAddress(
            address(this),
            vm.getNonce(address(this)) + 1
        );

        remote = new TesouroRemoteStrategy(
            address(usdcBase),
            governance,
            address(baseMessenger),
            address(baseTransmitter),
            ETHEREUM_DOMAIN,
            predictedHub,
            address(tesouro),
            address(tesouroOracle),
            address(brlOracle),
            address(router)
        );

        hub = new OracleCCTPStrategy(
            address(usdcEth),
            "Hub TESOURO",
            address(ethMessenger),
            address(ethTransmitter),
            BASE_DOMAIN,
            8453,
            address(remote),
            depositor,
            8
        );
        assertEq(address(hub), predictedHub, "hub prediction");

        hubVault = ITokenizedStrategy(address(hub));
        hubVault.setKeeper(keeper);

        vm.prank(governance);
        remote.setKeeper(remoteKeeper);

        vm.label(address(hub), "hub");
        vm.label(address(remote), "remote");
    }

    function _etchTokenizedStrategy() internal {
        MockVaultFactory factory = new MockVaultFactory();
        TokenizedStrategy impl = new TokenizedStrategy(address(factory));
        vm.etch(TOKENIZED_STRATEGY, address(impl).code);
    }

    /// @dev router swaps at exactly `_price` (8 dec) USD per TESOURO.
    function _setRouterPrice(int256 _price) internal {
        // usdc -> tesouro: 1e6 USDC buys 1e6 * 1e8 / price TESOURO base units
        router.setRate(
            address(usdcBase),
            address(tesouro),
            (1e18 * 1e8) / uint256(_price)
        );
        router.setRate(
            address(tesouro),
            address(usdcBase),
            (1e18 * uint256(_price)) / 1e8
        );
    }

    function _setTesouroPrice(int256 _price) internal {
        tesouroOracle.setAnswer(_price);
        _setRouterPrice(_price);
    }

    /// @dev Vault deposits into the hub, which burns USDC towards Base.
    function _hubDeposit(uint256 _amount) internal {
        usdcEth.mint(depositor, _amount);
        vm.startPrank(depositor);
        usdcEth.approve(address(hub), _amount);
        hubVault.deposit(_amount, depositor);
        vm.stopPrank();
    }

    /// @dev Simulates Circle minting the last hub burn on Base.
    function _relayHubBurnToRemote() internal returns (uint256 amount) {
        MockTokenMessenger.Burn memory b = ethMessenger.lastBurn();
        assertEq(b.destinationDomain, BASE_DOMAIN);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(address(remote)))));
        amount = b.amount;
        usdcBase.mint(address(remote), amount);
    }

    /// @dev Simulates Circle minting the last remote burn on Ethereum.
    function _relayRemoteBurnToHub() internal returns (uint256 amount) {
        MockTokenMessenger.Burn memory b = baseMessenger.lastBurn();
        assertEq(b.destinationDomain, ETHEREUM_DOMAIN);
        assertEq(b.mintRecipient, bytes32(uint256(uint160(address(hub)))));
        amount = b.amount;
        usdcEth.mint(address(hub), amount);
    }

    function _relayReportToHub() internal {
        bytes memory body = baseTransmitter.lastBody();
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );
    }

    function _relayRequestToRemote() internal {
        bytes memory body = ethTransmitter.lastBody();
        baseTransmitter.deliver(
            address(remote),
            ETHEREUM_DOMAIN,
            address(hub),
            FINALIZED,
            body
        );
    }

    function _remoteReport() internal {
        skip(1);
        vm.prank(remoteKeeper);
        remote.report();
    }

    /// @dev deposit -> bridge -> remote report -> hub receives report.
    function _depositAndDeploy(uint256 _amount) internal {
        _hubDeposit(_amount);
        _relayHubBurnToRemote();
        _remoteReport();
        _relayReportToHub();
    }

    function _decodeReport(
        bytes memory _body
    ) internal pure returns (uint256, uint256, uint256, uint256) {
        return abi.decode(_body, (uint256, uint256, uint256, uint256));
    }
}
