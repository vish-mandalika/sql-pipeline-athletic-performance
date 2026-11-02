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

Two views sit on top:

| View | Grain |
|---|---|
| `daily_load` | 719 | one row per athlete per *training* day |
| `acwr_daily` | 1,737 | one row per athlete per *calendar* day on their spine |

---

## Architecture

Five artifacts with separate responsibilities:

- **`schema.sql`** owns structure. Drop-then-recreate, run in MySQL Workbench.
- **`etl.ipynb`** owns data. Extract → Transform → Load, run top to bottom.
- **`validation.sql`** asserts. Runs after every rebuild; every check has an
  expected result and a non-zero is a defect.
- **`exploration.sql`** explores. One-off analyses behind specific design
  decisions. No expected results — output is a finding, not a pass/fail.
- **`acwr.sql`** analyzes. Builds the two views, verifies them, and runs the
  injury join.

The validation/exploration split is deliberate. `validation.sql` is only useful if
every annotated zero in it is a verified claim, so queries with no expected result
live elsewhere.

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
6. Run `acwr.sql` in Workbench.

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

ACWR divides a 7-day acute load (fatigue proxy) by a 28-day chronic load expressed
as average weekly load (fitness proxy). Session load is session-RPE — RPE ×
duration, an *internal* load measure — materialized at transform because it is the
primitive every window query sums over.

**Chronic load is a 28-day mean scaled to a week, not a 28-day sum.** Numerator and
denominator have to be commensurate per-week quantities or the ratio's scale is
meaningless; a raw 28-day sum puts ratios near 0.25 and the published reference
bands no longer apply. In practice this collapses to the 28-day total ÷ 4.

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
  all fall inside the warmup window.
- Only one athlete (5) reports injuries after their last session: five check-ins
  across 33 days, five injury rows.
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

### Two rules qualify the ratio

Both are named in `acwr_daily.acwr_status`. A bare `NULL` would conflate them, and
the rules' own inputs (`sessions_in_chronic_window`, `days_since_spine_start`) are
exposed alongside it so a reader can recompute either condition without reading the
SQL.

- `sparse_window` — fewer than **4 sessions** in the 28-day frame. The ratio is
  `NULL`. The threshold comes from the construct rather than from this dataset: a
  four-week average should rest on at least one session per week it averages. It
  happens to fall in a clean empirical gap too — three athletes train at 0.5–0.6
  sessions/week and the rest at 1.8–5.6 — but the rule does not depend on that.
- `partial_window` — fewer than 28 calendar days of spine history. The ratio is
  **computed and marked**, not hidden. It remains dimensionally valid (both sides
  are still per-week) but rests on a shorter baseline. Marking rather than nulling
  follows the same principle as the injury `{}` rows: keep the information, make the
  judgment explicit downstream.

The guard is row-level rather than athlete-level by design. Sparsity is a property of
each 28-day window, not of an athlete — a dense athlete with a three-week gap has the
same unreliable denominator for those rows. An athlete-level cutoff would miss that,
and would be a statement about which athletes to include rather than about when a
baseline is estimable.

Precedence is declared rather than left to evaluation order: `sparse_window` ranks
first, because it says the baseline is not estimable at all where `partial_window`
only says it is short.

### Status distribution

Across 1,737 athlete-days:

| Status | Days | Share |
|---|---|---|
| `ok` | 1,160 | 66.8% |
| `partial_window` | 216 | 12.4% |
| `sparse_window` | 361 | 20.8% |

**A fifth of the series carries no ratio.** That is a finding about the dataset, not
a defect: this data is too sparse to support ACWR on a sizeable minority of days.
Three athletes account for most of it — athlete 13 is `sparse_window` on 128 of 129
days, athlete 9 on all 40, athlete 3 on all 7.

### Verification

Window functions fail quietly: a wrong frame boundary produces plausible numbers and
no constraint catches it.

**Reconciliations.** Row count equals the sum of per-athlete spine lengths (1,737).
`SUM(daily_load)` across the spine equals `SUM(session_load)` in `training_session`
(272,220 both sides), so the spine join neither lost nor duplicated rows.
`SUM(session_count)` equals 772.

**Hand computations**, each chosen for a different boundary:

| Athlete-day | Tests | Result |
|---|---|---|
| 13, 2020-03-18 | guard at its threshold (exactly 4 sessions); current row included in both frames | 0.875 ✓ |
| 4, 2019-11-28 | far boundary (a session at exactly 27 days back, correctly in); `partial_window` → `ok` transition; future sessions excluded | 1.030 ✓ |
| 5, 2020-01-15 | day after a 10-day gap, where `ROWS` and `RANGE` diverge most | 0.652 ✓ |

Two further boundary tests come from the series itself rather than a separate query.
Athlete 4's 540-load session on 2019-12-14 leaves the acute frame on 2019-12-21
(acute drops 1,180 → 640) and leaves the chronic frame on 2020-01-11 (chronic drops
1,065.00 → 930.00, a fall of 135, which is 540 ÷ 4). Both land exactly where the
frame definitions say they should.

A guard that cannot fire would look identical to a clean result, so
`MIN(sessions_in_chronic_window)` is checked explicitly. It returns 0, confirming the
guard sums carried session counts rather than counting spine rows.

---

## Injury correlation

**This is a demonstration of method, not a finding.** The numbers below are reported
because showing the join's yield and its result is more honest than reporting only
that a join exists.

### Join yield

| | Count |
|---|---|
| Injury rows | 111 |
| → on an athlete's spine | 103 |
| → with a non-null ACWR | 83 |
| Injury check-ins | 77 |
| → with a non-null ACWR | 55 (71%) |

Both losses trace to documented decisions. Eight rows fall off the spine entirely:
five of athlete 5's trailing reports and three leading-edge reports. A further twenty
land on the spine but in a `sparse_window`. Nothing is lost for an unexplained reason.

All nine injury-reporting athletes retain usable `ok` days, so the subset survives
intact — the sparse loggers the guard was built for are not among them. The rule that
excludes the most data excludes almost none of the data this analysis uses.

### Result

Comparing the 1,376 athlete-days where ACWR exists, split by whether an injury was
reported that day:

| | Athlete-days | Mean ACWR | Days > 1.5 | Mean acute | Mean chronic |
|---|---|---|---|---|---|
| No injury report | 1,323 | 0.985 | 168 (12.7%) | 1,286.4 | 1,306.0 |
| Injury report | 53 | 0.890 | 8 (15.1%) | 1,127.5 | 1,361.1 |

Acute and chronic are reported separately as well as the ratio, because the ratio
discards what its components say apart: 300→450 AU and 3,000→4,500 AU both give 1.5
and describe entirely different situations.

### Interpretation

**The direction is opposite to the ACWR hypothesis.** Injury-report days show *lower*
acute load, *higher* chronic load and a *lower* mean ratio than other days. Nothing
here supports spike-associated injury risk, and the 15.1% vs 12.7% figure above 1.5
turns on eight days against 168 — a single day moves it nearly two points.

Three reasons not to read anything into it, in order of weight:

1. **The join is same-day, and the construct is not.** Published ACWR work looks at
   load in the days *preceding* an injury. An injury reported on day X often follows
   reduced or ceased training, so acute load is already depressed by the time the
   report lands. This join measures the consequence, not the antecedent. That alone
   is enough to explain the direction.
2. **n = 53, and it is dominated by one athlete.** Athlete 12 contributes 48 of 77
   check-ins and 77 of 111 injury rows — 69% of the injury data in the dataset. Most
   of what the table above compares is one person's reporting behaviour. Athlete 12
   also reports ~1.6 body parts per check-in where most athletes report one, which is
   a difference in form usage rather than necessarily in injury rate.
3. **Severity is self-labeled** on a two-value scale, with no clinical definition and
   no way to distinguish a niggle from a layoff.

So the result is neither evidence against ACWR nor evidence for it. It is evidence
that a same-day join answers a different question than the construct asks. The
correct design — computing ACWR over the window preceding each report — is a next
step, not something this layer claims to have done.

### What this analysis can and cannot show

Sixteen recreational athletes, 772 sessions, injuries for nine, self-labeled severity,
one collection window. That is not enough to test an injury-risk hypothesis, and any
correlation found would be uninterpretable. Published ACWR work uses squad-seasons of
monitored professional athletes.

ACWR itself is contested. The 7 acute days sit inside the 28 chronic days, so the
numerator is a component of the denominator — a coupling that generates correlation
structure independent of any biological effect. The ratio also discards what its two
components say separately. Consensus moved against ACWR as a standalone decision
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
  complete training records. This is the limitation that bears most directly on the
  analytical layer: it is why the sparse-window guard exists, and why 20.8% of
  athlete-days carry no ratio.
- **Injury reporting is dominated by one athlete.** Athlete 12 accounts for 69% of
  injury rows and 62% of check-ins. Any cohort-level injury statistic is largely a
  statement about that one participant.
- **Injury data exists for only 9 of 16 athletes.** p08 has no `injury.csv` at all.
- **Only 71% of injury check-ins reach a usable ACWR value.** Eight injury rows fall
  outside the spine (five of athlete 5's trailing reports, three leading-edge) and a
  further twenty sit in a `sparse_window`. Both are consequences of deliberate
  decisions documented above, not oversights.
- **The injury join is same-day.** ACWR is matched to the day a report was submitted,
  not to the window preceding it. This is the wrong direction for the construct and
  is the most likely explanation for the result reported above. Correcting it is a
  next step.
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

- Lag the injury join: compute ACWR over the window *preceding* each report rather
  than on the report date, which is what the construct actually describes
- Report the injury comparison with athlete 12 excluded, to show how much of it is
  one participant
- Uncoupled ACWR (7-day acute against the prior 21 days) as a check on the
  mathematical coupling between numerator and denominator
- Daily-grain wellness view, aggregating the report-grain base tables
- Join soreness to injury by body part, once the lateralization granularity decision
  is made
