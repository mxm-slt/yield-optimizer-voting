import { getBigNumber } from "../test/utilities";

const hre = require("hardhat");
const { BigNumber } = require("ethers")

async function main() {
    const govToken = await deployMockToken("GovToken", "GVT")
    const vwaveToken = await deployVwaveToken()
    const lpToken = await deployMockToken("LPToken", "LPT")

    const factory = await deployFactory(govToken, vwaveToken)

    await createVoter(
        factory,
        await createTestPool(lpToken.address, vwaveToken.address)
    )
    await createVoter(
        factory,
        await createTestPool(lpToken.address, vwaveToken.address)
    )
    await createVoter(
        factory,
        await createTestPool(lpToken.address, vwaveToken.address)
    )
}

export async function createTestPool(stakedTokenAddress, rewardTokenAddress): Promise<any> {
    console.log("Deploying a pool for:", stakedTokenAddress, rewardTokenAddress)
    const RewardPool = await hre.ethers.getContractFactory("VaporwaveRewardPoolV2")
    const rewardPool = await RewardPool.deploy(stakedTokenAddress, rewardTokenAddress)
    console.log("Reward pool deployed to:", rewardPool.address)
    return rewardPool
}

export async function createVoter(factory, rewardPool): Promise<any> {
    const Voter = await hre.ethers.getContractFactory("Voter")
    const voterTx = await (await factory.newVoter(rewardPool.address)).wait()
    const voterAddress = voterTx.events.filter(x => x.event == "LogNewVoter")[0].args["voter"]
    console.log("Voter for pool " + rewardPool.address + " was deployed to: ", voterAddress)
    const voter = await Voter.attach(voterAddress)
    return voter
}

async function deployMockToken(name: string, code: string): Promise<any> {
    const ERC20Mock = await hre.ethers.getContractFactory("ERC20Mock")
    const token = await ERC20Mock.deploy(name, code, getBigNumber(10000))
    console.log("Token " + name + " deployed to:", token.address)
    return token
}

async function deployVwaveToken(): Promise<any> {
    // deploy Tokens
    const VwaveToken = await hre.ethers.getContractFactory("VwaveToken")
    const vwaveToken = await VwaveToken.deploy()
    console.log("VwaveToken deployed to:", vwaveToken.address)
    return vwaveToken
}

async function deployFactory(govToken, vwaveToken): Promise<any> {
    const VwaveFactory = await hre.ethers.getContractFactory("VwaveFactory")
    const vwaveFactory = await VwaveFactory.deploy(govToken.address, vwaveToken.address);
    await vwaveFactory.deployed()
    console.log("VwaveFactory deployed to:", vwaveFactory.address)
    return vwaveFactory
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });