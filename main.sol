// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Spella
 * @notice Spell-book trading platform: list spells by title hash and category, set price in wei; buyers pay and receive assignment; fees go to treasury. Suited for on-chain spell or book NFT-style markets.
 * @dev Vault, treasury, and spell keeper are set at deploy and are immutable. ReentrancyGuard and Pausable for mainnet safety.
 *
 * Spell listing: sellers call listSpell(titleHash, categoryHash, priceWei) or batchListSpells. Each spell gets a unique spellId.
 * Buying: anyone (except the seller) sends msg.value >= priceWei to buySpell(spellId). Fee (feeBps) is taken; remainder goes to seller.
 * Delisting: seller or owner may delist; spellKeeper may keeperDelist. Batch delist available for seller/owner.
 * Fees accumulate until sweepFees() sends them to treasury. WithdrawVault sends contract balance to vault (owner only).
 *
 * Constants: SPEL_BPS_BASE 10000, SPEL_MAX_FEE_BPS 350, SPEL_MAX_SPELLS 128, SPEL_PLATFORM_SALT fixed hex.
 * All constructor addresses are immutable and set at deployment.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract Spella is ReentrancyGuard, Pausable, Ownable {

    /// @notice Emitted when a new spell is listed for sale.
    event SpellListed(
        uint256 indexed spellId,
        address indexed seller,
        bytes32 titleHash,
        bytes32 indexed categoryHash,
        uint256 priceWei,
        uint256 atBlock
    );
    /// @notice Emitted when a spell is delisted (seller, owner, or keeper).
    event SpellDelisted(uint256 indexed spellId, address indexed seller, uint256 atBlock);
    /// @notice Emitted when a spell is purchased. feeWei is sent to treasury; seller receives priceWei - feeWei.
    event SpellTraded(
        bytes32 indexed tradeId,
        uint256 indexed spellId,
        address indexed buyer,
        address seller,
        uint256 priceWei,
        uint256 feeWei,
        uint256 atBlock
    );
    event SpellPriceUpdated(uint256 indexed spellId, uint256 previousPriceWei, uint256 newPriceWei, uint256 atBlock);
    event FeeSwept(address indexed to, uint256 amountWei, uint256 atBlock);
    event PlatformPauseToggled(bool paused);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps, uint256 atBlock);
    event CategoryLabelUpdated(bytes32 indexed categoryHash, bytes32 previousLabel, bytes32 newLabel, uint256 atBlock);
    event BatchSpellsListed(uint256[] spellIds, uint256 atBlock);
    event BatchSpellsDelisted(uint256[] spellIds, uint256 atBlock);

    error SPEL_ZeroAddress();        // Required address is zero.
    error SPEL_ZeroPrice();          // Price must be greater than zero.
    error SPEL_ZeroAmount();         // Amount must be greater than zero.
    error SPEL_PlatformPaused();     // Platform is paused; listing and buying disabled.
    error SPEL_SpellNotFound();      // spellId is zero or beyond spellCounter.
    error SPEL_SpellNotListed();     // Spell is not currently listed for sale.
    error SPEL_NotSeller();          // Caller is not the spell seller (for delist/updatePrice).
    error SPEL_NotKeeper();          // Caller is not the spellKeeper (for keeperDelist).
    error SPEL_InvalidFeeBps();      // Fee bps exceeds SPEL_MAX_FEE_BPS.
    error SPEL_TransferFailed();     // ETH transfer to seller, treasury, or vault failed.
    error SPEL_Reentrancy();         // Reentrant call detected.
    error SPEL_MaxSpellsReached();   // spellCounter would exceed SPEL_MAX_SPELLS.
    error SPEL_SpellAlreadyListed();  // Spell is already listed (unused in current logic).
    error SPEL_InsufficientPayment(); // msg.value < spell price on buySpell.
    error SPEL_ArrayLengthMismatch(); // Array lengths differ in batch calls.
    error SPEL_BatchTooLarge();      // Batch size exceeds SPEL_MAX_BATCH_LIST or SPEL_MAX_BATCH_DELIST.
    error SPEL_ZeroSpells();         // Batch array length is zero.
    error SPEL_InvalidTitleHash();   // titleHash is bytes32(0).
    error SPEL_BuyerIsSeller();      // Buyer cannot be the spell seller.
    error SPEL_SamePrice();          // New price equals current price in updateSpellPrice.

    uint256 public constant SPEL_BPS_BASE = 10000;
    uint256 public constant SPEL_MAX_FEE_BPS = 350;
    uint256 public constant SPEL_MAX_SPELLS = 128;
    uint256 public constant SPEL_PLATFORM_SALT = 0x3D8e1F4a7C0b2E5d9F3A6c8E1b4D7f0A3C6e9B2;
    uint256 public constant SPEL_MAX_BATCH_LIST = 20;
    uint256 public constant SPEL_MAX_BATCH_DELIST = 20;

    address public immutable vault;
    address public immutable treasury;
    address public immutable spellKeeper;
    uint256 public immutable deployedBlock;
    bytes32 public immutable platformDomain;

    uint256 public spellCounter;
    uint256 public feeBps;
    uint256 public tradeSequence;
    bool public platformPaused;

    struct SpellEntry {
        address seller;
        bytes32 titleHash;
        bytes32 categoryHash;
        uint256 priceWei;
        uint256 listedAtBlock;
        bool listed;
    }

    struct TradeRecord {
        bytes32 tradeId;
        uint256 spellId;
        address buyer;
        address seller;
        uint256 priceWei;
        uint256 feeWei;
        uint256 atBlock;
    }

    mapping(uint256 => SpellEntry) public spells;
    mapping(bytes32 => TradeRecord) public tradeSnapshots;
    mapping(uint256 => uint256) public spellTradeCount;
    mapping(uint256 => uint256) public spellVolumeWei;
    mapping(bytes32 => uint256) public categoryVolumeWei;
    mapping(address => uint256[]) private _spellIdsBySeller;
    uint256[] private _spellIds;
    uint256 private _feeAccum;

    modifier whenNotPaused() {
        if (platformPaused) revert SPEL_PlatformPaused();
        _;
    }

    constructor() {
        vault = address(0x1b3E6f9A2c5D8e0F4a7B9c1D3e5F7A0b2C4d6E8);
        treasury = address(0x4c7A0d2E5f8B1c3D6e9F2a5B8d0C3e6F9A1b4D7);
        spellKeeper = address(0x8F2a5C1e4B7d0A3f6C9e2B5d8F1a4C7E0b3D6f9);
        deployedBlock = block.number;
        platformDomain = keccak256(abi.encodePacked("Spella_", block.chainid, block.prevrandao, SPEL_PLATFORM_SALT));
        feeBps = 12;
    }

    function setPlatformPaused(bool paused) external onlyOwner {
        platformPaused = paused;
        emit PlatformPauseToggled(paused);
    }

    function setFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > SPEL_MAX_FEE_BPS) revert SPEL_InvalidFeeBps();
        uint256 prev = feeBps;
        feeBps = newFeeBps;
        emit FeeBpsUpdated(prev, newFeeBps, block.number);
    }

    /// @notice List a new spell for sale. Caller becomes the seller. Spell is assigned next sequential spellId.
    /// @param titleHash Keccak256 or other 32-byte identifier for the spell title (off-chain title → hash).
    /// @param categoryHash Category identifier (e.g. keccak256("combat"), keccak256("healing")).
    /// @param priceWei Price in wei that buyers must pay. Must be > 0.
    /// @return spellId The assigned spell ID (1-based, increments with each new spell).
    function listSpell(bytes32 titleHash, bytes32 categoryHash, uint256 priceWei) external whenNotPaused returns (uint256 spellId) {
        if (titleHash == bytes32(0)) revert SPEL_InvalidTitleHash();
        if (priceWei == 0) revert SPEL_ZeroPrice();
        if (spellCounter >= SPEL_MAX_SPELLS) revert SPEL_MaxSpellsReached();
        spellId = ++spellCounter;
        spells[spellId] = SpellEntry({
            seller: msg.sender,
            titleHash: titleHash,
            categoryHash: categoryHash,
            priceWei: priceWei,
            listedAtBlock: block.number,
            listed: true
        });
        _spellIds.push(spellId);
        _spellIdsBySeller[msg.sender].push(spellId);
        emit SpellListed(spellId, msg.sender, titleHash, categoryHash, priceWei, block.number);
    }

    /// @notice Delist a spell. Only the spell seller or contract owner may call. Spell remains in storage but listed = false.
    /// @param spellId The spell to delist.
    function delistSpell(uint256 spellId) external {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage entry = spells[spellId];
        if (!entry.listed) revert SPEL_SpellNotListed();
        if (entry.seller != msg.sender && msg.sender != owner()) revert SPEL_NotSeller();
        entry.listed = false;
        emit SpellDelisted(spellId, entry.seller, block.number);
    }

    /// @notice Update the listed price of a spell. Only the spell seller may call. Spell must still be listed.
    /// @param spellId The spell to update.
    /// @param newPriceWei New price in wei (must be > 0 and different from current).
    function updateSpellPrice(uint256 spellId, uint256 newPriceWei) external {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage entry = spells[spellId];
        if (!entry.listed) revert SPEL_SpellNotListed();
        if (entry.seller != msg.sender) revert SPEL_NotSeller();
        if (newPriceWei == 0) revert SPEL_ZeroPrice();
        if (newPriceWei == entry.priceWei) revert SPEL_SamePrice();
        uint256 prev = entry.priceWei;
        entry.priceWei = newPriceWei;
        emit SpellPriceUpdated(spellId, prev, newPriceWei, block.number);
    }

    /// @notice Buy a listed spell. Sender must send msg.value >= spell price. Seller cannot buy own spell. Fee (feeBps) goes to treasury; rest to seller.
