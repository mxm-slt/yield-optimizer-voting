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
    
    let voterTx = await (await this.factory.newVoter(this.rewardpool.address)).wait()
    let voterAddress = voterTx.events.filter(x => x.event == "LOG_NEW_VOTER")[0].args["voter"]
    this.voter = await this.Voter.attach(voterAddress)

    await this.govt.mint(this.alice.address, getBigNumber(10000))

    await deploy(this, [["rewarder", this.RewarderMock, [getBigNumber(1), this.r.address, this.chef.address]]])
    await this.vwave.mint(this.chef.address, getBigNumber(10000))
    await this.lp.approve(this.chef.address, getBigNumber(10))
    await this.rlp.transfer(this.bob.address, getBigNumber(1))
  })


  describe("Simple Vote", function () {
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
        await this.voter.vote(voteCount)
        expect(await this.voter.voteCount()).to.be.equal(voteCount)
    })
  })

 }
)