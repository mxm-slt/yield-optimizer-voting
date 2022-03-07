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
      "RewardPool"])
    await deploy(this, [["brokenRewarder", this.RewarderBrokenMock]])
  })

  beforeEach(async function () {
    await deploy(this, [["vwave", this.VwaveToken]])
    await deploy(this, [["govt", this.GovToken]])

    await deploy(this, [
      ["lp", this.ERC20Mock, ["LP Token", "LPT", getBigNumber(10)]],
      ["dummy", this.ERC20Mock, ["Dummy", "DummyT", getBigNumber(10)]],
      ["rlp", this.ERC20Mock, ["LP", "rLPT", getBigNumber(10)]],
      ["rewardpool", this.RewardPool, []],
      ["r", this.ERC20Mock, ["Reward", "RewardT", getBigNumber(100000)]],
    ])
      

    await deploy(this, [["factory", this.VwaveFactory, [this.govt.address, this.vwave.address]]])
    this.chef = await this.MiniChefV2.attach(await this.factory.getChef())

    // only MiniChef can distribute rewards to RewardPools
    await this.rewardpool.setRewardDistribution(await this.factory.getVwaveRewarder()) 


    let voterTx = await (await this.factory.newVoter(this.rewardpool.address)).wait()
    let voterAddress = voterTx.events.filter(x => x.event == "LOG_NEW_VOTER")[0].args["voter"]
    this.voter = await this.Voter.attach(voterAddress)

    await this.govt.mint(this.alice.address, getBigNumber(10000))

    await deploy(this, [["rewarder", this.RewarderMock, [getBigNumber(1), this.r.address, this.chef.address]]])
    await this.vwave.mint(this.chef.address, getBigNumber(10000))
    await this.lp.approve(this.chef.address, getBigNumber(10))
    await this.rlp.transfer(this.bob.address, getBigNumber(1))
  })


  describe.only("Simple Vote", function () {
    it("voteCount == 0", async function () {
      expect(await this.voter.voteCount()).to.be.equal(0)
    })

    it("alice has govt", async function () {
      let govtBalance = getBigNumber(10000)
      expect(await this.govt.balanceOf(this.alice.address)).to.be.equal(govtBalance)
    })

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

      await advanceTime(86400) // +24 hours

      // check the amount of reward accumulated in a pool
      let logAfter24h = await this.chef.updatePool(0)

      let timestamp2 = (await ethers.provider.getBlock(logAfter24h.blockNumber)).timestamp
      let timestamp = (await ethers.provider.getBlock(logVote.blockNumber)).timestamp
      
      // TODO VwavePerSecond=10000000000000000, introduce this parameter in contracts
      let expectedVwave = BigNumber.from("10000000000000000").mul(timestamp2 - timestamp)
      let pendingVwave = await this.chef.pendingVwave(0, this.voter.address)
      expect(pendingVwave).to.be.equal(expectedVwave)

      await this.voter.harvest()

      await this.voter.unvote(voteCount)
      expect(await this.govt.balanceOf(this.alice.address)).to.be.equal(govtBalance)



    })

    it.skip("alice can't vote without approving govt", async function () {
      let voteCount = getBigNumber(100)
      await expect(await this.voter.vote(voteCount)).to.be.revertedWith("ERC20: transfer amount exceeds allowance")
    })

    it.skip("alice unvotes", async function () {
      let voteCount = getBigNumber(100)
      await this.govt.approve(this.voter.address, voteCount)
      await this.voter.vote(voteCount)


    })
  })

}
)
