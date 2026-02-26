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
    /// @param spellId The spell to purchase.
    /// @return tradeId Unique trade identifier (keccak256 of chain, block, sequence, parties, amount, prevrandao).
    /// @return feeWei The fee taken (priceWei * feeBps / 10000).
    function buySpell(uint256 spellId) external payable nonReentrant whenNotPaused returns (bytes32 tradeId, uint256 feeWei) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage entry = spells[spellId];
        if (!entry.listed) revert SPEL_SpellNotListed();
        if (entry.seller == msg.sender) revert SPEL_BuyerIsSeller();
        if (msg.value < entry.priceWei) revert SPEL_InsufficientPayment();

        entry.listed = false;
        feeWei = (entry.priceWei * feeBps) / SPEL_BPS_BASE;
        uint256 sellerReceives = entry.priceWei - feeWei;
        _feeAccum += feeWei;

        tradeId = keccak256(abi.encodePacked(
            "Spella_Trade",
            block.chainid,
            block.number,
            tradeSequence++,
            spellId,
            msg.sender,
            entry.seller,
            entry.priceWei,
            block.prevrandao
        ));

        tradeSnapshots[tradeId] = TradeRecord({
            tradeId: tradeId,
            spellId: spellId,
            buyer: msg.sender,
            seller: entry.seller,
            priceWei: entry.priceWei,
            feeWei: feeWei,
            atBlock: block.number
        });

        spellTradeCount[spellId]++;
        spellVolumeWei[spellId] += entry.priceWei;
        categoryVolumeWei[entry.categoryHash] += entry.priceWei;

        (bool okSeller,) = entry.seller.call{value: sellerReceives}("");
        if (!okSeller) revert SPEL_TransferFailed();

        emit SpellTraded(tradeId, spellId, msg.sender, entry.seller, entry.priceWei, feeWei, block.number);
    }

    /// @notice Send all accumulated fees (from buySpell) to the treasury address. Anyone may call.
    function sweepFees() external nonReentrant {
        uint256 amount = _feeAccum;
        if (amount == 0) return;
        _feeAccum = 0;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert SPEL_TransferFailed();
        emit FeeSwept(treasury, amount, block.number);
    }

    /// @notice Keeper-only: delist a spell without being the seller. Used for moderation or policy.
    /// @param spellId The spell to delist.
    function keeperDelist(uint256 spellId) external {
        if (msg.sender != spellKeeper) revert SPEL_NotKeeper();
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage entry = spells[spellId];
        if (!entry.listed) revert SPEL_SpellNotListed();
        entry.listed = false;
        emit SpellDelisted(spellId, entry.seller, block.number);
    }

    function batchListSpells(
        bytes32[] calldata titleHashes,
        bytes32[] calldata categoryHashes,
        uint256[] calldata pricesWei
    ) external whenNotPaused returns (uint256[] memory spellIds) {
        uint256 n = titleHashes.length;
        if (n != categoryHashes.length || n != pricesWei.length) revert SPEL_ArrayLengthMismatch();
        if (n == 0) revert SPEL_ZeroSpells();
        if (n > SPEL_MAX_BATCH_LIST) revert SPEL_BatchTooLarge();
        if (spellCounter + n > SPEL_MAX_SPELLS) revert SPEL_MaxSpellsReached();

        spellIds = new uint256[](n);
        for (uint256 i; i < n;) {
            if (titleHashes[i] == bytes32(0)) revert SPEL_InvalidTitleHash();
            if (pricesWei[i] == 0) revert SPEL_ZeroPrice();
            uint256 spellId = ++spellCounter;
            spells[spellId] = SpellEntry({
                seller: msg.sender,
                titleHash: titleHashes[i],
                categoryHash: categoryHashes[i],
                priceWei: pricesWei[i],
                listedAtBlock: block.number,
                listed: true
            });
            spellIds[i] = spellId;
            _spellIds.push(spellId);
            _spellIdsBySeller[msg.sender].push(spellId);
            emit SpellListed(spellId, msg.sender, titleHashes[i], categoryHashes[i], pricesWei[i], block.number);
            unchecked { ++i; }
        }
        emit BatchSpellsListed(spellIds, block.number);
    }

    function batchDelistSpells(uint256[] calldata spellIdsToDelist) external {
        uint256 n = spellIdsToDelist.length;
        if (n == 0) revert SPEL_ZeroSpells();
        if (n > SPEL_MAX_BATCH_DELIST) revert SPEL_BatchTooLarge();
        for (uint256 i; i < n;) {
            uint256 spellId = spellIdsToDelist[i];
            if (spellId != 0 && spellId <= spellCounter) {
                SpellEntry storage entry = spells[spellId];
                if (entry.listed && (entry.seller == msg.sender || msg.sender == owner())) {
                    entry.listed = false;
                    emit SpellDelisted(spellId, entry.seller, block.number);
                }
            }
            unchecked { ++i; }
        }
        emit BatchSpellsDelisted(spellIdsToDelist, block.number);
    }

    function withdrawVault(uint256 amountWei) external onlyOwner nonReentrant {
        if (amountWei == 0) revert SPEL_ZeroAmount();
        uint256 bal = address(this).balance;
        if (amountWei > bal) amountWei = bal;
        (bool ok,) = vault.call{value: amountWei}("");
        if (!ok) revert SPEL_TransferFailed();
        emit FeeSwept(vault, amountWei, block.number);
    }

    function getSpellIds() external view returns (uint256[] memory) {
        return _spellIds;
    }

    function getSpellIdsBySeller(address seller) external view returns (uint256[] memory) {
        return _spellIdsBySeller[seller];
    }

    function getSpell(uint256 spellId) external view returns (
        address seller,
        bytes32 titleHash,
        bytes32 categoryHash,
        uint256 priceWei,
        uint256 listedAtBlock,
        bool listed
    ) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage e = spells[spellId];
        return (e.seller, e.titleHash, e.categoryHash, e.priceWei, e.listedAtBlock, e.listed);
    }

    function getTrade(bytes32 tradeId) external view returns (
        uint256 spellId,
        address buyer,
        address seller,
        uint256 priceWei,
        uint256 feeWei,
        uint256 atBlock
    ) {
        TradeRecord storage t = tradeSnapshots[tradeId];
        return (t.spellId, t.buyer, t.seller, t.priceWei, t.feeWei, t.atBlock);
    }

    function getListedSpellIds() external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].listed) count++;
        }
        uint256[] memory listed = new uint256[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].listed) listed[j++] = all[i];
        }
        return listed;
    }

    function getListedSpellIdsBySeller(address seller) external view returns (uint256[] memory) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        uint256 count;
        for (uint256 i; i < ids.length; i++) {
            if (spells[ids[i]].listed) count++;
        }
        uint256[] memory listed = new uint256[](count);
        uint256 j;
        for (uint256 i; i < ids.length; i++) {
            if (spells[ids[i]].listed) listed[j++] = ids[i];
        }
        return listed;
    }

    function getCategoryVolume(bytes32 categoryHash) external view returns (uint256) {
        return categoryVolumeWei[categoryHash];
    }

    function getAccumulatedFees() external view returns (uint256) {
        return _feeAccum;
    }

    function getSpellIdsInCategory(bytes32 categoryHash) external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].categoryHash == categoryHash && spells[all[i]].listed) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].categoryHash == categoryHash && spells[all[i]].listed) out[j++] = all[i];
        }
        return out;
    }

    function getSpellIdsInCategoryUnfiltered(bytes32 categoryHash) external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].categoryHash == categoryHash) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].categoryHash == categoryHash) out[j++] = all[i];
        }
        return out;
    }

    function getListedSpellIdsInPriceRange(uint256 minPriceWei, uint256 maxPriceWei) external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            SpellEntry storage e = spells[all[i]];
            if (e.listed && e.priceWei >= minPriceWei && e.priceWei <= maxPriceWei) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            SpellEntry storage e = spells[all[i]];
            if (e.listed && e.priceWei >= minPriceWei && e.priceWei <= maxPriceWei) out[j++] = all[i];
        }
        return out;
    }

    function getListedSpellIdsBySellerInCategory(address seller, bytes32 categoryHash) external view returns (uint256[] memory) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        uint256 count;
        for (uint256 i; i < ids.length; i++) {
            if (spells[ids[i]].listed && spells[ids[i]].categoryHash == categoryHash) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i; i < ids.length; i++) {
            if (spells[ids[i]].listed && spells[ids[i]].categoryHash == categoryHash) out[j++] = ids[i];
        }
        return out;
    }

    function getSpellCount() external view returns (uint256) {
        return spellCounter;
    }

    function getListedSpellCount() external view returns (uint256) {
        uint256 count;
        for (uint256 i; i < _spellIds.length; i++) {
            if (spells[_spellIds[i]].listed) count++;
        }
        return count;
    }

    function getSellerSpellCount(address seller) external view returns (uint256) {
        return _spellIdsBySeller[seller].length;
    }

    function getSellerListedSpellCount(address seller) external view returns (uint256) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        uint256 count;
        for (uint256 i; i < ids.length; i++) {
            if (spells[ids[i]].listed) count++;
        }
        return count;
    }

    function getSpellsPaginated(uint256 offset, uint256 limit) external view returns (
        uint256[] memory spellIdsOut,
        address[] memory sellersOut,
        bytes32[] memory titleHashesOut,
        bytes32[] memory categoryHashesOut,
        uint256[] memory pricesWeiOut,
        bool[] memory listedOut
    ) {
        uint256 total = _spellIds.length;
        if (offset >= total) {
            spellIdsOut = new uint256[](0);
            sellersOut = new address[](0);
            titleHashesOut = new bytes32[](0);
            categoryHashesOut = new bytes32[](0);
            pricesWeiOut = new uint256[](0);
            listedOut = new bool[](0);
            return (spellIdsOut, sellersOut, titleHashesOut, categoryHashesOut, pricesWeiOut, listedOut);
        }
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        spellIdsOut = new uint256[](n);
        sellersOut = new address[](n);
        titleHashesOut = new bytes32[](n);
        categoryHashesOut = new bytes32[](n);
        pricesWeiOut = new uint256[](n);
        listedOut = new bool[](n);
        for (uint256 i; i < n; i++) {
            uint256 spellId = _spellIds[offset + i];
            SpellEntry storage e = spells[spellId];
            spellIdsOut[i] = spellId;
            sellersOut[i] = e.seller;
            titleHashesOut[i] = e.titleHash;
            categoryHashesOut[i] = e.categoryHash;
            pricesWeiOut[i] = e.priceWei;
            listedOut[i] = e.listed;
        }
    }

    function getListedSpellsPaginated(uint256 offset, uint256 limit) external view returns (
        uint256[] memory spellIdsOut,
        address[] memory sellersOut,
        bytes32[] memory titleHashesOut,
        bytes32[] memory categoryHashesOut,
        uint256[] memory pricesWeiOut
    ) {
        uint256[] memory all = _spellIds;
        uint256 listedCount;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].listed) listedCount++;
        }
        if (offset >= listedCount) {
            spellIdsOut = new uint256[](0);
            sellersOut = new address[](0);
            titleHashesOut = new bytes32[](0);
            categoryHashesOut = new bytes32[](0);
            pricesWeiOut = new uint256[](0);
            return (spellIdsOut, sellersOut, titleHashesOut, categoryHashesOut, pricesWeiOut);
        }
        uint256 end = offset + limit;
        if (end > listedCount) end = listedCount;
        uint256 n = end - offset;
        spellIdsOut = new uint256[](n);
        sellersOut = new address[](n);
        titleHashesOut = new bytes32[](n);
        categoryHashesOut = new bytes32[](n);
        pricesWeiOut = new uint256[](n);
        uint256 collected;
        for (uint256 i; i < all.length && collected < end; i++) {
            if (!spells[all[i]].listed) continue;
            if (collected >= offset) {
                uint256 idx = collected - offset;
                SpellEntry storage e = spells[all[i]];
                spellIdsOut[idx] = all[i];
                sellersOut[idx] = e.seller;
                titleHashesOut[idx] = e.titleHash;
                categoryHashesOut[idx] = e.categoryHash;
                pricesWeiOut[idx] = e.priceWei;
            }
            collected++;
        }
    }

    function computeFeeForPrice(uint256 priceWei) external view returns (uint256 feeWei) {
        return (priceWei * feeBps) / SPEL_BPS_BASE;
    }

    function computeSellerReceives(uint256 priceWei) external view returns (uint256) {
        uint256 feeWei = (priceWei * feeBps) / SPEL_BPS_BASE;
        return priceWei - feeWei;
    }

    function isSpellListed(uint256 spellId) external view returns (bool) {
        if (spellId == 0 || spellId > spellCounter) return false;
        return spells[spellId].listed;
    }

    function getSpellSeller(uint256 spellId) external view returns (address) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        return spells[spellId].seller;
    }

    function getSpellPrice(uint256 spellId) external view returns (uint256) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        return spells[spellId].priceWei;
    }

    function getSpellCategory(uint256 spellId) external view returns (bytes32) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        return spells[spellId].categoryHash;
    }

    function getSpellTitleHash(uint256 spellId) external view returns (bytes32) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        return spells[spellId].titleHash;
    }

    function getPlatformStats() external view returns (
        uint256 totalSpells,
        uint256 totalListed,
        uint256 totalTrades,
        uint256 accumulatedFeesWei,
        uint256 currentFeeBps,
        bool paused
    ) {
        totalSpells = spellCounter;
        totalListed = 0;
        for (uint256 i; i < _spellIds.length; i++) {
            if (spells[_spellIds[i]].listed) totalListed++;
        }
        totalTrades = tradeSequence;
        accumulatedFeesWei = _feeAccum;
        currentFeeBps = feeBps;
        paused = platformPaused;
    }

    function getSpellStats(uint256 spellId) external view returns (
        uint256 tradeCount,
        uint256 volumeWei,
        uint256 listedAtBlock
    ) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage e = spells[spellId];
        return (spellTradeCount[spellId], spellVolumeWei[spellId], e.listedAtBlock);
    }

    function getSpellFull(uint256 spellId) external view returns (
        address seller,
        bytes32 titleHash,
        bytes32 categoryHash,
        uint256 priceWei,
        uint256 listedAtBlock,
        bool listed,
        uint256 tradeCount,
        uint256 volumeWei
    ) {
        if (spellId == 0 || spellId > spellCounter) revert SPEL_SpellNotFound();
        SpellEntry storage e = spells[spellId];
        return (
            e.seller,
            e.titleHash,
            e.categoryHash,
            e.priceWei,
            e.listedAtBlock,
            e.listed,
            spellTradeCount[spellId],
            spellVolumeWei[spellId]
        );
    }

    function getMultipleSpells(uint256[] calldata spellIds) external view returns (
        address[] memory sellers,
        bytes32[] memory titleHashes,
        bytes32[] memory categoryHashes,
        uint256[] memory pricesWei,
        bool[] memory listedFlags
    ) {
        uint256 n = spellIds.length;
        sellers = new address[](n);
        titleHashes = new bytes32[](n);
        categoryHashes = new bytes32[](n);
        pricesWei = new uint256[](n);
        listedFlags = new bool[](n);
        for (uint256 i; i < n; i++) {
            uint256 id = spellIds[i];
            if (id != 0 && id <= spellCounter) {
                SpellEntry storage e = spells[id];
                sellers[i] = e.seller;
                titleHashes[i] = e.titleHash;
                categoryHashes[i] = e.categoryHash;
                pricesWei[i] = e.priceWei;
                listedFlags[i] = e.listed;
            }
        }
    }

    function getMultipleSpellStats(uint256[] calldata spellIds) external view returns (
        uint256[] memory tradeCounts,
        uint256[] memory volumesWei
    ) {
        uint256 n = spellIds.length;
        tradeCounts = new uint256[](n);
        volumesWei = new uint256[](n);
        for (uint256 i; i < n; i++) {
            uint256 id = spellIds[i];
            if (id != 0 && id <= spellCounter) {
                tradeCounts[i] = spellTradeCount[id];
                volumesWei[i] = spellVolumeWei[id];
            }
        }
    }

    function totalVolumeWei() external view returns (uint256 total) {
        for (uint256 i; i < _spellIds.length; i++) {
            total += spellVolumeWei[_spellIds[i]];
        }
    }

    function getListedIdsForCategories(bytes32[] calldata categoryHashes) external view returns (uint256[][] memory spellIdLists) {
        spellIdLists = new uint256[][](categoryHashes.length);
        for (uint256 c; c < categoryHashes.length; c++) {
            uint256[] memory all = _spellIds;
            uint256 count;
            for (uint256 i; i < all.length; i++) {
                if (spells[all[i]].categoryHash == categoryHashes[c] && spells[all[i]].listed) count++;
            }
            spellIdLists[c] = new uint256[](count);
            uint256 j;
            for (uint256 i; i < all.length; i++) {
                if (spells[all[i]].categoryHash == categoryHashes[c] && spells[all[i]].listed) spellIdLists[c][j++] = all[i];
            }
        }
    }

    function getCategoryVolumes(bytes32[] calldata categoryHashes) external view returns (uint256[] memory volumes) {
        volumes = new uint256[](categoryHashes.length);
        for (uint256 i; i < categoryHashes.length; i++) {
            volumes[i] = categoryVolumeWei[categoryHashes[i]];
        }
    }

    function getSpellIdsListedAfterBlock(uint256 fromBlock) external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].listed && spells[all[i]].listedAtBlock >= fromBlock) count++;
        }
        uint256[] memory out = new uint256[](count);
        uint256 j;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].listed && spells[all[i]].listedAtBlock >= fromBlock) out[j++] = all[i];
        }
        return out;
    }

    function getSpellIdsBySellerPaginated(address seller, uint256 offset, uint256 limit) external view returns (uint256[] memory spellIdsOut) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        uint256 total = ids.length;
        if (offset >= total) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 n = end - offset;
        spellIdsOut = new uint256[](n);
        for (uint256 i; i < n; i++) {
            spellIdsOut[i] = ids[offset + i];
        }
    }

    function getListedSpellIdsPaginatedByCategory(bytes32 categoryHash, uint256 offset, uint256 limit) external view returns (uint256[] memory) {
        uint256[] memory all = _spellIds;
        uint256 count;
        for (uint256 i; i < all.length; i++) {
            if (spells[all[i]].categoryHash == categoryHash && spells[all[i]].listed) count++;
        }
        if (offset >= count) return new uint256[](0);
        uint256 end = offset + limit;
        if (end > count) end = count;
        uint256 n = end - offset;
        uint256[] memory out = new uint256[](n);
        uint256 collected;
        for (uint256 i; i < all.length && collected < end; i++) {
            if (spells[all[i]].categoryHash != categoryHash || !spells[all[i]].listed) continue;
            if (collected >= offset) out[collected - offset] = all[i];
            collected++;
        }
        return out;
    }

    function getSellerTotalVolume(address seller) external view returns (uint256 total) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        for (uint256 i; i < ids.length; i++) {
            total += spellVolumeWei[ids[i]];
        }
    }

    function getSellerTradeCount(address seller) external view returns (uint256 total) {
        uint256[] memory ids = _spellIdsBySeller[seller];
        for (uint256 i; i < ids.length; i++) {
            total += spellTradeCount[ids[i]];
        }
    }

    receive() external payable {}
}

