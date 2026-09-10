// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import { DeployENS } from "../foundry-script/DeployENS.s.sol";
import { ENS } from "../contracts/ens/ENS.sol";
import { ENSRegistry } from "../contracts/ens/ENSRegistry.sol";
import { IETHRegistrarController } from "../contracts/ens/ethregistrar/IETHRegistrarController.sol";
import { IPriceOracle } from "../contracts/ens/ethregistrar/IPriceOracle.sol";

contract ENSDeploymentTest is Test, DeployENS {
    bytes32 internal constant SECRET = keccak256("secret");
    uint256 internal constant ONE_YEAR = 365 days;

    address internal alice = address(0xA11CE);

    function setUp() public {
        vm.warp(1788865500);

        ENSRegistry registry = new ENSRegistry();
        ens = ENS(address(registry));
        deployer = address(this);
        finalOwner = address(this);

        _deployRoot();
        _deployBaseRegistrar();
        _deployReverseRegistrars();
        _deployPriceOracle();
        _deployController();
        _deployPublicResolver();
        _wireControllers();
        _deployUniversalResolver();
        _verify();

        vm.deal(alice, 1000 ether);
    }

    function test_NamehashConstantMatchesLabel() public pure {
        assertEq(L2P_NODE, keccak256(abi.encodePacked(ROOT_NODE, keccak256("l2p"))));
    }

    function test_RootOwnsRootNode() public view {
        assertEq(ens.owner(ROOT_NODE), address(root));
    }

    function test_BaseRegistrarOwnsL2pNode() public view {
        assertEq(ens.owner(L2P_NODE), address(baseRegistrar));
        assertEq(baseRegistrar.baseNode(), L2P_NODE);
    }

    function test_ReverseRegistrarOwnsAddrReverse() public view {
        assertEq(ens.owner(ADDR_REVERSE_NODE), address(reverseRegistrar));
    }

    function test_LabelsShorterThanThreeAreInvalid() public view {
        assertFalse(controller.valid("ab"));
        assertTrue(controller.valid("abc"));
    }

    function test_RegisterAndResolve() public {
        _register("l2protocol", alice);

        bytes32 node = keccak256(abi.encodePacked(L2P_NODE, keccak256("l2protocol")));
        assertEq(ens.owner(node), alice);
        assertEq(ens.resolver(node), address(publicResolver));
        assertEq(baseRegistrar.ownerOf(uint256(keccak256("l2protocol"))), alice);
        assertFalse(controller.available("l2protocol"));

        vm.prank(alice);
        publicResolver.setAddr(node, alice);
        assertEq(publicResolver.addr(node), alice);

        (bytes memory result, address resolverUsed) = universalResolver.resolve(
            hex"0a6c3270726f746f636f6c036c327000", abi.encodeWithSignature("addr(bytes32)", node)
        );
        assertEq(resolverUsed, address(publicResolver));
        assertEq(abi.decode(result, (address)), alice);
    }

    function test_ReverseResolution() public {
        _register("l2protocol", alice);
        bytes32 node = keccak256(abi.encodePacked(L2P_NODE, keccak256("l2protocol")));

        vm.startPrank(alice);
        publicResolver.setAddr(node, alice);
        reverseRegistrar.setNameForAddr(alice, alice, address(publicResolver), "l2protocol.l2p");
        vm.stopPrank();

        (string memory name,,) = universalResolver.reverse(abi.encodePacked(alice), 60);
        assertEq(name, "l2protocol.l2p");
    }

    function test_RegisterRevertsWithoutCommitment() public {
        IETHRegistrarController.Registration memory reg = _registration("l2protocol", alice);
        IPriceOracle.Price memory price = controller.rentPrice("l2protocol", ONE_YEAR);

        vm.prank(alice);
        vm.expectRevert();
        controller.register{ value: price.base + price.premium }(reg);
    }

    function test_RenewExtendsExpiry() public {
        _register("l2protocol", alice);
        uint256 id = uint256(keccak256("l2protocol"));
        uint256 before = baseRegistrar.nameExpires(id);

        IPriceOracle.Price memory price = controller.rentPrice("l2protocol", ONE_YEAR);
        vm.prank(alice);
        controller.renew{ value: price.base + price.premium }("l2protocol", ONE_YEAR, bytes32(0));

        assertEq(baseRegistrar.nameExpires(id), before + ONE_YEAR);
    }

    function test_NameBecomesAvailableAfterExpiryAndGracePeriod() public {
        _register("l2protocol", alice);
        uint256 id = uint256(keccak256("l2protocol"));

        vm.warp(baseRegistrar.nameExpires(id) + 1);
        assertFalse(controller.available("l2protocol"));

        vm.warp(baseRegistrar.nameExpires(id) + baseRegistrar.GRACE_PERIOD() + 1);
        assertTrue(controller.available("l2protocol"));
    }

    function test_OwnershipIsHandedToFinalOwner() public {
        address newOwner = address(0xB0B);

        ENSRegistry registry = new ENSRegistry();
        ens = ENS(address(registry));
        deployer = address(this);
        finalOwner = newOwner;

        _deployRoot();
        _deployBaseRegistrar();
        _deployReverseRegistrars();
        _deployPriceOracle();
        _deployController();
        _deployPublicResolver();
        _wireControllers();
        _deployUniversalResolver();
        _transferOwnership();
        _verify();

        assertEq(root.owner(), newOwner);
        assertEq(baseRegistrar.owner(), newOwner);
        assertEq(reverseRegistrar.owner(), newOwner);
        assertEq(defaultReverseRegistrar.owner(), newOwner);
        assertEq(controller.owner(), newOwner);
        assertEq(ens.owner(REVERSE_NODE), newOwner);

        assertTrue(root.controllers(newOwner));
        assertFalse(root.controllers(address(this)));
    }

    function test_PriceIsFixedInL2P() public view {
        // 5 L2P per year for names of five characters and up, priced per second.
        IPriceOracle.Price memory oneYear = controller.rentPrice("l2protocol", ONE_YEAR);
        assertEq(oneYear.base, 5 ether);
        assertEq(oneYear.premium, 0);

        IPriceOracle.Price memory twoYears = controller.rentPrice("l2protocol", 2 * ONE_YEAR);
        assertEq(twoYears.base, 2 * oneYear.base);
    }

    function test_ShorterNamesCostMore() public view {
        uint256 three = controller.rentPrice("abc", ONE_YEAR).base;
        uint256 four = controller.rentPrice("abcd", ONE_YEAR).base;
        uint256 five = controller.rentPrice("abcde", ONE_YEAR).base;

        assertEq(three, 640 ether);
        assertEq(four, 160 ether);
        assertEq(five, 5 ether);
    }

    function test_PremiumDecaysToZeroAfterTheDecayPeriod() public {
        _register("l2protocol", alice);
        uint256 expiry = baseRegistrar.nameExpires(uint256(keccak256("l2protocol")));
        uint256 auctionStart = expiry + baseRegistrar.GRACE_PERIOD();

        vm.warp(auctionStart + 1);
        uint256 atStart = controller.rentPrice("l2protocol", ONE_YEAR).premium;
        assertGt(atStart, 0);

        vm.warp(auctionStart + 1 days);
        uint256 afterOneDay = controller.rentPrice("l2protocol", ONE_YEAR).premium;
        assertLt(afterOneDay, atStart);

        vm.warp(auctionStart + 21 days);
        assertEq(controller.rentPrice("l2protocol", ONE_YEAR).premium, 0);
    }

    function _registration(
        string memory label,
        address owner
    ) internal pure returns (IETHRegistrarController.Registration memory) {
        return IETHRegistrarController.Registration({
            label: label,
            owner: owner,
            duration: ONE_YEAR,
            secret: SECRET,
            resolver: address(0),
            data: new bytes[](0),
            reverseRecord: 0,
            referrer: bytes32(0)
        });
    }

    function _register(
        string memory label,
        address owner
    ) internal {
        IETHRegistrarController.Registration memory reg = _registration(label, owner);
        reg.resolver = address(publicResolver);

        vm.startPrank(owner);
        controller.commit(controller.makeCommitment(reg));
        vm.warp(block.timestamp + 61);

        IPriceOracle.Price memory price = controller.rentPrice(label, ONE_YEAR);
        controller.register{ value: price.base + price.premium }(reg);
        vm.stopPrank();
    }
}
