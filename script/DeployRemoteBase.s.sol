// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import {TesouroRemoteStrategyFactory} from "../src/remote/TesouroRemoteStrategyFactory.sol";
import {TesouroRemoteStrategy} from "../src/remote/TesouroRemoteStrategy.sol";
import {CCTPHelpers} from "../src/libraries/CCTPHelpers.sol";
import {TesouroAddresses} from "../src/libraries/TesouroAddresses.sol";

/**
 * @notice Base side of the USD hub / TESOURO deployment. NOT run yet.
 *
 * Step 1 (Base):    forge script script/DeployRemoteBase.s.sol --sig "deployFactory()" \
 *                     --rpc-url $BASE_RPC_URL --broadcast
 *                   env: REMOTE_GOVERNANCE
 * Step 2 (Ethereum): script/DeployHub.s.sol with TESOURO_REMOTE_FACTORY = step 1 output.
 * Step 3 (Base):    forge script script/DeployRemoteBase.s.sol \
 *                     --rpc-url $BASE_RPC_URL --broadcast   (broadcaster = REMOTE_GOVERNANCE)
 *                   env: TESOURO_REMOTE_FACTORY, HUB_STRATEGY
 *                   optional: TESOURO_SWAP_ROUTER (TODO: unverified route, zero = hold USDC),
 *                             REMOTE_KEEPER, TESOURO_USD_CEILING (default 75_000e6),
 *                             DISABLE_FX_STOP (bool), TESOURO, TESOURO_USD_ORACLE, BRL_USD_ORACLE
 */
contract DeployRemoteBase is Script {
    uint256 internal constant BASE_CHAIN_ID = 8453;

    function deployFactory() external returns (address factory) {
        require(block.chainid == BASE_CHAIN_ID, "not Base");
        address governance = _required("REMOTE_GOVERNANCE");

        vm.startBroadcast();
        factory = address(
            new TesouroRemoteStrategyFactory(
                governance,
                CCTPHelpers.BASE_USDC,
                CCTPHelpers.TOKEN_MESSENGER,
                CCTPHelpers.MESSAGE_TRANSMITTER
            )
        );
        vm.stopBroadcast();

        console.log("[DEPLOYED] TesouroRemoteStrategyFactory (Base):", factory);
    }

    function run() external returns (address remote) {
        require(block.chainid == BASE_CHAIN_ID, "not Base");

        TesouroRemoteStrategyFactory factory = TesouroRemoteStrategyFactory(
            _required("TESOURO_REMOTE_FACTORY")
        );
        address hub = _required("HUB_STRATEGY");

        address tesouro = vm.envOr("TESOURO", TesouroAddresses.BASE_TESOURO);
        address tesouroOracle = vm.envOr(
            "TESOURO_USD_ORACLE",
            TesouroAddresses.BASE_REDSTONE_TESOURO_USD
        );
        address brlOracle = vm.envOr("DISABLE_FX_STOP", false)
            ? address(0)
            : vm.envOr("BRL_USD_ORACLE", TesouroAddresses.BASE_CHAINLINK_BRL_USD);
        address router = vm.envOr("TESOURO_SWAP_ROUTER", address(0));
        address remoteKeeper = vm.envOr("REMOTE_KEEPER", address(0));
        uint256 ceiling = vm.envOr("TESOURO_USD_CEILING", uint256(75_000e6));

        require(tesouro != address(0) && tesouroOracle != address(0), "zero");
        if (router == address(0)) {
            console.log("[WARN] TESOURO_SWAP_ROUTER not set: strategy will hold USDC (TODO route)");
        }

        address predicted = factory.computeCreateAddress(
            tesouro,
            CCTPHelpers.ETHEREUM_DOMAIN,
            hub
        );

        vm.startBroadcast();

        remote = factory.deployRemoteStrategy(
            CCTPHelpers.ETHEREUM_DOMAIN,
            hub,
            TesouroRemoteStrategyFactory.RemoteParams({
                tesouro: tesouro,
                tesouroUsdOracle: tesouroOracle,
                brlUsdOracle: brlOracle,
                router: router
            })
        );

        // Broadcaster must be the factory governance (also strategy governance).
        TesouroRemoteStrategy s = TesouroRemoteStrategy(remote);
        if (remoteKeeper != address(0)) s.setKeeper(remoteKeeper);
        if (ceiling != s.maxUsdExposure()) s.setMaxUsdExposure(ceiling);

        vm.stopBroadcast();

        require(remote == predicted, "Address mismatch!");
        console.log("[DEPLOYED] TesouroRemoteStrategy (Base):", remote);
        console.log("           hub counterpart:", hub);
        console.log("           maxUsdExposure:", ceiling);
    }

    function _required(string memory _key) internal view returns (address a) {
        a = vm.envAddress(_key);
        require(a != address(0), string.concat("missing ", _key));
    }
}
