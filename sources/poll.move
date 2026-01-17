/// Poll module for bet resolution voting with dual-quorum.
module terminal::poll;

use std::string::String;
use sui::event;
use sui::table::{Self, Table};
use sui::vec_set::{Self, VecSet};

use terminal::bet::{Self, Bet};

// === Constants ===

const WITNESS_QUORUM_BPS: u64 = 6666;
const BPS_DENOMINATOR: u64 = 10000;
const MAX_WITNESS_COUNT: u64 = 10;
const MAX_WITNESS_WEIGHT_BPS: u64 = 5000; // Max 50% weight for single witness

// === Error Codes ===

const EInvalidCap: u64 = 0;
const EAlreadyVoted: u64 = 1;
const ENotWitness: u64 = 2;
const EPollResolved: u64 = 3;
const EWitnessAlreadyRegistered: u64 = 4;
const ENotParticipant: u64 = 5;
const EInvalidOutcome: u64 = 6;
const EZeroWeight: u64 = 7;
const EBetPollMismatch: u64 = 8;
const ETooManyWitnesses: u64 = 9;
const EWeightExceedsMax: u64 = 10;
const ERevokedCap: u64 = 11;

// === Events ===

public struct PollCreated has copy, drop {
    poll_id: ID,
    bet_id: ID,
    created_by: address,
}

public struct WitnessAdded has copy, drop {
    poll_id: ID,
    bet_id: ID,
    witness: address,
    weight: u64,
    total_witness_weight: u64,
}

public struct ParticipantVoted has copy, drop {
    poll_id: ID,
    bet_id: ID,
    voter: address,
    outcome: address,
    votes_for_outcome: u64,
    total_participant_votes: u64,
}

public struct WitnessVoted has copy, drop {
    poll_id: ID,
    bet_id: ID,
    voter: address,
    outcome: address,
    weight: u64,
    weight_for_outcome: u64,
    total_witness_votes: u64,
}

public struct WitnessVetoed has copy, drop {
    poll_id: ID,
    bet_id: ID,
    witness: address,
    relinquished_weight: u64,
    remaining_total_weight: u64,
}

public struct PollResolved has copy, drop {
    poll_id: ID,
    bet_id: ID,
    winner: address,
    resolution_type: String,
    participant_votes: u64,
    witness_weight: u64,
}

public struct WitnessCapRevoked has copy, drop {
    poll_id: ID,
    bet_id: ID,
    revoked_cap_id: ID,
    revoked_by: address,
}

// === Structs ===

public struct WitnessCap has key, store {
    id: UID,
    poll_id: ID,
    witness: address,
    weight: u64,
}

public struct Vote has store, copy, drop {
    outcome: address,
    weight: u64,
}

public struct Poll has key {
    id: UID,
    bet_id: ID,
    required_participants: u64,
    participant_votes: Table<address, Vote>,
    participant_outcome_counts: Table<address, u64>,
    participant_vote_count: u64,
    witnesses: Table<address, u64>,
    witness_votes: Table<address, Vote>,
    witness_outcome_weights: Table<address, u64>,
    total_witness_weight: u64,
    voted_witness_weight: u64,
    resolved: bool,
    outcome: Option<address>,
    participant_voter_list: vector<address>,
    witness_outcome_list: vector<address>,
    witness_count: u64,
    revoked_witness_caps: VecSet<ID>,
}

// === Public Functions ===

/// Create a new poll for a bet
public fun new(
    bet_id: ID,
    required_participants: u64,
    ctx: &mut TxContext,
): Poll {
    let poll = Poll {
        id: object::new(ctx),
        bet_id,
        required_participants,
        participant_votes: table::new(ctx),
        participant_outcome_counts: table::new(ctx),
        participant_vote_count: 0,
        witnesses: table::new(ctx),
        witness_votes: table::new(ctx),
        witness_outcome_weights: table::new(ctx),
        total_witness_weight: 0,
        voted_witness_weight: 0,
        resolved: false,
        outcome: option::none(),
        participant_voter_list: vector::empty(),
        witness_outcome_list: vector::empty(),
        witness_count: 0,
        revoked_witness_caps: vec_set::empty(),
    };

    event::emit(PollCreated {
        poll_id: object::id(&poll),
        bet_id,
        created_by: ctx.sender(),
    });

    poll
}

/// Update required participants count
public(package) fun set_required_participants(self: &mut Poll, count: u64, ctx: &mut TxContext) {
    self.required_participants = count;
    self.check_resolution(ctx);
}

/// Set the Bet ID (called during initialization)
public(package) fun set_bet_id(self: &mut Poll, bet_id: ID) {
    self.bet_id = bet_id;
}

/// Add a witness with voting weight (only participants can add witnesses)
public(package) fun add_witness(
    self: &mut Poll,
    bet: &Bet,
    witness: address,
    weight: u64,
    ctx: &mut TxContext,
): WitnessCap {
    assert!(!self.resolved, EPollResolved);
    assert!(bet::id(bet) == self.bet_id, EBetPollMismatch);
    assert!(bet::is_participant(bet, ctx.sender()), ENotParticipant);
    assert!(!self.witnesses.contains(witness), EWitnessAlreadyRegistered);
    assert!(weight > 0, EZeroWeight);
    assert!(self.witness_count < MAX_WITNESS_COUNT, ETooManyWitnesses);
    
    // Validate weight doesn't exceed max percentage after adding
    let new_total = self.total_witness_weight + weight;
    let max_individual_weight = (new_total * MAX_WITNESS_WEIGHT_BPS) / BPS_DENOMINATOR;
    assert!(weight <= max_individual_weight, EWeightExceedsMax);

    self.witnesses.add(witness, weight);
    self.total_witness_weight = self.total_witness_weight + weight;
    self.witness_count = self.witness_count + 1;

    event::emit(WitnessAdded {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        witness,
        weight,
        total_witness_weight: self.total_witness_weight,
    });

    WitnessCap {
        id: object::new(ctx),
        poll_id: object::id(self),
        witness,
        weight,
    }
}

/// Participant casts a vote (validates voter and outcome are bet participants)
public fun participant_vote(
    self: &mut Poll,
    bet: &Bet,
    outcome: address,
    ctx: &mut TxContext,
) {
    let voter = ctx.sender();
    
    assert!(!self.resolved, EPollResolved);
    assert!(bet::id(bet) == self.bet_id, EBetPollMismatch);
    assert!(bet::is_participant(bet, voter), ENotParticipant);
    assert!(bet::is_participant(bet, outcome), EInvalidOutcome);
    assert!(!self.participant_votes.contains(voter), EAlreadyVoted);

    self.participant_votes.add(voter, Vote { outcome, weight: 1 });
    self.participant_vote_count = self.participant_vote_count + 1;
    self.participant_voter_list.push_back(voter);

    if (self.participant_outcome_counts.contains(outcome)) {
        let count = self.participant_outcome_counts.borrow_mut(outcome);
        *count = *count + 1;
    } else {
        self.participant_outcome_counts.add(outcome, 1);
    };

    let votes_for_outcome = *self.participant_outcome_counts.borrow(outcome);

    event::emit(ParticipantVoted {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        voter,
        outcome,
        votes_for_outcome,
        total_participant_votes: self.participant_vote_count,
    });

    self.check_resolution(ctx);
}

/// Witness casts a vote (validates outcome is a bet participant)
public fun witness_vote(
    self: &mut Poll,
    bet: &Bet,
    cap: &WitnessCap,
    outcome: address,
    ctx: &mut TxContext,
) {
    assert!(!self.resolved, EPollResolved);
    assert!(bet::id(bet) == self.bet_id, EBetPollMismatch);
    assert!(cap.poll_id == object::id(self), EInvalidCap);
    assert!(self.witnesses.contains(cap.witness), ENotWitness);
    assert!(!self.revoked_witness_caps.contains(&object::id(cap)), ERevokedCap);
    assert!(bet::is_participant(bet, outcome), EInvalidOutcome);
    assert!(!self.witness_votes.contains(cap.witness), EAlreadyVoted);

    let weight = cap.weight;

    self.witness_votes.add(cap.witness, Vote { outcome, weight });
    self.voted_witness_weight = self.voted_witness_weight + weight;

    if (self.witness_outcome_weights.contains(outcome)) {
        let current = self.witness_outcome_weights.borrow_mut(outcome);
        *current = *current + weight;
    } else {
        self.witness_outcome_weights.add(outcome, weight);
        self.witness_outcome_list.push_back(outcome);
    };

    let weight_for_outcome = *self.witness_outcome_weights.borrow(outcome);

    event::emit(WitnessVoted {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        voter: cap.witness,
        outcome,
        weight,
        weight_for_outcome,
        total_witness_votes: self.voted_witness_weight,
    });

    self.check_resolution(ctx);
}

/// Revoke a WitnessCap
public(package) fun revoke_witness_cap(
    self: &mut Poll,
    cap_to_revoke: ID,
    ctx: &TxContext,
) {
    if (!self.revoked_witness_caps.contains(&cap_to_revoke)) {
        self.revoked_witness_caps.insert(cap_to_revoke);
    };

    event::emit(WitnessCapRevoked {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        revoked_cap_id: cap_to_revoke,
        revoked_by: ctx.sender(),
    });
}

/// Witness vetoes - relinquishes voting power
public fun veto(
    self: &mut Poll,
    cap: WitnessCap,
    _ctx: &mut TxContext,
) {
    let WitnessCap { id, poll_id, witness, weight } = cap;

    assert!(!self.resolved, EPollResolved);
    assert!(poll_id == object::id(self), EInvalidCap);
    assert!(self.witnesses.contains(witness), ENotWitness);

    self.witnesses.remove(witness);
    self.total_witness_weight = self.total_witness_weight - weight;
    self.witness_count = self.witness_count - 1;

    if (self.witness_votes.contains(witness)) {
        let vote = self.witness_votes.remove(witness);
        self.voted_witness_weight = self.voted_witness_weight - vote.weight;

        if (self.witness_outcome_weights.contains(vote.outcome)) {
            let outcome_weight = self.witness_outcome_weights.borrow_mut(vote.outcome);
            *outcome_weight = *outcome_weight - vote.weight;
        };
    };

    event::emit(WitnessVetoed {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        witness,
        relinquished_weight: weight,
        remaining_total_weight: self.total_witness_weight,
    });

    id.delete();
}

fun check_resolution(self: &mut Poll, _ctx: &mut TxContext) {
    if (self.resolved) { return };

    // Priority 1: Unanimous participant agreement
    if (self.participant_vote_count == self.required_participants && self.required_participants > 0) {
        let first_voter = *self.participant_voter_list.borrow(0);
        let first_vote = self.participant_votes.borrow(first_voter);
        let outcome = first_vote.outcome;
        let count = *self.participant_outcome_counts.borrow(outcome);

        if (count == self.required_participants) {
            self.resolved = true;
            self.outcome = option::some(outcome);

            event::emit(PollResolved {
                poll_id: object::id(self),
                bet_id: self.bet_id,
                winner: outcome,
                resolution_type: b"participant_unanimous".to_string(),
                participant_votes: self.participant_vote_count,
                witness_weight: 0,
            });
            return
        };
    };

    // Priority 2: Witness 66.66% quorum
    if (self.total_witness_weight > 0 && self.witness_outcome_list.length() > 0) {
        let mut best_outcome = @0x0;
        let mut best_weight = 0u64;
        let mut i = 0;
        let len = self.witness_outcome_list.length();

        while (i < len) {
            let outcome = *self.witness_outcome_list.borrow(i);
            let weight = *self.witness_outcome_weights.borrow(outcome);
            if (weight > best_weight) {
                best_weight = weight;
                best_outcome = outcome;
            };
            i = i + 1;
        };

        if (best_weight > 0) {
            let quorum_threshold = (self.total_witness_weight * WITNESS_QUORUM_BPS) / BPS_DENOMINATOR;

            if (best_weight >= quorum_threshold) {
                self.resolved = true;
                self.outcome = option::some(best_outcome);

                event::emit(PollResolved {
                    poll_id: object::id(self),
                    bet_id: self.bet_id,
                    winner: best_outcome,
                    resolution_type: b"witness_quorum".to_string(),
                    participant_votes: self.participant_vote_count,
                    witness_weight: best_weight,
                });
            };
        };
    };
}

/// Force resolution (package-only)
public(package) fun force_resolve(self: &mut Poll, winner: address, resolution_type: String) {
    assert!(!self.resolved, EPollResolved);

    self.resolved = true;
    self.outcome = option::some(winner);

    event::emit(PollResolved {
        poll_id: object::id(self),
        bet_id: self.bet_id,
        winner,
        resolution_type,
        participant_votes: self.participant_vote_count,
        witness_weight: self.voted_witness_weight,
    });
}

// === Getters ===

public fun id(self: &Poll): ID { object::id(self) }
public fun bet_id(self: &Poll): ID { self.bet_id }
public fun is_resolved(self: &Poll): bool { self.resolved }
public fun outcome(self: &Poll): Option<address> { self.outcome }
public fun participant_vote_count(self: &Poll): u64 { self.participant_vote_count }
public fun required_participants(self: &Poll): u64 { self.required_participants }
public fun total_witness_weight(self: &Poll): u64 { self.total_witness_weight }
public fun voted_witness_weight(self: &Poll): u64 { self.voted_witness_weight }
public fun has_participant_voted(self: &Poll, addr: address): bool { self.participant_votes.contains(addr) }
public fun has_witness_voted(self: &Poll, addr: address): bool { self.witness_votes.contains(addr) }
public fun is_witness(self: &Poll, addr: address): bool { self.witnesses.contains(addr) }

public fun witness_weight(self: &Poll, addr: address): u64 {
    if (self.witnesses.contains(addr)) {
        *self.witnesses.borrow(addr)
    } else {
        0
    }
}

public fun participant_votes_for(self: &Poll, outcome: address): u64 {
    if (self.participant_outcome_counts.contains(outcome)) {
        *self.participant_outcome_counts.borrow(outcome)
    } else {
        0
    }
}

public fun witness_weight_for(self: &Poll, outcome: address): u64 {
    if (self.witness_outcome_weights.contains(outcome)) {
        *self.witness_outcome_weights.borrow(outcome)
    } else {
        0
    }
}

public fun cap_poll_id(cap: &WitnessCap): ID { cap.poll_id }
public fun cap_witness(cap: &WitnessCap): address { cap.witness }
public fun cap_weight(cap: &WitnessCap): u64 { cap.weight }
public fun witness_quorum_bps(): u64 { WITNESS_QUORUM_BPS }
public fun witness_count(self: &Poll): u64 { self.witness_count }
public fun max_witness_count(): u64 { MAX_WITNESS_COUNT }
