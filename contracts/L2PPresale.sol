// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title L2PPresale
/// @notice The presale schedule of L2P: five consecutive eras of equal length, each offering the
///         same amount of L2P at a USD price that steps up from one era to the next.
///
/// @dev This contract lives in genesis, so no constructor ever runs. The schedule is compiled in
///      as constants and the owner is written straight into storage slot 0 by the genesis
///      generator, the same way the ENSRegistry root owner is. The schedule has no clock until
///      the owner calls {start}: that block becomes the first block of era 0, and every era
///      boundary follows from it. Prices are USD values with {PRICE_DECIMALS} decimals, the
///      Chainlink convention that L2PUsdOracle uses as well, so 10_000 means $0.0001.
contract L2PPresale is Ownable2Step {
    enum Status {
        NotStarted,
        Active,
        Ended
    }

    /// @param startBlock First block of the era (inclusive). Zero until the presale is started.
    /// @param endBlock Last block of the era (inclusive). Zero until the presale is started.
    /// @param priceUsd USD price of one L2P during the era, with {PRICE_DECIMALS} decimals.
    /// @param supply Amount of L2P on offer during the era, in wei.
    struct Era {
        uint256 startBlock;
        uint256 endBlock;
        uint256 priceUsd;
        uint256 supply;
    }

    uint256 public constant ERA_COUNT = 5;
    uint256 public constant BLOCK_INTERVAL_MS = 1500;
    uint256 public constant PRESALE_DURATION = 365 days;
    uint256 public constant ERA_BLOCKS = (PRESALE_DURATION * 1000 / BLOCK_INTERVAL_MS) / ERA_COUNT;
    uint256 public constant TOTAL_BLOCKS = ERA_BLOCKS * ERA_COUNT;

    uint8 public constant PRICE_DECIMALS = 8;
    uint256 public constant ERA_SUPPLY = 1_500_000_000 ether;
    uint256 public constant PRESALE_SUPPLY = ERA_SUPPLY * ERA_COUNT;

    /// @notice The block in which the owner started the presale, zero while it has not been.
    uint256 public startBlock;

    event PresaleStarted(uint256 startBlock, uint256 endBlock);

    // @notice signature: 0x1fbde445
    error AlreadyStarted();
    // @notice signature: 0x6f312cbd
    error NotStarted();
    // @notice signature: 0x853a2f26
    error PresaleNotActive(Status status);
    // @notice signature: 0xde9997d0
    error InvalidEra(uint256 index);
    // @notice signature: 0xeebbdb70
    error BlockOutsidePresale(uint256 blockNumber);

    /*----------------- owner -----------------*/

    /// @notice Starts the presale in the current block. Can be called once.
    function start() external onlyOwner {
        if (startBlock != 0) revert AlreadyStarted();
        startBlock = block.number;
        emit PresaleStarted(block.number, endBlock());
    }

    /// @dev Renouncing before the start would leave the presale impossible to start, ever,
    ///      and genesis cannot be redone. After the start the schedule is fixed anyway.
    function renounceOwnership() public override onlyOwner {
        if (startBlock == 0) revert NotStarted();
        super.renounceOwnership();
    }

    /*----------------- views -----------------*/

    /// @notice Whether the presale has not started yet, is running, or is over.
    function status() public view returns (Status) {
        if (startBlock == 0) return Status.NotStarted;
        if (block.number > endBlock()) return Status.Ended;
        return Status.Active;
    }

    /// @notice The last block of the presale (inclusive), zero while it has not been started.
    function endBlock() public view returns (uint256) {
        if (startBlock == 0) return 0;
        return startBlock + TOTAL_BLOCKS - 1;
    }

    /// @notice The USD price of one L2P in the current era, with {PRICE_DECIMALS} decimals.
    /// @dev Reverts with {PresaleNotActive} outside the presale.
    function currentPriceUsd() external view returns (uint256) {
        return eraPrices()[currentEraIndex()];
    }

    /// @notice The zero-based index of the current era.
    /// @dev Reverts with {PresaleNotActive} outside the presale.
    function currentEraIndex() public view returns (uint256) {
        _requireActive();
        return _eraIndexAt(block.number);
    }

    /// @notice The current era.
    /// @dev Reverts with {PresaleNotActive} outside the presale.
    function currentEra() external view returns (Era memory) {
        return era(currentEraIndex());
    }

    /// @notice The number of blocks until the next era begins, counted from the current block.
    ///         In the last era this is the number of blocks until the presale is over.
    /// @dev Reverts with {PresaleNotActive} outside the presale.
    function blocksUntilNextEra() external view returns (uint256) {
        return _eraEndBlock(currentEraIndex()) + 1 - block.number;
    }

    /// @notice The zero-based index of the era a given block falls in.
    /// @dev Reverts with {NotStarted} before the start and with {BlockOutsidePresale} for a
    ///      block before the start or after the end.
    function eraIndexAt(
        uint256 blockNumber
    ) external view returns (uint256) {
        if (startBlock == 0) revert NotStarted();
        if (blockNumber < startBlock || blockNumber > endBlock()) revert BlockOutsidePresale(blockNumber);
        return _eraIndexAt(blockNumber);
    }

    /// @notice One era by its zero-based index. The block range is zero until the presale is
    ///         started; the price and supply are always known.
    function era(
        uint256 index
    ) public view returns (Era memory) {
        if (index >= ERA_COUNT) revert InvalidEra(index);
        return Era({
            startBlock: startBlock == 0 ? 0 : _eraStartBlock(index),
            endBlock: startBlock == 0 ? 0 : _eraEndBlock(index),
            priceUsd: eraPrices()[index],
            supply: ERA_SUPPLY
        });
    }

    /// @notice All eras in order. The block ranges are zero until the presale is started.
    function eras() external view returns (Era[ERA_COUNT] memory list) {
        for (uint256 i; i < ERA_COUNT; ++i) {
            list[i] = era(i);
        }
    }

    /// @notice The USD price of one L2P per era, with {PRICE_DECIMALS} decimals.
    function eraPrices() public pure returns (uint256[ERA_COUNT] memory) {
        return [uint256(0.0001e8), 0.00011e8, 0.00012e8, 0.00013e8, 0.00014e8];
    }

    /*----------------- internal -----------------*/

    function _requireActive() internal view {
        Status current = status();
        if (current != Status.Active) revert PresaleNotActive(current);
    }

    function _eraIndexAt(
        uint256 blockNumber
    ) internal view returns (uint256) {
        return (blockNumber - startBlock) / ERA_BLOCKS;
    }

    function _eraStartBlock(
        uint256 index
    ) internal view returns (uint256) {
        return startBlock + index * ERA_BLOCKS;
    }

    function _eraEndBlock(
        uint256 index
    ) internal view returns (uint256) {
        return _eraStartBlock(index) + ERA_BLOCKS - 1;
    }
}
