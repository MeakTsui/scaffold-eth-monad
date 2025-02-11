// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MultiSourceRandom
 * @dev 实现一个多源的随机数生成合约，包含多种随机数生成机制
 */
contract MultiSourceRandom is Ownable, Pausable, ReentrancyGuard {
    // 存储提交的随机数种子
    mapping(address => bytes32) public commitments;
    
    // 每轮的参与者数量
    uint256 public participants;
    
    // 提交阶段的时间窗口
    uint256 public constant COMMIT_PHASE_LENGTH = 5 minutes;
    
    // 当前轮次的开始时间
    uint256 public roundStartTime;
    
    // 用于即时随机数生成的nonce
    uint256 private nonce;
    
    // 延迟随机数相关变量
    uint256 public futureBlockNumber;
    bytes32 public commitHash;
    
    // 最后生成的随机数
    uint256 public lastRandomNumber;
    
    // 事件声明
    event RandomNumberRequested(address indexed requester, uint256 futureBlockNumber);
    event RandomNumberGenerated(address indexed requester, uint256 randomNumber);
    event NewRoundStarted(uint256 timestamp);
    event CommitmentSubmitted(address indexed participant, bytes32 commitment);
    event NumberRevealed(address indexed participant, uint256 number);
    
    constructor() {
        roundStartTime = block.timestamp;
        nonce = 0;
    }
    
    /**
     * @dev 获取即时随机数
     * 注意：这种方法不够安全，仅适用于低价值场景
     */
    function getInstantRandom() public returns (uint256) {
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            blockhash(block.number - 1),
            block.timestamp,
            msg.sender,
            nonce
        )));
        nonce++;
        lastRandomNumber = randomNumber;
        emit RandomNumberGenerated(msg.sender, randomNumber);
        return randomNumber;
    }
    
    /**
     * @dev 请求延迟随机数
     * 更安全，因为有时间延迟
     */
    function requestDelayedRandom() external whenNotPaused {
        futureBlockNumber = block.number + 5; // 等待5个区块
        commitHash = blockhash(block.number);
        emit RandomNumberRequested(msg.sender, futureBlockNumber);
    }
    
    /**
     * @dev 获取延迟随机数
     */
    function getDelayedRandom() external whenNotPaused returns (uint256) {
        require(block.number >= futureBlockNumber, "Too early to generate random number");
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            commitHash,
            blockhash(futureBlockNumber),
            getAdditionalEntropy()
        )));
        lastRandomNumber = randomNumber;
        emit RandomNumberGenerated(msg.sender, randomNumber);
        return randomNumber;
    }
    
    /**
     * @dev 提交随机数种子的哈希
     * 用于commit-reveal模式
     */
    function commit(bytes32 commitment) external whenNotPaused {
        require(block.timestamp < roundStartTime + COMMIT_PHASE_LENGTH, "Commit phase ended");
        require(commitments[msg.sender] == bytes32(0), "Already committed");
        
        commitments[msg.sender] = commitment;
        participants++;
        emit CommitmentSubmitted(msg.sender, commitment);
    }
    
    /**
     * @dev 揭示之前提交的随机数
     */
    function reveal(uint256 number, bytes32 salt) external whenNotPaused nonReentrant {
        require(block.timestamp >= roundStartTime + COMMIT_PHASE_LENGTH, "Still in commit phase");
        require(commitments[msg.sender] == keccak256(abi.encodePacked(number, salt)), "Invalid reveal");
        
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(
            number,
            salt,
            getAdditionalEntropy()
        )));
        
        lastRandomNumber = randomNumber;
        delete commitments[msg.sender];
        emit NumberRevealed(msg.sender, number);
        emit RandomNumberGenerated(msg.sender, randomNumber);
    }
    
    /**
     * @dev 开始新的一轮
     */
    function startNewRound() external whenNotPaused {
        roundStartTime = block.timestamp;
        participants = 0;
        emit NewRoundStarted(roundStartTime);
    }
    
    /**
     * @dev 获取额外的熵源
     */
    function getAdditionalEntropy() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            block.prevrandao,
            block.coinbase,
            gasleft(),
            block.timestamp
        ));
    }
    
    /**
     * @dev 范围内的随机数
     * @param min 最小值
     * @param max 最大值
     */
    function getRandomNumberInRange(uint256 min, uint256 max) external returns (uint256) {
        require(max > min, "Invalid range");
        uint256 randomNumber = getInstantRandom();
        return (randomNumber % (max - min + 1)) + min;
    }
    
    // 管理功能
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
}
