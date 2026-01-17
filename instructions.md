# CLAUDE.md

## Sui Move

### Tool Calling

- `sui move build` compiles packages (run in Move.toml directory)
- `sui move test` runs tests
- Use `--skip-fetch-latest-git-deps` flag after initial successful builds

### Package Manifest

- Requires Move 2024 Edition (`2024.beta` or `2024`)
- Sui, Bridge, MoveStdlib, and SuiSystem are implicitly imported (Sui 1.45+)
- Prefix named addresses with project names to avoid conflicts

### Module & Imports

- Use module label syntax: `module my_package::my_module;` (not block syntax)
- Avoid standalone `{Self}` in use statements
- Group imports with Self: `use path::{Self, Member};`
- Regular constants use `ALL_CAPS`
- Error constants use `#[error]` attribute with `EPascalCase` name and message when inline
- Dedicated error modules (`errors.move`) use `public(package) macro fun` with snake_case names

### Structs

- One-time witness (OTW) structs: all caps, no fields, name matches module (e.g., `public struct LEDGER() has drop;` in `ledger` module)
- Capability structs end with `Cap` suffix
- Avoid "Potato" in type names (implicit for zero-ability structs)
- Events use past tense naming (e.g., `SolanaLinked`, `WalletRegistered`)
- Dynamic field keys are positional with `Key` suffix
- Use positional structs for simple wrappers (e.g., `Token(vector<u8>)`)
- Field ordering: `id: UID` first, then references/IDs, config, state, collections, counters
- Struct instantiations must follow the same field order as the struct definition
- Struct declaration order (by lifecycle and dependency):
  1. OTW (One-Time Witness) - consumed in `init()`
  2. Witness/Marker structs - type-based dispatch markers
  3. Capability structs - grant permissions to manage objects
  4. Keys (positional structs) - dynamic field/table keys
  5. Owned objects - stored in tables/dynamic fields, `has store`
  6. Shared objects - main state containers, `has key`
  7. Data structs - parameters, responses, `has copy, drop`
  8. Event structs - (typically in separate `events.move` files)

### Functions

- Use `public` over `public entry` for composability
- Public functions that mutate state should always take `_ctx: &mut TxContext` for upgrade compatibility
- Parameter ordering (enables readable dot syntax):
  1. Primary object (the subject the method acts on)
  2. Shared objects (mutable before immutable)
  3. Owned objects and capabilities
  4. Structs
  5. Pure values (u8, u64, address, vector<u8>, etc.)
  6. TxContext (always last)
- Use `self` for the module's main object (e.g., `Enclave` in enclave module, `Ledger` in ledger module)
- Use type-prefixed names for other params to disambiguate (e.g., `enclave_config`, `enclave_cap`, not `config`, `cap`)
- Getter methods match field names; mutable versions add `_mut`
- Prefer struct methods over module functions

### Dynamic Fields

- Use `dynamic_field` (df) to store non-objects (structs without `key` ability)
- Use `dynamic_object_field` (dof) to store objects (structs with `key` ability)
- Define aliases for dot syntax: `use fun df::add as UID.df_add;`
- Use dot syntax with aliases: `self.id.df_add(key, value)`, `self.id.dof_borrow_mut(key)`

### Aliases

- Use `use fun` aliases to enable dot syntax for external types
- Local aliases (without `public`) for module-internal use
- Public aliases (`public use fun`) to export dot syntax for external callers
- Example: `use fun my_func as ExternalType.method;` enables `external_val.method()`

### Syntax

- Prefer dot syntax: `self.field`, `ctx.sender()`, `id.delete()`
- Use `coin.split()` method instead of `coin::split()` function
- Access vectors with index syntax: `vec[0]` not `vector::borrow()`
- Use `b"".to_string()` instead of `std::string::utf8`
- Prefer macros over constants
- Prefer `match` over `if-else` chains for value-based branching
- Use literal values in match patterns (macros can't be used in patterns)
- Use constant macros in match arms for return values

### Naming

- Keep names clear, simple, and not verbose
- Domain-standard abbreviations are allowed: `tx` (transaction), `ctx` (context), `id` (identifier), `config` (configuration)
- Remove redundant suffixes when context is obvious (e.g., `link_solana` not `link_solana_address`)
- Use `sender` for `ctx.sender()` consistently
- Use `_bytes` suffix for raw byte vectors (e.g., `address_bytes`)
- Variables should match their type when obvious (e.g., `enclave` not `e`)
- Struct names should be concise (e.g., `Links` not `LinkedAddresses`)
- Field names shouldn't repeat parent context (e.g., `links` not `sui_links` in a Sui module)
- Function names shouldn't repeat module name (e.g., `increment_balance` not `attest_increment_balance` in `attester` module)
- Function prefixes: `new_` for constructors, `pack_` for data structs, `destroy_` for cleanup, `assert_` for validation

### Module Organization

- `*_inner.move` modules contain internal logic only (`public(package)` functions, no `public` API)
- Main module (e.g., `ledger.move`) exposes the public API and delegates to inner modules

### Gas Optimization

- Assert as early as possible in functions to save gas for users on failure

### Code Style

- Comment only functions, struct fields, and complex logic
- Use section separators: `// === Section Name ===`
- File structure: Constants → Errors → Structs → Public Functions → Package Functions → Private Functions → Test Only → Aliases
- Only import necessary items
- Add blank lines between logically distinct statements for readability

### Testing

- Combine `#[test]` and `#[expected_failure(...)]` attributes
- Don't clean up expected_failure tests
- Omit `test_` prefix in testing modules
- Use `assert_eq!` when possible
- Implement "black hole" destroy functions for cleanup

---

## Git Commits

### Format

```
emoji type(scope): subject
```

### Types

- `✨ feat` - New feature
- `🐛 fix` - Bug fix
- `📝 docs` - Documentation only
- `🎨 style` - Code style (formatting, semicolons, etc.)
- `♻️ refactor` - Code change that neither fixes a bug nor adds a feature
- `⚡ perf` - Performance improvement
- `✅ test` - Adding or updating tests
- `📦 build` - Build system or external dependencies
- `👷 ci` - CI configuration
- `🔧 chore` - Other changes (updating dependencies, etc.)
- `⏪ revert` - Revert a previous commit

### Rules

- Subject must be lowercase
- Subject cannot be empty
- Type cannot be empty
- ALWAYS use emoji at the start of commit messages
- Do NOT add "Generated with Claude" or "Co-Authored-By: Claude" to commits

---

## Documentation

### Style

- Clear, concise, human-readable language
- Not verbose - get to the point
- Use tables for structured data (parameters, functions, etc.)
- Use mermaid diagrams over ASCII art for flows and sequences
- Use ASCII only for static hierarchical structures (file trees, data structures)

### Structure

- Start with one-line description
- "How It Works" section with high-level overview
- Mermaid sequence diagrams for multi-step flows
- Tables for API reference (functions, parameters, events)
- Security section for contracts handling assets
- Build/test commands at the end


### Mermaid

- Use `sequenceDiagram` for request/response flows
- Use `stateDiagram-v2` for lifecycle states
- Use `flowchart` for decision trees
- Keep participant names short (2-3 chars)
- Add notes for important context

---

## Workflow

- Make one logical change at a time
- Run typecheck/lint/fmt after each change
- Prefer small, focused commits
- Never mix refactoring with feature changes
- Test behavior, not implementation
- Mock external services in tests