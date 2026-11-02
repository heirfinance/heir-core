// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title FeeCollector
/// @notice Holds fees forwarded by DigitalWill. The owner (a Safe) can withdraw the
///         accumulated balance at any time. Deliberately minimal: no accounting beyond
///         address(this).balance, no roles beyond Ownable.
contract FeeCollector is Ownable, ReentrancyGuard {
    event FeeReceived(address indexed from, uint256 amount);
    event FeesWithdrawn(address indexed to, uint256 amount);

    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice Withdraw the entire fee balance to `to`. Owner-only (the Safe).
    function withdraw(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 amount = address(this).balance;
        require(amount > 0, "nothing to withdraw");

        emit FeesWithdrawn(to, amount);

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @notice Current fee balance held by this contract.
    function totalFees() external view returns (uint256) {
        return address(this).balance;
    }
}
