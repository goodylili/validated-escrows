module terminal::terminal;

use std::string::String;
use sui::coin::Coin;
use sui::event;

use terminal::bet::{Self, Bet, CreatorCap, ParticipantCap};
use terminal::poll::{Self, Poll, WitnessCap};
use terminal::vault::{Self, Vault, VaultCap};

// === Error Codes ===

const EPollNotResolved: u64 = 0;
const EBetPollMismatch: u64 = 1;
const EBetVaultMismatch: u64 = 2;
const ENotExpired: u64 = 3;
const EBetNotLocked: u64 = 4;
const ENotAuthorized: u64 = 5;
const ERevokedCap: u64 = 6;
const ENotParticipant: u64 = 7;

// === Structs ===

/// Admin capability for package-wide operations
public struct AdminCap has key, store {
    id: UID,
}

// === Events ===

public struct BetSystemCreated has copy, drop {
    bet_id: ID,
    vault_id: ID,
    poll_id: ID,
    creator: address,
    terms: String,
    expiry: u64,
}

public struct BetForceDissolvedExpired has copy, drop {
    bet_id: ID,
    vault_id: ID,
    dissolved_by: address,
    expiry: u64,
}

// === Public Entry Functions ===

fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap {
        id: object::new(ctx),
    };
    transfer::transfer(admin_cap, ctx.sender());
}

/// Create a complete bet with vault and poll
/// Creator is automatically added as a participant
public fun create_bet(
    terms: String,
    expiry: u64,
    ctx: &mut TxContext,
): (Bet, Vault, Poll, CreatorCap, VaultCap, ParticipantCap) {
    let creator = ctx.sender();

    // Create vault first
    let (mut vault, vault_cap) = vault::new(object::id_from_address(@0x0), ctx);
    let vault_id = vault::id(&vault);

    // Create poll
    let mut poll = poll::new(object::id_from_address(@0x0), 0, ctx);
    let poll_id = poll::id(&poll);

    // Create bet
    let (mut bet, creator_cap) = bet::new(terms, expiry, vault_id, poll_id, ctx);
    let bet_id = bet::id(&bet);

    // Update vault and poll with correct bet_id
    vault.set_bet_id(bet_id);
    poll.set_bet_id(bet_id);

    // Add creator as a participant
    let participant_cap = bet.add_participant(creator, ctx);
    
    // Register creator in vault so they can deposit
    vault.add_participant(creator, ctx);
    
    // Update poll required participants
    // Update poll required participants
    poll.set_required_participants(bet::participant_count(&bet), ctx);

    event::emit(BetSystemCreated {
        bet_id,
        vault_id,
        poll_id,
        creator,
        terms: bet::terms(&bet),
        expiry,
    });

    (bet, vault, poll, creator_cap, vault_cap, participant_cap)
}

/// Join a bet and deposit funds
/// SECURITY FIX: Added validation for bet/vault/poll linkage
public fun join_bet<T>(
    bet: &mut Bet,
    vault: &mut Vault,
    poll: &mut Poll,
    coin: Coin<T>,
    ctx: &mut TxContext,
): ParticipantCap {
    // SECURITY FIX: Validate bet, vault, and poll are properly linked
    assert!(bet::vault_id(bet) == vault::id(vault), EBetVaultMismatch);
    assert!(bet::poll_id(bet) == poll::id(poll), EBetPollMismatch);

    // Join bet
    let cap = bet.join(ctx);
    let participant = bet::get_participant_address(&cap);

    // Register as vault participant so they can deposit
    vault.add_participant(participant, ctx);

    // Deposit to vault
    vault.deposit(coin, ctx);

    // Update poll required participants
    poll.set_required_participants(bet::participant_count(bet), ctx);

    cap
}

/// Leave a bet and claim refund
/// SECURITY FIX: Added validation for bet/vault/poll linkage and cap validity
public fun leave_bet<T>(
    bet: &mut Bet,
    vault: &mut Vault,
    poll: &mut Poll,
    cap: ParticipantCap,
    ctx: &mut TxContext,
): (Coin<T>, Option<ParticipantCap>) {
    let participant = bet::participant_cap_participant(&cap);
    let cap_bet_id = bet::participant_cap_bet_id(&cap);

    // SECURITY FIX: Validate cap belongs to this bet
    assert!(cap_bet_id == bet::id(bet), ENotAuthorized);
    // SECURITY FIX: Validate bet, vault, and poll are linked
    assert!(bet::vault_id(bet) == vault::id(vault), EBetVaultMismatch);
    assert!(bet::poll_id(bet) == poll::id(poll), EBetPollMismatch);
    // SECURITY FIX: Check cap is not revoked
    assert!(!bet::is_participant_cap_revoked(bet, object::id(&cap)), ERevokedCap);

    // Withdraw deposit from vault (removes from registry)
    let refund = vault.withdraw_deposit<T>(participant, ctx);

    // Check if user has other deposits
    if (vault.deposit_count_for_user(participant) > 0) {
        // User still has active deposits, do not remove from bet/vault participants
        // Return cap so they can withdraw other assets
        (refund, option::some(cap))
    } else {
        // User has no more deposits, remove completely

        // Leave bet
        bet.leave(cap, ctx);

        // Remove from vault participants
        vault.remove_participant(participant);

        // Update poll required participants
        // Note: bet.leave already decremented participant count in bet
        poll.set_required_participants(bet::participant_count(bet), ctx);

        (refund, option::none())
    }
}

/// Revoke a participant's ability to get re-issued caps (Soft Ban - prevents re-entry and winning)
/// Also revokes their ParticipantCap if provided
public fun revoke_participant(
    bet: &mut Bet,
    vault: &mut Vault,
    cap: &CreatorCap,
    participant: address,
    participant_cap_id: Option<ID>,
    ctx: &TxContext,
) {
    assert!(bet::cap_bet_id(cap) == bet::id(bet), ENotAuthorized);
    assert!(!bet::is_creator_cap_revoked(bet, object::id(cap)), ERevokedCap);
    assert!(bet::is_participant(bet, bet::cap_issued_to(cap)), ENotParticipant);
    // SECURITY FIX: Validate bet and vault are linked
    assert!(bet::vault_id(bet) == vault::id(vault), EBetVaultMismatch);

    bet.revoke_participant(participant, ctx);
    // SECURITY FIX: Also revoke in vault to prevent being set as winner
    vault.revoke_participant(participant);

    // SECURITY FIX: Revoke the participant's cap if ID is provided
    if (participant_cap_id.is_some()) {
        bet.revoke_participant_cap(*participant_cap_id.borrow());
    };
}

/// Deposit additional funds to vault
public fun deposit<T>(
    vault: &mut Vault,
    coin: Coin<T>,
    ctx: &mut TxContext,
) {
    vault.deposit(coin, ctx);
}

/// Lock bet and vault together
public fun lock_bet(
    bet: &mut Bet,
    vault: &mut Vault,
    creator_cap: &CreatorCap,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    bet.lock(creator_cap, ctx);
    vault.lock(vault_cap, ctx);
}



/// Dissolve bet and set vault to disbursed
public fun dissolve_bet(
    bet: &mut Bet,
    vault: &mut Vault,
    creator_cap: &CreatorCap,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    bet.dissolve(creator_cap, ctx);
    vault.set_disbursed(vault_cap, ctx);
}

/// Participant votes on poll outcome
public fun vote(
    bet: &Bet,
    poll: &mut Poll,
    outcome: address,
    ctx: &mut TxContext,
) {
    poll.participant_vote(bet, outcome, ctx);
}

/// Witness votes on poll outcome
public fun witness_vote(
    bet: &Bet,
    poll: &mut Poll,
    cap: &WitnessCap,
    outcome: address,
    ctx: &mut TxContext,
) {
    poll.witness_vote(bet, cap, outcome, ctx);
}

/// Witness vetoes (relinquishes voting power)
public fun witness_veto(
    poll: &mut Poll,
    cap: WitnessCap,
    ctx: &mut TxContext,
) {
    poll.veto(cap, ctx);
}

/// Add a witness to the poll (requires bet reference for authorization)
public fun add_witness(
    bet: &Bet,
    poll: &mut Poll,
    witness: address,
    weight: u64,
    ctx: &mut TxContext,
): WitnessCap {
    poll.add_witness(bet, witness, weight, ctx)
}

/// Claim winnings after bet resolution
public fun claim_winnings<T>(
    vault: &mut Vault,
    ctx: &mut TxContext,
): Coin<T> {
    vault.claim_winnings(ctx)
}

/// Claim refund after bet dissolution
public fun claim_refund<T>(
    vault: &mut Vault,
    ctx: &mut TxContext,
): Coin<T> {
    vault.claim_refund(ctx)
}

// === NFT Functions ===

/// Deposit an NFT into the vault
public fun deposit_nft<T: key + store>(
    vault: &mut Vault,
    nft: T,
    ctx: &mut TxContext,
) {
    vault.deposit_nft(nft, ctx);
}

/// Claim NFT winnings after bet resolution
public fun claim_nft_winnings<T: key + store>(
    vault: &mut Vault,
    object_id: ID,
    ctx: &mut TxContext,
): T {
    vault.claim_nft_winnings(object_id, ctx)
}

/// Claim NFT refund after bet dissolution
public fun claim_nft_refund<T: key + store>(
    vault: &mut Vault,
    object_id: ID,
    ctx: &mut TxContext,
): T {
    vault.claim_nft_refund(object_id, ctx)
}

/// Resolve bet after poll is resolved (validates bet/poll/vault linkage)
/// SECURITY FIX: Added validation that poll outcome is present and bet is locked
public fun resolve_bet(
    bet: &mut Bet,
    poll: &Poll,
    vault: &mut Vault,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    // Validate linkage between bet, poll, and vault
    assert!(bet::poll_id(bet) == poll::id(poll), EBetPollMismatch);
    assert!(bet::vault_id(bet) == vault::id(vault), EBetVaultMismatch);
    // SECURITY FIX: Verify bet is in locked state before resolution
    assert!(bet::is_locked(bet), EBetNotLocked);
    assert!(poll.is_resolved(), EPollNotResolved);

    // SECURITY FIX: Validate that outcome is present before borrowing
    let outcome = poll.outcome();
    assert!(outcome.is_some(), EPollNotResolved);

    let winner = *outcome.borrow();

    // SECURITY FIX: Validate winner is a participant in the bet
    assert!(bet::is_participant(bet, winner), ENotParticipant);

    bet.resolve(winner, ctx);
    vault.set_resolved(vault_cap, winner, ctx);
}

/// Force dissolve an expired locked bet (anyone can call after expiry)
/// SECURITY FIX: Added bet/vault linkage validation
public fun force_dissolve_expired(
    bet: &mut Bet,
    vault: &mut Vault,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    let now = ctx.epoch_timestamp_ms();
    let expiry = bet::expiry(bet);

    // SECURITY FIX: Validate bet and vault are linked
    assert!(bet::vault_id(bet) == vault::id(vault), EBetVaultMismatch);
    // SECURITY FIX: Validate vault_cap belongs to this vault
    assert!(vault::cap_vault_id(vault_cap) == vault::id(vault), ENotAuthorized);

    assert!(now >= expiry, ENotExpired);
    assert!(bet::is_locked(bet), EBetNotLocked);

    // Force resolve the poll as dissolved
    // Note: bet.dissolve requires CreatorCap, so we use a package-level approach
    // We update both bet status and vault status

    bet.force_dissolve(ctx);
    vault.set_disbursed(vault_cap, ctx);

    event::emit(BetForceDissolvedExpired {
        bet_id: bet::id(bet),
        vault_id: vault::id(vault),
        dissolved_by: ctx.sender(),
        expiry,
    });
}

/// Edit bet terms
public fun edit_terms(
    bet: &mut Bet,
    cap: &CreatorCap,
    terms: String,
    ctx: &TxContext,
) {
    bet.edit_terms(cap, terms, ctx);
}

/// Add reference to bet
public fun add_reference(
    bet: &mut Bet,
    cap: &CreatorCap,
    reference: String,
    ctx: &TxContext,
) {
    bet.add_reference(cap, reference, ctx);
}

/// Set multimedia URL
public fun set_multimedia(
    bet: &mut Bet,
    cap: &CreatorCap,
    url: String,
    ctx: &TxContext,
) {
    bet.set_multimedia(cap, url, ctx);
}

/// Add allowed participant
public fun add_allowed(
    bet: &mut Bet,
    cap: &CreatorCap,
    addr: address,
    ctx: &mut TxContext,
) {
    bet.add_allowed(cap, addr, ctx);
}

/// Remove allowed participant
public fun remove_allowed(
    bet: &mut Bet,
    cap: &CreatorCap,
    addr: address,
    ctx: &mut TxContext,
) {
    bet.remove_allowed(cap, addr, ctx);
}

/// Issue another CreatorCap
public fun issue_creator_cap(
    bet: &Bet,
    cap: &CreatorCap,
    recipient: address,
    ctx: &mut TxContext,
): CreatorCap {
    bet.issue_creator_cap(cap, recipient, ctx)
}

/// Issue another VaultCap
public fun issue_vault_cap(
    vault: &Vault,
    cap: &VaultCap,
    recipient: address,
    ctx: &mut TxContext,
): VaultCap {
    vault.issue_cap(cap, recipient, ctx)
}

/// Revoke a CreatorCap
public fun revoke_creator_cap(
    bet: &mut Bet,
    cap: &CreatorCap,
    cap_to_revoke: ID,
    ctx: &TxContext,
) {
    bet.revoke_creator_cap(cap, cap_to_revoke, ctx);
}

/// Revoke a VaultCap
public fun revoke_vault_cap(
    vault: &mut Vault,
    cap: &VaultCap,
    cap_to_revoke: ID,
    ctx: &TxContext,
) {
    vault.revoke_cap(cap, cap_to_revoke, ctx);
}

/// Revoke a WitnessCap (requires legitimate CreatorCap)
public fun revoke_witness_cap(
    bet: &Bet,
    poll: &mut Poll,
    cap: &CreatorCap,
    cap_to_revoke: ID,
    ctx: &TxContext,
) {
    assert!(bet::cap_bet_id(cap) == bet::id(bet), ENotAuthorized);
    assert!(!bet::is_creator_cap_revoked(bet, object::id(cap)), ERevokedCap);
    assert!(bet::poll_id(bet) == poll::id(poll), EBetPollMismatch);
    
    // Validate cap holder is a current participant
    assert!(bet::is_participant(bet, bet::cap_issued_to(cap)), ENotParticipant);

    poll.revoke_witness_cap(cap_to_revoke, ctx);
}


