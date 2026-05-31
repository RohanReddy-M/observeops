# ADR-003: DynamoDB Instead of RDS (PostgreSQL/MySQL)

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

SecureShip needs persistent storage for ship records. We chose the database based on access patterns, operational overhead, and cost — not familiarity.

## Decision

Use DynamoDB with PAY_PER_REQUEST billing for ship data storage.

## Rationale

**Start with the access pattern, not the database:**

A common mistake is picking a database and then fitting the data model to it. The right approach is: define the access patterns first, then pick the database that serves them best.

Our access patterns for ship data:
1. `GET /api/v1/ships/{ship_id}` — lookup by ID → key-value access
2. `GET /api/v1/ships` — list all ships (with pagination) → scan with filter
3. `POST /api/v1/ships` — create a ship → single-item write

This is a simple key-value pattern. No joins. No complex queries. No aggregations. No transactions across multiple records.

**DynamoDB advantages for this pattern:**

1. **Single-digit millisecond reads**: DynamoDB is designed for key-value lookups. A `GetItem` by `ship_id` is consistently <5ms from the same region.

2. **Zero operational overhead**: No patching, no connection pool management, no storage provisioning, no backup schedule. AWS handles everything.

3. **PAY_PER_REQUEST billing**: We pay per API call, not for idle capacity. At our scale (demo usage, maybe 100 requests/day), the cost is effectively zero ($0.25 per million reads).

4. **No connection pool exhaustion**: RDS has a connection limit (PostgreSQL on a t3.micro allows ~100 connections). Under a traffic spike, your application can exhaust the connection pool and start failing. DynamoDB has no such limit.

5. **PITR built-in**: Point-in-time recovery to any second in the last 35 days is one Terraform setting. RDS requires configuring automated backups, retention periods, and snapshot copies separately.

**Why not RDS:**

RDS (PostgreSQL/MySQL) would be correct if:
- We needed complex joins (e.g., ships + cargo manifests + crew records with foreign keys)
- We needed ACID transactions across multiple records
- We needed full-text search
- We needed complex analytical queries

None of these apply to a simple ship registry with CRUD operations.

Running PostgreSQL on t3.micro also means:
- Managing the database engine version and patching
- Managing connection pool (PgBouncer or similar)
- Paying for storage provisioning even when idle
- Setting up Multi-AZ for HA (costs 2x)

**Billing mode choice — PAY_PER_REQUEST:**

We chose on-demand billing over provisioned capacity because:
- Our load is unpredictable (demo project with no sustained traffic)
- Provisioned capacity requires upfront capacity planning — you guess wrong and either over-provision (waste money) or under-provision (throttling)
- PAY_PER_REQUEST auto-scales to any load instantly with no warmup

## Consequences

**Positive:**
- No operational overhead
- No connection pool management
- Scales to any load automatically
- PITR included
- Encryption at rest included

**Negative:**
- No SQL — queries that are trivial in SQL require careful DynamoDB modeling
- No complex joins — if schema evolves to require them, migration is non-trivial
- Local development requires DynamoDB Local or the in-memory fallback (which we've implemented)

## The Interview Answer

"We chose DynamoDB because our access pattern is simple key-value lookups by ship_id — exactly what DynamoDB is optimized for. There are no joins, no complex queries, no transactions across records. The key design principle was: define access patterns first, then choose the database. For a ship registry doing CRUD by primary key, DynamoDB gives us single-digit millisecond reads, zero operational overhead, and automatic scaling with no connection pool to manage. If we needed complex reporting or cross-record transactions, we'd use PostgreSQL instead."
