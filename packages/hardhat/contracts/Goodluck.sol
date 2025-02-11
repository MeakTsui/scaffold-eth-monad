// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./MultiSourceRandom.sol";

contract LuckyGameSimple is ReentrancyGuard, Ownable {
    IERC20 public token;  // 游戏代币
    MultiSourceRandom public randomGenerator; // 随机数生成器

    // 游戏参数
    uint256 public constant MULTIPLIER = 197;  // 1.97倍
    uint256 public constant DENOMINATOR = 100;
    
    // 质押相关
    struct Staker {
        uint256 amount;        // 质押数量
        uint256 rewardDebt;    // 奖励债务
    }
    
    mapping(address => Staker) public stakers;
    uint256 public totalStaked;         // 总质押量
    uint256 public accRewardPerShare;   // 每份额累计奖励
    uint256 public pendingRewards;      // 待分配奖励
    
    // 游戏状态
    mapping(address => bool) public hasPendingBet;  // 用户是否有待处理的投注
    mapping(address => uint256) public pendingBetAmount;  // 待处理投注金额
    mapping(address => uint256) public pendingBetChoice;  // 待处理投注选择
    
    // 事件
    event BetPlaced(address indexed user, uint256 amount, uint256 choice, bool won);
    event BetRequested(address indexed user, uint256 amount, uint256 choice);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    
    constructor(address _token, address _randomGenerator) {
        token = IERC20(_token);
        randomGenerator = MultiSourceRandom(_randomGenerator);
    }

    // 下注函数 - 一次交易完成
    function placeBet(uint256 amount, uint256 choice) external nonReentrant {
        require(choice <= 1, "Invalid choice");
        require(amount > 0, "Amount must be greater than 0");
        require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // 转移代币到合约
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // 生成随机结果 - 使用即时随机数
        uint256 result = randomGenerator.getInstantRandom() % 2;
        bool won = (result == choice);
        
        if (won) {
            // 赢家获得1.97倍返还
            uint256 winAmount = (amount * MULTIPLIER) / DENOMINATOR;
            require(token.transfer(msg.sender, winAmount), "Transfer failed");
        } else {
            // 输家的金额进入奖池
            pendingRewards += amount;
            updateRewards();
        }
        
        emit BetPlaced(msg.sender, amount, choice, won);
    }

    // 高额投注的安全版本（使用延迟随机数）
    function placeBetSafe(uint256 amount, uint256 choice) external nonReentrant {
        require(choice <= 1, "Invalid choice");
        require(amount > 0, "Amount must be greater than 0");
        require(token.balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // 转移代币到合约
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        // 请求随机数
        randomGenerator.requestDelayedRandom();
        
        // 保存投注信息
        hasPendingBet[msg.sender] = true;
        pendingBetAmount[msg.sender] = amount;
        pendingBetChoice[msg.sender] = choice;
        
        emit BetRequested(msg.sender, amount, choice);
    }
    
    // 完成下注
    function finalizeBet() external nonReentrant {
        require(hasPendingBet[msg.sender], "No pending bet");
        
        uint256 amount = pendingBetAmount[msg.sender];
        uint256 choice = pendingBetChoice[msg.sender];
        
        // 获取随机结果
        uint256 result = randomGenerator.getDelayedRandom() % 2;
        bool won = (result == choice);
        
        // 清除待处理状态
        hasPendingBet[msg.sender] = false;
        pendingBetAmount[msg.sender] = 0;
        pendingBetChoice[msg.sender] = 0;
        
        if (won) {
            // 赢家获得1.97倍返还
            uint256 winAmount = (amount * MULTIPLIER) / DENOMINATOR;
            require(token.transfer(msg.sender, winAmount), "Transfer failed");
        } else {
            // 输家的金额进入奖池
            pendingRewards += amount;
            updateRewards();
        }
        
        emit BetPlaced(msg.sender, amount, choice, won);
    }
    
    // 取消待处理的投注（如果随机数生成失败）
    function cancelPendingBet() external nonReentrant {
        require(hasPendingBet[msg.sender], "No pending bet");
        
        uint256 amount = pendingBetAmount[msg.sender];
        
        // 清除待处理状态
        hasPendingBet[msg.sender] = false;
        pendingBetAmount[msg.sender] = 0;
        pendingBetChoice[msg.sender] = 0;
        
        // 返还代币
        require(token.transfer(msg.sender, amount), "Transfer failed");
    }
    
    // 质押代币
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        updateRewards();
        
        // 先领取之前的收益
        if (stakers[msg.sender].amount > 0) {
            claimReward();
        }
        
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        
        stakers[msg.sender].amount += amount;
        totalStaked += amount;
        
        // 更新用户的rewardDebt
        stakers[msg.sender].rewardDebt = (stakers[msg.sender].amount * accRewardPerShare) / 1e18;
        
        emit Staked(msg.sender, amount);
    }
    
    // 取消质押
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(stakers[msg.sender].amount >= amount, "Insufficient staked amount");
        
        updateRewards();
        
        uint256 pending = (stakers[msg.sender].amount * accRewardPerShare) / 1e18 - stakers[msg.sender].rewardDebt;
        
        stakers[msg.sender].amount -= amount;
        totalStaked -= amount;
        
        stakers[msg.sender].rewardDebt = (stakers[msg.sender].amount * accRewardPerShare) / 1e18;
        
        // 一次性转账所有代币（包括解除质押的金额和待领取的收益）
        uint256 totalAmount = amount + pending;
        require(token.transfer(msg.sender, totalAmount), "Transfer failed");
        
        emit Unstaked(msg.sender, amount);
        if (pending > 0) {
            emit RewardClaimed(msg.sender, pending);
        }
    }
    
    // 领取收益
    function claimReward() public nonReentrant {
        updateRewards();
        
        uint256 pending = (stakers[msg.sender].amount * accRewardPerShare) / 1e18 - stakers[msg.sender].rewardDebt;
        if (pending > 0) {
            require(token.transfer(msg.sender, pending), "Transfer failed");
            stakers[msg.sender].rewardDebt = (stakers[msg.sender].amount * accRewardPerShare) / 1e18;
            emit RewardClaimed(msg.sender, pending);
        }
    }
    
    // 更新收益
    function updateRewards() internal {
        if (totalStaked == 0) {
            return;
        }
        
        if (pendingRewards > 0) {
            accRewardPerShare += (pendingRewards * 1e18) / totalStaked;
            pendingRewards = 0;
        }
    }
    
    // 查看待领取的收益
    function pendingReward(address user) external view returns (uint256) {
        if (totalStaked == 0) {
            return 0;
        }
        
        uint256 _accRewardPerShare = accRewardPerShare;
        if (pendingRewards > 0) {
            _accRewardPerShare += (pendingRewards * 1e18) / totalStaked;
        }
        
        return (stakers[user].amount * _accRewardPerShare) / 1e18 - stakers[user].rewardDebt;
    }

    // 紧急提款（仅合约拥有者）
    function emergencyWithdraw(uint256 amount) external onlyOwner {
        require(token.transfer(owner(), amount), "Transfer failed");
    }
}