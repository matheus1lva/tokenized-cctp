// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseRemoteStrategy} from "../bases/BaseRemoteStrategy.sol";
import {BaseCCTP} from "../bases/BaseCCTP.sol";
import {IAggregatorV3} from "../interfaces/oracles/IAggregatorV3.sol";
import {IOracleSwapRouter} from "../interfaces/swappers/IOracleSwapRouter.sol";
import {OracleLib} from "../libraries/OracleLib.sol";
import {OracleCCTPMessages} from "../libraries/OracleCCTPMessages.sol";

/// @notice Remote strategy that receives USDC via CCTP, swaps it into a
///         priced (non ERC4626) token and values it with an AggregatorV3
///         style oracle.
/// @dev Reports to the hub with an extended payload
///      (totalAssets, timestamp, price, oracleUpdatedAt) and accepts
///      withdraw requests from the hub, which are queued in
///      `pendingWithdrawal` and fulfilled by a keeper via processWithdrawal.
abstract contract BaseOracleRemoteStrategy is BaseRemoteStrategy, BaseCCTP {
    using SafeERC20 for ERC20;

    event UpdatedRouter(address indexed router);

    event UpdatedSlippageBps(uint256 slippageBps);

    event UpdatedMaxStaleness(uint256 maxStaleness);

    event WithdrawRequested(
        uint256 amount,
        uint256 timestamp,
        uint256 totalPending
    );

    event PendingWithdrawalCleared(uint256 amount);

    event ExcessReturned(uint256 amount);

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Hard cap on the configurable slippage.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    /// @notice The priced token held by this strategy (e.g. TESOURO).
    ERC20 public immutable HELD_TOKEN;

    /// @notice HELD_TOKEN / USD oracle.
    IAggregatorV3 public immutable PRICE_ORACLE;

    uint256 internal immutable HELD_SCALE;
    uint256 internal immutable ORACLE_SCALE;
    uint256 internal immutable ASSET_SCALE;

    /// @notice Swap adapter. Zero means "hold USDC" until governance sets it.
    IOracleSwapRouter public router;

    /// @notice Max tolerated slippage vs. oracle value for every swap.
    uint256 public slippageBps;

    /// @notice Max age of the PRICE_ORACLE answer.
    uint256 public maxStaleness;

    /// @notice USDC requested by the hub that has not been bridged back yet.
    uint256 public pendingWithdrawal;

    /// @notice Timestamp (hub chain) of the last withdraw request received.
    uint256 public lastWithdrawRequest;

    constructor(
        address _asset,
        address _governance,
        address _tokenMessenger,
        address _messageTransmitter,
        uint32 _sourceDomain,
        address _remoteCounterpart,
        address _heldToken,
        address _priceOracle,
        address _router
    )
        BaseRemoteStrategy(
            _asset,
            _governance,
            bytes32(uint256(_sourceDomain)),
            _remoteCounterpart
        )
        BaseCCTP(_asset, _tokenMessenger, _messageTransmitter)
    {
        require(
            _heldToken != address(0) && _priceOracle != address(0),
            "ZeroAddress"
        );
        require(_heldToken != _asset, "InvalidToken");

        HELD_TOKEN = ERC20(_heldToken);
        PRICE_ORACLE = IAggregatorV3(_priceOracle);
        HELD_SCALE = 10 ** ERC20(_heldToken).decimals();
        ORACLE_SCALE = 10 ** IAggregatorV3(_priceOracle).decimals();
        ASSET_SCALE = 10 ** ERC20(_asset).decimals();

        router = IOracleSwapRouter(_router);
        slippageBps = 100; // 1%
        maxStaleness = 26 hours; // 24h heartbeat + buffer

        // Approve token messenger for CCTP bridging
        asset.forceApprove(_tokenMessenger, type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function setRouter(address _router) external virtual onlyGovernance {
        router = IOracleSwapRouter(_router);
        emit UpdatedRouter(_router);
    }

    function setSlippageBps(
        uint256 _slippageBps
    ) external virtual onlyGovernance {
        require(_slippageBps <= MAX_SLIPPAGE_BPS, "TooHigh");
        slippageBps = _slippageBps;
        emit UpdatedSlippageBps(_slippageBps);
    }

    function setMaxStaleness(
        uint256 _maxStaleness
    ) external virtual onlyGovernance {
        require(_maxStaleness > 0, "ZeroStaleness");
        maxStaleness = _maxStaleness;
        emit UpdatedMaxStaleness(_maxStaleness);
    }

    /// @notice Drop a queued hub request (e.g. it was satisfied manually).
    function clearPendingWithdrawal() external virtual onlyGovernance {
        emit PendingWithdrawalCleared(pendingWithdrawal);
        pendingWithdrawal = 0;
    }

    function rescue(
        address _token,
        address _to,
        uint256 _amount
    ) external virtual onlyGovernance {
        require(!_isProtectedToken(_token), "InvalidToken");
        ERC20(_token).safeTransfer(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                        KEEPER / REPORTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy idle (minus what the hub asked back), return excess,
    ///         and send the extended report to the hub.
    function report()
        external
        virtual
        override
        isReady
        onlyKeepers
        returns (uint256 _totalAssets, uint256)
    {
        if (!isShutdown) {
            uint256 idle = balanceOfAsset();
            uint256 reserved = pendingWithdrawal;
            if (idle > reserved) {
                _pushFunds(idle - reserved);
            }
        }

        _returnExcess();

        _totalAssets = _sendReport();
    }

    /// @notice Process a withdrawal and bridge USDC back to the hub.
    function processWithdrawal(
        uint256 _amount
    ) external virtual override onlyKeepers isReady {
        _processWithdrawal(_amount);
    }

    /// @notice Fulfil everything the hub has requested so far.
    function processPendingWithdrawal() external virtual onlyKeepers isReady {
        _processWithdrawal(pendingWithdrawal);
    }

    /*//////////////////////////////////////////////////////////////
                        CCTP MESSAGE HANDLING
    //////////////////////////////////////////////////////////////*/

    /// @notice Receive a withdraw request from the hub strategy.
    /// @dev Same validation as the hub side: transmitter, domain, sender
    ///      and finality. Requests accumulate; CCTP nonces prevent replays.
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

        (uint256 amount, uint256 timestamp) = OracleCCTPMessages
            .decodeWithdrawRequest(_messageBody);

        pendingWithdrawal += amount;
        if (timestamp > lastWithdrawRequest) lastWithdrawRequest = timestamp;

        emit WithdrawRequested(amount, timestamp, pendingWithdrawal);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Current oracle price (reverts if stale or non positive).
    function latestPrice()
        public
        view
        virtual
        returns (uint256 price, uint256 updatedAt)
    {
        return OracleLib.readPrice(PRICE_ORACLE, maxStaleness);
    }

    function isPriceFresh() public view virtual returns (bool ok) {
        (ok, , ) = OracleLib.tryReadPrice(PRICE_ORACLE, maxStaleness);
    }

    function balanceOfHeld() public view virtual returns (uint256) {
        return HELD_TOKEN.balanceOf(address(this));
    }

    /// @notice USDC value of the held token at the oracle price.
    /// @dev Reverts if the oracle is stale so stale values never get reported.
    function valueOfDeployedAssets()
        public
        view
        virtual
        override
        returns (uint256)
    {
        uint256 held = balanceOfHeld();
        if (held == 0) return 0;
        (uint256 price, ) = latestPrice();
        return _heldToAsset(held, price);
    }

    function protectedTokens()
        public
        view
        virtual
        override
        returns (address[] memory _protectedTokens)
    {
        _protectedTokens = new address[](2);
        _protectedTokens[0] = address(asset);
        _protectedTokens[1] = address(HELD_TOKEN);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: FUNDS
    //////////////////////////////////////////////////////////////*/

    /// @dev Buys HELD_TOKEN with up to `_amount` USDC, capped by `_maxBuy()`.
    function _pushFunds(
        uint256 _amount
    ) internal virtual override returns (uint256) {
        if (address(router) == address(0)) return 0;

        _amount = Math.min(_amount, Math.min(balanceOfAsset(), _maxBuy()));
        if (_amount == 0) return 0;

        (uint256 price, ) = latestPrice();
        uint256 minOut = (_assetToHeld(_amount, price, Math.Rounding.Down) *
            (MAX_BPS - slippageBps)) / MAX_BPS;

        _swap(address(asset), address(HELD_TOKEN), _amount, minOut);
        return _amount;
    }

    /// @dev Sells enough HELD_TOKEN to raise `_amount` USDC (capped by
    ///      balance). Returns the exact USDC received.
    function _pullFunds(
        uint256 _amount
    ) internal virtual override returns (uint256) {
        if (_amount == 0) return 0;
        (uint256 price, ) = latestPrice();
        uint256 toSell = Math.min(
            balanceOfHeld(),
            _assetToHeld(_amount, price, Math.Rounding.Up)
        );
        return _sellHeld(toSell, price);
    }

    function _sellHeld(
        uint256 _heldAmount,
        uint256 _price
    ) internal virtual returns (uint256) {
        if (_heldAmount == 0) return 0;
        require(address(router) != address(0), "NoRouter");
        uint256 minOut = (_heldToAsset(_heldAmount, _price) *
            (MAX_BPS - slippageBps)) / MAX_BPS;
        return
            _swap(address(HELD_TOKEN), address(asset), _heldAmount, minOut);
    }

    function _swap(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _minOut
    ) internal virtual returns (uint256 received) {
        uint256 before = ERC20(_tokenOut).balanceOf(address(this));
        ERC20(_tokenIn).forceApprove(address(router), _amountIn);
        router.swap(_tokenIn, _tokenOut, _amountIn, _minOut, address(this));
        ERC20(_tokenIn).forceApprove(address(router), 0);
        received = ERC20(_tokenOut).balanceOf(address(this)) - before;
        require(received >= _minOut, "Slippage");
        emit Swapped(_tokenIn, _tokenOut, _amountIn, received);
    }

    function _processWithdrawal(uint256 _amount) internal virtual {
        if (_amount == 0) return;

        uint256 loose = balanceOfAsset();
        uint256 available = loose + valueOfDeployedAssets();
        if (_amount > available) _amount = available;

        if (_amount > loose) {
            uint256 needed = _amount - loose;
            uint256 withdrawn = _pullFunds(needed);
            if (withdrawn < needed) _amount = loose + withdrawn;
        }

        require(_amount > 0, "ZeroAmount");
        require(balanceOfAsset() >= _amount, "not enough");

        uint256 bridged = _bridgeAssets(_amount);
        _reducePending(bridged);

        emit WithdrawProcessed(bridged);

        // Report so the hub accounting matches what was just bridged.
        _sendReport();
    }

    /// @dev Bridges idle USDC that cannot be deployed (see `_excessIdle`).
    function _returnExcess() internal virtual returns (uint256 excess) {
        excess = _excessIdle();
        if (excess == 0) return 0;
        _bridgeAssets(excess);
        _reducePending(excess);
        emit ExcessReturned(excess);
    }

    function _reducePending(uint256 _amount) internal virtual {
        uint256 pending = pendingWithdrawal;
        pendingWithdrawal = _amount >= pending ? 0 : pending - _amount;
    }

    function _sendReport() internal virtual returns (uint256 _totalAssets) {
        uint256 held = balanceOfHeld();
        uint256 price;
        uint256 updatedAt;
        // Always attach the oracle observation, even with no position, so
        // the hub can run its freshness/deviation checks.
        (price, updatedAt) = latestPrice();
        _totalAssets = balanceOfAsset() + _heldToAsset(held, price);

        _bridgeMessage(
            OracleCCTPMessages.encodeReport(
                _totalAssets,
                block.timestamp,
                price,
                updatedAt
            )
        );

        emit Reported(_totalAssets);
    }

    /// @dev Tend deploys idle USDC, keeping what the hub asked back.
    function _tend(uint256 _idleAssets) internal virtual override {
        require(!isShutdown, "Shutdown");
        uint256 reserved = pendingWithdrawal;
        if (_idleAssets > reserved) _pushFunds(_idleAssets - reserved);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Max USDC that can be swapped into HELD_TOKEN right now.
    function _maxBuy() internal view virtual returns (uint256) {
        return type(uint256).max;
    }

    /// @dev Idle USDC that should be sent back to the hub on report.
    function _excessIdle() internal view virtual returns (uint256) {
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL: MATH
    //////////////////////////////////////////////////////////////*/

    function _heldToAsset(
        uint256 _held,
        uint256 _price
    ) internal view virtual returns (uint256) {
        return
            Math.mulDiv(
                _held,
                _price * ASSET_SCALE,
                HELD_SCALE * ORACLE_SCALE
            );
    }

    function _assetToHeld(
        uint256 _assets,
        uint256 _price,
        Math.Rounding _rounding
    ) internal view virtual returns (uint256) {
        return
            Math.mulDiv(
                _assets,
                HELD_SCALE * ORACLE_SCALE,
                _price * ASSET_SCALE,
                _rounding
            );
    }

    /*//////////////////////////////////////////////////////////////
                            CCTP BRIDGING
    //////////////////////////////////////////////////////////////*/

    /// @notice Bridge USDC back to the hub via CCTP.
    function _bridgeAssets(
        uint256 _amount
    ) internal virtual override returns (uint256) {
        TOKEN_MESSENGER.depositForBurn(
            _amount,
            uint32(uint256(REMOTE_ID)),
            _addressToBytes32(REMOTE_COUNTERPART),
            address(asset),
            bytes32(0),
            0,
            FINALITY_THRESHOLD_FINALIZED
        );

        return _amount;
    }

    /// @notice Send a message (no tokens) to the hub via CCTP.
    function _bridgeMessage(bytes memory _data) internal virtual override {
        MESSAGE_TRANSMITTER.sendMessage(
            uint32(uint256(REMOTE_ID)),
            _addressToBytes32(REMOTE_COUNTERPART),
            bytes32(0),
            FINALITY_THRESHOLD_FINALIZED,
            _data
        );
    }
}
