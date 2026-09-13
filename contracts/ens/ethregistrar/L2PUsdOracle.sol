//SPDX-License-Identifier: MIT
pragma solidity ~0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import { AggregatorInterface } from "./StablePriceOracle.sol";

/// @notice The USD price of one L2P, set by the owner rather than read from a price feed.
///
/// @dev This is the AggregatorInterface that StablePriceOracle divides its USD prices by, in the
///      Chainlink convention of 8 decimals: an answer of 1e8 means $1.00 per L2P, 10000 means
///      $0.0001. There is no external feed on this chain, and upstream's DummyOracle lets anyone
///      set the value, so this one restricts the setter to the owner. That owner is the deployer
///      at first and governance later, the same as the other ENS contracts.
contract L2PUsdOracle is AggregatorInterface, Ownable {
    int256 private answer;

    event AnswerUpdated(int256 previous, int256 current);

    error InvalidAnswer(int256 answer);

    /// @param initialAnswer The USD price of one L2P times 1e8. Must be positive.
    constructor(
        int256 initialAnswer
    ) {
        _setAnswer(initialAnswer);
    }

    /// @notice Updates the USD price of one L2P, times 1e8.
    function setLatestAnswer(
        int256 newAnswer
    ) external onlyOwner {
        _setAnswer(newAnswer);
    }

    /// @inheritdoc AggregatorInterface
    function latestAnswer() external view override returns (int256) {
        return answer;
    }

    /// @dev A zero answer would make every registration revert on division by zero, and a
    ///      negative one would be cast to a huge unsigned price, so neither is accepted.
    function _setAnswer(
        int256 newAnswer
    ) internal {
        if (newAnswer <= 0) revert InvalidAnswer(newAnswer);
        emit AnswerUpdated(answer, newAnswer);
        answer = newAnswer;
    }
}
