# PMData ETL — Athlete Training Load & Injury Risk

A SQL-first analytics pipeline modeling athlete training load and injury risk
(acute:chronic workload ratio), built on the PMData sports-science dataset —
combining public research data with my own experience training competitively.

The emphasis of this project is **schema design and defensible data-modeling
decisions**, not dashboards. The notebook documents the reasoning behind each
decision, including the alternatives that were rejected and why.

---

## What it does

Sixteen athletes' self-reported wellness, training-load and injury data arrive as
per-athlete CSV folders. The pipeline extracts them, resolves several grain and
vocabulary problems, and loads a normalized MySQL schema that supports
Acute:Chronic Workload Ratio (ACWR) analysis against injury reports.

| Table | Rows | Grain |
|---|---|---|
| `athlete` | 16 | one row per athlete (dimension) |
| `body_part` | 7 | one row per SNOMED CT body-region code (lookup) |
| `injuries` | 111 | one row per injured body part per report |
| `wellness` | 1,745 | one row per wellness submission (timestamp) |
| `soreness_report` | 891 | one row per soreness code per wellness submission |
| `training_session` | 772 | one row per training session |
| `session_activity` | 841 | one row per activity type per session |

---

## Architecture

Four artifacts with separate responsibilities:

- **`schema.sql`** owns structure. Drop-then-recreate, run in MySQL Workbench.
- **`etl.ipynb`** owns data. Extract → Transform → Load, run top to bottom.
- **`validation.sql`** asserts. Runs after every rebuild; every check has an
  expected result and a non-zero is a defect.
- **`exploration.sql`** explores. One-off analyses behind specific design
  decisions. No expected results — output is a finding, not a pass/fail.

That last split is deliberate. `validation.sql` is only useful if every annotated
zero in it is a verified claim, so queries with no expected result live elsewhere.

The notebook is deliberately *not* self-sufficient for re-runs. It loads with
`if_exists="append"`, so re-running it against a populated database raises a
primary-key violation — by design. Structure and data stay separately owned, and
the schema file is what makes the pair reproducible.

### Running it

```bash
pip install -r requirements.txt
```

1. Create a `.env` file in the repo root:
   ```
   MYSQL_PASSWORD=your_password
   ```
2. Place the PMData dataset at `data/pmdata/` (not committed — see *Data*).
3. Run `schema.sql` in MySQL Workbench (Ctrl+Shift+Enter runs the whole script).
4. Restart & Run All in `etl.ipynb`.
5. Run `validation.sql` in Workbench.

Steps 3 and 4 must happen in that order. Repeat both to rebuild from scratch.

---

## Design decisions

The full reasoning is in the notebook's markdown cells. The decisions that most
shaped the schema:

**Report grain, not aggregated grain.** Wellness and injury reports are stored at
the timestamp they were submitted, not collapsed to a date. Collapsing at load
manufactures false duplicates for athletes who submitted twice in one day, and
throws away information that can't be recovered. Daily aggregation belongs in a
downstream SQL view, so cleaning stays reversible.

**Keep rows that carry information; drop rows that carry none.** An injury report
of `{}` means "checked in, reported no injury" — that is a signal, so those rows
are kept. Wellness submissions of all zeros and training entries with an empty
activity list *and* null RPE *and* null duration are empty form submissions, so
they are dropped (11 srpe rows, 2 wellness rows).

**Zeros are preserved, not interpreted.** A wellness submission with a lone zero
in one field is a real report with one unlogged value. Those zeros are stored as
`0` rather than converted to `NULL`: the pipeline preserves the source's sentinel
rather than reinterpreting it. The consequence is that the database cannot
distinguish an unlogged field from a genuine score, so any `AVG()` over the
five-point scales is dragged toward zero. Downstream aggregation needs to exclude
zeros explicitly.

**Surrogate integer primary keys, natural keys as `UNIQUE` constraints.** Every
fact gets an integer surrogate; the natural key that defines its grain is enforced
as a `UNIQUE` constraint rather than used as the PK. This keeps joins narrow while
still documenting — and enforcing — what makes a row unique. Because those
constraints are declared, a successful load *is* the uniqueness verification:
a duplicate would have raised at insert rather than passing a separate check.

**Child tables inherit their parent's key rather than recomputing one.**
`soreness_report` explodes a repeating group from `wellness`, so it reads
`wellness_id` directly off the parent row it came from. Referential integrity then
holds by construction rather than by two independent numberings happening to
agree. `session_activity` originally used a parallel numbering and was refactored
to match — nothing was broken, but its correctness depended on two loops staying
in the same order, which is a coincidence rather than a guarantee.

**`body_part` uses a natural key, and no surrogate.** SNOMED CT codes are assigned
by an external standards body, globally unique and never reissued. Adding a
surrogate on top would introduce a layer with no benefit and discard the property
that makes the code valuable — that it means the same thing outside this database.

**The two body-part vocabularies are intentionally separate.** `injuries.injury_area`
holds lateralized strings from the injury form (`right_knee`); `soreness_report`
holds SNOMED integer codes from the wellness form. Different source files,
different vocabularies, different granularity. Merging them would fabricate a
correspondence the source data does not contain.

**Key generation belongs to the transform layer.** All surrogate keys are assigned
in pandas before load, because the `source_id → athlete_id` bridge has to exist
before any fact can reference an athlete. `AUTO_INCREMENT` is therefore absent from
the schema: it would declare that MySQL owns key generation when it does not.

**Timestamp precision is reduced deliberately.** Source timestamps are timezone-aware
UTC with millisecond precision. Since the dataset is uniformly UTC the offset carries
no information, and milliseconds on a self-reported form are noise. Timestamps are
floored to whole seconds and localized to naive UTC *in pandas*, so the notebook's
frames match what lands in MySQL rather than letting the database truncate silently.
The natural keys hold at the reduced precision, which the load's success confirms.

---

## ACWR layer

> **Status: design decisions taken, implementation pending.** This section records
> the decisions and the evidence behind them. Update when the layer is built.

ACWR divides a 7-day acute load (fatigue proxy) by a 28-day chronic load expressed
as average weekly load (fitness proxy). Session load is session-RPE — RPE ×
duration, an *internal* load measure — materialized at transform because it is the
primitive every window query sums over.

**Chronic load is a 28-day mean scaled to a week, not a 28-day sum.** Numerator and
denominator have to be commensurate per-week quantities or the ratio's scale is
meaningless; a raw 28-day sum puts ratios near 0.25 and the published reference
bands no longer apply.

**ACWR is a property of a calendar day, not of a session.** ACWR is designed as a
monitoring signal — something read on a given day to inform a decision about that
day — so the output grain is one row per (athlete, calendar day). This is the first
point in the project where timestamps collapse to dates, which is exactly where the
report-grain decision said that collapse belonged. Athletes log up to two sessions
in a day, so the daily aggregation is load-bearing rather than a pass-through.

**A date spine fills non-training days.** Athletes don't train daily, so a row-based
window frame would let a 7-row window span three weeks. A per-athlete date spine
makes rows and calendar days 1:1. `RANGE BETWEEN INTERVAL 6 DAY PRECEDING` is used
anyway rather than `ROWS`: with a complete spine the two are equivalent, but `RANGE`
states the intent and stays correct if the spine ever has a gap.

**Spine bounds are per-athlete, not global.** Each athlete's spine runs from their
first to their last logged session. This was the layer's central decision, and it was
taken on evidence (`exploration.sql`):

- No athlete with injury reports lacks a session range, so there is no athlete for
  whom a spine cannot be built.
- Only three injury check-ins precede an athlete's first session, by 1–6 days, and
  all fall inside the warmup window where ACWR is `NULL` regardless.
- Only one athlete (5) reports injuries after their last session: five check-ins
  across 33 days, eight injury rows.
- Two athletes logged 2 and 3 sessions respectively across the five-month window
  while logging wellness throughout. Their non-training days are not evidenced as
  rest — the more likely reading is that they used one form and not the other.

The trade is between two kinds of error. Per-athlete bounds produce **missing** ACWR
values for athlete 5's five check-ins, and missing is visible: the join returns
nothing and the gap can be stated. Global bounds would cover those five but
manufacture roughly 180 athlete-days of zero-load spine for the two sparse loggers,
producing a ratio that decays to zero and reads as real detraining when it reflects
form usage. That error is silent, which is the failure mode this layer is most
exposed to. Per-athlete bounds also match the construct: ACWR is always relative to
an athlete's own chronic baseline, never to the cohort, so a per-athlete date axis
is consistent with the measure rather than merely convenient.

p16 produces no ACWR rows at all, having no sessions.

**Verification is by hand-computed expected values.** Window functions fail quietly:
a wrong frame boundary produces plausible numbers and no constraint catches it. Acute
and chronic are checked against manual computations for specific athlete-days rather
than by inspecting output.

### What this analysis can and cannot show

The injury join is a **demonstration of method, not a finding**. Sixteen recreational
athletes, 772 sessions, injuries for nine, self-labeled severity, one collection
window. That is not enough to test an injury-risk hypothesis, and any correlation
found would be uninterpretable. Published ACWR work uses squad-seasons of monitored
professional athletes.

ACWR itself is contested. The 7 acute days sit inside the 28 chronic days, so the
numerator is a component of the denominator — a coupling that generates correlation
structure independent of any biological effect. The ratio also discards what its two
components say separately: 300→450 AU and 3000→4500 AU give the same 1.5 and describe
entirely different situations. Consensus moved against ACWR as a standalone decision
tool. It is implemented here as the analytical target the schema was built to support,
not as a claim about these athletes.

---

## Validation

`validation.sql` covers five categories:

- **Row counts** per table, confirming MySQL agrees with the notebook.
- **Orphan checks** across all six foreign-key relationships, plus the inverse —
  childless parents. The orphan direction *confirms* rather than discovers: the FKs
  reject orphans at insert, so zero is the only possible result. The childless-parent
  direction can genuinely return rows, and does (session 528; 1,370 wellness reports
  with no soreness codes). Together they show both sides of every relationship were
  considered, not just the constraint.
- **Null audits** on all 18 nullable columns. Unlike the orphan checks these can
  genuinely fail, since nothing in the schema forces those columns to be populated.
  `soreness_report` and `session_activity` have no nullable columns, so coverage is
  complete rather than partial.
- **Distribution checks** — activities per session, soreness codes per report,
  records per athlete, sessions per athlete-day. These catch shape problems that
  constraints cannot: a session with an implausible number of activities satisfies
  every key while still indicating a parse error.
- **Domain integrity** — the paper's scale definitions and the one derived column.
  The schema stores the wellness scales as bare `int` and enforces none of the
  source's ranges, and nothing enforces that `session_load` equals `rpe ×
  duration_min`. These are the checks most able to fail, and the `session_load`
  check in particular guards the exact primitive the ACWR windows sum over.

The file opens with `SELECT @@sql_mode;` because several arguments in it rest on the
load having succeeded. That reasoning holds for the `UNIQUE` constraints
unconditionally, but for the enum columns it depends on strict mode being active —
in non-strict mode an out-of-domain enum value inserts as `''` rather than raising.

Two independent derivations agree. The soreness-code distribution derived in SQL
reproduces the distribution computed in pandas before the explode (98/133/88/33/12/6/5),
which sums to 375 reports and 891 codes; 1,745 wellness rows minus 1,370 childless rows
equals the same 375. The activity distribution reconciles the same way: 705 + 62 + 4
= 771 sessions with activities, which is 772 minus the one childless session, and
705 + 124 + 12 = 841 activity rows.

---

## Known limitations

These are properties of the source data, not pipeline defects — but they constrain
what can be concluded from it:

- **Training-session participation is extremely uneven.** Session counts range from
  **2 to 113** per athlete across the same five-month window — a 50× spread. Two
  athletes (3 and 9) logged 2 and 3 sessions respectively while continuing to submit
  wellness reports for a further 91 and 79 days. Those are almost certainly not
  complete training records, and any ACWR computed for them describes form usage
  rather than training. This is the limitation that bears most directly on the
  analytical layer.
- **Injury data exists for only 9 of 16 athletes.** ACWR-to-injury correlation is
  computable for that subset only. p08 has no `injury.csv` at all.
- **Five injury check-ins fall outside the ACWR spine.** Athlete 5 reported injuries
  from 1 to 33 days after their last logged session. Under per-athlete spine bounds
  those reports have no ACWR row to join to and are excluded from the correlation.
  This is a consequence of a deliberate decision, documented above, not an oversight.
- **p16 has no training sessions.** All 11 of its srpe entries were empty
  submissions, dropped in transform (verified against the raw file by timestamp).
  p16 therefore appears in no session-based output at all, including the ACWR layer.
- **Soreness is sparse.** 1,370 of 1,745 wellness submissions report no soreness,
  so per-body-part analysis works with roughly 21% of reports.
- **Wellness participation is uneven**, ranging from 72 to 147 reports per athlete.
  Cross-athlete comparison needs normalizing.
- **Lone zeros are indistinguishable from scores.** Preserved rather than converted
  to `NULL` (see *Design decisions*), so aggregates over the five-point scales must
  exclude them explicitly.
- **SNOMED code names were hand-mapped** from the SNOMED CT browser. I could not
  locate the wellness form's code vocabulary documented in the PMData paper. A
  left/right mislabeling would be silent — nothing in the pipeline can detect it.
- **The soreness vocabulary mixes lateralized and unlateralized concepts** (left/right
  lower leg and upper arm, but undifferentiated pelvis, torso and head). Joining
  soreness to injury by body part requires an explicit granularity decision.
- **One training session (528) has no recorded activity type.** A legitimate
  childless parent: the session load is intact, only the activity label is missing.
- **Internal load only.** Session-RPE is subjective and single-dimensional, and an
  athlete's internal scale can drift over a five-month window. There is no external
  workload measure (distance, power) in this dataset to corroborate it.

---

## Data

The PMData dataset is not committed to this repository. It is available from the
original authors (Thambawita et al., *PMData: A Sports Logging Dataset*, MMSys '20).
Expected layout:

```
data/pmdata/
  participant-overview.xlsx
  p01/pmsys/{srpe.csv, wellness.csv, injury.csv}
  p02/pmsys/...
  ...
  p16/pmsys/...
```

`.env` and `data/` are both gitignored.

---

## Next steps

- Implement the ACWR layer as views: daily load aggregation → per-athlete date spine
  → rolling acute and chronic windows → ratio
- Decide whether athletes below a minimum session count are excluded from the ACWR
  layer or included and flagged
- Decide whether the chronic window's first 27 days return `NULL` or a partial value
- Injury correlation against ACWR spikes for the 9-athlete subset
- Daily-grain wellness view, aggregating the report-grain base tables
