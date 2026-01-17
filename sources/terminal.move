/// Terminal module - Public API coordinating bets, vaults, and polls.
module terminal::terminal;

use std::string::String;
use sui::coin::Coin;
use sui::event;

use terminal::bet::{Self, Bet, CreatorCap, ParticipantCap};
use terminal::poll::{Self, Poll, WitnessCap};
use terminal::vault::{Self, Vault, VaultCap};

// === Events ===

public struct BetSystemCreated has copy, drop {
    bet_id: ID,
    vault_id: ID,
    poll_id: ID,
    creator: address,
    terms: String,
    expiry: u64,
    open_to_all: bool,
}

// === Public Entry Functions ===

/// Create a complete bet with vault and poll
/// Creator is automatically added as a participant
public fun create_bet(
    terms: String,
    expiry: u64,
    open_to_all: bool,
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
    let (mut bet, creator_cap) = bet::new(terms, expiry, open_to_all, vault_id, poll_id, ctx);
    let bet_id = bet::id(&bet);

    // Add creator as a participant
    let participant_cap = bet.add_participant(creator, ctx);
    
    // Register creator in vault so they can deposit
    vault.add_participant(creator, ctx);
    
    // Update poll required participants
    poll.set_required_participants(bet::participant_count(&bet));

    event::emit(BetSystemCreated {
        bet_id,
        vault_id,
        poll_id,
        creator,
        terms: bet::terms(&bet),
        expiry,
        open_to_all,
    });

    (bet, vault, poll, creator_cap, vault_cap, participant_cap)
}

/// Join a bet and deposit funds
public fun join_bet<T>(
    bet: &mut Bet,
    vault: &mut Vault,
    poll: &mut Poll,
    coin: Coin<T>,
    ctx: &mut TxContext,
): ParticipantCap {
    // Join bet
    let cap = bet.join(ctx);
    let participant = bet::get_participant_address(&cap);
    
    // Register as vault participant so they can deposit
    vault.add_participant(participant, ctx);
    
    // Deposit to vault
    vault.deposit(coin, ctx);
    
    // Update poll required participants
    poll.set_required_participants(bet::participant_count(bet));

    cap
}

/// Leave a bet and claim refund
public fun leave_bet<T>(
    bet: &mut Bet,
    vault: &mut Vault,
    poll: &mut Poll,
    cap: ParticipantCap,
    ctx: &mut TxContext,
): Coin<T> {
    let participant = bet::participant_cap_participant(&cap);
    
    // Leave bet
    bet.leave(cap, ctx);
    
    // Withdraw deposit from vault (removes from registry)
    let refund = vault.withdraw_deposit<T>(participant, ctx);
    
    // Remove from vault participants
    vault.remove_participant(participant);
    
    // Update poll required participants
    poll.set_required_participants(bet::participant_count(bet));

    refund
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

/// Unlock bet and vault together
public fun unlock_bet(
    bet: &mut Bet,
    vault: &mut Vault,
    creator_cap: &CreatorCap,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    bet.unlock(creator_cap, ctx);
    vault.unlock(vault_cap, ctx);
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
    poll: &mut Poll,
    outcome: address,
    ctx: &mut TxContext,
) {
    let voter = ctx.sender();
    poll.participant_vote(voter, outcome, ctx);
}

/// Witness votes on poll outcome
public fun witness_vote(
    poll: &mut Poll,
    cap: &WitnessCap,
    outcome: address,
    ctx: &mut TxContext,
) {
    poll.witness_vote(cap, outcome, ctx);
}

/// Witness vetoes (relinquishes voting power)
public fun witness_veto(
    poll: &mut Poll,
    cap: WitnessCap,
    ctx: &mut TxContext,
) {
    poll.veto(cap, ctx);
}

/// Add a witness to the poll
public fun add_witness(
    poll: &mut Poll,
    witness: address,
    weight: u64,
    ctx: &mut TxContext,
): WitnessCap {
    poll.add_witness(witness, weight, ctx)
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

/// Resolve bet after poll is resolved
public fun resolve_bet(
    bet: &mut Bet,
    poll: &Poll,
    vault: &mut Vault,
    vault_cap: &VaultCap,
    ctx: &TxContext,
) {
    assert!(poll.is_resolved(), 0);
    let winner = *poll.outcome().borrow();

    bet.resolve(winner, ctx);
    vault.set_resolved(vault_cap, winner, ctx);
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
