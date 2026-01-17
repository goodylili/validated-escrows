# Terminal Betting Platform - Product Requirements

## Overview

Terminal is a decentralized betting platform built on Sui. It consists of four interconnected modules: Bet, Vault, Poll, and Terminal (orchestrator).

---

## Bets

- **Shared object** that tracks participants, status, and resolution
- **Terms**: String describing the bet conditions
- **References**: Up to 20 URLs/links (e.g., social media references)
- **Multimedia URL**: Optional media URL for proof
- **Expiry**: Timestamp set at creation (minimum 1 hour from creation); not extendable
- **Allowed List**: Whitelist of addresses that can participate (creator always included)

### Bet Status Flow

```
OPEN (0) → LOCKED (1) → RESOLVED (2)
                     → DISSOLVED (3)
```

- **OPEN**: Participants can join/leave, creator can configure
- **LOCKED**: No more joins/leaves, voting begins (requires ≥2 participants to lock)
- **RESOLVED**: Winner determined, winner claims all assets
- **DISSOLVED**: Refund mode, all participants claim their deposits back

### Roles

#### Bet Creator
- Automatically becomes a participant
- Receives CreatorCap on bet creation
- **CreatorCap Powers**:
  - Edit bet terms, references, and multimedia URL
  - Manage the allowed participants list
  - Lock the bet (requires ≥2 participants)
  - Dissolve the bet (only when OPEN status)
  - Issue CreatorCap to other participants (cannot issue to self)
  - Revoke CreatorCaps issued to others (cannot revoke own cap)
  - Revoke participants (soft-ban) and their ParticipantCaps

#### Participants
- Can join if on the allowed list and bet is OPEN
- Can leave only when bet status is OPEN (automatically withdraws their deposits)
- Receive ParticipantCap proving membership
- Can vote to resolve the bet (unanimous agreement required among all participants)
- Can add witnesses to the poll (witnesses must also be participants)
- **ParticipantCap**: Proves membership for a specific bet; can be revoked via soft-ban

---

## Polls

- Created automatically with each bet
- Attached to a specific bet (validated via bet_id)

### Resolution Mechanisms

Two independent paths to resolve a poll:

1. **Participant Voting (Unanimous)**
   - Each participant has 1 vote with weight 1
   - Resolution requires ALL participants to vote for the same outcome
   - Unanimous agreement triggers immediate resolution

2. **Witness Voting (Quorum-based)**
   - Witnesses are added by participants (must themselves be participants)
   - Each witness has a weight (1-100 initially, then max 50% of existing total)
   - Resolution requires 66.66% quorum of locked witness weight
   - First witness vote locks the total weight (prevents veto manipulation)

**Priority**: Participant unanimous agreement takes precedence

### Witnesses
- Must be participants in the bet to become witnesses
- Receive WitnessCap with a fixed weight (determined at creation)
- Can cast weighted vote for any participant as the winner
- Can veto (relinquish voting power, removes them as witness)
- Maximum 10 witnesses per poll
- Weight constraints prevent any single witness from having >50% voting power

### Witness Weight Locking

When the first witness casts a vote:
- `locked_witness_weight` is set to the current `total_witness_weight`
- Subsequent vetoes reduce total weight but quorum is calculated against locked weight
- Prevents gaming the quorum by strategically vetoing after voting begins

---

## Vaults

- Created automatically with each bet (one vault per bet)
- Holds participant deposits (coins and NFTs)
- Maintains a deposit registry tracking who deposited what

### Vault Status Flow

```
OPEN (0) → LOCKED (1) → RESOLVED (2) [winner takes all]
                     → DISBURSED (3) [refunds]
```

- **OPEN**: Accepts deposits/withdrawals from participants
- **LOCKED**: Locked with the bet, no more deposits/withdrawals
- **RESOLVED**: Winner determined, winner can claim all assets
- **DISBURSED**: Refund mode, each participant claims their own deposits

### Asset Management

**Coins**:
- Minimum deposit: 1000 units (prevents dust attacks)
- Deposits are aggregated per depositor
- On claim, ALL matching deposits collected and returned as single coin

**NFTs**:
- Stored in ObjectBag with object ID
- Type validated on withdrawal/claim
- Each NFT tracked individually in deposit registry

### VaultCap
- Issued to bet creator automatically
- Can be issued to other participants
- **Powers**:
  - Lock vault
  - Set vault as resolved (designate winner)
  - Set vault as disbursed (enable refunds)
  - Issue/revoke other VaultCaps

### Claim Process

- **Winner (RESOLVED)**: Calls `claim_winnings` to receive ALL assets in vault
- **Participants (DISBURSED)**: Each calls `claim_refund` to receive their own deposits
- Claims are per-asset-type (must claim coins and NFTs separately)

---

## Security Features

### Revocation System (Soft-Ban)

Three-tier revocation prevents exploits:
1. **CreatorCap Revocation**: Prevents unauthorized bet control
2. **Participant Revocation**: Adds to revoked list, prevents re-issuing caps, prevents being winner
3. **ParticipantCap Revocation**: Specific cap marked invalid, prevents cap reuse after revocation

### Validation Checks

- Bet/Vault/Poll ID matching at all critical operations
- Revoked capability checks before any privileged operation
- Winner must be an active (non-revoked) participant
- Expired locked bets can be force-dissolved

### Constraints

| Constraint | Value |
|-----------|-------|
| Minimum expiry duration | 1 hour from creation |
| Minimum participants to lock | 2 |
| Maximum references | 20 |
| Maximum witnesses | 10 |
| Max initial witness weight | 100 |
| Max witness weight (after first) | 50% of existing total |
| Witness quorum | 66.66% |
| Minimum deposit | 1000 units |

---

## Complete Bet Lifecycle

1. **Creation**: `create_bet()` creates Bet, Vault, Poll; creator receives CreatorCap, VaultCap, ParticipantCap

2. **Participation**: Participants call `join_bet()` with deposit; receive ParticipantCap; poll.required_participants increments

3. **Leaving** (optional): Participant calls `leave_bet()` while OPEN; withdraws deposits; ParticipantCap returned

4. **Locking**: Creator calls `lock_bet()` (requires ≥2 participants); bet and vault become LOCKED

5. **Witness Setup** (optional): Participants add witnesses via `add_witness()`; witnesses receive WitnessCap

6. **Voting**:
   - Participants vote via `vote()` for a winner
   - Witnesses vote via `witness_vote()` with their weight
   - Resolution triggers when: unanimous participant vote OR 66.66% witness quorum

7. **Resolution**: After poll resolves, `resolve_bet()` sets winner; vault becomes RESOLVED

8. **Payout**: Winner calls `claim_winnings()` for all assets

### Alternative: Expiry/Dissolution

- If bet is OPEN: Creator can `dissolve()` to enable refunds
- If bet is LOCKED and expired: Anyone can `force_dissolve_expired()` to enable refunds
- Participants call `claim_refund()` to retrieve their deposits
