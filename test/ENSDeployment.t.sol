// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import { DeployENS } from "../foundry-script/DeployENS.s.sol";
import { ENS } from "../contracts/ens/ENS.sol";
import { IETHRegistrarController } from "../contracts/ens/ethregistrar/IETHRegistrarController.sol";
import { IPriceOracle } from "../contracts/ens/ethregistrar/IPriceOracle.sol";
import { L2PUsdOracle } from "../contracts/ens/ethregistrar/L2PUsdOracle.sol";

contract ENSDeploymentTest is Test, DeployENS {
    bytes32 internal constant SECRET = keccak256("secret");
    uint256 internal constant ONE_YEAR = 365 days;
    uint256 internal constant PRICE_TOLERANCE = 1e9; // 1e-9 relative, see test_PriceIsPeggedToUsd

    address internal alice = address(0xA11CE);
    address internal rateKey = address(0x0AC1E);

    function setUp() public {
        vm.warp(1788865500);

        ens = _deployRegistry();
        deployer = address(this);
        finalOwner = address(this);
        oracleUpdater = rateKey;

        _deployRoot();
        _deployBaseRegistrar();
        _deployReverseRegistrars();
        _deployPriceOracle();
        _deployController();
        _deployPublicResolver();
        _wireControllers();
        _deployUniversalResolver();
        _verify();

        vm.deal(alice, 1_000_000 ether);
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

        ens = _deployRegistry();
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
        assertEq(usdOracle.owner(), newOwner);
        assertEq(usdOracle.updater(), rateKey);
        assertEq(ens.owner(REVERSE_NODE), newOwner);

        assertTrue(root.controllers(newOwner));
        assertFalse(root.controllers(address(this)));
    }

    function test_VerifyCatchesAnIncompleteHandover() public {
        finalOwner = address(0xB0B);
        vm.expectRevert("Root not owned by the final owner");
        this.verifyExternally();
    }

    function verifyExternally() external view {
        _verify();
    }

    function test_DefaultOracleUpdaterIsTheMainnetKeyOnlyOnMainnet() public {
        vm.chainId(12216);
        assertEq(_defaultOracleUpdater(), 0x4c7E113666b776298246B7208a6564E251Bb370D);

        vm.chainId(714);
        assertEq(_defaultOracleUpdater(), deployer);
    }

    function test_PriceIsPeggedToUsd() public view {
        // $5 per year for names of five characters and up, at $0.0001 per L2P, priced per second.
        // The per-second price is rounded down, so a year comes out a hair under the round number.
        IPriceOracle.Price memory oneYear = controller.rentPrice("l2protocol", ONE_YEAR);
        assertApproxEqRel(oneYear.base, 50_000 ether, PRICE_TOLERANCE);
        assertEq(oneYear.premium, 0);

        IPriceOracle.Price memory twoYears = controller.rentPrice("l2protocol", 2 * ONE_YEAR);
        assertEq(twoYears.base, 2 * oneYear.base);
    }

    function test_ShorterNamesCostMore() public view {
        uint256 three = controller.rentPrice("abc", ONE_YEAR).base;
        uint256 four = controller.rentPrice("abcd", ONE_YEAR).base;
        uint256 five = controller.rentPrice("abcde", ONE_YEAR).base;

        assertApproxEqRel(three, 6_400_000 ether, PRICE_TOLERANCE);
        assertApproxEqRel(four, 1_600_000 ether, PRICE_TOLERANCE);
        assertApproxEqRel(five, 50_000 ether, PRICE_TOLERANCE);
    }

    function test_PriceInL2PFollowsTheUsdOracle() public {
        uint256 before = controller.rentPrice("l2protocol", ONE_YEAR).base;

        // L2P doubles in USD terms, so a name costs half as much L2P.
        usdOracle.setLatestAnswer(20_000);
        assertApproxEqRel(controller.rentPrice("l2protocol", ONE_YEAR).base, before / 2, PRICE_TOLERANCE);

        // At $1.00 per L2P the USD prices are the L2P prices.
        usdOracle.setBounds(1, 1e9);
        usdOracle.setLatestAnswer(1e8);
        assertApproxEqRel(controller.rentPrice("l2protocol", ONE_YEAR).base, 5 ether, PRICE_TOLERANCE);
        assertApproxEqRel(controller.rentPrice("abc", ONE_YEAR).base, 640 ether, PRICE_TOLERANCE);
    }

    function test_OracleStartsWithBoundsAroundTheInitialRate() public view {
        assertEq(usdOracle.latestAnswer(), 10_000);
        assertEq(usdOracle.minAnswer(), 100);
        assertEq(usdOracle.maxAnswer(), 1_000_000);
    }

    function test_OnlyTheOwnerAndTheUpdaterCanSetTheUsdPrice() public {
        vm.prank(alice);
        vm.expectRevert(L2PUsdOracle.NotUpdater.selector);
        usdOracle.setLatestAnswer(20_000);

        vm.prank(rateKey);
        usdOracle.setLatestAnswer(20_000);
        assertEq(usdOracle.latestAnswer(), 20_000);

        usdOracle.setLatestAnswer(10_000);
        assertEq(usdOracle.latestAnswer(), 10_000);
    }

    function test_UpdaterIsHeldToDoublingOrHalvingPerDay() public {
        vm.startPrank(rateKey);
        vm.expectRevert(
            abi.encodeWithSelector(L2PUsdOracle.AnswerChangeTooLarge.selector, int256(10_000), int256(20_001))
        );
        usdOracle.setLatestAnswer(20_001);
        vm.expectRevert(
            abi.encodeWithSelector(L2PUsdOracle.AnswerChangeTooLarge.selector, int256(10_000), int256(4_999))
        );
        usdOracle.setLatestAnswer(4_999);

        // hourly updates move freely within the day's range, but stepping does not stretch it
        usdOracle.setLatestAnswer(15_000);
        vm.warp(block.timestamp + 1 hours);
        usdOracle.setLatestAnswer(20_000);
        vm.warp(block.timestamp + 1 hours);
        vm.expectRevert(
            abi.encodeWithSelector(L2PUsdOracle.AnswerChangeTooLarge.selector, int256(10_000), int256(30_000))
        );
        usdOracle.setLatestAnswer(30_000);
        usdOracle.setLatestAnswer(5_000);

        // a new day starts from the rate as it stands then
        vm.warp(usdOracle.windowStart() + usdOracle.UPDATE_WINDOW());
        usdOracle.setLatestAnswer(10_000);
        assertEq(usdOracle.windowStartAnswer(), 5_000);
        vm.stopPrank();
    }

    function test_ALeakedUpdaterNeedsAboutAWeekToReachTheTopBound() public {
        vm.startPrank(rateKey);
        uint256 start = block.timestamp;
        int256 top = usdOracle.maxAnswer();
        while (usdOracle.latestAnswer() < top) {
            int256 next = usdOracle.latestAnswer() * 2;
            usdOracle.setLatestAnswer(next > top ? top : next);
            vm.warp(usdOracle.windowStart() + usdOracle.UPDATE_WINDOW());
        }
        vm.stopPrank();

        // seven doublings from 10_000 to the 1_000_000 bound, one per day
        assertEq(block.timestamp - start, 7 days);
    }

    function test_OwnerSettingARateStartsANewWindow() public {
        vm.warp(block.timestamp + 3 hours);
        usdOracle.setLatestAnswer(40_000);
        assertEq(usdOracle.windowStart(), block.timestamp);
        assertEq(usdOracle.windowStartAnswer(), 40_000);

        vm.prank(rateKey);
        usdOracle.setLatestAnswer(80_000);
        assertEq(usdOracle.latestAnswer(), 80_000);
    }

    function test_NobodyCanLeaveTheBounds() public {
        // the owner is not held to the step or the interval, but is held to the bounds
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidAnswer.selector, int256(1_000_001)));
        usdOracle.setLatestAnswer(1_000_001);
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidAnswer.selector, int256(99)));
        usdOracle.setLatestAnswer(99);

        // a leaked updater key can push the rate up only step by step, and never past the top
        usdOracle.setLatestAnswer(800_000);
        vm.prank(rateKey);
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidAnswer.selector, int256(1_600_000)));
        usdOracle.setLatestAnswer(1_600_000);
    }

    function test_OwnerReplacesALeakedUpdater() public {
        address newKey = address(0x0AC2E);
        usdOracle.setUpdater(newKey);

        vm.prank(rateKey);
        vm.expectRevert(L2PUsdOracle.NotUpdater.selector);
        usdOracle.setLatestAnswer(12_000);

        // the updater cannot take the oracle over
        vm.prank(newKey);
        vm.expectRevert("Ownable: caller is not the owner");
        usdOracle.transferOwnership(newKey);
        vm.prank(newKey);
        vm.expectRevert("Ownable: caller is not the owner");
        usdOracle.setUpdater(newKey);
        vm.prank(newKey);
        vm.expectRevert("Ownable: caller is not the owner");
        usdOracle.setBounds(1, type(int256).max);
    }

    function test_BoundsMustBePositiveOrderedAndHoldTheRate() public {
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidBounds.selector, int256(0), int256(100)));
        usdOracle.setBounds(0, 100);
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidBounds.selector, int256(200), int256(100)));
        usdOracle.setBounds(200, 100);
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidAnswer.selector, int256(10_000)));
        usdOracle.setBounds(20_000, 30_000);

        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidBounds.selector, int256(0), int256(1)));
        new L2PUsdOracle(1, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(L2PUsdOracle.InvalidAnswer.selector, int256(5)));
        new L2PUsdOracle(5, 10, 20);
    }

    function test_RegistrationRevenueGoesToTheControllerOwner() public {
        uint256 price = controller.rentPrice("l2protocol", ONE_YEAR).base;
        _register("l2protocol", alice);
        assertEq(address(controller).balance, price);

        address treasury = address(0x7E5);
        controller.transferOwnership(treasury);
        controller.withdraw();

        assertEq(treasury.balance, price);
        assertEq(address(controller).balance, 0);
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

    /// @dev Deployed from the compiled artifact rather than imported, so that ENSRegistry.sol
    ///      stays out of this file's compilation unit and keeps its pinned 0.8.17 bytecode.
    function _deployRegistry() internal returns (ENS) {
        return ENS(deployCode("ENSRegistry.sol:ENSRegistry"));
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
