// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "forge-std/Test.sol";

interface IWL2P {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(
        address owner
    ) external view returns (uint256);
    function deposit() external payable;
    function withdraw(
        uint256 wad
    ) external;
    function transfer(
        address dst,
        uint256 wad
    ) external returns (bool);
}

interface ICreateX {
    function deployCreate2(
        bytes32 salt,
        bytes memory initCode
    ) external payable returns (address);
    function computeCreate2Address(
        bytes32 salt,
        bytes32 initCodeHash
    ) external view returns (address);
}

interface IERC1820Registry {
    function setInterfaceImplementer(
        address account,
        bytes32 interfaceHash,
        address implementer
    ) external;
    function getInterfaceImplementer(
        address account,
        bytes32 interfaceHash
    ) external view returns (address);
    function setManager(
        address account,
        address newManager
    ) external;
    function getManager(
        address account
    ) external view returns (address);
    function interfaceHash(
        string calldata interfaceName
    ) external pure returns (bytes32);
}

interface IImmutableCreate2Factory {
    function safeCreate2(
        bytes32 salt,
        bytes calldata initializationCode
    ) external payable returns (address);
    function findCreate2Address(
        bytes32 salt,
        bytes calldata initCode
    ) external view returns (address);
    function hasBeenDeployed(
        address deploymentAddress
    ) external view returns (bool);
}

contract ERC1820Implementer {
    bytes32 internal constant ERC1820_ACCEPT_MAGIC = keccak256("ERC1820_ACCEPT_MAGIC");

    function canImplementInterfaceForAddress(
        bytes32,
        address
    ) external pure returns (bytes32) {
        return ERC1820_ACCEPT_MAGIC;
    }
}

contract Greeter {
    function greet() external pure returns (string memory) {
        return "hello";
    }
}

// Loads the predeploys from the generated genesis files exactly as written there (code and
// storage, no constructor) and checks that they behave like their counterparts on other chains.
contract GenesisPredeploysTest is Test {
    address internal constant WL2P = 0x0000000000000000000000000000000000003001;
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    address internal constant DETERMINISTIC_DEPLOYMENT_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    address internal constant SAFE_SINGLETON_FACTORY = 0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7;
    address internal constant ERC1820_REGISTRY = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    address internal constant IMMUTABLE_CREATE2_FACTORY = 0x0000000000FFe8B47B3e2130213B802212439497;

    // Runtime code hashes on Ethereum, BSC, Polygon, Arbitrum, Base and Optimism.
    bytes32 internal constant CREATEX_CODE_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    bytes32 internal constant CREATE2_FACTORY_CODE_HASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;
    bytes32 internal constant ERC1820_CODE_HASH = 0xf0aa940bb32e37c5f7268b53acc48c7cdd148cd0fc196f30faa00a4d66c0443a;
    bytes32 internal constant IMMUTABLE_CREATE2_FACTORY_CODE_HASH =
        0x767db8f19b71e367540fa372e8e81e4dcb7ca8feede0ae58a0c0bd08b7320dee;

    address internal alice = address(0xA11CE);

    function test_mainnetGenesis() public {
        _checkGenesis("genesis.json");
    }

    function test_testnetGenesis() public {
        _checkGenesis("genesis-testnet.json");
    }

    function test_devGenesis() public {
        _checkGenesis("genesis-dev.json");
    }

    function _checkGenesis(
        string memory file
    ) internal {
        string memory json = vm.readFile(file);
        _load(json, WL2P);
        _load(json, CREATEX);
        _load(json, DETERMINISTIC_DEPLOYMENT_PROXY);
        _load(json, SAFE_SINGLETON_FACTORY);
        _load(json, ERC1820_REGISTRY);
        _load(json, IMMUTABLE_CREATE2_FACTORY);

        assertEq(CREATEX.codehash, CREATEX_CODE_HASH, "CreateX code");
        assertEq(
            DETERMINISTIC_DEPLOYMENT_PROXY.codehash, CREATE2_FACTORY_CODE_HASH, "deterministic deployment proxy code"
        );
        assertEq(SAFE_SINGLETON_FACTORY.codehash, CREATE2_FACTORY_CODE_HASH, "Safe singleton factory code");
        assertEq(ERC1820_REGISTRY.codehash, ERC1820_CODE_HASH, "ERC-1820 registry code");
        assertEq(
            IMMUTABLE_CREATE2_FACTORY.codehash, IMMUTABLE_CREATE2_FACTORY_CODE_HASH, "ImmutableCreate2Factory code"
        );
        assertEq(WL2P.code, vm.getDeployedCode("WL2P.sol:WL2P"), "WL2P code differs from the build");

        _checkWL2P();
        _checkCreateX();
        _checkCreate2Factory(DETERMINISTIC_DEPLOYMENT_PROXY);
        _checkCreate2Factory(SAFE_SINGLETON_FACTORY);
        _checkERC1820Registry();
        _checkImmutableCreate2Factory();
    }

    function _load(
        string memory json,
        address account
    ) internal {
        string memory key = string.concat(".alloc['", vm.toString(account), "']");
        vm.etch(account, vm.parseJsonBytes(json, string.concat(key, ".code")));

        string memory storageKey = string.concat(key, ".storage");
        if (!vm.keyExistsJson(json, storageKey)) {
            return;
        }
        string[] memory slots = vm.parseJsonKeys(json, storageKey);
        for (uint256 i = 0; i < slots.length; i++) {
            bytes32 value = vm.parseJsonBytes32(json, string.concat(storageKey, "['", slots[i], "']"));
            vm.store(account, vm.parseBytes32(slots[i]), value);
        }
    }

    function _checkWL2P() internal {
        IWL2P wl2p = IWL2P(WL2P);
        assertEq(wl2p.name(), "Wrapped L2P");
        assertEq(wl2p.symbol(), "WL2P");
        assertEq(wl2p.decimals(), 18);
        assertEq(wl2p.totalSupply(), 0);

        vm.deal(alice, 3 ether);
        vm.startPrank(alice);
        wl2p.deposit{ value: 2 ether }();
        (bool sent,) = WL2P.call{ value: 1 ether }("");
        assertTrue(sent);
        assertEq(wl2p.balanceOf(alice), 3 ether);
        assertEq(wl2p.totalSupply(), 3 ether);

        assertTrue(wl2p.transfer(address(0xB0B), 1 ether));
        wl2p.withdraw(2 ether);
        vm.stopPrank();

        assertEq(wl2p.balanceOf(alice), 0);
        assertEq(wl2p.balanceOf(address(0xB0B)), 1 ether);
        assertEq(alice.balance, 2 ether);
        assertEq(wl2p.totalSupply(), 1 ether);
    }

    function _checkCreateX() internal {
        bytes memory initCode = type(Greeter).creationCode;
        bytes32 salt = keccak256("l2p-genesis");

        address expected = ICreateX(CREATEX).computeCreate2Address(keccak256(abi.encode(salt)), keccak256(initCode));
        address deployed = ICreateX(CREATEX).deployCreate2(salt, initCode);

        assertEq(deployed, expected);
        assertEq(Greeter(deployed).greet(), "hello");
    }

    function _checkCreate2Factory(
        address factory
    ) internal {
        bytes memory initCode = type(Greeter).creationCode;
        bytes32 salt = keccak256("l2p-genesis");

        (bool success, bytes memory result) = factory.call(abi.encodePacked(salt, initCode));
        assertTrue(success);

        address expected = vm.computeCreate2Address(salt, keccak256(initCode), factory);
        assertEq(address(bytes20(result)), expected);
        assertEq(Greeter(expected).greet(), "hello");
    }

    function _checkERC1820Registry() internal {
        IERC1820Registry registry = IERC1820Registry(ERC1820_REGISTRY);
        bytes32 interfaceHash = registry.interfaceHash("ERC777TokensRecipient");
        assertEq(interfaceHash, keccak256("ERC777TokensRecipient"));

        assertEq(registry.getManager(alice), alice);
        assertEq(registry.getInterfaceImplementer(alice, interfaceHash), address(0));

        address implementer = address(new ERC1820Implementer());
        vm.prank(alice);
        registry.setInterfaceImplementer(alice, interfaceHash, implementer);
        assertEq(registry.getInterfaceImplementer(alice, interfaceHash), implementer);

        vm.prank(alice);
        registry.setManager(alice, address(0xB0B));
        assertEq(registry.getManager(alice), address(0xB0B));

        vm.prank(alice);
        vm.expectRevert("Not the manager");
        registry.setInterfaceImplementer(alice, interfaceHash, address(0));
    }

    function _checkImmutableCreate2Factory() internal {
        IImmutableCreate2Factory factory = IImmutableCreate2Factory(IMMUTABLE_CREATE2_FACTORY);
        bytes memory initCode = type(Greeter).creationCode;
        bytes32 salt = bytes32(abi.encodePacked(alice, bytes12(keccak256("l2p-genesis"))));

        address expected = vm.computeCreate2Address(salt, keccak256(initCode), IMMUTABLE_CREATE2_FACTORY);
        assertEq(factory.findCreate2Address(salt, initCode), expected);

        vm.prank(address(0xB0B));
        vm.expectRevert("Invalid salt - first 20 bytes of the salt must match calling address.");
        factory.safeCreate2(salt, initCode);

        vm.prank(alice);
        assertEq(factory.safeCreate2(salt, initCode), expected);
        assertTrue(factory.hasBeenDeployed(expected));
        assertEq(Greeter(expected).greet(), "hello");
    }
}
