// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.6.12;

import "../BoringERC20.sol";

contract MockERC20 is BoringERC20 {
	uint256 public totalSupply;

	constructor(uint256 _initialAmount) public {
		// Give the creator all initial tokens
		balanceOf[msg.sender] = _initialAmount;
		// Update total supply
		totalSupply = _initialAmount;
	}
}
