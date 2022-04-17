import { ADDRESS_ZERO, getCurrentBlockTime, advanceBlock, advanceBlockTo, advanceTime, advanceTimeAndBlock, deploy, getBigNumber, prepare } from "./utilities"
import { assert, expect } from "chai"

import { ethers } from "hardhat"
const { predictAddresses } = require("./predictAddresses");

const { BigNumber } = require("ethers")

describe.only("TimeTest", function () {
    
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
        let voterAddress = voterTx.events.filter(x => x.event == "LogNewVoter")[0].args["voter"]
        this.voter = await this.Voter.attach(voterAddress)
    
        await this.vwave.mint(this.chef.address, getBigNumber(10000))
        await this.vwave.mint(this.unirouterNative2VWAVe.address, getBigNumber(10000))
        let wnativeFees = getBigNumber(100)
        // Vaporwave farming fees go fee receipient
        await this.wnative.transfer(this.feeReceipient.address, wnativeFees)

      })
        

    describe("Block and time", function () {
        it("check that blocktime and block generation behave nicely", async function () {
            let t1 = await getCurrentBlockTime()
            let t2 = await getCurrentBlockTime()
            
            // each block advances time
            expect(t1).to.be.equal(t2)
            await advanceBlock()
            let t3 = await getCurrentBlockTime()
            expect(t1).to.be.not.equal(t3)

            // each block advances time for +1 sec
            await advanceBlock()
            await advanceBlock()
            await advanceBlock()
            expect(await getCurrentBlockTime() - t3).to.be.equal(3)

            // each transaction requires a block to be mined and advances time for +1 sec
            let t4 = await getCurrentBlockTime()
            await this.vwave.mint(this.alice.address, getBigNumber(100))
            await this.vwave.mint(this.alice.address, getBigNumber(200))
            await this.vwave.mint(this.alice.address, getBigNumber(300))
            await this.vwave.mint(this.alice.address, getBigNumber(400))
            expect(await getCurrentBlockTime() - t4).to.be.equal(4)

            // advance time set the next block's timestamp, it dosen't adjust current block's timestamp
            let timeStampBeforeAdvanceTime0 = await getCurrentBlockTime()
            await advanceTime(86400)
            let timeStampAftereAdvanceTime0 = await getCurrentBlockTime()
            expect(timeStampAftereAdvanceTime0 - timeStampBeforeAdvanceTime0).to.be.equal(0)
            await advanceTime(-86400) // subsequent adjustment accumulate

            let timeStampBeforeAdvanceTime1 = await getCurrentBlockTime()
            await advanceTime(86400)
            await advanceBlock()
            let timeStampAftereAdvanceTime1 = await getCurrentBlockTime()
            expect(timeStampAftereAdvanceTime1 - timeStampBeforeAdvanceTime1).to.be.equal(86400)

            let timeStampBeforeAdvanceTime2 = await getCurrentBlockTime()
            await advanceBlock()
            await advanceTime(86400)
            let timeStampAftereAdvanceTime2 = await getCurrentBlockTime()
            expect(timeStampAftereAdvanceTime2 - timeStampBeforeAdvanceTime2).to.be.equal(1)
            await advanceTime(-86400)


            // internal transactions do not advance time
            let timeBeforeHarvest = await getCurrentBlockTime()
            await this.feeReceipient.harvest() 
            let timeAfterHarvest = await getCurrentBlockTime()
            expect(timeAfterHarvest - timeBeforeHarvest).to.be.equal(1)

            // view only operations do not minde/advance time
            await this.vwave.balanceOf(this.alice.address)
            expect(timeAfterHarvest - await getCurrentBlockTime()).to.be.equal(0)

            // timestamp inside a transaction = Current Block Time + 1
            let timeBeforeCall = await getCurrentBlockTime()
            await expect(this.wnative.mintWithTimestamp(this.alice.address, getBigNumber(123))).to.emit(this.wnative, "Time").withArgs(timeBeforeCall+1)      
        })
    
    })
})
