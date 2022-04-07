import { ADDRESS_ZERO, advanceBlock, advanceBlockTo, advanceTime, advanceTimeAndBlock, deploy, getBigNumber, prepare } from "./utilities"
import { assert, expect } from "chai"

import { ethers } from "hardhat"

const { BigNumber } = require("ethers")



describe.only("VoterChefPool", function () {

  before(async function () {
    await prepare(this, ["MiniChefV2",
      "VwaveToken",
      "ERC20Mock",
      "RewarderMock",
      "RewarderBrokenMock",
      "Voter",
      "GovToken",
      "VwaveRewarder",
      "VwaveFactory",
      "VaporwaveRewardPoolV2"])
    await deploy(this, [["brokenRewarder", this.RewarderBrokenMock]])
  })

  beforeEach(async function () {
    await deploy(this, [["vwave", this.VwaveToken]])
    await deploy(this, [["govt", this.GovToken]])
    await deploy(this, [["lp", this.ERC20Mock, ["LP Token", "LPT", getBigNumber(10)]]])
    await deploy(this, [["rewardpool", this.VaporwaveRewardPoolV2, [this.lp.address, this.vwave.address]],])
    await deploy(this, [["factory", this.VwaveFactory, [this.govt.address, this.vwave.address]]])

    this.chef = await this.MiniChefV2.attach(await this.factory.getChef())
    this.VWAVE_PER_SECOND = await this.factory.VWAVE_PER_SECOND()

    // only MiniChef can distribute rewards to RewardPools
    let rewarder = await this.factory.getVwaveRewarder()
    await this.rewardpool.setKeeper(rewarder)

    let voterTx = await (await this.factory.newVoter(this.rewardpool.address)).wait()
    let voterAddress = voterTx.events.filter(x => x.event == "LOG_NEW_VOTER")[0].args["voter"]
    this.voter = await this.Voter.attach(voterAddress)

    await this.govt.mint(this.alice.address, getBigNumber(10000))
    await this.lp.mint(this.alice.address, getBigNumber(2000))
    await this.vwave.mint(this.chef.address, getBigNumber(10000))

  })


  describe("Simple Vote", function () {

    it("alice votes", async function () {
      let govtBalance = await this.govt.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      expect(await this.govt.allowance(this.alice.address, this.voter.address)).to.be.equal(voteCount)
      let logVote = await this.voter.vote(voteCount)
      expect(await this.voter.voteCount()).to.be.equal(voteCount)
      expect(await this.voter.totalVoteCount()).to.be.equal(voteCount)
      let govtBalanceAfterVote = await this.govt.balanceOf(this.alice.address)
      expect(govtBalanceAfterVote).to.be.equal(govtBalance.sub(voteCount))

      await advanceTime(86400) // +24 hours, seems to work for Chef

      // check the amount of reward accumulated in a Chef's pool
      let logAfter24h = await this.chef.updatePool(0)

      let timestamp2 = (await ethers.provider.getBlock(logAfter24h.blockNumber)).timestamp
      let timestamp = (await ethers.provider.getBlock(logVote.blockNumber)).timestamp
      
      // TODO VwavePerSecond=10_000_000_000_000_000 = 1e16 ==> 1e18/100 = 0.01, make it configurable in contracts
      let expectedVwave = BigNumber.from(this.VWAVE_PER_SECOND).mul(timestamp2 - timestamp)
      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      expect(pendingVwave).to.be.equal(expectedVwave)

      await expect(this.voter.harvest()).to.emit(this.rewardpool, "RewardAdded")

      let lpStakeAmount = getBigNumber(200)
      await this.lp.approve(this.rewardpool.address, lpStakeAmount)
      let logStake = await this.rewardpool.stake(lpStakeAmount)
      
      expect(await this.rewardpool.totalSupply()).to.be.equal(lpStakeAmount)
      expect(await this.rewardpool.balanceOf(this.alice.address)).to.be.equal(lpStakeAmount)
      expect(await this.rewardpool.earned(this.alice.address)).to.be.equal(getBigNumber(0))
      expect(await this.rewardpool.rewardPerToken()).to.be.equal(getBigNumber(0))      
      expect(await this.rewardpool.lastTimeRewardApplicable()).to.be.equal(await this.rewardpool.lastUpdateTime())

      await advanceTime(86400) // +24 hours

      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(getBigNumber(0))

      await expect(this.rewardpool.getReward()).to.emit(this.rewardpool, "RewardPaid")

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)
      expect(vwaveBalance).to.be.not.equal(getBigNumber(0))

      await this.voter.unvote(voteCount)
      expect(await this.govt.balanceOf(this.alice.address)).to.be.equal(govtBalance)
      expect(await this.voter.voteCount()).to.be.equal(getBigNumber(0))
      expect(await this.voter.totalVoteCount()).to.be.equal(getBigNumber(0))
    })

    it("voteCount == 0", async function () {
      expect(await this.voter.voteCount()).to.be.equal(0)
    })

    it("alice has govt", async function () {
      let govtBalance = getBigNumber(10000)
      expect(await this.govt.balanceOf(this.alice.address)).to.be.equal(govtBalance)
    })

    it("alice can't vote without approving govt", async function () {
      let voteCount = getBigNumber(100)
      await expect(this.voter.vote(voteCount)).to.be.revertedWith("ERC20: transfer amount exceeds allowance")
    })

    it("harvest all", async function () {
      let govtBalance = await this.govt.balanceOf(this.alice.address)
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      let logVote = await this.voter.vote(voteCount)
      await advanceTime(86400) // +24 hours, seems to work for Chef

      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      await this.factory.harvestAll()

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)

      // TODO
    })

  })

  describe("Time Lock Vote", function () {
    it("alice votes", async function () {
      let govtBalance = await this.govt.balanceOf(this.alice.address)
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365)

      // max pcnt = 40%, max period = 4 years
      // period above is 1 year, so
      // 40% / 4 of 100 = 10% of 100 = 10
      let actualVoteCount = voteCount.add(getBigNumber(10))
      expect(await this.voter.voteCount()).to.be.equal(actualVoteCount)
      expect(await this.voter.totalVoteCount()).to.be.equal(actualVoteCount)
      let govtBalanceAfterVote = await this.govt.balanceOf(this.alice.address)
      expect(govtBalanceAfterVote).to.be.equal(govtBalance.sub(voteCount))

      // check the amount of reward accumulated in a Chef's pool
      let logAfter24h = await this.chef.updatePool(0)

      let timestamp2 = (await ethers.provider.getBlock(logAfter24h.blockNumber)).timestamp
      let timestamp = (await ethers.provider.getBlock(logVote.blockNumber)).timestamp

      // TODO VwavePerSecond=10_000_000_000_000_000 = 1e16 ==> 1e18/100 = 0.01, make it configurable in contracts
      let expectedVwave = BigNumber.from(this.VWAVE_PER_SECOND).mul(timestamp2 - timestamp)
      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
//       expect(pendingVwave).to.be.equal(expectedVwave)

      await expect(this.voter.harvest()).to.emit(this.rewardpool, "RewardAdded")

      let lpStakeAmount = getBigNumber(200)
      await this.lp.approve(this.rewardpool.address, lpStakeAmount)
      let logStake = await this.rewardpool.stake(lpStakeAmount)

      expect(await this.rewardpool.totalSupply()).to.be.equal(lpStakeAmount)
      expect(await this.rewardpool.balanceOf(this.alice.address)).to.be.equal(lpStakeAmount)
      expect(await this.rewardpool.earned(this.alice.address)).to.be.equal(getBigNumber(0))
      expect(await this.rewardpool.rewardPerToken()).to.be.equal(getBigNumber(0))
      expect(await this.rewardpool.lastTimeRewardApplicable()).to.be.equal(await this.rewardpool.lastUpdateTime())

      await advanceTime(86400) // +24 hours

      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(getBigNumber(0))

      await expect(this.rewardpool.getReward()).to.emit(this.rewardpool, "RewardPaid")

      let vwaveBalance = await this.vwave.balanceOf(this.alice.address)
      expect(vwaveBalance).to.be.not.equal(getBigNumber(0))
    })

    it("alice can unvote expired lock", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 7)

      await advanceTime(60 * 60 * 24 * 14); // +24 hours, seems to work for Chef
      this.voter.unvote(voteCount);
    })

    it("alice can't unvote locked", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 7)

      await expect(this.voter.unvote(voteCount)).to.be.revertedWith("'Not enough non-locked votes")
    })

    it("alice can't lock, too short period", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      await expect(this.voter.voteWithLock(voteCount, 60)).to.be.revertedWith("Invalid duration")
    })

    it("alice can't lock, too long period", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)

      await expect(this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365 * 5)).to.be.revertedWith("Invalid duration")
    })


  })

  describe.only("Retire", function () {
    it("retire and withdraw time locked", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365)

      await advanceTime(86400) // +24 hours
      await expect(this.voter.retire()).to.emit(this.voter, "Retired")

      let isRetired = await this.voter.isRetired()
      console.log(isRetired)
      expect(isRetired).to.be.equal(true)

      // no crash trying to unvote locked
      this.voter.unvote(voteCount);

    })


  })



}
)
