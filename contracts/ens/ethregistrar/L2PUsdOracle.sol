//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import { AggregatorInterface } from "./StablePriceOracle.sol";

/// @notice The USD price of one L2P, set on-chain rather than read from a price feed.
///
/// @dev This is the AggregatorInterface that StablePriceOracle divides its USD prices by, in the
///      Chainlink convention of 8 decimals: an answer of 1e8 means $1.00 per L2P, 10000 means
///      $0.0001. There is no external feed on this chain, and upstream's DummyOracle lets anyone
///      set the value, so this one splits the right in two. The owner is the offline key that owns
///      the other ENS contracts; it appoints the updater, sets the bounds and can set any rate within
///      them. The updater is the key that keeps the rate current every hour, so it lives on a server.
///      It is held to the bounds and, within each {UPDATE_WINDOW}, to at most doubling or halving the
///      rate it found when the window began, however many updates it sends. A leaked updater key
///      therefore needs about a week to move the rate a hundredfold, which leaves the owner time to
///      replace it with {setUpdater}. Neither role is meant for governance: the governor can only call
///      GovHub, so a rate handed to it could never move again.
contract L2PUsdOracle is AggregatorInterface, Ownable {
    uint256 public constant UPDATE_WINDOW = 1 days;

    int256 private answer;

    /// @notice The key that may update the rate within the limits, zero when there is none.
    address public updater;
    /// @notice The lowest rate anyone may set.
    int256 public minAnswer;
    /// @notice The highest rate anyone may set.
    int256 public maxAnswer;
    /// @notice When the current window began. The owner setting a rate also begins a new one.
    uint256 public windowStart;
    /// @notice The rate when the current window began, which the updater may at most double or halve.
    int256 public windowStartAnswer;

    event AnswerUpdated(int256 previous, int256 current);
    event UpdaterChanged(address previous, address current);
    event BoundsChanged(int256 minAnswer, int256 maxAnswer);

    error InvalidAnswer(int256 answer);
    error InvalidBounds(int256 minAnswer, int256 maxAnswer);
    error AnswerChangeTooLarge(int256 previous, int256 requested);
    error NotUpdater();

    /// @param initialAnswer The USD price of one L2P times 1e8. Must lie within the bounds.
    /// @param minAnswer_ The lowest rate that may ever be set until the owner moves the bounds. Must be positive.
    /// @param maxAnswer_ The highest rate that may ever be set until the owner moves the bounds.
    constructor(
        int256 initialAnswer,
        int256 minAnswer_,
        int256 maxAnswer_
    ) {
        _setBounds(minAnswer_, maxAnswer_);
        _setAnswer(initialAnswer);
        _startWindow();
    }

    /// @notice Updates the USD price of one L2P, times 1e8. The owner may set any rate within the
    ///         bounds; the updater may also move it at most to double or half of {windowStartAnswer}.
    function setLatestAnswer(
        int256 newAnswer
    ) external {
        if (msg.sender == owner()) {
            _setAnswer(newAnswer);
            _startWindow();
            return;
        }
        if (msg.sender != updater) revert NotUpdater();
        if (block.timestamp >= windowStart + UPDATE_WINDOW) _startWindow();
        if (newAnswer > windowStartAnswer * 2 || newAnswer * 2 < windowStartAnswer) {
            revert AnswerChangeTooLarge(windowStartAnswer, newAnswer);
        }
        _setAnswer(newAnswer);
    }

    /// @notice Appoints the key that keeps the rate current, or removes it with the zero address.
    function setUpdater(
        address newUpdater
    ) external onlyOwner {
        emit UpdaterChanged(updater, newUpdater);
        updater = newUpdater;
    }

    /// @notice Moves the bounds. The current rate has to lie within the new ones.
    function setBounds(
        int256 newMinAnswer,
        int256 newMaxAnswer
    ) external onlyOwner {
        _setBounds(newMinAnswer, newMaxAnswer);
        if (answer < newMinAnswer || answer > newMaxAnswer) revert InvalidAnswer(answer);
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view override returns (int256) {
        return answer;
    }

    /// @dev A zero answer would make every registration revert on division by zero, and a
    ///      negative one would be cast to a huge unsigned price, so the lower bound is positive.
    function _setBounds(
        int256 newMinAnswer,
        int256 newMaxAnswer
    ) internal {
        if (newMinAnswer <= 0 || newMinAnswer > newMaxAnswer) revert InvalidBounds(newMinAnswer, newMaxAnswer);
        minAnswer = newMinAnswer;
        maxAnswer = newMaxAnswer;
        emit BoundsChanged(newMinAnswer, newMaxAnswer);
    }

    function _startWindow() internal {
        windowStart = block.timestamp;
        windowStartAnswer = answer;
    }

    function _setAnswer(
        int256 newAnswer
    ) internal {
        if (newAnswer < minAnswer || newAnswer > maxAnswer) revert InvalidAnswer(newAnswer);
        emit AnswerUpdated(answer, newAnswer);
        answer = newAnswer;
    }
}
