module terminal::vault;

use std::string::String;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object_bag::{Self, ObjectBag};
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

// === Constants ===

const STATUS_OPEN: u8 = 0;
const STATUS_LOCKED: u8 = 1;
const STATUS_RESOLVED: u8 = 2;
const STATUS_DISBURSED: u8 = 3;

// === Error Codes ===

const ENotAuthorized: u64 = 0;
const EVaultLocked: u64 = 1;
const EVaultNotResolved: u64 = 2;
const ENoDeposit: u64 = 3;
const EAlreadyResolved: u64 = 4;
const EVaultNotDisbursed: u64 = 5;
const ENotOpen: u64 = 6;
const EInsufficientBalance: u64 = 7;
const ENotParticipant: u64 = 8;
const ENftNotFound: u64 = 9;
const EZeroDeposit: u64 = 10;
const ESelfNotAllowed: u64 = 11;

const EDepositTooSmall: u64 = 12;
const ERevokedCap: u64 = 13;
const ERevokedParticipant: u64 = 14;
const EInvalidRecipient: u64 = 15;
const ESelfRevocation: u64 = 16;
const ENftTypeMismatch: u64 = 17;

/// Minimum deposit amount to prevent dust attacks
const MIN_DEPOSIT_AMOUNT: u64 = 1000; // Minimum 1000 units (adjust based on token decimals)

// === Events ===

public struct CoinDeposited has copy, drop {
    vault_id: ID,
    bet_id: ID,
    depositor: address,
    amount: u64,
    asset_type: String,
    new_total_balance: u64,
}

public struct NftDeposited has copy, drop {
    vault_id: ID,
    bet_id: ID,
    depositor: address,
    object_id: ID,
    asset_type: String,
}

public struct VaultLocked has copy, drop {
    vault_id: ID,
    bet_id: ID,
    locked_by: address,
    depositor_count: u64,
}



public struct VaultResolved has copy, drop {
    vault_id: ID,
    bet_id: ID,
    winner: address,
    resolved_by: address,
}

public struct VaultDisbursed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    disbursed_by: address,
    depositor_count: u64,
}

public struct CoinRefundClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    claimant: address,
    amount: u64,
    asset_type: String,
}

public struct NftRefundClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    claimant: address,
    object_id: ID,
    asset_type: String,
}

public struct CoinWithdrawn has copy, drop {
    vault_id: ID,
    bet_id: ID,
    depositor: address,
    amount: u64,
    asset_type: String,
}

public struct NftWithdrawn has copy, drop {
    vault_id: ID,
    bet_id: ID,
    depositor: address,
    object_id: ID,
    asset_type: String,
}

public struct CoinWinningsClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    winner: address,
    amount: u64,
    asset_type: String,
}

public struct NftWinningsClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    winner: address,
    object_id: ID,
    asset_type: String,
}

public struct VaultCapIssued has copy, drop {
    vault_id: ID,
    bet_id: ID,
    issued_to: address,
    issued_by: address,
}

public struct VaultCapRevoked has copy, drop {
    vault_id: ID,
    bet_id: ID,
    revoked_cap_id: ID,
    revoked_by: address,
}

public struct ParticipantRegistered has copy, drop {
    vault_id: ID,
    bet_id: ID,
    participant: address,
}

public struct ParticipantRemoved has copy, drop {
    vault_id: ID,
    bet_id: ID,
    participant: address,
}

// === Structs ===

public struct VaultCap has key, store {
    id: UID,
    vault_id: ID,
    issued_to: address,
}

public struct BalanceKey<phantom T> has copy, drop, store {}

/// Unified deposit entry for both coins and NFTs
public struct DepositEntry has store, copy, drop {
    depositor: address,
    asset_type: String,
    amount: u64,           // Coin amount (0 for NFTs)
    object_id: Option<ID>, // NFT object ID (none for coins)
}

public struct Vault has key {
    id: UID,
    bet_id: ID,
    /// Coin balances stored by type
    coin_assets: Bag,
    /// NFT objects stored by their ID
    nft_assets: ObjectBag,
    /// Simple vector-based deposit registry
    deposits: vector<DepositEntry>,
    /// Registry of valid depositors (bet participants)
    participants: Table<address, bool>,
    status: u8,
    winner: Option<address>,
    /// Track revoked VaultCap IDs
    revoked_caps: VecSet<ID>,
    /// Track revoked/soft-banned participants (cannot be winners)
    revoked_participants: VecSet<address>,
}

// === Public Functions ===

/// Create a new vault attached to a bet
public fun new(bet_id: ID, ctx: &mut TxContext): (Vault, VaultCap) {
    let vault = Vault {
        id: object::new(ctx),
        bet_id,
        coin_assets: bag::new(ctx),
        nft_assets: object_bag::new(ctx),
        deposits: vector::empty(),
        participants: table::new(ctx),
        status: STATUS_OPEN,
        winner: option::none(),
        revoked_caps: vec_set::empty(),
        revoked_participants: vec_set::empty(),
    };

    let cap = VaultCap {
        id: object::new(ctx),
        vault_id: object::id(&vault),
        issued_to: ctx.sender(), // Initial cap to creator
    };

    (vault, cap)
}

/// Set the Bet ID (called during initialization)
public(package) fun set_bet_id(self: &mut Vault, bet_id: ID) {
    self.bet_id = bet_id;
}

/// Register an address as a valid participant (called by bet module)
public(package) fun add_participant(self: &mut Vault, participant: address, _ctx: &mut TxContext) {
    if (!self.participants.contains(participant)) {
        self.participants.add(participant, true);
        
        event::emit(ParticipantRegistered {
            vault_id: object::id(self),
            bet_id: self.bet_id,
            participant,
        });
    };
}

/// Remove an address from valid participants (called by bet module)
/// SECURITY FIX: Emit event when participant is removed
public(package) fun remove_participant(self: &mut Vault, participant: address) {
    if (self.participants.contains(participant)) {
        self.participants.remove(participant);

        event::emit(ParticipantRemoved {
            vault_id: object::id(self),
            bet_id: self.bet_id,
            participant,
        });
    };
}

/// Revoke/soft-ban a participant (prevents them from being winner)
public(package) fun revoke_participant(self: &mut Vault, participant: address) {
    if (!self.revoked_participants.contains(&participant)) {
        self.revoked_participants.insert(participant);
    };
}

// === Coin Functions ===

/// Deposit coins into the vault (only registered participants can deposit)
/// SECURITY FIX: Enforce minimum deposit to prevent dust attacks
public fun deposit<T>(
    self: &mut Vault,
    coin: Coin<T>,
    ctx: &mut TxContext,
) {
    assert!(self.status == STATUS_OPEN, ENotOpen);

    let sender = ctx.sender();
    assert!(self.participants.contains(sender), ENotParticipant);

    let amount = coin.value();
    assert!(amount > 0, EZeroDeposit);
    // SECURITY FIX: Enforce minimum deposit amount to prevent dust attacks
    assert!(amount >= MIN_DEPOSIT_AMOUNT, EDepositTooSmall);
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();

    // Add to coin assets
    if (self.coin_assets.contains(BalanceKey<T> {})) {
        let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
        balance.join(coin.into_balance());
    } else {
        self.coin_assets.add(BalanceKey<T> {}, coin.into_balance());
    };

    // Check if this depositor already has an entry for this asset type
    let mut found = false;
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow_mut(i);
        if (entry.depositor == sender && entry.asset_type == asset_type && entry.object_id.is_none()) {
            entry.amount = entry.amount + amount;
            found = true;
            break
        };
        i = i + 1;
    };

    // If no existing entry, add a new one
    if (!found) {
        self.deposits.push_back(DepositEntry {
            depositor: sender,
            asset_type,
            amount,
            object_id: option::none(),
        });
    };

    let new_total: &Balance<T> = self.coin_assets.borrow(BalanceKey<T> {});

    event::emit(CoinDeposited {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        depositor: sender,
        amount,
        asset_type,
        new_total_balance: new_total.value(),
    });
}

/// Claim coin refund when vault is disbursed
/// SECURITY FIX: Collects ALL matching deposits to prevent double-claim exploits
public fun claim_refund<T>(
    self: &mut Vault,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(self.status == STATUS_DISBURSED, EVaultNotDisbursed);

    let sender = ctx.sender();
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;

    // SECURITY FIX: Find ALL matching deposit entries and collect total amount
    // This prevents double-claim if duplicate entries somehow exist
    let mut total_amount = 0u64;
    let mut indices_to_remove: vector<u64> = vector::empty();
    let mut i = 0;
    let len = self.deposits.length();

    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == sender && entry.asset_type == asset_type && entry.object_id.is_none()) {
            total_amount = total_amount + entry.amount;
            indices_to_remove.push_back(i);
        };
        i = i + 1;
    };

    assert!(indices_to_remove.length() > 0, ENoDeposit);
    // SECURITY FIX: Ensure we're not refunding zero
    assert!(total_amount > 0, EZeroDeposit);

    // Remove entries in reverse order to maintain valid indices
    let mut j = indices_to_remove.length();
    while (j > 0) {
        j = j - 1;
        let idx = *indices_to_remove.borrow(j);
        self.deposits.swap_remove(idx);
    };

    let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
    assert!(balance.value() >= total_amount, EInsufficientBalance);

    event::emit(CoinRefundClaimed {
        vault_id,
        bet_id,
        claimant: sender,
        amount: total_amount,
        asset_type,
    });

    coin::from_balance(balance.split(total_amount), ctx)
}

/// Withdraw coin deposit when vault is open (for participants leaving the bet early)
/// SECURITY FIX: Collects ALL matching deposits to prevent double-withdraw exploits
public(package) fun withdraw_deposit<T>(
    self: &mut Vault,
    depositor: address,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(self.status == STATUS_OPEN, ENotOpen);

    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;

    // SECURITY FIX: Find ALL matching deposit entries and collect total amount
    // This prevents double-withdraw if duplicate entries somehow exist
    let mut total_amount = 0u64;
    let mut indices_to_remove: vector<u64> = vector::empty();
    let mut i = 0;
    let len = self.deposits.length();

    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == depositor && entry.asset_type == asset_type && entry.object_id.is_none()) {
            total_amount = total_amount + entry.amount;
            indices_to_remove.push_back(i);
        };
        i = i + 1;
    };

    assert!(indices_to_remove.length() > 0, ENoDeposit);
    // SECURITY FIX: Ensure we're not withdrawing zero
    assert!(total_amount > 0, EZeroDeposit);

    // Remove entries in reverse order to maintain valid indices
    let mut j = indices_to_remove.length();
    while (j > 0) {
        j = j - 1;
        let idx = *indices_to_remove.borrow(j);
        self.deposits.swap_remove(idx);
    };

    let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
    assert!(balance.value() >= total_amount, EInsufficientBalance);

    event::emit(CoinWithdrawn {
        vault_id,
        bet_id,
        depositor,
        amount: total_amount,
        asset_type,
    });

    coin::from_balance(balance.split(total_amount), ctx)
}

/// Claim coin winnings when vault is resolved (winner takes all of a type)
public fun claim_winnings<T>(
    self: &mut Vault,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(self.status == STATUS_RESOLVED, EVaultNotResolved);
    assert!(self.winner.is_some(), EVaultNotResolved);
    assert!(ctx.sender() == *self.winner.borrow(), ENotAuthorized);

    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;
    let winner = ctx.sender();

    let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
    let amount = balance.value();

    event::emit(CoinWinningsClaimed {
        vault_id,
        bet_id,
        winner,
        amount,
        asset_type,
    });

    coin::from_balance(balance.split(amount), ctx)
}

// === NFT Functions ===

/// Deposit an NFT into the vault (only registered participants can deposit)
public fun deposit_nft<T: key + store>(
    self: &mut Vault,
    nft: T,
    ctx: &mut TxContext,
) {
    assert!(self.status == STATUS_OPEN, ENotOpen);
    
    let sender = ctx.sender();
    assert!(self.participants.contains(sender), ENotParticipant);

    let object_id = object::id(&nft);
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();

    // Store the NFT in the ObjectBag
    self.nft_assets.add(object_id, nft);

    // Add deposit entry
    self.deposits.push_back(DepositEntry {
        depositor: sender,
        asset_type,
        amount: 0,
        object_id: option::some(object_id),
    });

    event::emit(NftDeposited {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        depositor: sender,
        object_id,
        asset_type,
    });
}

/// Claim NFT refund when vault is disbursed
/// SECURITY FIX: Verify NFT type matches the deposited type
public fun claim_nft_refund<T: key + store>(
    self: &mut Vault,
    object_id: ID,
    ctx: &mut TxContext,
): T {
    assert!(self.status == STATUS_DISBURSED, EVaultNotDisbursed);

    let sender = ctx.sender();
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;

    // Find and verify the deposit entry belongs to sender
    let mut found_idx: Option<u64> = option::none();
    let mut i = 0;
    let len = self.deposits.length();

    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == sender &&
            entry.object_id.is_some() &&
            *entry.object_id.borrow() == object_id) {
            // SECURITY FIX: Verify the type matches what was deposited
            assert!(entry.asset_type == asset_type, ENftTypeMismatch);
            found_idx = option::some(i);
            break
        };
        i = i + 1;
    };

    assert!(found_idx.is_some(), ENoDeposit);
    self.deposits.swap_remove(*found_idx.borrow());

    // Remove NFT from storage
    assert!(self.nft_assets.contains(object_id), ENftNotFound);
    let nft: T = self.nft_assets.remove(object_id);

    event::emit(NftRefundClaimed {
        vault_id,
        bet_id,
        claimant: sender,
        object_id,
        asset_type,
    });

    nft
}

/// Withdraw NFT deposit when vault is open (for participants leaving the bet early)
/// SECURITY FIX: Verify NFT type matches the deposited type
public(package) fun withdraw_nft<T: key + store>(
    self: &mut Vault,
    depositor: address,
    object_id: ID,
    _ctx: &mut TxContext,
): T {
    assert!(self.status == STATUS_OPEN, ENotOpen);

    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;

    // Find and verify the deposit entry belongs to depositor
    let mut found_idx: Option<u64> = option::none();
    let mut i = 0;
    let len = self.deposits.length();

    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == depositor &&
            entry.object_id.is_some() &&
            *entry.object_id.borrow() == object_id) {
            // SECURITY FIX: Verify the type matches what was deposited
            assert!(entry.asset_type == asset_type, ENftTypeMismatch);
            found_idx = option::some(i);
            break
        };
        i = i + 1;
    };

    assert!(found_idx.is_some(), ENoDeposit);
    self.deposits.swap_remove(*found_idx.borrow());

    // Remove NFT from storage
    assert!(self.nft_assets.contains(object_id), ENftNotFound);
    let nft: T = self.nft_assets.remove(object_id);

    event::emit(NftWithdrawn {
        vault_id,
        bet_id,
        depositor,
        object_id,
        asset_type,
    });

    nft
}

/// Claim NFT winnings when vault is resolved (winner claims specific NFT)
/// SECURITY: Winner can only claim NFTs that were deposited in this vault
/// The deposit entry must exist to prove the NFT was part of the bet
/// SECURITY FIX: Verify NFT type matches the deposited type
public fun claim_nft_winnings<T: key + store>(
    self: &mut Vault,
    object_id: ID,
    ctx: &mut TxContext,
): T {
    assert!(self.status == STATUS_RESOLVED, EVaultNotResolved);
    assert!(self.winner.is_some(), EVaultNotResolved);
    assert!(ctx.sender() == *self.winner.borrow(), ENotAuthorized);

    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let vault_id = object::id(self);
    let bet_id = self.bet_id;
    let winner = ctx.sender();

    // SECURITY FIX: Verify the NFT has a valid deposit entry before allowing claim
    // This ensures only NFTs that were actually deposited can be claimed
    let mut found_idx: Option<u64> = option::none();
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.object_id.is_some() && *entry.object_id.borrow() == object_id) {
            // SECURITY FIX: Verify the type matches what was deposited
            assert!(entry.asset_type == asset_type, ENftTypeMismatch);
            found_idx = option::some(i);
            break
        };
        i = i + 1;
    };

    // Must have a deposit entry - this proves the NFT was legitimately deposited
    assert!(found_idx.is_some(), ENoDeposit);

    // Remove the deposit entry
    self.deposits.swap_remove(*found_idx.borrow());

    // Remove NFT from storage
    assert!(self.nft_assets.contains(object_id), ENftNotFound);
    let nft: T = self.nft_assets.remove(object_id);

    event::emit(NftWinningsClaimed {
        vault_id,
        bet_id,
        winner,
        object_id,
        asset_type,
    });

    nft
}

// === Vault Management ===

/// Lock the vault
public fun lock(self: &mut Vault, cap: &VaultCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(!self.revoked_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EVaultLocked);
    self.status = STATUS_LOCKED;
    event::emit(VaultLocked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        locked_by: ctx.sender(),
        depositor_count: self.depositor_count(),
    });
}



/// Set vault as resolved with a winner (must be a registered participant and not revoked)
public fun set_resolved(self: &mut Vault, cap: &VaultCap, winner: address, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(!self.revoked_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status != STATUS_RESOLVED && self.status != STATUS_DISBURSED, EAlreadyResolved);
    assert!(self.participants.contains(winner), ENotParticipant);
    // SECURITY FIX: Ensure winner is not a revoked/soft-banned participant
    assert!(!self.revoked_participants.contains(&winner), ERevokedParticipant);
    self.status = STATUS_RESOLVED;
    self.winner = option::some(winner);
    event::emit(VaultResolved {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        winner,
        resolved_by: ctx.sender(),
    });
}

/// Set vault as disbursed (refund mode)
public fun set_disbursed(self: &mut Vault, cap: &VaultCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(!self.revoked_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status != STATUS_RESOLVED && self.status != STATUS_DISBURSED, EAlreadyResolved);
    self.status = STATUS_DISBURSED;
    event::emit(VaultDisbursed {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        disbursed_by: ctx.sender(),
        depositor_count: self.depositor_count(),
    });
}

/// Create a new VaultCap for delegation (only to participants, cannot issue to self)
/// SECURITY FIX: Validate recipient is not zero address and strengthen self-issuance check
public fun issue_cap(self: &Vault, cap: &VaultCap, recipient: address, ctx: &mut TxContext): VaultCap {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(!self.revoked_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    // SECURITY FIX: Validate recipient is not zero address
    assert!(recipient != @0x0, EInvalidRecipient);
    // SECURITY FIX: Prevent issuing to self (both sender and cap holder)
    assert!(recipient != ctx.sender(), ESelfNotAllowed);
    assert!(recipient != cap.issued_to, ESelfNotAllowed);
    assert!(self.participants.contains(recipient), ENotParticipant);
    // SECURITY FIX: Ensure recipient is not revoked
    assert!(!self.revoked_participants.contains(&recipient), ERevokedParticipant);
    event::emit(VaultCapIssued {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        issued_to: recipient,
        issued_by: ctx.sender(),
    });
    VaultCap {
        id: object::new(ctx),
        vault_id: object::id(self),
        issued_to: recipient,
    }
}

/// Revoke a VaultCap
/// SECURITY FIX: Prevent self-revocation
public fun revoke_cap(self: &mut Vault, cap: &VaultCap, cap_to_revoke: ID, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(!self.revoked_caps.contains(&object::id(cap)), ERevokedCap);
    // SECURITY FIX: Prevent revoking your own capability
    assert!(object::id(cap) != cap_to_revoke, ESelfRevocation);

    if (!self.revoked_caps.contains(&cap_to_revoke)) {
        self.revoked_caps.insert(cap_to_revoke);
    };

    event::emit(VaultCapRevoked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        revoked_cap_id: cap_to_revoke,
        revoked_by: ctx.sender(),
    });
}


// === Getters ===

public fun status(self: &Vault): u8 { self.status }
public fun is_open(self: &Vault): bool { self.status == STATUS_OPEN }
public fun is_locked(self: &Vault): bool { self.status == STATUS_LOCKED }
public fun is_resolved(self: &Vault): bool { self.status == STATUS_RESOLVED }
public fun is_disbursed(self: &Vault): bool { self.status == STATUS_DISBURSED }
public fun winner(self: &Vault): Option<address> { self.winner }
public fun bet_id(self: &Vault): ID { self.bet_id }
public fun id(self: &Vault): ID { object::id(self) }

public fun balance<T>(self: &Vault): u64 {
    if (self.coin_assets.contains(BalanceKey<T> {})) {
        let bal: &Balance<T> = self.coin_assets.borrow(BalanceKey<T> {});
        bal.value()
    } else {
        0
    }
}

public fun has_coin_deposit<T>(self: &Vault, addr: address): bool {
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == addr && entry.asset_type == asset_type && entry.object_id.is_none()) {
            return true
        };
        i = i + 1;
    };
    false
}

public fun coin_deposit_amount<T>(self: &Vault, addr: address): u64 {
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == addr && entry.asset_type == asset_type && entry.object_id.is_none()) {
            return entry.amount
        };
        i = i + 1;
    };
    0
}

public fun has_nft_deposit(self: &Vault, addr: address, object_id: ID): bool {
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == addr && 
            entry.object_id.is_some() && 
            *entry.object_id.borrow() == object_id) {
            return true
        };
        i = i + 1;
    };
    false
}

/// Get total count of unique depositors
public fun depositor_count(self: &Vault): u64 {
    let mut depositors: vector<address> = vector::empty();
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (!depositors.contains(&entry.depositor)) {
            depositors.push_back(entry.depositor);
        };
        i = i + 1;
    };
    depositors.length()
}

/// Get all deposits for an address
public fun get_deposits(self: &Vault, addr: address): vector<DepositEntry> {
    let mut result: vector<DepositEntry> = vector::empty();
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == addr) {
            result.push_back(*entry);
        };
        i = i + 1;
    };
    result
}

/// Get total count of deposits for a specific user
public fun deposit_count_for_user(self: &Vault, user: address): u64 {
    let mut count = 0;
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == user) {
            count = count + 1;
        };
        i = i + 1;
    };
    count
}

public fun deposit_count(self: &Vault): u64 {
    self.deposits.length()
}

public fun cap_vault_id(cap: &VaultCap): ID { cap.vault_id }
public fun cap_issued_to(cap: &VaultCap): address { cap.issued_to }
public fun is_participant(self: &Vault, addr: address): bool { self.participants.contains(addr) }
public fun has_nft(self: &Vault, object_id: ID): bool { self.nft_assets.contains(object_id) }
public fun is_cap_revoked(self: &Vault, cap_id: ID): bool { self.revoked_caps.contains(&cap_id) }
public fun is_participant_revoked(self: &Vault, addr: address): bool { self.revoked_participants.contains(&addr) }

// === Share Function ===

/// Convert a Vault into a shared object
public fun share(vault: Vault) {
    transfer::share_object(vault);
}

// === Status Constants ===

public fun status_open(): u8 { STATUS_OPEN }
public fun status_locked(): u8 { STATUS_LOCKED }
public fun status_resolved(): u8 { STATUS_RESOLVED }
public fun status_disbursed(): u8 { STATUS_DISBURSED }
