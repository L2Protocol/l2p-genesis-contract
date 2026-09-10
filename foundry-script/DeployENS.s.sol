// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import { ENS } from "../contracts/ens/ENS.sol";
import { Root } from "../contracts/ens/root/Root.sol";
import { BaseRegistrarImplementation } from "../contracts/ens/ethregistrar/BaseRegistrarImplementation.sol";
import { L2PPriceOracle } from "../contracts/ens/ethregistrar/L2PPriceOracle.sol";
import { IPriceOracle } from "../contracts/ens/ethregistrar/IPriceOracle.sol";
import { L2PRegistrarController } from "../contracts/ens/ethregistrar/L2PRegistrarController.sol";
import { ReverseRegistrar } from "../contracts/ens/reverseRegistrar/ReverseRegistrar.sol";
import { IReverseRegistrar } from "../contracts/ens/reverseRegistrar/IReverseRegistrar.sol";
import { DefaultReverseRegistrar } from "../contracts/ens/reverseRegistrar/DefaultReverseRegistrar.sol";
import { IDefaultReverseRegistrar } from "../contracts/ens/reverseRegistrar/IDefaultReverseRegistrar.sol";
import { PublicResolver } from "../contracts/ens/resolvers/PublicResolver.sol";
import { INameWrapper } from "../contracts/ens/wrapper/INameWrapper.sol";
import { GatewayProvider } from "../contracts/ens/ccipRead/GatewayProvider.sol";
import { IGatewayProvider } from "../contracts/ens/ccipRead/IGatewayProvider.sol";
import { UniversalResolver } from "../contracts/ens/universalResolver/UniversalResolver.sol";

contract DeployENS is Script {
    bytes32 internal constant ROOT_NODE = bytes32(0);
    bytes32 internal constant L2P_LABEL = keccak256("l2p");
    bytes32 internal constant L2P_NODE = 0x81416bb7c03bc54e8597f6c932543fcd87e0649cd943cb29f71df95a7487f431;
    bytes32 internal constant REVERSE_LABEL = keccak256("reverse");
    bytes32 internal constant ADDR_LABEL = keccak256("addr");
    bytes32 internal constant REVERSE_NODE = 0xa097f6721ce401e757d1223a763fef49b8b5f90bb18567ddb86fd205dff71d34;
    bytes32 internal constant ADDR_REVERSE_NODE = 0x91d1777781884d03a6757a803996e38de2a42967fb37eeaca72729271025a9e2;

    ENS internal ens;
    address internal deployer;
    address internal finalOwner;

    Root public root;
    BaseRegistrarImplementation public baseRegistrar;
    ReverseRegistrar public reverseRegistrar;
    DefaultReverseRegistrar public defaultReverseRegistrar;
    L2PPriceOracle public priceOracle;
    L2PRegistrarController public controller;
    PublicResolver public publicResolver;
    GatewayProvider public batchGatewayProvider;
    UniversalResolver public universalResolver;

    function run() external {
        ens = ENS(vm.envOr("ENS_REGISTRY", address(0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e)));

        uint256 pk = _deployerKey();
        deployer = pk == 0 ? msg.sender : vm.addr(pk);
        finalOwner = vm.envOr("ENS_OWNER", deployer);

        address rootOwner = ens.owner(ROOT_NODE);
        if (rootOwner != deployer) {
            revert(
                string.concat(
                    "DeployENS: sending as ",
                    vm.toString(deployer),
                    " but the ENS root node is owned by ",
                    vm.toString(rootOwner),
                    ". Set DEPLOYER_PRIVATE_KEY, or pass --private-key / --sender. ",
                    "If the root node is owned by a Root contract, this deployment has already run."
                )
            );
        }

        if (pk == 0) {
            vm.startBroadcast(deployer);
        } else {
            vm.startBroadcast(pk);
        }

        _deployRoot();
        _deployBaseRegistrar();
        _deployReverseRegistrars();
        _deployPriceOracle();
        _deployController();
        _deployPublicResolver();
        _wireControllers();
        _deployUniversalResolver();
        _transferOwnership();

        vm.stopBroadcast();

        _verify();
        _report();
    }

    /// @dev Reads the deployer key, accepting it with or without the 0x prefix, the way cast does.
    ///      Returns 0 when it is not set at all, which leaves the sender to --private-key/--sender.
    function _deployerKey() internal view returns (uint256) {
        string memory raw = vm.envOr("DEPLOYER_PRIVATE_KEY", string(""));
        bytes memory b = bytes(raw);
        if (b.length == 0) return 0;
        if (b.length < 2 || b[0] != "0" || b[1] != "x") {
            raw = string.concat("0x", raw);
        }
        return vm.parseUint(raw);
    }

    function _deployRoot() internal {
        root = new Root(ens);
        ens.setOwner(ROOT_NODE, address(root));
        root.setController(deployer, true);
    }

    function _deployBaseRegistrar() internal {
        baseRegistrar = new BaseRegistrarImplementation(ens, L2P_NODE);
        root.setSubnodeOwner(L2P_LABEL, address(baseRegistrar));
    }

    function _deployReverseRegistrars() internal {
        reverseRegistrar = new ReverseRegistrar(ens);
        root.setSubnodeOwner(REVERSE_LABEL, deployer);
        ens.setSubnodeOwner(REVERSE_NODE, ADDR_LABEL, address(reverseRegistrar));
        defaultReverseRegistrar = new DefaultReverseRegistrar();
    }

    function _deployPriceOracle() internal {
        uint256[] memory rentPrices = new uint256[](5);
        rentPrices[0] = vm.envOr("RENT_L2P_1_LETTER", uint256(0)) * 1 ether;
        rentPrices[1] = vm.envOr("RENT_L2P_2_LETTER", uint256(0)) * 1 ether;
        rentPrices[2] = vm.envOr("RENT_L2P_3_LETTER", uint256(640)) * 1 ether;
        rentPrices[3] = vm.envOr("RENT_L2P_4_LETTER", uint256(160)) * 1 ether;
        rentPrices[4] = vm.envOr("RENT_L2P_5_LETTER", uint256(5)) * 1 ether;

        priceOracle = new L2PPriceOracle(
            rentPrices,
            vm.envOr("START_PREMIUM_L2P", uint256(100_000)) * 1e18,
            vm.envOr("PREMIUM_TOTAL_DAYS", uint256(21))
        );
    }

    function _deployController() internal {
        controller = new L2PRegistrarController(
            baseRegistrar,
            IPriceOracle(address(priceOracle)),
            vm.envOr("MIN_COMMITMENT_AGE", uint256(60)),
            vm.envOr("MAX_COMMITMENT_AGE", uint256(86400)),
            IReverseRegistrar(address(reverseRegistrar)),
            IDefaultReverseRegistrar(address(defaultReverseRegistrar)),
            ens
        );
    }

    function _deployPublicResolver() internal {
        publicResolver =
            new PublicResolver(ens, INameWrapper(address(0)), address(controller), address(reverseRegistrar));
    }

    function _wireControllers() internal {
        baseRegistrar.addController(address(controller));
        reverseRegistrar.setController(address(controller), true);
        defaultReverseRegistrar.setController(address(controller), true);
        reverseRegistrar.setDefaultResolver(address(publicResolver));
        baseRegistrar.setResolver(address(publicResolver));
        root.setResolver(address(publicResolver));
    }

    function _deployUniversalResolver() internal {
        string[] memory urls = vm.envOr("BATCH_GATEWAY_URLS", ",", new string[](0));
        batchGatewayProvider = new GatewayProvider(finalOwner, urls);
        universalResolver = new UniversalResolver(finalOwner, ens, IGatewayProvider(address(batchGatewayProvider)));
    }

    function _transferOwnership() internal {
        if (finalOwner == deployer) return;

        root.setController(finalOwner, true);
        root.setController(deployer, false);
        root.transferOwnership(finalOwner);
        baseRegistrar.transferOwnership(finalOwner);
        reverseRegistrar.transferOwnership(finalOwner);
        defaultReverseRegistrar.transferOwnership(finalOwner);
        controller.transferOwnership(finalOwner);
        ens.setOwner(REVERSE_NODE, finalOwner);
    }

    function _verify() internal view {
        require(ens.owner(ROOT_NODE) == address(root), "root node not owned by Root");
        require(ens.owner(L2P_NODE) == address(baseRegistrar), "l2p node not owned by BaseRegistrar");
        require(ens.owner(ADDR_REVERSE_NODE) == address(reverseRegistrar), "addr.reverse not owned by ReverseRegistrar");
        require(ens.resolver(L2P_NODE) == address(publicResolver), "l2p resolver not set");
        require(baseRegistrar.controllers(address(controller)), "controller not authorised on BaseRegistrar");
        require(controller.valid("l2protocol"), "controller rejects a valid label");
    }

    function _report() internal view {
        console.log("=== ENS deployment (.l2p) ===");
        console.log("ENSRegistry            ", address(ens));
        console.log("Root                   ", address(root));
        console.log("BaseRegistrar (.l2p)   ", address(baseRegistrar));
        console.log("ReverseRegistrar       ", address(reverseRegistrar));
        console.log("DefaultReverseRegistrar", address(defaultReverseRegistrar));
        console.log("L2PPriceOracle         ", address(priceOracle));
        console.log("L2PRegistrarController ", address(controller));
        console.log("PublicResolver         ", address(publicResolver));
        console.log("BatchGatewayProvider   ", address(batchGatewayProvider));
        console.log("UniversalResolver      ", address(universalResolver));
        console.log("owner                  ", finalOwner);
    }
}
