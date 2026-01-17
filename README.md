# Terminal: Decentralized Betting Platform for Sui

Terminal enables trustless peer-to-peer betting on Sui with built-in dispute resolution through participant consensus and weighted witness voting.

## Core Mechanism

The protocol operates on a capability-based access model: users create bets with specific terms, deposit assets into a shared vault, and resolve outcomes through voting. As the system enforces, "Resolution requires either unanimous participant agreement or 66.66% witness quorum."

The platform employs a 4-module architecture where bets manage participants, vaults hold assets, polls handle voting, and the terminal module orchestrates all operations with security validations.

## How It Works

1. **Create**: A user creates a bet with terms, expiry, and allowed participants. The system generates a linked Bet, Vault, and Poll.

2. **Join**: Whitelisted participants join by depositing coins or NFTs into the vault. Each receives a ParticipantCap proving membership.

3. **Lock**: Once ≥2 participants have joined, the creator locks the bet. No more joins or leaves allowed.

4. **Vote**: Participants vote for a winner. Optionally, witnesses (weighted voters) can also vote. Resolution triggers on unanimous participant vote or 66.66% witness quorum.

5. **Claim**: The winner claims all assets from the vault. If the bet expires or is dissolved, participants claim refunds instead.

## Technical Stack

```
terminal/
├── sources/
│   ├── bet.move      # Participant management, status tracking, capabilities
│   ├── vault.move    # Asset custody, deposits, claims, refunds
│   ├── poll.move     # Voting logic, witness management, quorum calculation
│   └── terminal.move # Orchestration, security validations, lifecycle management
```

### Modules

- **Bet (Move)**: Manages participant registry, bet status (OPEN → LOCKED → RESOLVED/DISSOLVED), allowed list, and capability issuance
- **Vault (Move)**: Handles coin and NFT deposits, maintains deposit registry, processes winner payouts and participant refunds
- **Poll (Move)**: Tracks participant votes (unanimous) and witness votes (66.66% quorum), locks witness weights to prevent manipulation
- **Terminal (Move)**: Coordinates all modules, enforces cross-module validations, manages complete bet lifecycle

## Capabilities

The system uses four capability types for access control:

| Capability | Issued To | Powers |
|-----------|-----------|--------|
| `CreatorCap` | Bet creator | Edit terms, lock/dissolve bet, manage participants, issue caps |
| `ParticipantCap` | Participants | Prove membership, vote, leave bet |
| `VaultCap` | Bet creator | Lock vault, set winner, enable refunds, issue caps |
| `WitnessCap` | Witnesses | Cast weighted vote, veto |

## Status Flows

**Bet Status**
```
OPEN (0) → LOCKED (1) → RESOLVED (2)
                     ↘ DISSOLVED (3)
```

**Vault Status**
```
OPEN (0) → LOCKED (1) → RESOLVED (2)  [winner takes all]
                     ↘ DISBURSED (3)  [refunds]
```

## Getting Started

### Prerequisites

- [Sui CLI](https://docs.sui.io/build/install) >= 1.0.0
- Move compiler

### Build

```bash
sui move build
```

### Test

```bash
sui move test
```

### Deploy

```bash
sui client publish --gas-budget 100000000
```

## Key Functions

### Creating a Bet

```move
terminal::create_bet(
    terms: String,
    expiry: u64,
    allowed: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext
): (Bet, Vault, Poll, CreatorCap, VaultCap, ParticipantCap)
```

### Joining a Bet

```move
terminal::join_bet<T>(
    bet: &mut Bet,
    vault: &mut Vault,
    poll: &mut Poll,
    coin: Coin<T>,
    ctx: &mut TxContext
): ParticipantCap
```

### Voting

```move
terminal::vote(
    bet: &Bet,
    poll: &mut Poll,
    outcome: address,
    ctx: &TxContext
)
```

### Resolution

```move
terminal::resolve_bet(
    bet: &mut Bet,
    poll: &Poll,
    vault: &mut Vault,
    cap: &VaultCap
)
```

### Claiming Winnings

```move
vault::claim_winnings<T>(
    vault: &mut Vault,
    ctx: &TxContext
): Coin<T>
```

## Constraints

| Parameter | Value |
|-----------|-------|
| Minimum expiry duration | 1 hour |
| Minimum participants to lock | 2 |
| Maximum references | 20 |
| Maximum witnesses | 10 |
| Maximum initial witness weight | 100 |
| Maximum witness weight (subsequent) | 50% of total |
| Witness quorum threshold | 66.66% |
| Minimum coin deposit | 1000 units |

## Security Features

- **Capability-based access**: All privileged operations require valid capabilities
- **Three-tier revocation**: CreatorCap, participant, and ParticipantCap revocation for soft-bans
- **Cross-module validation**: Bet/Vault/Poll ID matching enforced at all critical operations
- **Weight locking**: First witness vote locks total weight to prevent quorum manipulation
- **Expiry enforcement**: Locked expired bets can be force-dissolved for refunds

## Important Notes

- This is experimental software. Use at your own risk.
- Capabilities are transferable (`key, store`). Losing a capability means losing associated permissions.
- Winners must be active (non-revoked) participants.
- All claims are per-asset-type (coins and NFTs claimed separately).

## License

MIT
