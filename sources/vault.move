/// Vault module for heterogeneous asset storage with deposit tracking.
/// Supports both coins and NFTs with a simplified vector-based registry.
module terminal::vault;

use std::string::String;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::event;
use sui::object_bag::{Self, ObjectBag};
use sui::table::{Self, Table};

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
const ENotLocked: u64 = 12;

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

public struct VaultUnlocked has copy, drop {
    vault_id: ID,
    bet_id: ID,
    unlocked_by: address,
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

public struct ParticipantRegistered has copy, drop {
    vault_id: ID,
    bet_id: ID,
    participant: address,
}

// === Structs ===

public struct VaultCap has key, store {
    id: UID,
    vault_id: ID,
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
    };

    let cap = VaultCap {
        id: object::new(ctx),
        vault_id: object::id(&vault),
    };

    (vault, cap)
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
public(package) fun remove_participant(self: &mut Vault, participant: address) {
    if (self.participants.contains(participant)) {
        self.participants.remove(participant);
    };
}

// === Coin Functions ===

/// Deposit coins into the vault (only registered participants can deposit)
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

    // Find and remove the deposit entry
    let mut amount = 0u64;
    let mut found_idx: Option<u64> = option::none();
    let mut i = 0;
    let len = self.deposits.length();
    
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == sender && entry.asset_type == asset_type && entry.object_id.is_none()) {
            amount = entry.amount;
            found_idx = option::some(i);
            break
        };
        i = i + 1;
    };

    assert!(found_idx.is_some(), ENoDeposit);
    self.deposits.swap_remove(*found_idx.borrow());

    let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
    assert!(balance.value() >= amount, EInsufficientBalance);

    event::emit(CoinRefundClaimed {
        vault_id,
        bet_id,
        claimant: sender,
        amount,
        asset_type,
    });

    coin::from_balance(balance.split(amount), ctx)
}

/// Withdraw coin deposit when vault is open (for participants leaving the bet early)
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

    // Find and remove the deposit entry
    let mut amount = 0u64;
    let mut found_idx: Option<u64> = option::none();
    let mut i = 0;
    let len = self.deposits.length();
    
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.depositor == depositor && entry.asset_type == asset_type && entry.object_id.is_none()) {
            amount = entry.amount;
            found_idx = option::some(i);
            break
        };
        i = i + 1;
    };

    assert!(found_idx.is_some(), ENoDeposit);
    self.deposits.swap_remove(*found_idx.borrow());

    let balance: &mut Balance<T> = self.coin_assets.borrow_mut(BalanceKey<T> {});
    assert!(balance.value() >= amount, EInsufficientBalance);

    event::emit(CoinWithdrawn {
        vault_id,
        bet_id,
        depositor,
        amount,
        asset_type,
    });

    coin::from_balance(balance.split(amount), ctx)
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

    // Remove NFT from storage (winner can claim any NFT)
    assert!(self.nft_assets.contains(object_id), ENftNotFound);
    let nft: T = self.nft_assets.remove(object_id);

    // Remove the deposit entry for this NFT
    let mut i = 0;
    let len = self.deposits.length();
    while (i < len) {
        let entry = self.deposits.borrow(i);
        if (entry.object_id.is_some() && *entry.object_id.borrow() == object_id) {
            self.deposits.swap_remove(i);
            break
        };
        i = i + 1;
    };

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
    assert!(self.status == STATUS_OPEN, EVaultLocked);
    self.status = STATUS_LOCKED;
    event::emit(VaultLocked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        locked_by: ctx.sender(),
        depositor_count: self.depositor_count(),
    });
}

/// Unlock the vault
public fun unlock(self: &mut Vault, cap: &VaultCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(self.status == STATUS_LOCKED, ENotLocked);
    self.status = STATUS_OPEN;
    event::emit(VaultUnlocked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        unlocked_by: ctx.sender(),
    });
}

/// Set vault as resolved with a winner (must be a registered participant)
public fun set_resolved(self: &mut Vault, cap: &VaultCap, winner: address, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(self.status != STATUS_RESOLVED && self.status != STATUS_DISBURSED, EAlreadyResolved);
    assert!(self.participants.contains(winner), ENotParticipant);
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
public fun issue_cap(self: &Vault, cap: &VaultCap, recipient: address, ctx: &mut TxContext): VaultCap {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(recipient != ctx.sender(), ESelfNotAllowed);
    assert!(self.participants.contains(recipient), ENotParticipant);
    event::emit(VaultCapIssued {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        issued_to: recipient,
        issued_by: ctx.sender(),
    });
    VaultCap {
        id: object::new(ctx),
        vault_id: object::id(self),
    }
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

/// Get total deposit count
public fun deposit_count(self: &Vault): u64 {
    self.deposits.length()
}

public fun cap_vault_id(cap: &VaultCap): ID { cap.vault_id }
public fun is_participant(self: &Vault, addr: address): bool { self.participants.contains(addr) }
public fun has_nft(self: &Vault, object_id: ID): bool { self.nft_assets.contains(object_id) }

// === Status Constants ===

public fun status_open(): u8 { STATUS_OPEN }
public fun status_locked(): u8 { STATUS_LOCKED }
public fun status_resolved(): u8 { STATUS_RESOLVED }
public fun status_disbursed(): u8 { STATUS_DISBURSED }
