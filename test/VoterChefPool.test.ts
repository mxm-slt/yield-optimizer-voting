import { ADDRESS_ZERO, advanceBlock, advanceBlockTo, advanceTime, advanceTimeAndBlock, deploy, getBigNumber, prepare } from "./utilities"
import { assert, expect } from "chai"

import { ethers } from "hardhat"
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
      "VaporwaveFeeRecipientV2",
      "VaporwaveRewardPoolV2"])
    await deploy(this, [["brokenRewarder", this.RewarderBrokenMock]])
  })

  beforeEach(async function () {
    await deploy(this, [["vwave", this.VwaveToken]])
    await deploy(this, [["govtMock", this.ERC20Mock, ["GovToken Mock", "GovTM", getBigNumber(10000)]]])
    await deploy(this, [["lp", this.ERC20Mock, ["LP Token", "LPT", getBigNumber(10000)]]])
    await deploy(this, [["wnative", this.ERC20Mock, ["wnative", "wnative", getBigNumber(10000)]]])
    await deploy(this, [["unirouterNative2VWAVe", this.UniswapRouterMock, [this.wnative.address, this.vwave.address] ]])

    await deploy(this, [["rewardpoolA", this.VaporwaveRewardPoolV2, [this.lp.address, this.vwave.address]],])
    await deploy(this, [["vwaveWETHRewardPool", this.VaporwaveRewardPoolV2, [this.vwave.address, this.wnative.address]],])
    await deploy(this, [["factory", this.VwaveFactory, [this.govtMock.address, this.vwave.address]]])
    
    this.chef = await this.MiniChefV2.attach(await this.factory.getChef())
    this.VWAVE_PER_SECOND = await this.factory.VWAVE_PER_SECOND()

    await deploy(this, [["feeReceipient", this.VaporwaveFeeRecipientV2, 
                        [ this.vwaveWETHRewardPool.address, 
                          this.unirouterNative2VWAVe.address,
                          this.vwave.address,
                          this.wnative.address,
                          this.chef.address ]]])

    await this.vwaveWETHRewardPool.setKeeper(this.feeReceipient.address)

    const predictedAddresses = await predictAddresses({ creator: this.alice.address });

    await deploy(this, [["govVault", this.VaporGovVault, 
                        [predictedAddresses.strategy,
                        "Gov Token", "GVT", 21600 ]]])

    await deploy(this, [["vwaveMaxi", this.VwaveMaxi, 
                        [ this.vwave.address, 
                          this.vwaveWETHRewardPool.address,
                          this.govVault.address,
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
    let voterAddress = voterTx.events.filter(x => x.event == "LOG_NEW_VOTER")[0].args["voter"]
    this.voter = await this.Voter.attach(voterAddress)

    await this.vwave.mint(this.chef.address, getBigNumber(10000))
    await this.vwave.mint(this.unirouterNative2VWAVe.address, getBigNumber(10000))

  })


  describe("Integration tests", function () {
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
      await this.vwave.approve(this.govVault.address, vwaveDeposit)
      await this.govVault.deposit(vwaveDeposit)
      // check that a user have received gov token
      expect(await this.govVault.balanceOf(this.alice.address)).to.be.equal(vwaveDeposit) 
      expect(await this.vwave.balanceOf(this.alice.address)).to.be.equal(0) 

      await advanceBlock()
      
      let rewardsAvailable = await this.vwaveMaxi.rewardsAvailable()
      // we expect some rewards to be generated
      expect(rewardsAvailable.gt(0)).to.be.true
      await this.vwaveMaxi.managerHarvest()
      await this.govVault.withdrawAll()
      // check that we now have more than 500 VWAVE after withdrawing
      let newVwaveDeposit = await this.vwave.balanceOf(this.alice.address)
      expect(newVwaveDeposit.gt(vwaveDeposit)).to.be.true
    })

    it("alice votes", async function () {
      let govtBalance = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      expect(await this.govtMock.allowance(this.alice.address, this.voter.address)).to.be.equal(voteCount)
      let logVote = await this.voter.vote(voteCount)
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
    it.skip("alice votes with time lock", async function () {
      let govtBalance = await this.govtMock.balanceOf(this.alice.address)
      expect(govtBalance).to.be.equal(getBigNumber(10000))
      let voteCount = getBigNumber(100)
      await this.govtMock.approve(this.voter.address, voteCount)
      expect(await this.govtMock.allowance(this.alice.address, this.voter.address)).to.be.equal(voteCount)
      let logVote = await this.voter.voteWithLock(voteCount, 60 * 60 * 24 * 365)

      // max pcnt = 40%, max period = 4 years
      // period above is 1 year, so
      // 40% / 4 of 100 = 10% of 100 = 10
      let actualVoteCount = voteCount.add(getBigNumber(10))
      expect(await this.voter.voteCount()).to.be.equal(actualVoteCount)
      expect(await this.voter.totalVoteCount()).to.be.equal(actualVoteCount)
      let govtBalanceAfterVote = await this.govtMock.balanceOf(this.alice.address)
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
  })
}
)
