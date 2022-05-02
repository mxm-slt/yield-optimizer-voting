import { ADDRESS_ZERO, advanceBlock, advanceBlockTo, advanceTime, advanceTimeAndBlock, deploy, getBigNumber, prepare } from "./utilities"
import { assert, expect } from "chai"

import { ethers } from "hardhat"
import common from "mocha/lib/interfaces/common";
const { predictAddresses } = require("./predictAddresses");

const { BigNumber } = require("ethers")

describe.only("VoterChefPool", function () {

  before(async function () {
    await prepare(this, ["MiniChefV2",
      "VwaveToken",
      "ERC20Mock",
      "RewarderMock",
      "RewarderBrokenMock",
      "UniswapRouterMock",
      "Voter",
      "VwaveRewarder",
      "VwaveFactory",
      "VwaveMaxi",
      "VaporGovVault",
      "VaporVaultV3",
      "VaporwaveFeeRecipientV2",
      "VaporwaveRewardPoolV2"])
    await deploy(this, [["brokenRewarder", this.RewarderBrokenMock]])
  })

  beforeEach(async function () {
    await deploy(this, [["vwave", this.VwaveToken]])
    await deploy(this, [["govtMock", this.ERC20Mock, ["GovToken Mock", "GovTM", getBigNumber(10000)]]])
    await deploy(this, [["lp", this.ERC20Mock, ["LP Token", "LPT", getBigNumber(10000)]]])
    await deploy(this, [["wnative", this.ERC20Mock, ["wnative", "wnative", getBigNumber(10000)]]])
    await deploy(this, [["unirouterNative2VWAVe", this.UniswapRouterMock, [this.wnative.address, this.vwave.address]]])

    await deploy(this, [["rewardpoolA", this.VaporwaveRewardPoolV2, [this.lp.address, this.vwave.address]],])
    await deploy(this, [["vwaveWETHRewardPool", this.VaporwaveRewardPoolV2, [this.vwave.address, this.wnative.address]],])
    await deploy(this, [["factory", this.VwaveFactory, [this.govtMock.address, this.vwave.address]]])

    this.chef = await this.MiniChefV2.attach(await this.factory.getChef())
    this.VWAVE_PER_SECOND = await this.factory.VWAVE_PER_SECOND()

    await deploy(this, [["feeReceipient", this.VaporwaveFeeRecipientV2,
      [this.vwaveWETHRewardPool.address,
      this.unirouterNative2VWAVe.address,
      this.vwave.address,
      this.wnative.address,
      this.chef.address]]])

    await this.vwaveWETHRewardPool.setKeeper(this.feeReceipient.address)

    const predictedAddresses = await predictAddresses({ creator: this.alice.address });

    await deploy(this, [["vaporVaultV3", this.VaporVaultV3,
      [predictedAddresses.strategy,
        "vaporVaultV3 Token", "VVV3"]]])

    await deploy(this, [["vwaveMaxi", this.VwaveMaxi,
      [this.vwave.address,
      this.vwaveWETHRewardPool.address,
      this.vaporVaultV3.address,
      this.unirouterNative2VWAVe.address,
      this.alice.address,
      this.bob.address,
      this.feeReceipient.address,
      [this.wnative.address, this.vwave.address]
      ]]])


    // only MiniChef can distribute rewards to RewardPools
    let rewarder = await this.factory.getVwaveRewarder()
    await this.rewardpoolA.setKeeper(rewarder)

    let voterTx = await (await this.factory.newVoter(this.rewardpoolA.address)).wait()
    let voterAddress = voterTx.events.filter(x => x.event == "LogNewVoter")[0].args["voter"]
    this.voter = await this.Voter.attach(voterAddress)

    await this.vwave.mint(this.chef.address, getBigNumber(10000))
    await this.vwave.mint(this.unirouterNative2VWAVe.address, getBigNumber(10000))

  })


  describe("Integration tests", function () {

    it("fee recepient + reward pool + vault + maxi", async function () {
      let wnativeFees = getBigNumber(100)
      // Vaporwave farming fees go fee receipient
      await this.wnative.transfer(this.feeReceipient.address, wnativeFees)
      expect(await this.wnative.balanceOf(this.feeReceipient.address)).to.be.equal(getBigNumber(100))
      // Harvest fees
      await this.feeReceipient.harvest()
      // 75% weth goes to vwaveWETHRewardPool
      expect(await this.wnative.balanceOf(this.vwaveWETHRewardPool.address)).to.be.equal(getBigNumber(75))
      // 25% weth used to buy VWAVE that go to minichef, for testing purposes: 1 vwave = 1 weth
      expect(await this.vwave.balanceOf(this.chef.address)).to.be.equal(getBigNumber(10025))
      // no one stacked anything
      expect(await this.vwaveWETHRewardPool.totalSupply()).to.be.equal(0)
      // let's stake some
      let vwaveStake = getBigNumber(500)
      await this.vwave.mint(this.alice.address, vwaveStake)
      await this.vwave.approve(this.vwaveWETHRewardPool.address, vwaveStake)
      await this.vwaveWETHRewardPool.stake(vwaveStake)
      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(0)

      await advanceTime(86400)
      await advanceBlock()

      let rewardPerToken = await this.vwaveWETHRewardPool.rewardPerToken()
      let expectedReward = rewardPerToken.mul(vwaveStake).div(ethers.BigNumber.from("10").pow(18))

      let balanceBeforeReward = await this.wnative.balanceOf(this.alice.address)
      await expect(this.vwaveWETHRewardPool.getReward()).to.emit(this.vwaveWETHRewardPool, "RewardPaid").withArgs(this.alice.address, expectedReward)
      let balanceAfterReward = await this.wnative.balanceOf(this.alice.address)
      expect(balanceAfterReward.sub(balanceBeforeReward)).to.equal(expectedReward)
      // expect the reward to be roughly equal 75
      expect(expectedReward.sub(getBigNumber(75)).abs().lt(getBigNumber(1))).to.equal(true)
      let rewardPerTokenAfterGetReward = await this.vwaveWETHRewardPool.rewardPerToken()

      // check that only dust remains
      expect(rewardPerTokenAfterGetReward.lt(getBigNumber(1))).to.equal(true)

      await this.vwaveWETHRewardPool.withdraw(vwaveStake) // unstake and check
      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(vwaveStake)
      expect(await this.vwaveWETHRewardPool.totalSupply()).to.be.equal(0)

      // MAXI and Vault
      let vwaveDeposit = getBigNumber(700)
      await this.vwave.mint(this.alice.address, vwaveDeposit)
      let balance = await this.vwave.balanceOf(this.alice.address)
      let vwaveTotalDeposit = getBigNumber(1200)   // 500+700 = 1200
      expect(balance).to.be.equal(vwaveTotalDeposit)

      await this.vwave.approve(this.vaporVaultV3.address, vwaveTotalDeposit)
      // deposit VWAVE into the vault
      await this.vaporVaultV3.depositAll() // 1200 VWAVE

      // give some wnative to the pool to distribute
      let rewardAmount = getBigNumber(3000) // weth ~ wnative
      await this.wnative.mint(this.vwaveWETHRewardPool.address, rewardAmount)


      /// --- HACK: artificially call notifyreward because only Fee Recepient can do this
      await this.vwaveWETHRewardPool.setKeeper(this.alice.address)
      await this.vwaveWETHRewardPool.notifyRewardAmount(rewardAmount)
      /// --------------------------------------------------------------------------------

      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(0)
      expect(await this.vaporVaultV3.balance()).to.be.equal(vwaveTotalDeposit)

      await advanceTime(86400)
      await advanceBlock()

      expect(await this.vwaveWETHRewardPool.totalSupply()).to.be.equal(vwaveTotalDeposit)

      let beforeFees = await this.wnative.balanceOf(this.alice.address)

      await this.vwaveMaxi.managerHarvest()

      let afterFees = await this.wnative.balanceOf(this.alice.address)
      let feeEarnings = afterFees.sub(beforeFees)
      let totalSupplyAfterHarvest = await this.vwaveWETHRewardPool.totalSupply()
      // we've earned all reward weth from the pool and swapped them for the VWAVE (minus fees)
      // +3000 VWAVE - feeEarnings
      // 1 VWAVE = 1 WETH
      let expectedTotalSupply = vwaveTotalDeposit.add(rewardAmount).sub(feeEarnings)
      let supplyDiff = totalSupplyAfterHarvest.sub(expectedTotalSupply).abs()
      // console.log(ethers.utils.formatEther(totalSupplyAfterHarvest))
      // console.log(ethers.utils.formatEther(vwaveTotalDeposit.add(rewardAmount).sub(feeEarnings)))
      // console.log(ethers.utils.formatEther(supplyDiff))
      expect(supplyDiff.lt(getBigNumber(1))).to.be.equal(true)

    })


    it("feeReceipient + rewardpool: 1 voter, 1 day", async function () {
      let wnativeFees = getBigNumber(100)
      // Vaporwave farming fees go fee receipient
      await this.wnative.transfer(this.feeReceipient.address, wnativeFees)
      expect(await this.wnative.balanceOf(this.feeReceipient.address)).to.be.equal(getBigNumber(100))
      // Harvest fees
      await this.feeReceipient.harvest()
      // 75% weth goes to vwaveWETHRewardPool
      expect(await this.wnative.balanceOf(this.vwaveWETHRewardPool.address)).to.be.equal(getBigNumber(75))
      // 25% weth used to buy VWAVE that go to minichef, for testing purposes: 1 vwave = 1 weth
      expect(await this.vwave.balanceOf(this.chef.address)).to.be.equal(getBigNumber(10025))
      // no one stacked anything
      expect(await this.vwaveWETHRewardPool.totalSupply()).to.be.equal(0);
      // let's stake some
      let vwaveStake = getBigNumber(500)
      await this.vwave.mint(this.alice.address, vwaveStake)
      await this.vwave.approve(this.vwaveWETHRewardPool.address, vwaveStake)
      await this.vwaveWETHRewardPool.stake(vwaveStake)

      await advanceTime(86400)
      await advanceBlock()

      let rewardPerToken = await this.vwaveWETHRewardPool.rewardPerToken()
      let expectedReward = rewardPerToken.mul(vwaveStake).div(ethers.BigNumber.from("10").pow(18))

      let balanceBeforeReward = await this.wnative.balanceOf(this.alice.address)
      await expect(this.vwaveWETHRewardPool.getReward()).to.emit(this.vwaveWETHRewardPool, "RewardPaid").withArgs(this.alice.address, expectedReward)
      let balanceAfterReward = await this.wnative.balanceOf(this.alice.address)
      expect(balanceAfterReward.sub(balanceBeforeReward)).to.equal(expectedReward)
      //console.log(ethers.utils.formatEther(expectedReward.sub(getBigNumber(75))))
      expect(expectedReward.sub(getBigNumber(75)).abs().lt(getBigNumber(1))).to.equal(true)

    })


    it("feeReceipient + rewardpool: 2 voters, 1 day", async function () {
      let wnativeFees = getBigNumber(100)
      // Vaporwave farming fees go fee receipient
      await this.wnative.transfer(this.feeReceipient.address, wnativeFees)
      expect(await this.wnative.balanceOf(this.feeReceipient.address)).to.be.equal(getBigNumber(100))
      // Harvest fees
      await this.feeReceipient.harvest()
      // 75% weth goes to vwaveWETHRewardPool
      expect(await this.wnative.balanceOf(this.vwaveWETHRewardPool.address)).to.be.equal(getBigNumber(75))
      // 25% weth used to buy VWAVE that go to minichef, for testing purposes: 1 vwave = 1 weth
      expect(await this.vwave.balanceOf(this.chef.address)).to.be.equal(getBigNumber(10025))
      // no one stacked anything
      expect(await this.vwaveWETHRewardPool.totalSupply()).to.be.equal(0);
      // let's stake some
      let vwaveStake = getBigNumber(500)
      await this.vwave.mint(this.alice.address, vwaveStake)
      await this.vwave.mint(this.bob.address, vwaveStake)
      await this.vwave.approve(this.vwaveWETHRewardPool.address, vwaveStake)
      await this.vwave.connect(this.bob).approve(this.vwaveWETHRewardPool.address, vwaveStake)
      await this.vwaveWETHRewardPool.stake(vwaveStake)
      await this.vwaveWETHRewardPool.connect(this.bob).stake(vwaveStake)

      await advanceTime(86400)
      await advanceBlock()

      let rewardPerToken = await this.vwaveWETHRewardPool.rewardPerToken()
      let expectedReward = rewardPerToken.mul(vwaveStake).div(ethers.BigNumber.from("10").pow(18))

      let balanceBeforeReward = await this.wnative.balanceOf(this.alice.address)
      await expect(this.vwaveWETHRewardPool.getReward()).to.emit(this.vwaveWETHRewardPool, "RewardPaid").withArgs(this.alice.address, expectedReward)
      let balanceAfterReward = await this.wnative.balanceOf(this.alice.address)
      expect(balanceAfterReward.sub(balanceBeforeReward)).to.equal(expectedReward)
      //console.log(ethers.utils.formatEther(expectedReward.sub(getBigNumber(75))))
      expect(expectedReward.sub(getBigNumber(75).div(2)).abs().lt(getBigNumber(1))).to.equal(true)

    })


    it("fee receipient + rewardpool + govvault + vwave maxi", async function () {

      let wnativeFees = getBigNumber(100)
      // Vaporwave farming fees go fee receipient
      await this.wnative.transfer(this.feeReceipient.address, wnativeFees)
      expect(await this.wnative.balanceOf(this.feeReceipient.address)).to.be.equal(getBigNumber(100))
      // Harvest fees
      await this.feeReceipient.harvest()
      // 75% weth goes to vwaveWETHRewardPool
      expect(await this.wnative.balanceOf(this.vwaveWETHRewardPool.address)).to.be.equal(getBigNumber(75))
      // 25% weth used to buy VWAVE that go to minichef, for testing purposes: 1 vwave = 1 weth
      expect(await this.vwave.balanceOf(this.chef.address)).to.be.equal(getBigNumber(10025))

      // a user deposits VWAVE to get gov tokens
      let vwaveDeposit = getBigNumber(500)
      await this.vwave.mint(this.alice.address, vwaveDeposit)
      //await this.vwave.approve(this.govVault.address, vwaveDeposit)
      await this.vwave.approve(this.vaporVaultV3.address, vwaveDeposit)
      await this.vaporVaultV3.deposit(vwaveDeposit) //await this.govVault.deposit(vwaveDeposit)
      // check that a user have received gov token
      expect(await this.vaporVaultV3.balanceOf(this.alice.address)).to.be.equal(vwaveDeposit)  // expect(await this.govVault.balanceOf(this.alice.address)).to.be.equal(vwaveDeposit)
      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(0)

      await advanceBlock()

      let rewardsAvailable = await this.vwaveMaxi.rewardsAvailable()
      // we expect some rewards to be generated
      expect(rewardsAvailable.gt(0)).to.be.true
      await this.vwaveMaxi.managerHarvest()
      await this.vaporVaultV3.withdrawAll() // await this.govVault.withdrawAll()
      // check that we now have more than 500 VWAVE after withdrawing
      let newVwaveBalance = await this.vwave.balanceOf(this.alice.address)
      expect(newVwaveBalance.gt(vwaveDeposit)).to.be.true
    })

    it("alice votes", async function () {
      let govtBalance = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      expect(await this.govtMock.allowance(this.alice.address, this.voter.address)).to.be.equal(voteCount)
      let logVote = await this.voter.vote(voteCount)

      expect(await this.voter.totalBalance()).to.be.equal(voteCount)
      expect(await this.voter.voteCount()).to.be.equal(voteCount)
      expect(await this.voter.totalVoteCount()).to.be.equal(voteCount)

      let govtBalanceAfterVote = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalanceAfterVote).to.be.equal(govtBalance.sub(voteCount))

      await advanceTime(86400) // +24 hours

      // check the amount of reward accumulated in a Chef's pool
      let logAfter24h = await this.chef.updatePool(0)

      let timestamp2 = (await ethers.provider.getBlock(logAfter24h.blockNumber)).timestamp
      let timestamp = (await ethers.provider.getBlock(logVote.blockNumber)).timestamp

      // TODO VwavePerSecond=10_000_000_000_000_000 = 1e16 ==> 1e18/100 = 0.01, make it configurable in contracts
      let expectedVwave = BigNumber.from(this.VWAVE_PER_SECOND).mul(timestamp2 - timestamp)
      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      expect(pendingVwave).to.be.equal(expectedVwave)

      await expect(this.voter.harvest()).to.emit(this.rewardpoolA, "RewardAdded")

      let lpStakeAmount = getBigNumber(200)
      await this.lp.approve(this.rewardpoolA.address, lpStakeAmount)
      let logStake = await this.rewardpoolA.stake(lpStakeAmount)

      expect(await this.rewardpoolA.totalSupply()).to.be.equal(lpStakeAmount)
      expect(await this.rewardpoolA.balanceOf(this.alice.address)).to.be.equal(lpStakeAmount)
      expect(await this.rewardpoolA.earned(this.alice.address)).to.be.equal(getBigNumber(0))
      expect(await this.rewardpoolA.rewardPerToken()).to.be.equal(getBigNumber(0))
      expect(await this.rewardpoolA.lastTimeRewardApplicable()).to.be.equal(await this.rewardpoolA.lastUpdateTime())

      await advanceTime(86400) // +24 hours

      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(getBigNumber(0))

      await expect(this.rewardpoolA.getReward()).to.emit(this.rewardpoolA, "RewardPaid")

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)
      expect(vwaveBalance).to.be.not.equal(getBigNumber(0))

      await this.voter.unvote(voteCount)
      expect(await this.govtMock.balanceOf(this.alice.address)).to.be.equal(govtBalance)
      expect(await this.voter.voteCount()).to.be.equal(getBigNumber(0))
      expect(await this.voter.totalVoteCount()).to.be.equal(getBigNumber(0))
    })

    it("voteCount == 0", async function () {
      expect(await this.voter.voteCount()).to.be.equal(0)
    })

    it("alice has govt", async function () {
      let govtBalance = getBigNumber(10000)
      expect(await this.govtMock.balanceOf(this.alice.address)).to.be.equal(govtBalance)
    })

    it("alice can't vote without approving govt", async function () {
      let voteCount = getBigNumber(100)
      await expect(this.voter.vote(voteCount)).to.be.revertedWith("ERC20: transfer amount exceeds allowance")
    })

    it("harvest all", async function () {
      let govtBalance = await this.govtMock.balanceOf(this.alice.address)
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      let logVote = await this.voter.vote(voteCount)
      await advanceTime(86400) // +24 hours, seems to work for Chef

      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      await this.factory.harvestAll()

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)

      // TODO
    })

  })

  describe("Time Lock Vote", function () {
    it("alice votes with time lock", async function () {
      let govtBalance = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, govtBalance)
      expect(await this.govtMock.allowance(this.alice.address, this.voter.address)).to.be.equal(govtBalance)
      
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365 * 2)

      // Similar to ordinary vote: 
      // let lockTime = getBigNumber(2).mul(60).mul(60).mul(24).mul(365)
      // let maxLockTime = lockTime.mul(4)
      // let lockBonus = voteCount.mul(lockTime).div(maxLockTime).mul(40).div(100)
      // console.log(ethers.utils.formatEther(voteCount.add(lockBonus)))
      // let logVote = await this.voter.vote(voteCount.add(lockBonus))


      // max pcnt = 40%, max period = 4 years
      // period above is 2 year, so
      // 40% / 4 of 100 = 10% of 100 = 10
      let actualVoteCount = voteCount.add(getBigNumber(20))
      expect(await this.voter.voteCount()).to.be.equal(actualVoteCount)
      expect(await this.voter.totalVoteCount()).to.be.equal(actualVoteCount)
      let govtBalanceAfterVote = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalanceAfterVote).to.be.equal(govtBalance.sub(voteCount))

      await advanceTime(86400) // +24 hours, seems to work for Chef

      // check the amount of reward accumulated in a Chef's pool
      let logAfter24h = await this.chef.updatePool(0)

      let timestamp2 = (await ethers.provider.getBlock(logAfter24h.blockNumber)).timestamp

      // TODO VwavePerSecond=10_000_000_000_000_000 = 1e16 ==> 1e18/100 = 0.01, make it configurable in contracts
      let expectedVwave = BigNumber.from(this.VWAVE_PER_SECOND).mul(timestamp2 - voteTimestamp)
      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      expect(pendingVwave).to.be.equal(expectedVwave)

      await expect(this.voter.harvest()).to.emit(this.rewardpoolA, "RewardAdded")

      let lpStakeAmount = getBigNumber(200)
      await this.lp.approve(this.rewardpoolA.address, lpStakeAmount)
      let logStake = await this.rewardpoolA.stake(lpStakeAmount)

      expect(await this.rewardpoolA.totalSupply()).to.be.equal(lpStakeAmount)
      expect(await this.rewardpoolA.balanceOf(this.alice.address)).to.be.equal(lpStakeAmount)
      expect(await this.rewardpoolA.earned(this.alice.address)).to.be.equal(getBigNumber(0))
      expect(await this.rewardpoolA.rewardPerToken()).to.be.equal(getBigNumber(0))
      expect(await this.rewardpoolA.lastTimeRewardApplicable()).to.be.equal(await this.rewardpoolA.lastUpdateTime())

      await advanceTime(86400) // +24 hours

      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(getBigNumber(0))

      await expect(this.rewardpoolA.getReward()).to.emit(this.rewardpoolA, "RewardPaid")

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)
      expect(vwaveBalance).to.be.not.equal(getBigNumber(0))
    })

    it("alice can unvote expired lock", async function () {
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 7)

      await advanceTime(60 * 60 * 24 * 14); // +24 hours, seems to work for Chef
      this.voter.unvote(voteCount);
    })

    it("alice can't unvote locked", async function () {
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 7)

      await expect(this.voter.unvote(voteCount)).to.be.revertedWith("'Not enough non-locked votes")
    })

    it("alice can't lock, too short period", async function () {
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      await expect(this.voter.voteWithLock(voteCount, 60)).to.be.revertedWith("Invalid duration")
    })

    it("alice can't lock, too long period", async function () {
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)

      await expect(this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365 * 5)).to.be.revertedWith("Invalid duration")
    })

  })

  describe("Retire and pause", function () {
    it("retire and withdraw time locked", async function () {
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      let lockDuration = 60 * 60 * 24 * 365;
      let logVote = await this.voter.voteWithLock(voteCount, lockDuration)
      let voteTimestamp = (await ethers.provider.getBlock(logVote.blockNumber)).timestamp
      expect(await this.voter.lockExpiration()).to.be.equal(voteTimestamp + lockDuration)

      await advanceTime(86400) // +24 hours
      // cannot call directly, only via factory
      await expect(this.voter.retire()).to.be.revertedWith("Caller cannot retire")
      // can call via factory
      await expect(this.factory.retire(this.voter.address)).to.emit(this.voter, "Retired")
      // make sure voter state changed
      await expect(await this.voter.isRetired()).to.be.equal(true)
      // retired must be deleted from factory
      await expect(await this.factory.isVoter(this.voter.address)).to.be.equal(false)
      await expect(await this.factory.getVoterCount()).to.be.equal(0)

      //can retire only once
      await expect(this.factory.retire(this.voter.address)).to.be.revertedWith("Unknown voter")

      // no crash trying to unvote locked
      await this.voter.unvote(voteCount);
      expect(await this.voter.totalBalance()).to.be.equal(0)
    })

    it("Pause and unpause", async function () {
      let voteCount = getBigNumber(1000)
      await this.govtMock.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(getBigNumber(10), 60 * 60 * 24 * 365)
      let logPause = await this.voter.pause()

      expect(await this.voter.isActive()).to.be.equal(false)
      expect(await this.voter.isRetired()).to.be.equal(false)

      // cannot unlock timelocked when paused
      await expect(this.voter.unvote(getBigNumber(10))).to.be.revertedWith("Not enough non-locked votes")

      // cannot vote when paused
      await expect(this.voter.vote(getBigNumber(10))).to.be.revertedWith("Voting is paused")

      await this.voter.unpause()
      // now we can vote more
      await this.voter.vote(getBigNumber(10))

    })

  })



}
)
