// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FeeCollector — storage for Digital Will deposit fees
/// @author heir.finance
/// @notice Holds native coin and ERC-20 fees received from DigitalWill. The owner can withdraw them
///         at any time. User funds are never held here.
/// @dev    Deliberately minimal: no accounting beyond its own balances and no roles beyond Ownable.
///         "ETH" in names and comments means the native coin of the chain this contract is deployed on.
contract FeeCollector is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Emitted when native coins are received.
    /// @param from Sender.
    /// @param amount Amount received.
    event FeeReceived(address indexed from, uint256 amount);
    /// @notice Emitted when the owner withdraws native coins.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event FeesWithdrawn(address indexed to, uint256 amount);
    /// @notice Emitted when the owner withdraws a token.
    /// @param token Token withdrawn.
    /// @param to Recipient.
    /// @param amount Amount withdrawn.
    event TokenFeesWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @param initialOwner Account allowed to withdraw fees.
    constructor(address initialOwner) Ownable(initialOwner) {}

    receive() external payable {
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice Withdraws the entire native coin balance. Owner only.
    /// @param to Recipient.
    function withdraw(address payable to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 amount = address(this).balance;
        require(amount > 0, "nothing to withdraw");

        emit FeesWithdrawn(to, amount);

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "transfer failed");
    }

    /// @notice Withdraws the entire balance of a token. Owner only.
    /// @param token Token to withdraw.
    /// @param to Recipient.
    function withdrawToken(IERC20 token, address to) external onlyOwner nonReentrant {
        require(to != address(0), "zero address");
        uint256 amount = token.balanceOf(address(this));
        require(amount > 0, "nothing to withdraw");
        emit TokenFeesWithdrawn(address(token), to, amount);
        SafeERC20.safeTransfer(token, to, amount);
    }

    /// @notice Returns the native coin fees held by this contract.
    /// @return Current native coin balance.
    function totalFees() external view returns (uint256) {
        return address(this).balance;
    }
}