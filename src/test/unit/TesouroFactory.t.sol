// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {UnitSetup} from "./utils/UnitSetup.sol";
import {TesouroRemoteStrategyFactory} from "../../remote/TesouroRemoteStrategyFactory.sol";
import {TesouroRemoteStrategy} from "../../remote/TesouroRemoteStrategy.sol";
import {CREATE3} from "../../libraries/CREATE3.sol";

contract TesouroFactoryTest is UnitSetup {
    function test_factory_predictsAndDeploys() public {
        TesouroRemoteStrategyFactory f = new TesouroRemoteStrategyFactory(
            governance,
            address(usdcBase),
            address(baseMessenger),
            address(baseTransmitter)
        );
        address hubAddr = address(0x1234567);

        // Hub side can predict with only the factory address + salt.
        address predicted = CREATE3.getDeployed(
            address(f),
            keccak256(abi.encode(address(tesouro), ETHEREUM_DOMAIN, hubAddr))
        );
        assertEq(
            predicted,
            f.computeCreateAddress(address(tesouro), ETHEREUM_DOMAIN, hubAddr)
        );

        TesouroRemoteStrategyFactory.RemoteParams memory p = TesouroRemoteStrategyFactory
            .RemoteParams({
                tesouro: address(tesouro),
                tesouroUsdOracle: address(tesouroOracle),
                brlUsdOracle: address(brlOracle),
                router: address(0)
            });

        vm.expectRevert("!governance");
        vm.prank(stranger);
        f.deployRemoteStrategy(ETHEREUM_DOMAIN, hubAddr, p);

        vm.prank(governance);
        address deployed = f.deployRemoteStrategy(ETHEREUM_DOMAIN, hubAddr, p);
        assertEq(deployed, predicted);

        TesouroRemoteStrategy r = TesouroRemoteStrategy(deployed);
        assertEq(r.governance(), governance);
        assertEq(r.REMOTE_COUNTERPART(), hubAddr);
        assertEq(uint256(r.REMOTE_ID()), ETHEREUM_DOMAIN);
        assertEq(address(r.HELD_TOKEN()), address(tesouro));
        assertEq(address(r.FX_ORACLE()), address(brlOracle));
        assertEq(address(r.router()), address(0));
    }
}
