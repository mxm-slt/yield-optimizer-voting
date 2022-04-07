// SPDX-License-Identifier: MIT

pragma solidity ^0.6.12;

import "./StratTrisolV5StratsManager.sol";

abstract contract StratTrisolV5FeeManager is StratTrisolV5StratsManager {
    uint constant public STRATEGIST_FEE = 112;
    uint constant public TREASURY_FEE = 112;
    uint constant public MAX_FEE = 1000;
    uint constant public MAX_CALL_FEE = 111;

    uint constant public WITHDRAWAL_FEE_CAP = 50;
    uint constant public WITHDRAWAL_MAX = 10000;

    uint public withdrawalFee = 10;

    uint public callFee = 111;
    uint public vaporwaveFee = MAX_FEE - STRATEGIST_FEE - callFee;


    function setCallFee(uint256 _fee) public onlyManager {
        require(_fee <= MAX_CALL_FEE, "!cap");
        
        callFee = _fee;
        vaporwaveFee = MAX_FEE - STRATEGIST_FEE - callFee;
    }

    function setWithdrawalFee(uint256 _fee) public onlyManager {
        require(_fee <= WITHDRAWAL_FEE_CAP, "!cap");

        withdrawalFee = _fee;
    }
}