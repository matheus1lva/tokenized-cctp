// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

import {TesouroRemoteStrategy} from "./TesouroRemoteStrategy.sol";
import {CREATE3} from "../libraries/CREATE3.sol";
import {Governance} from "@periphery/utils/Governance.sol";
import {BaseCCTP} from "../bases/BaseCCTP.sol";

/**
 * @title TesouroRemoteStrategyFactory (Base)
 * @notice CREATE3 factory for TesouroRemoteStrategy, following the
 *         RemoteStrategyFactory pattern: the address only depends on
 *         (factory, tesouro, origin domain, hub strategy), so the hub can
 *         be deployed on Ethereum first with the predicted remote address.
 * @dev Unlike RemoteStrategyFactory, deployment is governance-only: the
 *      oracle/router arguments are not part of the salt, so a permissionless
 *      deploy could be front-run with malicious parameters at the predicted
 *      address.
 */
contract TesouroRemoteStrategyFactory is Governance, BaseCCTP {
    event NewRemoteStrategy(
        address indexed strategy,
        address indexed tesouro,
        uint32 indexed remoteDomain,
        address remoteCounterpart
    );

    struct RemoteParams {
        address tesouro;
        address tesouroUsdOracle;
        address brlUsdOracle; // may be zero to disable the FX stop
        address router; // may be zero until a route is verified
    }

    /// @notice keccak256(tesouro, remoteDomain, remoteCounterpart) => strategy
    mapping(bytes32 => address) public deployments;

    constructor(
        address _governance,
        address _usdc,
        address _tokenMessenger,
        address _messageTransmitter
    )
        Governance(_governance)
        BaseCCTP(_usdc, _tokenMessenger, _messageTransmitter)
    {}

    function deployRemoteStrategy(
        uint32 _remoteDomain,
        address _remoteCounterpart,
        RemoteParams calldata _params
    ) external onlyGovernance returns (address) {
        require(
            _params.tesouro != address(0) &&
                _params.tesouroUsdOracle != address(0) &&
                _remoteCounterpart != address(0),
            "ZeroAddress"
        );

        bytes32 salt = getSalt(
            _params.tesouro,
            _remoteDomain,
            _remoteCounterpart
        );

        if (deployments[salt] != address(0)) return deployments[salt];

        bytes memory creationCode = abi.encodePacked(
            type(TesouroRemoteStrategy).creationCode,
            abi.encode(
                USDC,
                governance,
                address(TOKEN_MESSENGER),
                address(MESSAGE_TRANSMITTER),
                _remoteDomain,
                _remoteCounterpart,
                _params.tesouro,
                _params.tesouroUsdOracle,
                _params.brlUsdOracle,
                _params.router
            )
        );

        address strategyAddress = CREATE3.deploy(salt, creationCode, 0);
        deployments[salt] = strategyAddress;

        emit NewRemoteStrategy(
            strategyAddress,
            _params.tesouro,
            _remoteDomain,
            _remoteCounterpart
        );

        return strategyAddress;
    }

    function computeCreateAddress(
        address _tesouro,
        uint32 _remoteDomain,
        address _remoteCounterpart
    ) public view returns (address) {
        return
            CREATE3.getDeployed(
                address(this),
                getSalt(_tesouro, _remoteDomain, _remoteCounterpart)
            );
    }

    function getSalt(
        address _tesouro,
        uint32 _remoteDomain,
        address _remoteCounterpart
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encode(_tesouro, _remoteDomain, _remoteCounterpart));
    }

    function handleReceiveFinalizedMessage(
        uint32,
        bytes32,
        uint32,
        bytes calldata
    ) external virtual override returns (bool) {
        revert("Not implemented");
    }
}
