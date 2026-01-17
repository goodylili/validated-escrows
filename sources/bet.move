/// Bet module for creating and managing peer-to-peer bets.
module terminal::bet;

use std::string::String;
use sui::event;
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

// === Constants ===

const STATUS_OPEN: u8 = 0;
const STATUS_LOCKED: u8 = 1;
const STATUS_RESOLVED: u8 = 2;
const STATUS_DISSOLVED: u8 = 3;

// === Error Codes ===

const EInvalidCap: u64 = 0;
const EBetLocked: u64 = 1;
const EBetNotOpen: u64 = 2;
const ENotParticipant: u64 = 3;
const EAlreadyJoined: u64 = 4;
const EBetExpired: u64 = 5;
const ENotAllowed: u64 = 6;
const EAlreadyResolved: u64 = 7;
const ECannotLeave: u64 = 8;
const ESelfNotAllowed: u64 = 9;

// === Events ===

public struct BetCreated has copy, drop {
    bet_id: ID,
    creator: address,
    terms: String,
    expiry: u64,
    open_to_all: bool,
    vault_id: ID,
    poll_id: ID,
}

public struct ParticipantJoined has copy, drop {
    bet_id: ID,
    participant: address,
    participant_count: u64,
}

public struct ParticipantLeft has copy, drop {
    bet_id: ID,
    participant: address,
    participant_count: u64,
}

public struct BetLocked has copy, drop {
    bet_id: ID,
    locked_by: address,
    participant_count: u64,
}

public struct BetUnlocked has copy, drop {
    bet_id: ID,
    unlocked_by: address,
}

public struct BetResolved has copy, drop {
    bet_id: ID,
    winner: address,
    resolved_by: address,
}

public struct BetDissolved has copy, drop {
    bet_id: ID,
    dissolved_by: address,
    participant_count: u64,
}

public struct BetMetadataUpdated has copy, drop {
    bet_id: ID,
    updated_by: address,
    field: String,
}

public struct CreatorCapIssued has copy, drop {
    bet_id: ID,
    issued_to: address,
    issued_by: address,
}

// === Structs ===

public struct CreatorCap has key, store {
    id: UID,
    bet_id: ID,
}

public struct ParticipantCap has key, store {
    id: UID,
    bet_id: ID,
    participant: address,
}

public struct Bet has key {
    id: UID,
    terms: String,
    references: vector<String>,
    multimedia_url: Option<String>,
    expiry: u64,
    creator: address,
    status: u8,
    open_to_all: bool,
    allowed: VecSet<address>,
    participants: Table<address, u64>,
    participant_count: u64,
    vault_id: ID,
    poll_id: ID,
    winner: Option<address>,
}

// === Public Functions ===

/// Create a new bet
public fun new(
    terms: String,
    expiry: u64,
    open_to_all: bool,
    vault_id: ID,
    poll_id: ID,
    ctx: &mut TxContext,
): (Bet, CreatorCap) {
    let creator = ctx.sender();

    let bet = Bet {
        id: object::new(ctx),
        terms,
        references: vector::empty(),
        multimedia_url: option::none(),
        expiry,
        creator,
        status: STATUS_OPEN,
        open_to_all,
        allowed: vec_set::empty(),
        participants: table::new(ctx),
        participant_count: 0,
        vault_id,
        poll_id,
        winner: option::none(),
    };

    let cap = CreatorCap {
        id: object::new(ctx),
        bet_id: object::id(&bet),
    };

    event::emit(BetCreated {
        bet_id: object::id(&bet),
        creator,
        terms: bet.terms,
        expiry,
        open_to_all,
        vault_id,
        poll_id,
    });

    (bet, cap)
}

/// Join a bet - requires vault to be passed for participant registration
public fun join(self: &mut Bet, ctx: &mut TxContext): ParticipantCap {
    let sender = ctx.sender();
    let now = ctx.epoch_timestamp_ms();

    assert!(self.status == STATUS_OPEN, EBetNotOpen);
    assert!(now < self.expiry, EBetExpired);
    assert!(!self.participants.contains(sender), EAlreadyJoined);

    if (!self.open_to_all) {
        assert!(self.allowed.contains(&sender), ENotAllowed);
    };

    self.participants.add(sender, now);
    self.participant_count = self.participant_count + 1;

    event::emit(ParticipantJoined {
        bet_id: object::id(self),
        participant: sender,
        participant_count: self.participant_count,
    });

    ParticipantCap {
        id: object::new(ctx),
        bet_id: object::id(self),
        participant: sender,
    }
}

/// Get participant address for vault registration
public fun get_participant_address(cap: &ParticipantCap): address {
    cap.participant
}

/// Leave a bet (only when open)
public fun leave(self: &mut Bet, cap: ParticipantCap, ctx: &TxContext) {
    let ParticipantCap { id, bet_id, participant } = cap;

    assert!(bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, ECannotLeave);
    assert!(self.participants.contains(participant), ENotParticipant);

    self.participants.remove(participant);
    self.participant_count = self.participant_count - 1;

    event::emit(ParticipantLeft {
        bet_id: object::id(self),
        participant,
        participant_count: self.participant_count,
    });

    id.delete();
    let _ = ctx;
}

/// Lock the bet
public fun lock(self: &mut Bet, cap: &CreatorCap, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    self.status = STATUS_LOCKED;

    event::emit(BetLocked {
        bet_id: object::id(self),
        locked_by: ctx.sender(),
        participant_count: self.participant_count,
    });
}

/// Unlock the bet
public fun unlock(self: &mut Bet, cap: &CreatorCap, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_LOCKED, EBetNotOpen);

    self.status = STATUS_OPEN;

    event::emit(BetUnlocked {
        bet_id: object::id(self),
        unlocked_by: ctx.sender(),
    });
}

/// Resolve the bet with a winner (called internally)
public(package) fun resolve(self: &mut Bet, winner: address, ctx: &TxContext) {
    assert!(self.status == STATUS_LOCKED, EBetNotOpen);
    assert!(self.participants.contains(winner), ENotParticipant);

    self.status = STATUS_RESOLVED;
    self.winner = option::some(winner);

    event::emit(BetResolved {
        bet_id: object::id(self),
        winner,
        resolved_by: ctx.sender(),
    });
}

/// Dissolve the bet (refund mode)
public fun dissolve(self: &mut Bet, cap: &CreatorCap, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status != STATUS_RESOLVED && self.status != STATUS_DISSOLVED, EAlreadyResolved);

    self.status = STATUS_DISSOLVED;

    event::emit(BetDissolved {
        bet_id: object::id(self),
        dissolved_by: ctx.sender(),
        participant_count: self.participant_count,
    });
}

/// Add address to allowed list
public fun add_allowed(self: &mut Bet, cap: &CreatorCap, addr: address, _ctx: &mut TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    if (!self.allowed.contains(&addr)) {
        self.allowed.insert(addr);
    };
}

/// Remove address from allowed list
public fun remove_allowed(self: &mut Bet, cap: &CreatorCap, addr: address, _ctx: &mut TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    if (self.allowed.contains(&addr)) {
        self.allowed.remove(&addr);
    };
}

/// Update bet terms
public fun edit_terms(self: &mut Bet, cap: &CreatorCap, terms: String, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    self.terms = terms;

    event::emit(BetMetadataUpdated {
        bet_id: object::id(self),
        updated_by: ctx.sender(),
        field: b"terms".to_string(),
    });
}

/// Add a reference URL
public fun add_reference(self: &mut Bet, cap: &CreatorCap, reference: String, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    self.references.push_back(reference);

    event::emit(BetMetadataUpdated {
        bet_id: object::id(self),
        updated_by: ctx.sender(),
        field: b"references".to_string(),
    });
}

/// Set multimedia URL
public fun set_multimedia(self: &mut Bet, cap: &CreatorCap, url: String, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);

    self.multimedia_url = option::some(url);

    event::emit(BetMetadataUpdated {
        bet_id: object::id(self),
        updated_by: ctx.sender(),
        field: b"multimedia_url".to_string(),
    });
}

/// Issue another CreatorCap
public fun issue_creator_cap(self: &Bet, cap: &CreatorCap, recipient: address, ctx: &mut TxContext): CreatorCap {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(recipient != ctx.sender(), ESelfNotAllowed);

    event::emit(CreatorCapIssued {
        bet_id: object::id(self),
        issued_to: recipient,
        issued_by: ctx.sender(),
    });

    CreatorCap {
        id: object::new(ctx),
        bet_id: object::id(self),
    }
}

// === Getters ===

public fun id(self: &Bet): ID { object::id(self) }
public fun status(self: &Bet): u8 { self.status }
public fun terms(self: &Bet): String { self.terms }
public fun references(self: &Bet): vector<String> { self.references }
public fun multimedia_url(self: &Bet): Option<String> { self.multimedia_url }
public fun expiry(self: &Bet): u64 { self.expiry }
public fun creator(self: &Bet): address { self.creator }
public fun is_open_to_all(self: &Bet): bool { self.open_to_all }
public fun is_participant(self: &Bet, addr: address): bool { self.participants.contains(addr) }
public fun participant_count(self: &Bet): u64 { self.participant_count }
public fun vault_id(self: &Bet): ID { self.vault_id }
public fun poll_id(self: &Bet): ID { self.poll_id }
public fun winner(self: &Bet): Option<address> { self.winner }
public fun is_open(self: &Bet): bool { self.status == STATUS_OPEN }
public fun is_locked(self: &Bet): bool { self.status == STATUS_LOCKED }
public fun is_resolved(self: &Bet): bool { self.status == STATUS_RESOLVED }
public fun is_dissolved(self: &Bet): bool { self.status == STATUS_DISSOLVED }
public fun is_expired(self: &Bet, ctx: &TxContext): bool { ctx.epoch_timestamp_ms() >= self.expiry }
public fun cap_bet_id(cap: &CreatorCap): ID { cap.bet_id }
public fun participant_cap_bet_id(cap: &ParticipantCap): ID { cap.bet_id }
public fun participant_cap_participant(cap: &ParticipantCap): address { cap.participant }

// === Status Constants ===

public fun status_open(): u8 { STATUS_OPEN }
public fun status_locked(): u8 { STATUS_LOCKED }
public fun status_resolved(): u8 { STATUS_RESOLVED }
public fun status_dissolved(): u8 { STATUS_DISSOLVED }
