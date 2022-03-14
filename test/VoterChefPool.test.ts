import { ADDRESS_ZERO, advanceBlock, advanceBlockTo, advanceTime, advanceTimeAndBlock, deploy, getBigNumber, prepare } from "./utilities"
import { assert, expect } from "chai"

import { ethers } from "hardhat"

const { BigNumber } = require("ethers")



describe("VoterChefPool", function () {

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


  describe.only("Simple Vote", function () {

    it("alice votes", async function () {
      let govtBalance = await this.govt.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      expect(await this.govt.allowance(this.alice.address, this.voter.address)).to.be.equal(voteCount)
      let logVote = await this.voter.vote(voteCount)
      expect(await this.voter.voteCount()).to.be.equal(voteCount)
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

}
)
