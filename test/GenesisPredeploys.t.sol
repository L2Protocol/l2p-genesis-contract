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

    // Runtime code hashes on Ethereum, BSC, Polygon, Arbitrum, Base and Optimism.
    bytes32 internal constant CREATEX_CODE_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    bytes32 internal constant CREATE2_FACTORY_CODE_HASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

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

        assertEq(CREATEX.codehash, CREATEX_CODE_HASH, "CreateX code");
        assertEq(
            DETERMINISTIC_DEPLOYMENT_PROXY.codehash, CREATE2_FACTORY_CODE_HASH, "deterministic deployment proxy code"
        );
        assertEq(SAFE_SINGLETON_FACTORY.codehash, CREATE2_FACTORY_CODE_HASH, "Safe singleton factory code");
        assertEq(WL2P.code, vm.getDeployedCode("WL2P.sol:WL2P"), "WL2P code differs from the build");

        _checkWL2P();
        _checkCreateX();
        _checkCreate2Factory(DETERMINISTIC_DEPLOYMENT_PROXY);
        _checkCreate2Factory(SAFE_SINGLETON_FACTORY);
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
}
