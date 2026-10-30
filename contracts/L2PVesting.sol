// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.30;

/// @title L2PVesting
/// @notice Holds L2P for one beneficiary and releases it on a fixed schedule: nothing before the
///         cliff, then linearly from {start} until {start} + {duration}. At the cliff the part that
///         has accrued since {start} becomes available at once.
///
/// @dev The team allocation lives in genesis at 0x...3002, so no constructor runs there and the
///      genesis generator writes the four schedule slots straight into storage, the same way the
///      presale owner is written. Advisors get their own copy of this contract, deployed the
///      ordinary way through the constructor and funded with a plain transfer. The schedule and
///      the beneficiary cannot be changed and the vesting cannot be revoked. Coins held here
///      cannot be staked, so they carry no voting power until they are released.
contract L2PVesting {
    /// @notice The only address the contract ever pays.
    address public beneficiary;
    /// @notice Unix time the schedule counts from.
    uint256 public start;
    /// @notice Seconds after {start} before anything can be released.
    uint256 public cliffDuration;
    /// @notice Seconds after {start} at which everything is released.
    uint256 public duration;
    /// @notice L2P paid out so far.
    uint256 public released;

    event Released(address indexed beneficiary, uint256 amount);

    // @notice signature: 0x5566df5c
    error InvalidBeneficiary();
    // @notice signature: 0xdba16ce8
    error InvalidSchedule();
    // @notice signature: 0x90b8ec18
    error TransferFailed();

    constructor(
        address beneficiary_,
        uint256 start_,
        uint256 cliffDuration_,
        uint256 duration_
    ) {
        if (beneficiary_ == address(0)) revert InvalidBeneficiary();
        if (duration_ == 0 || cliffDuration_ > duration_) revert InvalidSchedule();
        beneficiary = beneficiary_;
        start = start_;
        cliffDuration = cliffDuration_;
        duration = duration_;
    }

    receive() external payable { }

    /// @notice Pays everything that has vested and not been paid yet to the beneficiary. Anyone may
    ///         call it; the coins only ever go to the beneficiary.
    function release() external {
        uint256 amount = releasable();
        if (amount == 0) return;
        released += amount;
        emit Released(beneficiary, amount);
        (bool success,) = beneficiary.call{ value: amount }("");
        if (!success) revert TransferFailed();
    }

    /// @notice What {release} would pay right now.
    function releasable() public view returns (uint256) {
        return vestedAmount(block.timestamp) - released;
    }

    /// @notice How much of everything this contract has received is vested at `timestamp`,
    ///         released or not.
    function vestedAmount(
        uint256 timestamp
    ) public view returns (uint256) {
        uint256 total = address(this).balance + released;
        if (timestamp < start + cliffDuration) return 0;
        if (timestamp >= start + duration) return total;
        return total * (timestamp - start) / duration;
    }
}
