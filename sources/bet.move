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

/// Minimum time before expiry (1 hour in milliseconds)
const MIN_EXPIRY_DURATION_MS: u64 = 3600000;

// === Error Codes ===

const EInvalidCap: u64 = 0;
const EBetLocked: u64 = 1;
const EBetNotOpen: u64 = 2;
const ENotParticipant: u64 = 3;
const EAlreadyJoined: u64 = 4;
const EBetExpired: u64 = 5;
const ENotAllowed: u64 = 6;
const ECannotLeave: u64 = 8;
const ESelfNotAllowed: u64 = 9;
const EInsufficientParticipants: u64 = 10;
const EExpiryInPast: u64 = 11;
const EExpiryTooSoon: u64 = 12;
const ERevokedCap: u64 = 13;
const ESelfRevocation: u64 = 14;
const ETooManyReferences: u64 = 15;

/// Maximum number of references allowed
const MAX_REFERENCES: u64 = 20;

// === Events ===

public struct BetCreated has copy, drop {
    bet_id: ID,
    creator: address,
    terms: String,
    expiry: u64,
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

public struct CreatorCapRevoked has copy, drop {
    bet_id: ID,
    revoked_cap_id: ID,
    revoked_by: address,
}

public struct ParticipantCapRevoked has copy, drop {
    bet_id: ID,
    participant: address,
    revoked_by: address,
}

// === Structs ===

public struct CreatorCap has key, store {
    id: UID,
    bet_id: ID,
    issued_to: address,
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
    allowed: VecSet<address>,
    participants: Table<address, u64>,
    participant_count: u64,
    vault_id: ID,
    poll_id: ID,
    winner: Option<address>,
    revoked_creator_caps: VecSet<ID>,
    revoked_participants: VecSet<address>,
    /// Track revoked ParticipantCap IDs to prevent reuse after revocation
    revoked_participant_caps: VecSet<ID>,
}

// === Public Functions ===

/// Create a new bet
public fun new(
    terms: String,
    expiry: u64,
    vault_id: ID,
    poll_id: ID,
    ctx: &mut TxContext,
): (Bet, CreatorCap) {
    let creator = ctx.sender();
    let now = ctx.epoch_timestamp_ms();

    // Validate expiry is in the future
    assert!(expiry > now, EExpiryInPast);
    // SECURITY FIX: Validate minimum expiry duration to prevent immediate expiry
    assert!(expiry >= now + MIN_EXPIRY_DURATION_MS, EExpiryTooSoon);

    let mut allowed = vec_set::empty();
    allowed.insert(creator);

    let bet = Bet {
        id: object::new(ctx),
        terms,
        references: vector::empty(),
        multimedia_url: option::none(),
        expiry,
        creator,
        status: STATUS_OPEN,
        allowed,
        participants: table::new(ctx),
        participant_count: 0,
        vault_id,
        poll_id,
        winner: option::none(),
        revoked_creator_caps: vec_set::empty(),
        revoked_participants: vec_set::empty(),
        revoked_participant_caps: vec_set::empty(),
    };

    let cap = CreatorCap {
        id: object::new(ctx),
        bet_id: object::id(&bet),
        issued_to: creator,
    };

    event::emit(BetCreated {
        bet_id: object::id(&bet),
        creator,
        terms: bet.terms,
        expiry,
        vault_id,
        poll_id,
    });

    (bet, cap)
}

/// Add a participant directly (package-level, used for auto-adding bet creator)
public(package) fun add_participant(
    self: &mut Bet,
    participant: address,
    ctx: &mut TxContext,
): ParticipantCap {
    let now = ctx.epoch_timestamp_ms();

    assert!(self.status == STATUS_OPEN, EBetNotOpen);
    assert!(now < self.expiry, EBetExpired);
    assert!(!self.participants.contains(participant), EAlreadyJoined);
    assert!(!self.revoked_participants.contains(&participant), ERevokedCap);

    self.participants.add(participant, now);
    self.participant_count = self.participant_count + 1;

    event::emit(ParticipantJoined {
        bet_id: object::id(self),
        participant,
        participant_count: self.participant_count,
    });

    ParticipantCap {
        id: object::new(ctx),
        bet_id: object::id(self),
        participant,
    }
}

/// Join a bet - requires vault to be passed for participant registration
public fun join(self: &mut Bet, ctx: &mut TxContext): ParticipantCap {
    let sender = ctx.sender();
    let now = ctx.epoch_timestamp_ms();

    assert!(self.status == STATUS_OPEN, EBetNotOpen);
    assert!(now < self.expiry, EBetExpired);
    assert!(!self.participants.contains(sender), EAlreadyJoined);
    assert!(!self.revoked_participants.contains(&sender), ERevokedCap);

    assert!(self.allowed.contains(&sender), ENotAllowed);

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
    // SECURITY FIX: Check if this cap has been revoked
    assert!(!self.revoked_participant_caps.contains(&object::uid_to_inner(&id)), ERevokedCap);
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

/// Lock the bet (requires minimum 2 participants)
public fun lock(self: &mut Bet, cap: &CreatorCap, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);
    assert!(self.participant_count >= 2, EInsufficientParticipants);

    self.status = STATUS_LOCKED;

    event::emit(BetLocked {
        bet_id: object::id(self),
        locked_by: ctx.sender(),
        participant_count: self.participant_count,
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

/// Dissolve the bet (refund mode) - only works when bet is OPEN
/// For locked bets that have expired, use force_dissolve_expired in terminal module
public fun dissolve(self: &mut Bet, cap: &CreatorCap, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    // Only OPEN bets can be dissolved via this function
    // LOCKED bets must use force_dissolve_expired after expiry
    assert!(self.status == STATUS_OPEN, EBetLocked);

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
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    if (!self.allowed.contains(&addr)) {
        self.allowed.insert(addr);
    };
}

/// Remove address from allowed list
/// SECURITY FIX: Cannot remove the original creator from allowed list
public fun remove_allowed(self: &mut Bet, cap: &CreatorCap, addr: address, _ctx: &mut TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);
    // SECURITY FIX: Prevent removing the original creator from allowed list
    assert!(addr != self.creator, ENotAllowed);

    if (self.allowed.contains(&addr)) {
        self.allowed.remove(&addr);
    };
}

/// Update bet terms
public fun edit_terms(self: &mut Bet, cap: &CreatorCap, terms: String, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    self.terms = terms;

    event::emit(BetMetadataUpdated {
        bet_id: object::id(self),
        updated_by: ctx.sender(),
        field: b"terms".to_string(),
    });
}

/// Add a reference URL
/// SECURITY FIX: Limit number of references to prevent unbounded growth
public fun add_reference(self: &mut Bet, cap: &CreatorCap, reference: String, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);
    // SECURITY FIX: Prevent unbounded vector growth
    assert!(self.references.length() < MAX_REFERENCES, ETooManyReferences);

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
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    assert!(self.status == STATUS_OPEN, EBetLocked);

    self.multimedia_url = option::some(url);

    event::emit(BetMetadataUpdated {
        bet_id: object::id(self),
        updated_by: ctx.sender(),
        field: b"multimedia_url".to_string(),
    });
}

/// Issue another CreatorCap (only to participants, cannot issue to self)
/// SECURITY FIX: Strengthened self-issuance check
public fun issue_creator_cap(self: &Bet, cap: &CreatorCap, recipient: address, ctx: &mut TxContext): CreatorCap {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(self.participants.contains(cap.issued_to), ENotParticipant);
    // SECURITY FIX: Prevent issuing to self (both sender and cap holder)
    assert!(recipient != ctx.sender(), ESelfNotAllowed);
    assert!(recipient != cap.issued_to, ESelfNotAllowed);
    assert!(self.participants.contains(recipient), ENotParticipant);
    assert!(!self.revoked_participants.contains(&recipient), ERevokedCap);

    event::emit(CreatorCapIssued {
        bet_id: object::id(self),
        issued_to: recipient,
        issued_by: ctx.sender(),
    });

    CreatorCap {
        id: object::new(ctx),
        bet_id: object::id(self),
        issued_to: recipient,
    }
}

/// Revoke a CreatorCap (only original creator can revoke)
/// SECURITY FIX: Prevent self-revocation
public fun revoke_creator_cap(self: &mut Bet, cap: &CreatorCap, cap_to_revoke: ID, ctx: &TxContext) {
    assert!(cap.bet_id == object::id(self), EInvalidCap);
    assert!(!self.revoked_creator_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(ctx.sender() == self.creator, ENotAllowed);
    // SECURITY FIX: Prevent revoking your own capability
    assert!(object::id(cap) != cap_to_revoke, ESelfRevocation);

    if (!self.revoked_creator_caps.contains(&cap_to_revoke)) {
        self.revoked_creator_caps.insert(cap_to_revoke);
    };

    event::emit(CreatorCapRevoked {
        bet_id: object::id(self),
        revoked_cap_id: cap_to_revoke,
        revoked_by: ctx.sender(),
    });
}

/// Revoke a participant (called when they leave, prevents re-issuing caps)
public(package) fun revoke_participant(self: &mut Bet, participant: address, ctx: &TxContext) {
    if (!self.revoked_participants.contains(&participant)) {
        self.revoked_participants.insert(participant);
    };

    event::emit(ParticipantCapRevoked {
        bet_id: object::id(self),
        participant,
        revoked_by: ctx.sender(),
    });
}

/// Revoke a specific ParticipantCap ID (prevents reuse of old caps)
public(package) fun revoke_participant_cap(self: &mut Bet, cap_id: ID) {
    if (!self.revoked_participant_caps.contains(&cap_id)) {
        self.revoked_participant_caps.insert(cap_id);
    };
}

/// Force dissolve an expired bet (package-level, used by terminal)
public(package) fun force_dissolve(self: &mut Bet, ctx: &TxContext) {
    assert!(self.status == STATUS_LOCKED, EBetNotOpen);

    self.status = STATUS_DISSOLVED;

    event::emit(BetDissolved {
        bet_id: object::id(self),
        dissolved_by: ctx.sender(),
        participant_count: self.participant_count,
    });
}

// === Getters ===

public fun id(self: &Bet): ID { object::id(self) }
public fun status(self: &Bet): u8 { self.status }
public fun terms(self: &Bet): String { self.terms }
public fun references(self: &Bet): vector<String> { self.references }
public fun multimedia_url(self: &Bet): Option<String> { self.multimedia_url }
public fun expiry(self: &Bet): u64 { self.expiry }
public fun creator(self: &Bet): address { self.creator }
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
public fun cap_issued_to(cap: &CreatorCap): address { cap.issued_to }
public fun participant_cap_bet_id(cap: &ParticipantCap): ID { cap.bet_id }
public fun participant_cap_participant(cap: &ParticipantCap): address { cap.participant }
public fun is_creator_cap_revoked(self: &Bet, cap_id: ID): bool { self.revoked_creator_caps.contains(&cap_id) }
public fun is_participant_revoked(self: &Bet, addr: address): bool { self.revoked_participants.contains(&addr) }
public fun is_participant_cap_revoked(self: &Bet, cap_id: ID): bool { self.revoked_participant_caps.contains(&cap_id) }

// === Share Function ===

/// Convert a Bet into a shared object
public fun share(bet: Bet) {
    transfer::share_object(bet);
}

// === Status Constants ===

public fun status_open(): u8 { STATUS_OPEN }
public fun status_locked(): u8 { STATUS_LOCKED }
public fun status_resolved(): u8 { STATUS_RESOLVED }
public fun status_dissolved(): u8 { STATUS_DISSOLVED }
