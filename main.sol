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
