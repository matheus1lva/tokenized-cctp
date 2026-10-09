// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {TokenizedStrategy} from "@tokenized-strategy/TokenizedStrategy.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {OraclePricedHoldStrategy} from "../../local/OraclePricedHoldStrategy.sol";
import {PendlePTHoldStrategy} from "../../local/PendlePTHoldStrategy.sol";
import {MockERC20, MockAggregator, MockSwapRouter, MockVaultFactory} from "./mocks/Mocks.sol";
import {MockSY, MockPendleMarket, MockPYOracle, MockPendleRouter} from "./mocks/PendleMocks.sol";

contract LocalStrategiesTest is Test {
    address internal constant TOKENIZED_STRATEGY =
        0xD377919FA87120584B21279a491F82D5265A139c;

    address internal vault = address(0xD0D0);
    address internal keeper = address(0xBEEF);
    address internal stranger = address(0xBAD);

    MockERC20 internal usdc;

    // SPYon-like
    MockERC20 internal spyon;
    MockAggregator internal spyOracle;
    MockSwapRouter internal router;
    OraclePricedHoldStrategy internal hold;
    ITokenizedStrategy internal holdV;

    int256 internal constant SPY_PRICE = 780_56000000; // $780.56, 8 dec

    function setUp() public {
        vm.warp(1_790_000_000);
        TokenizedStrategy impl = new TokenizedStrategy(
            address(new MockVaultFactory())
        );
        vm.etch(TOKENIZED_STRATEGY, address(impl).code);

        usdc = new MockERC20("USD Coin", "USDC", 6);
        spyon = new MockERC20("SPDR S&P 500 ETF (Ondo Tokenized)", "SPYon", 18);
        spyOracle = new MockAggregator(8, "SPYon / USD", SPY_PRICE);
        router = new MockSwapRouter();
        _setSpyPrice(SPY_PRICE);

        hold = new OraclePricedHoldStrategy(
            address(usdc),
            "SPYon hold",
            address(spyon),
            address(spyOracle),
            address(router)
        );
        holdV = ITokenizedStrategy(address(hold));
        holdV.setKeeper(keeper);
        hold.setAllowed(vault, true);
        holdV.setProfitMaxUnlockTime(0);
    }

    function _setSpyPrice(int256 _price) internal {
        spyOracle.setAnswer(_price);
        // usdc(6) -> spyon(18): out = in * 1e12 * 1e8 / price
        router.setRate(
            address(usdc),
            address(spyon),
            (1e18 * 1e12 * 1e8) / uint256(_price)
        );
        router.setRate(
            address(spyon),
            address(usdc),
            (1e18 * uint256(_price)) / 1e8 / 1e12
        );
    }

    function _deposit(uint256 _amount) internal {
        usdc.mint(vault, _amount);
        vm.startPrank(vault);
        usdc.approve(address(hold), _amount);
        holdV.deposit(_amount, vault);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        ORACLE PRICED HOLD
    //////////////////////////////////////////////////////////////*/

    function test_hold_onlyAllowedDepositor() public {
        assertEq(holdV.maxDeposit(stranger), 0);
        assertEq(holdV.maxDeposit(vault), type(uint256).max);
    }

    function test_hold_valuation() public {
        _deposit(10_000e6);
        assertEq(usdc.balanceOf(address(hold)), 0);
        uint256 expectedTokens = (10_000e6 * 1e12 * 1e8) / uint256(SPY_PRICE);
        assertApproxEqRel(spyon.balanceOf(address(hold)), expectedTokens, 1e12);
        assertApproxEqAbs(hold.valueOfToken(), 10_000e6, 2);

        // +10% price -> report a ~10% profit.
        _setSpyPrice((SPY_PRICE * 110) / 100);
        assertApproxEqAbs(hold.valueOfToken(), 11_000e6, 2);
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = holdV.report();
        assertApproxEqAbs(profit, 1_000e6, 3);
        assertEq(loss, 0);

        // Withdraw half of the shares at the live price (performance fee
        // shares were minted on report, so use convertToAssets).
        uint256 half = holdV.balanceOf(vault) / 2;
        uint256 expected = holdV.convertToAssets(half);
        vm.prank(vault);
        holdV.redeem(half, vault, vault);
        assertApproxEqAbs(usdc.balanceOf(vault), expected, 3);
        assertGt(expected, 5_400e6);
    }

    function test_hold_staleOracleReverts() public {
        _deposit(10_000e6);

        skip(hold.maxStaleness() + 1);
        assertFalse(hold.isPriceFresh());

        vm.expectRevert("StalePrice");
        hold.valueOfToken();

        vm.prank(keeper);
        vm.expectRevert("StalePrice");
        holdV.report();

        // Weekend guard: no deposits, withdraws limited to idle (0).
        assertEq(holdV.maxDeposit(vault), 0);
        assertEq(holdV.maxWithdraw(vault), 0);

        // Feed comes back -> everything reopens.
        spyOracle.setAnswer(SPY_PRICE);
        assertGt(holdV.maxDeposit(vault), 0);
        vm.prank(keeper);
        holdV.report();
    }

    function test_hold_badPriceReverts() public {
        _deposit(1_000e6);
        spyOracle.setAnswer(0);
        vm.expectRevert("BadPrice");
        hold.valueOfToken();
    }

    function test_hold_slippageGuard() public {
        router.setRate(
            address(usdc),
            address(spyon),
            ((1e18 * 1e12 * 1e8) / uint256(SPY_PRICE) * 90) / 100
        );
        usdc.mint(vault, 1_000e6);
        vm.startPrank(vault);
        usdc.approve(address(hold), 1_000e6);
        vm.expectRevert("Slippage");
        holdV.deposit(1_000e6, vault);
        vm.stopPrank();
    }

    function test_hold_noRouterHoldsUsdc() public {
        hold.setRouter(address(0));
        _deposit(1_000e6);
        assertEq(usdc.balanceOf(address(hold)), 1_000e6);
        uint256 shares = holdV.balanceOf(vault);
        vm.prank(vault);
        holdV.redeem(shares, vault, vault);
        assertEq(usdc.balanceOf(vault), 1_000e6);
    }

    function test_hold_lossLimitConfigurable() public {
        assertEq(hold.lossLimitRatio(), 500);
        _deposit(10_000e6);
        _setSpyPrice((SPY_PRICE * 90) / 100);
        vm.prank(keeper);
        vm.expectRevert("healthCheck");
        holdV.report();
        hold.setLossLimitRatio(1_100);
        vm.prank(keeper);
        (, uint256 loss) = holdV.report();
        assertApproxEqAbs(loss, 1_000e6, 3);
    }

    /*//////////////////////////////////////////////////////////////
                            PENDLE PT HOLD
    //////////////////////////////////////////////////////////////*/

    function _deployPt(
        uint256 _expiry
    )
        internal
        returns (
            PendlePTHoldStrategy pts,
            MockERC20 pt,
            MockPYOracle oracle,
            MockPendleMarket market
        )
    {
        pt = new MockERC20("PT-USDC", "PT", 6);
        oracle = new MockPYOracle();
        oracle.setRate(0.95e18); // 5% discount to maturity
        MockSY sy = new MockSY(address(usdc));
        market = new MockPendleMarket(
            address(sy),
            address(pt),
            address(0x1234),
            _expiry
        );
        MockPendleRouter prouter = new MockPendleRouter(
            address(oracle),
            address(usdc),
            address(pt)
        );
        pts = new PendlePTHoldStrategy(
            address(usdc),
            "PT hold",
            address(market),
            address(oracle),
            address(prouter)
        );
        pts.setAllowed(vault, true);
        ITokenizedStrategy(address(pts)).setKeeper(keeper);
        ITokenizedStrategy(address(pts)).setProfitMaxUnlockTime(0);
    }

    function test_pt_buyValueAndRedeemAtMaturity() public {
        (
            PendlePTHoldStrategy pts,
            MockERC20 pt,
            MockPYOracle oracle,

        ) = _deployPt(block.timestamp + 90 days);
        ITokenizedStrategy v = ITokenizedStrategy(address(pts));

        usdc.mint(vault, 9_500e6);
        vm.startPrank(vault);
        usdc.approve(address(pts), 9_500e6);
        v.deposit(9_500e6, vault);
        vm.stopPrank();

        assertApproxEqAbs(pt.balanceOf(address(pts)), 10_000e6, 1);
        assertApproxEqAbs(pts.valueOfPt(), 9_500e6, 1);

        // Accrues towards par.
        oracle.setRate(0.98e18);
        vm.prank(keeper);
        (uint256 profit, ) = v.report();
        assertApproxEqAbs(profit, 300e6, 2);

        // Maturity: deposits close, tend redeems PT 1:1 to USDC.
        skip(91 days);
        oracle.setRate(1e18);
        assertEq(v.maxDeposit(vault), 0);
        (bool trigger, ) = pts.tendTrigger();
        assertTrue(trigger);
        vm.prank(keeper);
        v.tend();
        assertEq(pt.balanceOf(address(pts)), 0);
        assertApproxEqAbs(usdc.balanceOf(address(pts)), 10_000e6, 1);
    }

    function test_pt_rejectsExpiredOrWrongSy() public {
        MockERC20 pt = new MockERC20("PT", "PT", 6);
        MockPYOracle oracle = new MockPYOracle();

        MockSY wrongSy = new MockSY(address(0xdead));
        MockPendleMarket m1 = new MockPendleMarket(
            address(wrongSy),
            address(pt),
            address(0),
            block.timestamp + 1 days
        );
        vm.expectRevert("!tokenIn");
        new PendlePTHoldStrategy(
            address(usdc),
            "x",
            address(m1),
            address(oracle),
            address(0)
        );

        MockSY sy = new MockSY(address(usdc));
        MockPendleMarket m2 = new MockPendleMarket(
            address(sy),
            address(pt),
            address(0),
            block.timestamp
        );
        vm.expectRevert("Expired");
        new PendlePTHoldStrategy(
            address(usdc),
            "x",
            address(m2),
            address(oracle),
            address(0)
        );
    }
}
