// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

import {OracleCCTPStrategy} from "../src/origin/OracleCCTPStrategy.sol";
import {OraclePricedHoldStrategy} from "../src/local/OraclePricedHoldStrategy.sol";
import {PendlePTHoldStrategy} from "../src/local/PendlePTHoldStrategy.sol";
import {CCTPHelpers} from "../src/libraries/CCTPHelpers.sol";
import {CREATE3} from "../src/libraries/CREATE3.sol";
import {TesouroAddresses} from "../src/libraries/TesouroAddresses.sol";

interface IVaultFactoryLike {
    function deploy_new_vault(
        address asset,
        string memory name,
        string memory symbol,
        address role_manager,
        uint256 profit_max_unlock_time
    ) external returns (address);
}

interface IVaultLike {
    function set_role(address account, uint256 role) external;

    function add_strategy(address new_strategy) external;

    function update_max_debt_for_strategy(
        address strategy,
        uint256 new_max_debt
    ) external;

    function set_deposit_limit(uint256 deposit_limit) external;

    function transfer_role_manager(address role_manager) external;
}

interface IDebtAllocatorLike {
    function setStrategyDebtRatio(
        address _vault,
        address _strategy,
        uint256 _targetRatio
    ) external;
}

/**
 * @notice Ethereum hub of the USD vault (USDC in, sleeves out). NOT run yet.
 *
 * Suggested debt targets (bps of vault TVL):
 *   liquid core (existing Yearn sUSDS / Morpho OG strategy) 3500
 *   SPYon (OraclePricedHoldStrategy)                        1500
 *   QQQon (OraclePricedHoldStrategy)                        1000
 *   Pendle PT (PendlePTHoldStrategy)                        2000  <- cannot exceed PT liquidity
 *   TESOURO remote (OracleCCTPStrategy -> Base)             1500  <- also capped by USD ceiling
 *   cbBTC (optional OraclePricedHoldStrategy)                500
 *
 * Order: DeployRemoteBase.deployFactory() on Base -> this script -> DeployRemoteBase.run() on Base.
 *
 * Required env: SENDER (broadcaster), MANAGEMENT, KEEPER, EMERGENCY_ADMIN,
 *   PERFORMANCE_FEE_RECIPIENT, TESOURO_REMOTE_FACTORY (Base factory address).
 *   VAULT, or ROLE_MANAGER to deploy a new vault through the Yearn 3.0.4 factory.
 * Optional env: EQUITY_ROUTER (TODO: unverified, zero = hold USDC), PENDLE_MARKET,
 *   PENDLE_ORACLE, PENDLE_ROUTER, LIQUID_CORE_STRATEGY, CBBTC, CBBTC_USD_FEED,
 *   DEBT_ALLOCATOR, TESOURO_USD_CEILING, VAULT_DEPOSIT_LIMIT, PT_MAX_DEBT,
 *   SPYON, SPYON_USD_FEED, QQQON, QQQON_USD_FEED, TESOURO (Base address used in the salt).
 */
contract DeployHub is Script {
    uint256 internal constant ETH_CHAIN_ID = 1;
    uint256 internal constant BASE_CHAIN_ID = 8453;

    // Yearn V3 vault roles
    uint256 internal constant ADD_STRATEGY_MANAGER = 1;
    uint256 internal constant QUEUE_MANAGER = 16;
    uint256 internal constant MAX_DEBT_MANAGER = 128;
    uint256 internal constant DEPOSIT_LIMIT_MANAGER = 256;

    uint256 internal constant LIQUID_CORE_BPS = 3_500;
    uint256 internal constant SPYON_BPS = 1_500;
    uint256 internal constant QQQON_BPS = 1_000;
    uint256 internal constant PT_BPS = 2_000;
    uint256 internal constant TESOURO_BPS = 1_500;
    uint256 internal constant CBBTC_BPS = 500;

    struct Roles {
        address sender;
        address management;
        address keeper;
        address emergencyAdmin;
        address feeRecipient;
    }

    struct Deployed {
        address vault;
        address hub;
        address remote;
        address spyon;
        address qqqon;
        address pt;
        address cbbtc;
        address liquidCore;
    }

    function run() external returns (Deployed memory d) {
        require(block.chainid == ETH_CHAIN_ID, "not Ethereum");

        Roles memory r = Roles({
            sender: _required("SENDER"),
            management: _required("MANAGEMENT"),
            keeper: _required("KEEPER"),
            emergencyAdmin: _required("EMERGENCY_ADMIN"),
            feeRecipient: _required("PERFORMANCE_FEE_RECIPIENT")
        });
        address remoteFactory = _required("TESOURO_REMOTE_FACTORY");
        address usdc = CCTPHelpers.ETHEREUM_USDC;
        uint256 ceiling = vm.envOr("TESOURO_USD_CEILING", uint256(75_000e6));
        address equityRouter = vm.envOr("EQUITY_ROUTER", address(0));
        if (equityRouter == address(0)) {
            console.log("[WARN] EQUITY_ROUTER not set: SPYon/QQQon sleeves hold USDC (TODO route)");
        }

        d.vault = vm.envOr("VAULT", address(0));
        bool manageVault = d.vault == address(0);

        vm.startBroadcast(r.sender);

        if (manageVault) {
            address roleManager = _required("ROLE_MANAGER");
            d.vault = IVaultFactoryLike(
                vm.envOr("YEARN_VAULT_FACTORY", TesouroAddresses.ETH_YEARN_VAULT_FACTORY)
            ).deploy_new_vault(
                    usdc,
                    vm.envOr("VAULT_NAME", string("USD Hub (TESOURO / equities / PT)")),
                    vm.envOr("VAULT_SYMBOL", string("yvUSD-hub")),
                    r.sender,
                    7 days
                );
            IVaultLike(d.vault).set_role(
                r.sender,
                ADD_STRATEGY_MANAGER |
                    QUEUE_MANAGER |
                    MAX_DEBT_MANAGER |
                    DEPOSIT_LIMIT_MANAGER
            );
            // roleManager receives the vault at the end.
            require(roleManager != address(0), "missing ROLE_MANAGER");
        }

        // ---- TESOURO hub (CCTP to Base) ------------------------------------
        {
            address predictedHub = computeCreateAddress(
                r.sender,
                vm.getNonce(r.sender)
            );
            d.remote = CREATE3.getDeployed(
                remoteFactory,
                keccak256(
                    abi.encode(
                        vm.envOr("TESOURO", TesouroAddresses.BASE_TESOURO),
                        CCTPHelpers.ETHEREUM_DOMAIN,
                        predictedHub
                    )
                )
            );

            d.hub = address(
                new OracleCCTPStrategy(
                    usdc,
                    "USD Hub TESOURO (Base)",
                    CCTPHelpers.TOKEN_MESSENGER,
                    CCTPHelpers.MESSAGE_TRANSMITTER,
                    CCTPHelpers.BASE_DOMAIN,
                    BASE_CHAIN_ID,
                    d.remote,
                    d.vault,
                    8 // RedStone TESOURO/USD decimals
                )
            );
            require(d.hub == predictedHub, "hub prediction");
            OracleCCTPStrategy(d.hub).setMaxRemoteExposure(ceiling);
            _configure(d.hub, r);
        }

        // ---- Local equity sleeves ------------------------------------------
        d.spyon = _deployHold(
            usdc,
            "USD Hub SPYon",
            vm.envOr("SPYON", TesouroAddresses.ETH_SPYON),
            vm.envOr("SPYON_USD_FEED", TesouroAddresses.ETH_CHAINLINK_SPYON_USD),
            equityRouter,
            d.vault,
            r
        );
        d.qqqon = _deployHold(
            usdc,
            "USD Hub QQQon",
            vm.envOr("QQQON", TesouroAddresses.ETH_QQQON),
            vm.envOr("QQQON_USD_FEED", TesouroAddresses.ETH_CHAINLINK_QQQON_USD),
            equityRouter,
            d.vault,
            r
        );

        address cbbtc = vm.envOr("CBBTC", address(0));
        if (cbbtc != address(0)) {
            d.cbbtc = _deployHold(
                usdc,
                "USD Hub cbBTC",
                cbbtc,
                _required("CBBTC_USD_FEED"),
                equityRouter,
                d.vault,
                r
            );
        }

        // ---- Pendle PT -------------------------------------------------------
        address market = vm.envOr("PENDLE_MARKET", address(0));
        if (market != address(0)) {
            PendlePTHoldStrategy pt = new PendlePTHoldStrategy(
                usdc,
                "USD Hub Pendle PT",
                market,
                vm.envOr("PENDLE_ORACLE", TesouroAddresses.ETH_PENDLE_PY_LP_ORACLE),
                vm.envOr("PENDLE_ROUTER", TesouroAddresses.ETH_PENDLE_ROUTER)
            );
            pt.setAllowed(d.vault, true);
            d.pt = address(pt);
            _configure(d.pt, r);
        } else {
            console.log("[WARN] PENDLE_MARKET not set: PT sleeve skipped");
        }

        d.liquidCore = vm.envOr("LIQUID_CORE_STRATEGY", address(0));

        // ---- Vault wiring ----------------------------------------------------
        if (manageVault) {
            IVaultLike v = IVaultLike(d.vault);
            if (d.liquidCore != address(0)) _add(v, d.liquidCore, type(uint256).max);
            _add(v, d.spyon, type(uint256).max);
            _add(v, d.qqqon, type(uint256).max);
            if (d.pt != address(0)) {
                _add(v, d.pt, vm.envOr("PT_MAX_DEBT", type(uint256).max));
            }
            _add(v, d.hub, ceiling); // vault max debt == USD ceiling
            if (d.cbbtc != address(0)) _add(v, d.cbbtc, type(uint256).max);

            v.set_deposit_limit(vm.envOr("VAULT_DEPOSIT_LIMIT", uint256(0)));
            v.set_role(r.sender, 0);
            v.transfer_role_manager(_required("ROLE_MANAGER"));
        } else {
            console.log("[TODO] Existing VAULT: add the strategies and max debts manually");
        }

        // ---- Debt targets ----------------------------------------------------
        address allocator = vm.envOr("DEBT_ALLOCATOR", address(0));
        if (allocator != address(0)) {
            // Broadcaster must be a manager of the allocator and the vault
            // must already be configured on it.
            IDebtAllocatorLike a = IDebtAllocatorLike(allocator);
            if (d.liquidCore != address(0)) a.setStrategyDebtRatio(d.vault, d.liquidCore, LIQUID_CORE_BPS);
            a.setStrategyDebtRatio(d.vault, d.spyon, SPYON_BPS);
            a.setStrategyDebtRatio(d.vault, d.qqqon, QQQON_BPS);
            if (d.pt != address(0)) a.setStrategyDebtRatio(d.vault, d.pt, PT_BPS);
            a.setStrategyDebtRatio(d.vault, d.hub, TESOURO_BPS);
            if (d.cbbtc != address(0)) a.setStrategyDebtRatio(d.vault, d.cbbtc, CBBTC_BPS);
        } else {
            console.log("[TODO] DEBT_ALLOCATOR not set: apply debt targets manually");
        }

        vm.stopBroadcast();

        console.log("[DEPLOYED] Vault:", d.vault);
        console.log("[DEPLOYED] Hub OracleCCTPStrategy:", d.hub);
        console.log("[PREDICTED] Base TesouroRemoteStrategy:", d.remote);
        console.log("[DEPLOYED] SPYon hold:", d.spyon);
        console.log("[DEPLOYED] QQQon hold:", d.qqqon);
        if (d.pt != address(0)) console.log("[DEPLOYED] PT hold:", d.pt);
        if (d.cbbtc != address(0)) console.log("[DEPLOYED] cbBTC hold:", d.cbbtc);
        console.log("Next: run DeployRemoteBase.run() on Base with HUB_STRATEGY =", d.hub);
    }

    function _deployHold(
        address _usdc,
        string memory _name,
        address _token,
        address _feed,
        address _router,
        address _vault,
        Roles memory _r
    ) internal returns (address s) {
        require(_token != address(0) && _feed != address(0), "zero token/feed");
        OraclePricedHoldStrategy h = new OraclePricedHoldStrategy(
            _usdc,
            _name,
            _token,
            _feed,
            _router
        );
        h.setAllowed(_vault, true);
        s = address(h);
        _configure(s, _r);
    }

    /// @dev Same defaults as StrategyFactory: fees are charged by the vault.
    function _configure(address _strategy, Roles memory _r) internal {
        ITokenizedStrategy s = ITokenizedStrategy(_strategy);
        s.setPerformanceFee(0);
        s.setProfitMaxUnlockTime(0);
        s.setPerformanceFeeRecipient(_r.feeRecipient);
        s.setKeeper(_r.keeper);
        s.setEmergencyAdmin(_r.emergencyAdmin);
        s.setPendingManagement(_r.management);
    }

    function _add(IVaultLike _v, address _strategy, uint256 _maxDebt) internal {
        _v.add_strategy(_strategy);
        _v.update_max_debt_for_strategy(_strategy, _maxDebt);
    }

    function _required(string memory _key) internal view returns (address a) {
        a = vm.envAddress(_key);
        require(a != address(0), string.concat("missing ", _key));
    }
}
