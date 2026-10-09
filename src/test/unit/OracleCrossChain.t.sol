// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {UnitSetup} from "./utils/UnitSetup.sol";
import {MockAggregator} from "./mocks/Mocks.sol";
import {MockTokenMessenger, MockMessageTransmitter} from "./mocks/Mocks.sol";

contract OracleCrossChainTest is UnitSetup {
    uint256 internal constant CEILING = 75_000e6;

    /*//////////////////////////////////////////////////////////////
                                CEILING
    //////////////////////////////////////////////////////////////*/

    function test_defaults() public {
        assertEq(remote.maxUsdExposure(), CEILING);
        assertEq(remote.fxStopBps(), 1_000);
        assertEq(remote.fxReferencePrice(), uint256(BRL_PRICE));
        assertEq(remote.slippageBps(), 100);
        assertEq(hub.lossLimitRatio(), 300);
        assertEq(hub.REPORT_PRICE_DECIMALS(), 8);
        assertEq(remote.availableDepositLimit(), CEILING);
    }

    function test_ceiling_depositAboveCeilingBouncedBack() public {
        uint256 amount = 100_000e6;
        _hubDeposit(amount);
        assertEq(hub.remoteAssets(), amount);
        _relayHubBurnToRemote();

        _remoteReport();

        // Only $75k of TESOURO bought, the rest bridged back to the hub.
        assertLe(remote.valueOfDeployedAssets(), CEILING);
        assertApproxEqAbs(remote.valueOfDeployedAssets(), CEILING, 1);
        assertEq(remote.balanceOfAsset(), 0);
        assertEq(remote.availableDepositLimit(), 0);

        MockTokenMessenger.Burn memory b = baseMessenger.lastBurn();
        assertApproxEqAbs(b.amount, amount - CEILING, 1);

        (uint256 reported, , uint256 price, ) = _decodeReport(
            baseTransmitter.lastBody()
        );
        assertApproxEqAbs(reported, CEILING, 1);
        assertEq(price, uint256(TESOURO_PRICE));

        // Hub gets the report + the bounced USDC: no loss, no double count.
        _relayReportToHub();
        _relayRemoteBurnToHub();
        assertApproxEqAbs(hub.remoteAssets(), CEILING, 1);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = hubVault.report();
        assertEq(profit, 0);
        assertLe(loss, 1);
        assertApproxEqAbs(hubVault.totalAssets(), amount, 1);
    }

    function test_ceiling_secondDepositFullyBounced() public {
        _depositAndDeploy(CEILING);
        assertApproxEqAbs(remote.valueOfDeployedAssets(), CEILING, 1);

        _hubDeposit(10_000e6);
        _relayHubBurnToRemote();
        uint256 burnsBefore = baseMessenger.burnCount();
        _remoteReport();

        assertEq(baseMessenger.burnCount(), burnsBefore + 1);
        assertEq(baseMessenger.lastBurn().amount, 10_000e6);
        assertApproxEqAbs(remote.valueOfDeployedAssets(), CEILING, 1);
    }

    function test_ceiling_loweredCeilingTrimsOnTend() public {
        _depositAndDeploy(CEILING);

        // Price up 10%: value 82.5k > 75k * 1.02 buffer.
        _setTesouroPrice((TESOURO_PRICE * 110) / 100);
        assertGt(remote.valueOfDeployedAssets(), CEILING);
        (bool trigger, ) = remote.tendTrigger();
        assertTrue(trigger);

        skip(1);
        uint256 reportsBefore = baseTransmitter.sentCount();
        vm.prank(remoteKeeper);
        remote.tend();

        assertApproxEqAbs(remote.valueOfDeployedAssets(), CEILING, 2);
        assertLe(remote.balanceOfAsset(), 1); // rounding dust
        assertApproxEqAbs(baseMessenger.lastBurn().amount, 7_500e6, 2);
        // A fresh report followed the bridge.
        assertEq(baseTransmitter.sentCount(), reportsBefore + 1);

        (trigger, ) = remote.tendTrigger();
        assertFalse(trigger);
    }

    function test_ceiling_smallPriceDriftWithinBufferNoTrim() public {
        _depositAndDeploy(CEILING);
        _setTesouroPrice((TESOURO_PRICE * 101) / 100);
        (bool trigger, ) = remote.tendTrigger();
        assertFalse(trigger);
    }

    function test_ceiling_noRouterHoldsUsdcUpToCeiling() public {
        vm.prank(governance);
        remote.setRouter(address(0));

        _hubDeposit(100_000e6);
        _relayHubBurnToRemote();
        _remoteReport();

        assertEq(tesouro.balanceOf(address(remote)), 0);
        assertEq(remote.balanceOfAsset(), CEILING);
        assertEq(baseMessenger.lastBurn().amount, 25_000e6);
    }

    function test_ceiling_governanceOnly() public {
        vm.expectRevert("!governance");
        vm.prank(stranger);
        remote.setMaxUsdExposure(1);

        vm.prank(governance);
        remote.setMaxUsdExposure(50_000e6);
        assertEq(remote.maxUsdExposure(), 50_000e6);
    }

    function test_hubDepositLimit_maxRemoteExposure() public {
        assertEq(hubVault.maxDeposit(stranger), 0);

        hub.setMaxRemoteExposure(CEILING);
        assertEq(hubVault.maxDeposit(depositor), CEILING);

        _hubDeposit(50_000e6);
        assertEq(hubVault.maxDeposit(depositor), 25_000e6);
    }

    function test_slippageGuard_revertsOnBadRoute() public {
        _hubDeposit(10_000e6);
        _relayHubBurnToRemote();
        // Router gives 5% less than the oracle implies; tolerance is 1%.
        router.setRate(
            address(usdcBase),
            address(tesouro),
            (((1e18 * 1e8) / uint256(TESOURO_PRICE)) * 95) / 100
        );
        skip(1);
        vm.prank(remoteKeeper);
        vm.expectRevert("Slippage");
        remote.report();
    }

    /*//////////////////////////////////////////////////////////////
                            EXTENDED REPORT
    //////////////////////////////////////////////////////////////*/

    function test_extendedReport_decodedAndAccepted() public {
        _hubDeposit(20_000e6);
        _relayHubBurnToRemote();
        _remoteReport();

        MockMessageTransmitter.Sent memory s = baseTransmitter.lastSent();
        assertEq(s.destinationDomain, ETHEREUM_DOMAIN);
        assertEq(s.recipient, bytes32(uint256(uint160(address(hub)))));
        assertEq(s.minFinalityThreshold, FINALIZED);
        assertEq(s.body.length, 128);

        (
            uint256 ta,
            uint256 ts,
            uint256 price,
            uint256 updatedAt
        ) = _decodeReport(s.body);
        assertApproxEqAbs(ta, 20_000e6, 1);
        assertEq(ts, block.timestamp);
        assertEq(price, uint256(TESOURO_PRICE));
        assertEq(updatedAt, tesouroOracle.updatedAt());

        _relayReportToHub();
        assertApproxEqAbs(hub.remoteAssets(), 20_000e6, 1);
        assertEq(hub.lastRemoteAssetsReport(), ts);
        assertEq(hub.lastReportedPrice(), price);
        assertEq(hub.lastReportedOracleUpdatedAt(), updatedAt);
    }

    function test_legacyReport_rejected() public {
        bytes memory legacy = abi.encode(uint256(1e6), block.timestamp);
        vm.expectRevert("InvalidReportLength");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            legacy
        );
    }

    function test_report_invalidSenderDomainFinality() public {
        bytes memory body = abi.encode(
            uint256(1e6),
            block.timestamp,
            uint256(TESOURO_PRICE),
            block.timestamp
        );

        vm.expectRevert("InvalidTransmitter");
        hub.handleReceiveFinalizedMessage(
            BASE_DOMAIN,
            bytes32(uint256(uint160(address(remote)))),
            FINALIZED,
            body
        );

        vm.expectRevert("InvalidSender");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            stranger,
            FINALIZED,
            body
        );

        vm.expectRevert("InvalidDomain");
        ethTransmitter.deliver(
            address(hub),
            7,
            address(remote),
            FINALIZED,
            body
        );

        vm.expectRevert("InvalidFinalityThreshold");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            1_000,
            body
        );
    }

    function test_staleReport_rejected() public {
        // Report itself too old.
        uint256 old = block.timestamp - hub.maxReportAge() - 1;
        bytes memory body = abi.encode(
            uint256(1e6),
            old,
            uint256(TESOURO_PRICE),
            old
        );
        vm.expectRevert("StaleReport");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );

        // Fresh report carrying a stale oracle observation.
        uint256 oldOracle = block.timestamp - hub.maxOracleAge() - 1;
        body = abi.encode(
            uint256(1e6),
            block.timestamp,
            uint256(TESOURO_PRICE),
            oldOracle
        );
        vm.expectRevert("StaleReportPrice");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );

        // Zero price.
        body = abi.encode(
            uint256(1e6),
            block.timestamp,
            uint256(0),
            block.timestamp
        );
        vm.expectRevert("BadPrice");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );
    }

    function test_remoteRefusesToReportStalePrice() public {
        _hubDeposit(1_000e6);
        _relayHubBurnToRemote();
        skip(remote.maxStaleness() + 1);
        vm.prank(remoteKeeper);
        vm.expectRevert("StalePrice");
        remote.report();
    }

    function test_priceDeviation_rejected() public {
        // Hub oracle quotes 18 decimals to exercise normalisation.
        MockAggregator hubOracle = new MockAggregator(18, "TESOURO/USD", 0);
        hubOracle.setAnswer(int256(uint256(TESOURO_PRICE)) * 1e10 * 110 / 100);
        hub.setHubPriceOracle(address(hubOracle));

        _hubDeposit(1_000e6);
        _relayHubBurnToRemote();
        _remoteReport();

        bytes memory body = baseTransmitter.lastBody();
        vm.expectRevert("PriceDeviation");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );

        // 1% apart is inside the default 2% band.
        hubOracle.setAnswer(int256(uint256(TESOURO_PRICE)) * 1e10 * 101 / 100);
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );
        assertEq(hub.lastReportedPrice(), uint256(TESOURO_PRICE));

        // Stale hub oracle blocks reports too.
        hubOracle.set(hubOracle.answer(), block.timestamp - 27 hours);
        _remoteReport();
        body = baseTransmitter.lastBody();
        vm.expectRevert("StalePrice");
        ethTransmitter.deliver(
            address(hub),
            BASE_DOMAIN,
            address(remote),
            FINALIZED,
            body
        );
    }

    function test_reportParams_onlyManagement() public {
        vm.expectRevert("!management");
        vm.prank(stranger);
        hub.setReportParams(1, 1, 1);

        hub.setReportParams(2 hours, 30 hours, 100);
        assertEq(hub.maxReportAge(), 2 hours);
        assertEq(hub.maxOracleAge(), 30 hours);
        assertEq(hub.maxPriceDeviationBps(), 100);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW REQUEST ROUND TRIP
    //////////////////////////////////////////////////////////////*/

    function test_withdrawRequest_roundTrip() public {
        _depositAndDeploy(50_000e6);
        assertApproxEqAbs(hub.remoteAssets(), 50_000e6, 1);

        // Hub -> remote request.
        vm.prank(keeper);
        hub.requestRemoteWithdrawal(10_000e6);

        MockMessageTransmitter.Sent memory s = ethTransmitter.lastSent();
        assertEq(s.destinationDomain, BASE_DOMAIN);
        assertEq(s.recipient, bytes32(uint256(uint160(address(remote)))));
        assertEq(s.body.length, 96);

        _relayRequestToRemote();
        assertEq(remote.pendingWithdrawal(), 10_000e6);

        // Remote keeper fulfils it.
        skip(1);
        vm.prank(remoteKeeper);
        remote.processPendingWithdrawal();

        assertEq(remote.pendingWithdrawal(), 0);
        assertEq(baseMessenger.lastBurn().amount, 10_000e6);
        assertApproxEqAbs(remote.valueOfDeployedAssets(), 40_000e6, 2);

        // Remote -> hub: report + USDC.
        _relayReportToHub();
        _relayRemoteBurnToHub();
        assertApproxEqAbs(hub.remoteAssets(), 40_000e6, 2);
        assertEq(usdcEth.balanceOf(address(hub)), 10_000e6);

        vm.prank(keeper);
        hubVault.report();

        // Vault can now pull the bridged USDC.
        assertEq(hubVault.maxWithdraw(depositor), 10_000e6);
        vm.prank(depositor);
        hubVault.withdraw(10_000e6, depositor, depositor);
        assertEq(usdcEth.balanceOf(depositor), 10_000e6);
    }

    function test_withdrawRequest_reservedOnReport() public {
        _depositAndDeploy(20_000e6);
        vm.prank(keeper);
        hub.requestRemoteWithdrawal(5_000e6);
        _relayRequestToRemote();

        // New USDC lands while a request is pending: it is kept for the hub.
        _hubDeposit(5_000e6);
        _relayHubBurnToRemote();
        _remoteReport();
        assertEq(remote.balanceOfAsset(), 5_000e6);
        assertApproxEqAbs(remote.valueOfDeployedAssets(), 20_000e6, 1);

        skip(1);
        vm.prank(remoteKeeper);
        remote.processPendingWithdrawal();
        assertEq(remote.pendingWithdrawal(), 0);
        assertEq(baseMessenger.lastBurn().amount, 5_000e6);
    }

    function test_withdrawRequest_accessAndValidation() public {
        _depositAndDeploy(1_000e6);

        vm.expectRevert("!keeper");
        vm.prank(stranger);
        hub.requestRemoteWithdrawal(1e6);

        vm.prank(keeper);
        vm.expectRevert("ZeroAmount");
        hub.requestRemoteWithdrawal(0);

        uint256 tooMuch = hub.remoteAssets() + 1;
        vm.prank(keeper);
        vm.expectRevert("TooMuch");
        hub.requestRemoteWithdrawal(tooMuch);

        // Remote only accepts the request from the hub via the transmitter.
        bytes memory body = abi.encode(uint8(1), uint256(1e6), block.timestamp);
        vm.expectRevert("InvalidTransmitter");
        remote.handleReceiveFinalizedMessage(
            ETHEREUM_DOMAIN,
            bytes32(uint256(uint160(address(hub)))),
            FINALIZED,
            body
        );
        vm.expectRevert("InvalidSender");
        baseTransmitter.deliver(
            address(remote),
            ETHEREUM_DOMAIN,
            stranger,
            FINALIZED,
            body
        );
        vm.expectRevert("InvalidDomain");
        baseTransmitter.deliver(
            address(remote),
            BASE_DOMAIN,
            address(hub),
            FINALIZED,
            body
        );
        vm.expectRevert("InvalidFinalityThreshold");
        baseTransmitter.deliver(
            address(remote),
            ETHEREUM_DOMAIN,
            address(hub),
            1_000,
            body
        );
        bytes memory wrongType = abi.encode(uint8(2), uint256(1e6), block.timestamp);
        vm.expectRevert("UnknownMessage");
        baseTransmitter.deliver(
            address(remote),
            ETHEREUM_DOMAIN,
            address(hub),
            FINALIZED,
            wrongType
        );
    }

    /*//////////////////////////////////////////////////////////////
                                FX STOP
    //////////////////////////////////////////////////////////////*/

    function test_fxUnwind_onlyPastThreshold() public {
        _depositAndDeploy(50_000e6);

        // -5%: not triggered.
        brlOracle.setAnswer((BRL_PRICE * 95) / 100);
        assertFalse(remote.fxStopTriggered());
        skip(1);
        vm.prank(stranger);
        vm.expectRevert("FxNotTriggered");
        remote.fxUnwind();

        // Exactly -10%: still not past the threshold.
        brlOracle.setAnswer((BRL_PRICE * 90) / 100);
        assertFalse(remote.fxStopTriggered());

        // -11%: anyone can unwind.
        brlOracle.setAnswer((BRL_PRICE * 89) / 100);
        assertTrue(remote.fxStopTriggered());
        skip(1);
        vm.prank(stranger);
        remote.fxUnwind();

        assertTrue(remote.fxStopped());
        assertEq(tesouro.balanceOf(address(remote)), 0);
        assertEq(remote.balanceOfAsset(), 0);
        assertApproxEqAbs(baseMessenger.lastBurn().amount, 50_000e6, 2);
        (uint256 ta, , , ) = _decodeReport(baseTransmitter.lastBody());
        assertEq(ta, 0);

        // While stopped, new USDC is not deployed but bounced back.
        _hubDeposit(1_000e6);
        _relayHubBurnToRemote();
        _remoteReport();
        assertEq(tesouro.balanceOf(address(remote)), 0);
        assertEq(baseMessenger.lastBurn().amount, 1_000e6);

        // Governance resumes and re-anchors the reference.
        vm.prank(stranger);
        vm.expectRevert("!governance");
        remote.resetFxStop();
        vm.prank(governance);
        remote.resetFxStop();
        assertFalse(remote.fxStopped());
        assertEq(remote.fxReferencePrice(), uint256((BRL_PRICE * 89) / 100));
    }

    function test_fxUnwind_staleFxOracleDoesNotTrigger() public {
        _depositAndDeploy(10_000e6);
        brlOracle.set((BRL_PRICE * 80) / 100, block.timestamp - 3 hours);
        assertFalse(remote.fxStopTriggered());
        skip(1);
        vm.expectRevert("FxNotTriggered");
        remote.fxUnwind();
    }

    function test_fxUnwind_inChunks() public {
        _depositAndDeploy(40_000e6);
        uint256 held = tesouro.balanceOf(address(remote));
        vm.prank(governance);
        remote.setFxParams(1_000, 2 hours, held / 4);

        brlOracle.setAnswer((BRL_PRICE * 85) / 100);
        skip(1);
        remote.fxUnwind();
        assertApproxEqAbs(tesouro.balanceOf(address(remote)), (held * 3) / 4, 1);

        // Continues even if FX recovered, because the stop is armed.
        brlOracle.setAnswer(BRL_PRICE);
        skip(1);
        remote.fxUnwind();
        assertApproxEqAbs(tesouro.balanceOf(address(remote)), held / 2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                            LOSS LIMIT
    //////////////////////////////////////////////////////////////*/

    function test_lossLimit_configurable() public {
        _depositAndDeploy(10_000e6);
        vm.prank(keeper);
        hubVault.report();

        // TESOURO -5% -> remote reports a 5% loss.
        _setTesouroPrice((TESOURO_PRICE * 95) / 100);
        _remoteReport();
        _relayReportToHub();

        vm.prank(keeper);
        vm.expectRevert("healthCheck");
        hubVault.report();

        vm.expectRevert("!management");
        vm.prank(stranger);
        hub.setLossLimitRatio(600);

        hub.setLossLimitRatio(600);
        assertEq(hub.lossLimitRatio(), 600);

        vm.prank(keeper);
        (, uint256 loss) = hubVault.report();
        assertApproxEqAbs(loss, 500e6, 2);
    }
}
