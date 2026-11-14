# SQLite write boundaries

Use this when a SQLite-backed operation reads a decision and then writes its outcome.

- Distinguish a top-level write from a nested write. A deferred savepoint provides rollback, not an up-front writer reservation.
- For a standalone read/decide/write worker, acquire an immediate transaction before reading the deciding rows. Otherwise two WAL readers can observe the same work and one can fail when upgrading its stale snapshot to a writer.
- Keep nested writes inside the caller's transaction with savepoints. Do not introduce an unconditional `BEGIN IMMEDIATE` into a reusable handler that may already run inside an outer mutation.
- Keep domain decisions in application/domain code. Let storage own the transaction and supply fresh facts to that decision before persisting its result.
- Record the aggregate, generated identity, counters, lineage, attention signal, and audit receipt in the same transaction. Publish live events only after commit.
- Capture an inserted aggregate's ID immediately. Later inserts into lineage, audit, or signal tables change `last_insert_rowid()`; reading it later can associate the wrong aggregate with the result.
- Preserve append-only custody against `UPDATE`, `DELETE`, and `INSERT OR REPLACE`. An update trigger alone does not stop replacement's implicit delete.

## Behavioral verification

1. Use two independent database connections, synchronize competing workers, and prove that exactly one owns the window. Check the losing worker's result, not only the absence of duplicate rows.
2. Inject a failure at the final receipt write. Verify rollback of every affected table and counter, then retry successfully.
3. Use fixtures whose template, schedule, and generated occurrence have different IDs. Equal fixture IDs hide identity-association mistakes.
4. Recheck guards at enqueue, claim, and the pre-effect reservation when state can change between those boundaries.
