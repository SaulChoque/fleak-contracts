---
applyTo: '**'
---
# Project Context: Fleak (Comprehensive)

## Section 4: Smart Contracts (Foundry)

### 4.1 Core Concept

Smart contracts act as the escrow and immutable rulebook for financial incentives. Contracts are intentionally minimal and rely on a single trusted Oracle address (the backend) to resolve Flakes.

### 4.2 Development environment & target

- Framework: Foundry (Solidity + Forge for tests and scripts)
- Target networks: Base Sepolia (testnet) and Base Mainnet

### 4.3 Architecture & role

Contracts are "dumb": they do not verify evidence themselves — they trust the Oracle address that calls `resolveFlake`.

### 4.4 Key data structures & state

Each Flake is represented off‑chain but referenced on‑chain by an ID. Example Solidity structure (illustrative):

```solidity
struct Flake {
    uint256 flakeId;       // off‑chain ID
    uint256 totalStake;    // total escrowed funds
    address winner;        // eventual payout address
    State state;           // enum { ACTIVE, CLOSED }
    mapping(address => uint256) participants;
}

mapping(uint256 => Flake) public flakes;
```

### 4.5 Roles & permissions

- User: can create/join Flakes and stake funds.
- Owner (deployer): can manage contract settings (Ownable pattern).
- Oracle (critical): single address set in storage — only this address may call `resolveFlake`.

### 4.6 Key functions (concept)

- `createFlake(uint256 _flakeId, ...)` — public, payable: initialize Flake and accept stake.
- `joinFlake(uint256 _flakeId)` — public, payable: add stake to an existing Flake.
- `resolveFlake(uint256 _flakeId, address _winnerAddress)` — external: only callable by Oracle; closes the Flake and transfers funds to the winner.

### 4.7 Integration Guidelines

- **Escrow Lifecycle**
  - Contracts must surface participant stakes and refundable amounts via view functions consumed by `/api/flakes/deposit-status`.
  - Emit granular events (`FlakeCreated`, `StakeAdded`, `FlakeResolved`) so the backend can index state changes without over-polling.

- **Oracle Interaction**
  - Restrict `resolveFlake` to a single `oracle` address; backend should rotate this via an admin function if keys change.
  - Include safeguards for double resolution, e.g., revert if the flake is already closed or if the winning address lacks participants.

- **Funds Management**
  - Track fees or protocol cuts explicitly; emit events detailing distributions so the frontend can show transparent payouts.
  - Support partial withdrawals only when game rules allow; backend should expose these constraints to the Mini-App.

- **Testing & Tooling**
  - Provide Foundry scripts for staging deposits and resolutions to mirror `/api` behavior during integration testing.
  - Maintain deterministic test fixtures so backend developers can run local forks and validate oracle calls end-to-end.

- **Cross-Component Contracts Data Model**
  - Mirror off-chain IDs and states; ensure mappings align with MongoDB schemas (`flakeId`, participant addresses) to avoid reconciliation issues.
  - Document ABI changes promptly and bump versioning so frontend/backend regenerate typed clients (e.g., viem/TypeChain) in lockstep.

---
