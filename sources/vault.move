/// Vault module for heterogeneous asset storage with deposit tracking.
module terminal::vault;

use std::string::String;
use sui::bag::{Self, Bag};
use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::event;
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

// === Events ===

public struct Deposited has copy, drop {
    vault_id: ID,
    bet_id: ID,
    depositor: address,
    amount: u64,
    asset_type: String,
    new_total_balance: u64,
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

public struct RefundClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    claimant: address,
    amount: u64,
    asset_type: String,
}

public struct WinningsClaimed has copy, drop {
    vault_id: ID,
    bet_id: ID,
    winner: address,
    amount: u64,
    asset_type: String,
}

public struct VaultCapIssued has copy, drop {
    vault_id: ID,
    bet_id: ID,
    issued_to: address,
    issued_by: address,
}

// === Structs ===

public struct VaultCap has key, store {
    id: UID,
    vault_id: ID,
}

public struct BalanceKey<phantom T> has copy, drop, store {}

public struct DepositRecord has store, copy, drop {
    amount: u64,
}

public struct Vault has key {
    id: UID,
    bet_id: ID,
    assets: Bag,
    deposits: Table<address, Table<String, DepositRecord>>,
    /// Registry of valid depositors (bet participants)
    participants: Table<address, bool>,
    status: u8,
    winner: Option<address>,
    depositor_count: u64,
}

// === Public Functions ===

/// Create a new vault attached to a bet
public fun new(bet_id: ID, ctx: &mut TxContext): (Vault, VaultCap) {
    let vault = Vault {
        id: object::new(ctx),
        bet_id,
        assets: bag::new(ctx),
        deposits: table::new(ctx),
        participants: table::new(ctx),
        status: STATUS_OPEN,
        winner: option::none(),
        depositor_count: 0,
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
    };
}

/// Remove an address from valid participants (called by bet module)
public(package) fun remove_participant(self: &mut Vault, participant: address) {
    if (self.participants.contains(participant)) {
        self.participants.remove(participant);
    };
}

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
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();

    if (self.assets.contains(BalanceKey<T> {})) {
        let balance: &mut Balance<T> = self.assets.borrow_mut(BalanceKey<T> {});
        balance.join(coin.into_balance());
    } else {
        self.assets.add(BalanceKey<T> {}, coin.into_balance());
    };

    if (!self.deposits.contains(sender)) {
        self.deposits.add(sender, table::new(ctx));
        self.depositor_count = self.depositor_count + 1;
    };

    let sender_deposits = self.deposits.borrow_mut(sender);
    if (sender_deposits.contains(asset_type)) {
        let record = sender_deposits.borrow_mut(asset_type);
        record.amount = record.amount + amount;
    } else {
        sender_deposits.add(asset_type, DepositRecord { amount });
    };

    let new_total: &Balance<T> = self.assets.borrow(BalanceKey<T> {});

    event::emit(Deposited {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        depositor: sender,
        amount,
        asset_type,
        new_total_balance: new_total.value(),
    });
}

/// Claim refund when vault is disbursed
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

    assert!(self.deposits.contains(sender), ENoDeposit);
    let sender_deposits = self.deposits.borrow_mut(sender);
    assert!(sender_deposits.contains(asset_type), ENoDeposit);

    let record = sender_deposits.remove(asset_type);
    let amount = record.amount;

    let balance: &mut Balance<T> = self.assets.borrow_mut(BalanceKey<T> {});
    assert!(balance.value() >= amount, EInsufficientBalance);

    event::emit(RefundClaimed {
        vault_id,
        bet_id,
        claimant: sender,
        amount,
        asset_type,
    });

    coin::from_balance(balance.split(amount), ctx)
}

/// Claim winnings when vault is resolved (winner takes all of a type)
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

    let balance: &mut Balance<T> = self.assets.borrow_mut(BalanceKey<T> {});
    let amount = balance.value();

    event::emit(WinningsClaimed {
        vault_id,
        bet_id,
        winner,
        amount,
        asset_type,
    });

    coin::from_balance(balance.split(amount), ctx)
}

/// Lock the vault
public fun lock(self: &mut Vault, cap: &VaultCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(self.status == STATUS_OPEN, EVaultLocked);
    self.status = STATUS_LOCKED;
    event::emit(VaultLocked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        locked_by: ctx.sender(),
        depositor_count: self.depositor_count,
    });
}

/// Unlock the vault
public fun unlock(self: &mut Vault, cap: &VaultCap, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(self.status == STATUS_LOCKED, ENotOpen);
    self.status = STATUS_OPEN;
    event::emit(VaultUnlocked {
        vault_id: object::id(self),
        bet_id: self.bet_id,
        unlocked_by: ctx.sender(),
    });
}

/// Set vault as resolved with a winner
public fun set_resolved(self: &mut Vault, cap: &VaultCap, winner: address, ctx: &TxContext) {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
    assert!(self.status != STATUS_RESOLVED && self.status != STATUS_DISBURSED, EAlreadyResolved);
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
        depositor_count: self.depositor_count,
    });
}

/// Create a new VaultCap for delegation
public fun issue_cap(self: &Vault, cap: &VaultCap, recipient: address, ctx: &mut TxContext): VaultCap {
    assert!(cap.vault_id == object::id(self), ENotAuthorized);
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
    if (self.assets.contains(BalanceKey<T> {})) {
        let bal: &Balance<T> = self.assets.borrow(BalanceKey<T> {});
        bal.value()
    } else {
        0
    }
}

public fun has_deposit<T>(self: &Vault, addr: address): bool {
    if (!self.deposits.contains(addr)) { return false };
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    self.deposits.borrow(addr).contains(asset_type)
}

public fun deposit_amount<T>(self: &Vault, addr: address): u64 {
    if (!self.deposits.contains(addr)) { return 0 };
    let type_name = std::type_name::into_string(std::type_name::with_original_ids<T>());
    let asset_type = type_name.to_string();
    let sender_deposits = self.deposits.borrow(addr);
    if (!sender_deposits.contains(asset_type)) { return 0 };
    sender_deposits.borrow(asset_type).amount
}

public fun depositor_count(self: &Vault): u64 { self.depositor_count }
public fun cap_vault_id(cap: &VaultCap): ID { cap.vault_id }
public fun is_participant(self: &Vault, addr: address): bool { self.participants.contains(addr) }

// === Status Constants ===

public fun status_open(): u8 { STATUS_OPEN }
public fun status_locked(): u8 { STATUS_LOCKED }
public fun status_resolved(): u8 { STATUS_RESOLVED }
public fun status_disbursed(): u8 { STATUS_DISBURSED }
