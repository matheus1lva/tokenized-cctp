// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMessageHandlerV2} from "../../../interfaces/circle/IMessageHandlerV2.sol";

contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ERC20(_name, _symbol) {
        _dec = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address _to, uint256 _amount) external {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external {
        _burn(_from, _amount);
    }
}

contract MockAggregator {
    uint8 public decimals;
    string public description;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 _decimals, string memory _description, int256 _answer) {
        decimals = _decimals;
        description = _description;
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function set(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        updatedAt = _updatedAt;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice Records CCTP messages; tests deliver them by hand.
contract MockMessageTransmitter {
    struct Sent {
        uint32 destinationDomain;
        bytes32 recipient;
        uint32 minFinalityThreshold;
        bytes body;
        address sender;
    }

    Sent[] public sent;

    function sendMessage(
        uint32 _destinationDomain,
        bytes32 _recipient,
        bytes32,
        uint32 _minFinalityThreshold,
        bytes calldata _messageBody
    ) external {
        sent.push(
            Sent(
                _destinationDomain,
                _recipient,
                _minFinalityThreshold,
                _messageBody,
                msg.sender
            )
        );
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastBody() external view returns (bytes memory) {
        return sent[sent.length - 1].body;
    }

    function lastSent() external view returns (Sent memory) {
        return sent[sent.length - 1];
    }

    /// @notice Simulate Circle's receiveMessage on this chain.
    function deliver(
        address _handler,
        uint32 _sourceDomain,
        address _sender,
        uint32 _finality,
        bytes calldata _body
    ) external returns (bool) {
        return
            IMessageHandlerV2(_handler).handleReceiveFinalizedMessage(
                _sourceDomain,
                bytes32(uint256(uint160(_sender))),
                _finality,
                _body
            );
    }
}

/// @notice Burns USDC on depositForBurn; tests mint on the other side.
contract MockTokenMessenger {
    address public localMessageTransmitter;

    struct Burn {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        address burnToken;
    }

    Burn[] public burns;

    constructor(address _transmitter) {
        localMessageTransmitter = _transmitter;
    }

    function depositForBurn(
        uint256 _amount,
        uint32 _destinationDomain,
        bytes32 _mintRecipient,
        address _burnToken,
        bytes32,
        uint256,
        uint32
    ) external {
        IERC20(_burnToken).transferFrom(msg.sender, address(this), _amount);
        burns.push(
            Burn(_amount, _destinationDomain, _mintRecipient, _burnToken)
        );
    }

    function burnCount() external view returns (uint256) {
        return burns.length;
    }

    function lastBurn() external view returns (Burn memory) {
        return burns[burns.length - 1];
    }
}

/// @notice Swaps at a configurable price, minting the output token.
/// @dev rate = amount of tokenOut base units per 1e18 base units of tokenIn.
contract MockSwapRouter {
    mapping(address => mapping(address => uint256)) public rate;

    function setRate(address _in, address _out, uint256 _rate) external {
        rate[_in][_out] = _rate;
    }

    function swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minAmountOut,
        address _receiver
    ) external returns (uint256 out) {
        uint256 r = rate[_tokenIn][_tokenOut];
        require(r > 0, "no rate");
        IERC20(_tokenIn).transferFrom(msg.sender, address(this), _amountIn);
        out = (_amountIn * r) / 1e18;
        MockERC20(_tokenOut).mint(_receiver, out);
    }
}

/// @notice Vault factory stub for TokenizedStrategy.FACTORY().
contract MockVaultFactory {
    function protocol_fee_config() external pure returns (uint16, address) {
        return (0, address(0));
    }
}
