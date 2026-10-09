// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ApproxParams, TokenInput, TokenOutput, LimitOrderData} from "@periphery/interfaces/Pendle/IPendle.sol";
import {MockERC20} from "./Mocks.sol";

contract MockSY {
    address[] internal tokens;

    constructor(address _token) {
        tokens.push(_token);
    }

    function getTokensIn() external view returns (address[] memory) {
        return tokens;
    }

    function getTokensOut() external view returns (address[] memory) {
        return tokens;
    }
}

contract MockPendleMarket {
    address public sy;
    address public pt;
    address public yt;
    uint256 public expiry;

    constructor(address _sy, address _pt, address _yt, uint256 _expiry) {
        sy = _sy;
        pt = _pt;
        yt = _yt;
        expiry = _expiry;
    }

    function readTokens() external view returns (address, address, address) {
        return (sy, pt, yt);
    }

    function isExpired() external view returns (bool) {
        return block.timestamp >= expiry;
    }
}

contract MockPYOracle {
    uint256 public rate = 1e18;

    function setRate(uint256 _rate) external {
        rate = _rate;
    }

    function getPtToAssetRate(address, uint32) external view returns (uint256) {
        return rate;
    }
}

/// @notice Trades USDC (6 dec) <-> PT (6 dec) at the oracle rate.
contract MockPendleRouter {
    MockPYOracle public oracle;
    address public usdc;
    address public pt;

    constructor(address _oracle, address _usdc, address _pt) {
        oracle = MockPYOracle(_oracle);
        usdc = _usdc;
        pt = _pt;
    }

    function swapExactTokenForPt(
        address receiver,
        address,
        uint256 minPtOut,
        ApproxParams calldata,
        TokenInput calldata input,
        LimitOrderData calldata
    ) external payable returns (uint256 netPtOut, uint256, uint256) {
        IERC20(input.tokenIn).transferFrom(
            msg.sender,
            address(this),
            input.netTokenIn
        );
        netPtOut = (input.netTokenIn * 1e18) / oracle.rate();
        require(netPtOut >= minPtOut, "pt slippage");
        MockERC20(pt).mint(receiver, netPtOut);
    }

    function swapExactPtForToken(
        address receiver,
        address,
        uint256 exactPtIn,
        TokenOutput calldata output,
        LimitOrderData calldata
    ) external returns (uint256 netTokenOut, uint256, uint256) {
        IERC20(pt).transferFrom(msg.sender, address(this), exactPtIn);
        netTokenOut = (exactPtIn * oracle.rate()) / 1e18;
        require(netTokenOut >= output.minTokenOut, "token slippage");
        MockERC20(output.tokenOut).mint(receiver, netTokenOut);
    }

    function redeemPyToToken(
        address receiver,
        address,
        uint256 netPyIn,
        TokenOutput calldata output
    ) external returns (uint256 netTokenOut, uint256) {
        IERC20(pt).transferFrom(msg.sender, address(this), netPyIn);
        netTokenOut = netPyIn; // 1 PT = 1 USDC at maturity
        require(netTokenOut >= output.minTokenOut, "token slippage");
        MockERC20(output.tokenOut).mint(receiver, netTokenOut);
    }
}
