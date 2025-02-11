const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("LuckyGameSimple", function () {
  let luckyGame;
  let token;
  let randomGenerator;
  let owner;
  let player1;
  let player2;
  const MULTIPLIER = 197;
  const DENOMINATOR = 100;

  beforeEach(async function () {
    // 获取测试账户
    [owner, player1, player2] = await ethers.getSigners();

    // 部署 ERC20 代币
    const Token = await ethers.getContractFactory("MockERC20");
    token = await Token.deploy("Test Token", "TEST", ethers.parseEther("1000000"));
    await token.waitForDeployment();

    // 部署随机数生成器
    const RandomGenerator = await ethers.getContractFactory("MultiSourceRandom");
    randomGenerator = await RandomGenerator.deploy();
    await randomGenerator.waitForDeployment();

    // 部署游戏合约
    const LuckyGame = await ethers.getContractFactory("LuckyGameSimple");
    luckyGame = await LuckyGame.deploy(await token.getAddress(), await randomGenerator.getAddress());
    await luckyGame.waitForDeployment();

    // 给测试账户和合约转一些代币
    await token.transfer(player1.address, ethers.parseEther("10000"));
    await token.transfer(player2.address, ethers.parseEther("10000"));
    await token.transfer(await luckyGame.getAddress(), ethers.parseEther("100000")); // 给合约转入足够的代币
  });

  describe("基础功能测试", function () {
    it("应该正确初始化合约", async function () {
      expect(await luckyGame.token()).to.equal(await token.getAddress());
      expect(await luckyGame.randomGenerator()).to.equal(await randomGenerator.getAddress());
      expect(await luckyGame.owner()).to.equal(owner.address);
    });

    it("应该允许用户下注", async function () {
      const betAmount = ethers.parseEther("10");
      await token.connect(player1).approve(await luckyGame.getAddress(), betAmount);
      
      const initialBalance = await token.balanceOf(player1.address);
      await luckyGame.connect(player1).placeBet(betAmount, 1);
      const finalBalance = await token.balanceOf(player1.address);
      
      // 检查余额变化
      expect(finalBalance).to.not.equal(initialBalance);
    });

    it("不应该允许无效的选择", async function () {
      const betAmount = ethers.parseEther("10");
      await token.connect(player1).approve(await luckyGame.getAddress(), betAmount);
      
      await expect(
        luckyGame.connect(player1).placeBet(betAmount, 2)
      ).to.be.revertedWith("Invalid choice");
    });

    it("不应该允许零金额下注", async function () {
      await expect(
        luckyGame.connect(player1).placeBet(0, 1)
      ).to.be.revertedWith("Amount must be greater than 0");
    });
  });

  describe("质押功能测试", function () {
    it("应该允许用户质押代币", async function () {
      const stakeAmount = ethers.parseEther("100");
      await token.connect(player1).approve(await luckyGame.getAddress(), stakeAmount);
      
      await luckyGame.connect(player1).stake(stakeAmount);
      
      const stakerInfo = await luckyGame.stakers(player1.address);
      expect(stakerInfo.amount).to.equal(stakeAmount);
    });

    it("应该允许用户解除质押", async function () {
      const stakeAmount = ethers.parseEther("100");
      await token.connect(player1).approve(await luckyGame.getAddress(), stakeAmount);
      await luckyGame.connect(player1).stake(stakeAmount);
      
      await luckyGame.connect(player1).unstake(stakeAmount);
      
      const stakerInfo = await luckyGame.stakers(player1.address);
      expect(stakerInfo.amount).to.equal(0);
    });
  });

  describe("安全下注功能测试", function () {
    it("应该允许安全下注", async function () {
      const betAmount = ethers.parseEther("10");
      await token.connect(player1).approve(await luckyGame.getAddress(), betAmount);
      
      await luckyGame.connect(player1).placeBetSafe(betAmount, 1);
      
      expect(await luckyGame.hasPendingBet(player1.address)).to.be.true;
      expect(await luckyGame.pendingBetAmount(player1.address)).to.equal(betAmount);
    });

    it("应该允许完成安全下注", async function () {
      const betAmount = ethers.parseEther("10");
      await token.connect(player1).approve(await luckyGame.getAddress(), betAmount);
      
      await luckyGame.connect(player1).placeBetSafe(betAmount, 1);
      
      // 等待足够的区块以生成随机数
      for(let i = 0; i < 5; i++) {
        await ethers.provider.send("evm_mine", []);
      }
      
      await luckyGame.connect(player1).finalizeBet();
      
      expect(await luckyGame.hasPendingBet(player1.address)).to.be.false;
    });
  });

  describe("奖励分配测试", function () {
    it("应该正确分配奖励", async function () {
      // 首先让一些玩家输掉游戏来产生奖励
      const betAmount = ethers.parseEther("10");
      const doubleBetAmount = betAmount * 2n;
      await token.connect(player1).approve(await luckyGame.getAddress(), doubleBetAmount);
      await token.connect(player2).approve(await luckyGame.getAddress(), betAmount);
      
      // player1 和 player2 下注并输掉
      await luckyGame.connect(player1).placeBet(betAmount, 0);
      await luckyGame.connect(player2).placeBet(betAmount, 0);
      
      // 检查待分配奖励
      const pendingRewards = await luckyGame.pendingRewards();
      expect(pendingRewards).to.be.gt(0);
    });
  });
});
