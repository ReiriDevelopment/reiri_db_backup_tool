# Issues & Solutions

Bugs discovered during real-device comparison of controller's `meter.db` vs backup tool's `meter.db`.

---

## Issue 1 — Interval boundary record missing from gap-fill

**Symptom**
After a disconnect/reconnect gap, one meter record is missing from the backup even though adjacent records are present. Example: `202606151400` absent while `202606151415` and `202606151430` both exist.

**Root cause**
The controller stores energy data for each 15-minute interval using the **start time** as the record timestamp (e.g., the 14:00–14:15 interval is stamped `202606151400`), but only **pushes it at the end of the interval** (14:15). If the app disconnected at 14:09, it never received the 14:15 push.

When gap-fill runs, it calls `dbBackup(type, from=14:09, to=14:41)`. The controller filters records by `timestamp >= from`, so the `14:00` record is excluded (`14:00 < 14:09`), even though it was never delivered.

**Solution** (`lib/provider/recovery_provider.dart`)
Floor the gap-fill `from` time to the **previous write boundary** for each interval-based DB type before calling `dbBackup`. For meter/optime/ppd (15 min interval): `14:09 → 14:00`. For trend (5 min): equivalent flooring. Records already present in MAIN hit `UNIQUE(date,id)` and are silently ignored by `addMeterData`.

```dart
// _prevBoundary(14:09, 15) → 14:00
static DateTime _prevBoundary(DateTime from, int intervalMin) {
  final minsFromMidnight = from.hour * 60 + from.minute;
  final prevMins = (minsFromMidnight ~/ intervalMin) * intervalMin;
  return DateTime(from.year, from.month, from.day,
      prevMins ~/ 60, prevMins % 60);
}
```

`history.db` (24h conservative threshold) is event-based and excluded from this flooring.

---

## Issue 2 — Wrong surrogate `id` in backup DB after gap recovery

**Symptom**
From the reconnect time onwards (e.g., `202606151445`), the `id` column in the backup `meter.db` is `1` instead of `5`. The `date`, `value`, and `amount` columns are correct.

**Root cause**
The `meter` table (and `trend`, `optime`, `ppd`) does not store the controller's real point identifier directly. It stores a locally-assigned surrogate `db_id` that is assigned incrementally by each database independently via its `point_id` table (string id → integer db_id).

During gap recovery, a brand-new TEMP DB is created with an **empty** `point_id` table. As real-time data arrives, `addRealtimeMeterData` assigns `db_id = 1` to the first meter point it encounters (since TEMP starts with `maxId = 0`). Meanwhile, MAIN's `point_id` table already maps that same physical meter to `db_id = 5` (assigned by the controller's own firmware or the initial backup process).

The old flush (`_flushSingleDb`) did a raw `INSERT OR IGNORE INTO meter SELECT * FROM temp_db.meter`, copying TEMP's rows with `id = 1` into MAIN's `meter` table alongside existing rows with `id = 5`. MAIN's `point_id` table kept `id = 5` (the UNIQUE constraint on the string key rejected TEMP's mapping), but the `meter` data rows now carry an inconsistent `id = 1`.

**Why seeding TEMP's point_id from MAIN at creation does not fully fix this**
Even if TEMP's `point_id` were pre-populated from MAIN, `fillGapInMainDb` writes gap-fill records **directly to MAIN** during the same gap window (before the flush). If a brand-new point appears during this window, MAIN might assign it `db_id = 48` while TEMP — sitting on a stale copy seeded at the start — independently assigns `db_id = 48` to a *different* new point. A plain row-copy flush would then corrupt both, creating two entries sharing the same `db_id`.

**Solution** (`lib/service/recovery_service.dart`)
During flush, instead of copying TEMP rows directly, read each TEMP data row **joined back to TEMP's `point_id`** to recover the original string id, then replay it through `mainDb.addXxxData()`. This function already handles point_id lookup/creation against MAIN's current table (re-read fresh via `initXxxDb()` at flush time, *after* any gap-fill writes). The correct MAIN-side `db_id` is resolved or newly allocated, and TEMP's `point_id` table is never copied directly.

```dart
// Example for meter (optime/ppd/trend follow the same pattern)
SELECT m.date, p.id AS str_id, m.value, m.amount
FROM meter m
JOIN point_id p ON m.id = p.db_id
```

`history.db` is unaffected because its `id` column is already a plain text identifier (not a surrogate key), so the original `INSERT OR IGNORE SELECT *` via ATTACH is kept for it.

---

## Issue 3 — Wrong `amount` for first real-time record after flush

**Symptom**
At the exact time of the scheduled flush (e.g., `202606160300`, 3:00 am), the `amount` in the backup is dramatically wrong: `6.17` instead of `0.16`.

**Root cause**
This is a **direct consequence of Issue 2** (the wrong `id` after flush).

After the old flush, MAIN's `meter` table held two separate `id` streams for the same physical meter:
- `id = 5`: records up to the disconnect time (14:30), value = `8719.64`
- `id = 1`: records from reconnect time onwards (14:45 through 03:00am), value = `8725.65`

When the recovery flow switches back to MAIN after the flush, it calls `initMeterDb()` on MAIN. That function reads the most recent meter records to initialise `meterDb['value']` (the "last known value per db_id" cache). The most recent records for `id = 5` are the pre-gap rows (last value `8719.64`), because all newer real-time data was stored under `id = 1`.

When the first real-time push after the switch arrives (value `8725.81`), `addRealtimeMeterData` looks up the string id → `db_id = 5` (correct from MAIN's `point_id`) and computes:

```
amount = 8725.81 - meterDb['value']['5']
       = 8725.81 - 8719.64          ← stale pre-gap value
       = 6.17                        ← wrong
```

**Solution**
Fixed automatically by solving Issue 2. Once all TEMP records are flushed under `id = 5`, `initMeterDb()` after the flush sees the full chronological sequence as `id = 5`, sets `meterDb['value']['5'] = 8725.65` (the actual most recent value), and the first post-flush real-time amount computes correctly as `8725.81 - 8725.65 = 0.16`.

---

## Affected files

| File | Change |
|---|---|
| `lib/provider/recovery_provider.dart` | Floor gap-fill `from` to previous interval boundary (`_prevBoundary`); also keep `dbFile` reference in `ranges` map |
| `lib/service/recovery_service.dart` | Replace raw `INSERT OR IGNORE SELECT *` flush with point_id-aware replay via `addXxxData`; keep `_flushHistoryDb` for history.db |
