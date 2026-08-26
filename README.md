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

Two artifacts with separate responsibilities:

- **`schema.sql`** owns structure. Drop-then-recreate, run in MySQL Workbench.
- **`etl.ipynb`** owns data. Extract → Transform → Load, run top to bottom.
- **`validation.sql`** verifies the result after loading.

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

**Surrogate integer primary keys, natural keys as `UNIQUE` constraints.** Every
fact gets an integer surrogate; the natural key that defines its grain is enforced
as a `UNIQUE` constraint rather than used as the PK. This keeps joins narrow while
still documenting — and enforcing — what makes a row unique.

**Child tables inherit their parent's key rather than recomputing one.**
`soreness_report` explodes a repeating group from `wellness`, so it reads
`wellness_id` directly off the parent row it came from. Referential integrity then
holds by construction rather than by two independent numberings happening to
agree.

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
Both natural keys were re-verified as unique at the reduced precision.

---

## Validation

`validation.sql` covers four categories:

- **Row counts** per table, confirming MySQL agrees with the notebook.
- **Orphan checks** across all six foreign-key relationships. These *confirm*
  rather than discover: the FKs reject orphans at insert, so zero is the only
  possible result. The queries demonstrate the constraints are declared and holding.
- **Null audits** on every nullable column. Unlike the orphan checks these can
  genuinely fail, since nothing in the schema forces those columns to be populated.
- **Distribution checks** — activities per session, soreness codes per report,
  records per athlete. These catch shape problems that constraints cannot: a
  session with an implausible number of activities satisfies every key while still
  indicating a parse error.

The soreness-code distribution derived in SQL reproduces the distribution computed
in pandas before the explode (98/133/88/33/12/6/5), and 1,745 wellness rows minus
1,370 childless rows equals the 375 reports that carry codes. The two independent
derivations agree.

---

## Known limitations

These are properties of the source data, not pipeline defects — but they constrain
what can be concluded from it:

- **Injury data exists for only 9 of 16 athletes.** ACWR-to-injury correlation is
  computable for that subset only. p08 has no `injury.csv` at all.
- **p16 has no training sessions.** All 11 of its srpe entries were empty
  submissions, dropped in transform (verified against the raw file by timestamp).
- **Soreness is sparse.** 1,370 of 1,745 wellness submissions report no soreness,
  so per-body-part analysis works with roughly 21% of reports.
- **Wellness participation is uneven**, ranging from 72 to 147 reports per athlete.
  Cross-athlete comparison needs normalizing.
- **SNOMED code names were hand-mapped** from the SNOMED CT browser; the PMData
  paper does not document the wellness form's code vocabulary. A left/right
  mislabeling would be silent — nothing in the pipeline can detect it.
- **The soreness vocabulary mixes lateralized and unlateralized concepts** (left/right
  lower leg and upper arm, but undifferentiated pelvis, torso and head). Joining
  soreness to injury by body part requires an explicit granularity decision.
- **One training session (528) has no recorded activity type.** A legitimate
  childless parent: the session load is intact, only the activity label is missing.

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

- ACWR window function (7-day acute load over 28-day chronic load) in SQL
- Injury correlation against ACWR spikes for the 9-athlete subset
- Daily-grain wellness view, aggregating the report-grain base tables
