USE acwr;

-- =====================================================
-- ACWR LAYER
-- Acute:Chronic Workload Ratio at one row per (athlete, calendar day).
--
-- Acute  = 7-day total load            (fatigue proxy)
-- Chronic = 28-day mean daily load x 7 (fitness proxy, expressed per week)
-- ACWR    = acute / chronic
--
-- Both sides are per-week quantities. A raw 28-day SUM for chronic would put
-- ratios near 0.25 and the published reference bands would not apply.
-- =====================================================

DROP VIEW IF EXISTS acwr_daily;
DROP VIEW IF EXISTS daily_load;


-- -----------------------------------------------------
-- daily_load: collapse session grain to athlete-day grain.
--
-- This is the first point in the project where timestamps collapse to dates,
-- which is where the report-grain decision said the collapse belonged.
-- Athletes log up to two sessions in a day, so the SUM is load-bearing
-- rather than a pass-through (see validation.sql, sessions-per-athlete-day).
--
-- session_count is carried forward deliberately: the sparse-window guard in
-- acwr_daily needs a count of SESSIONS in the chronic frame, and once the
-- spine is joined on, counting rows would count calendar days instead.
-- -----------------------------------------------------
CREATE VIEW daily_load AS
SELECT
    athlete_id,
    DATE(end_time)    AS calendar_date,
    SUM(session_load) AS daily_load,
    COUNT(*)          AS session_count
FROM training_session
GROUP BY athlete_id, DATE(end_time)
;


-- -----------------------------------------------------
-- acwr_daily: spine + rolling windows + ratio + status.
-- -----------------------------------------------------
CREATE VIEW acwr_daily AS
WITH RECURSIVE

-- Per-athlete spine bounds. Athletes do not train daily, and a row-based
-- window frame would let a 7-row window span three weeks. The spine makes
-- rows and calendar days 1:1 so the frame means what it says.
--
-- Bounds are per-athlete rather than global. Global bounds would cover five
-- extra injury check-ins (athlete 5) but manufacture ~180 athlete-days of
-- zero load for athletes who logged 2-3 sessions across five months while
-- continuing to submit wellness - producing a ratio that decays to zero and
-- reads as real detraining when it reflects form usage. Missing values are
-- visible; wrong values are silent. See exploration.sql for the evidence.
--
-- p16 has no sessions, so it produces no bounds row and no ACWR rows at all.
bounds AS (
    SELECT
        athlete_id,
        MIN(DATE(end_time)) AS first_session,
        MAX(DATE(end_time)) AS last_session
    FROM training_session
    GROUP BY athlete_id
),

-- One row per athlete per calendar day between their own bounds.
-- All athletes advance in parallel within each iteration, so recursion depth
-- equals the longest spine (151 days), well under cte_max_recursion_depth.
spine AS (
    SELECT
        athlete_id,
        first_session AS calendar_date,
        first_session,
        last_session
    FROM bounds

    UNION ALL

    SELECT
        athlete_id,
        calendar_date + INTERVAL 1 DAY,
        first_session,
        last_session
    FROM spine
    WHERE calendar_date < last_session
),

-- Attach observed load to the spine. A spine day with no session is a real
-- zero-load day, not missing data, so both measures COALESCE to 0 on the
-- same rows - they must agree about what a rest day is.
filled AS (
    SELECT
        s.athlete_id,
        s.calendar_date,
        s.first_session,
        COALESCE(d.daily_load, 0)    AS daily_load,
        COALESCE(d.session_count, 0) AS session_count
    FROM spine AS s
    LEFT JOIN daily_load AS d
           ON d.athlete_id    = s.athlete_id
          AND d.calendar_date = s.calendar_date
),

-- RANGE with date intervals rather than ROWS. With a complete spine the two
-- are equivalent, but RANGE states the intent and stays correct if the spine
-- ever has a gap.
windowed AS (
    SELECT
        athlete_id,
        calendar_date,
        daily_load,
        SUM(daily_load)    OVER w7       AS acute_load,
        (AVG(daily_load)   OVER w28) * 7 AS chronic_load,
        SUM(session_count) OVER w28      AS sessions_in_chronic_window,
        DATEDIFF(calendar_date, first_session) + 1 AS days_since_spine_start
    FROM filled
    WINDOW
        w7 AS (
            PARTITION BY athlete_id
            ORDER BY calendar_date
            RANGE BETWEEN INTERVAL 6 DAY PRECEDING AND CURRENT ROW
        ),
        w28 AS (
            PARTITION BY athlete_id
            ORDER BY calendar_date
            RANGE BETWEEN INTERVAL 27 DAY PRECEDING AND CURRENT ROW
        )
)

SELECT
    athlete_id,
    calendar_date,
    daily_load,
    acute_load,
    ROUND(chronic_load, 2) AS chronic_load,

    -- Ratio is suppressed only where the baseline is not estimable.
    -- NULLIF guards division by zero: 28 consecutive zero-load days would
    -- otherwise return NULL silently rather than by intent.
    CASE
        WHEN sessions_in_chronic_window < 4 THEN NULL
        ELSE ROUND(acute_load / NULLIF(chronic_load, 0), 3)
    END AS acwr,

    -- Two independent conditions, so precedence is declared rather than left
    -- to evaluation order. sparse_window ranks first: it says the baseline is
    -- not estimable at all, where partial_window only says it is short.
    --
    --   sparse_window  - fewer than 4 sessions in the 28-day frame. Chronic is
    --                    a four-week average, so it should rest on at least one
    --                    session per week it averages. Ratio suppressed.
    --   partial_window - fewer than 28 calendar days of spine history. The
    --                    ratio is still dimensionally valid (both sides remain
    --                    per-week) but rests on a shorter baseline, so it is
    --                    computed and marked rather than hidden.
    --   ok             - neither condition.
    CASE
        WHEN sessions_in_chronic_window < 4 THEN 'sparse_window'
        WHEN days_since_spine_start     < 28 THEN 'partial_window'
        ELSE 'ok'
    END AS acwr_status,

    -- The rules' own inputs are exposed so a reader can recompute either
    -- condition without reading this SQL.
    sessions_in_chronic_window,
    days_since_spine_start
FROM windowed
;


-- =====================================================
-- VERIFICATION
-- Window functions fail quietly: a wrong frame boundary produces plausible numbers and no constraint catches it. These are sanity checks.
-- =====================================================

-- Row count must equal the sum of per-athlete spine lengths (see exploration.sql spine-length query: SUM of spine_days).
SELECT COUNT(*) AS acwr_rows FROM acwr_daily;

-- Total load must survive the spine join unchanged. If this does not equal
-- the SUM(session_load) of training_session, the join lost or duplicated rows.
SELECT
    (SELECT SUM(daily_load)   FROM acwr_daily)       AS spine_total_load,
    (SELECT SUM(session_load) FROM training_session) AS source_total_load
;

-- Same for sessions: the chronic-window counts come from session_count, so
-- confirm the underlying daily grain still accounts for all 772 sessions.
SELECT SUM(session_count) AS sessions_accounted FROM daily_load;

-- Row count must equal to the sum of training_days - 719 (see exploration.sql spine-length query: COUNT(DISTINCT DATE(end_time)) AS training_days)
SELECT COUNT(*) FROM daily_load;

-- Status distribution per athlete. Athletes 5, 9 and 13 train at roughly
-- 0.5-0.6 sessions/week and should dominate sparse_window. Athlete 3 has a
-- 7-day spine and must never appear as 'ok'.
SELECT
    athlete_id,
    SUM(acwr_status = 'ok')             AS ok_days,
    SUM(acwr_status = 'partial_window') AS partial_days,
    SUM(acwr_status = 'sparse_window')  AS sparse_days,
    COUNT(*)                            AS total_days
FROM acwr_daily
GROUP BY athlete_id
ORDER BY athlete_id
;

-- If sparse_days is 0 everywhere, the guard is counting spine rows rather than sessions and cannot fire. 
-- This check exists to catch that specific failure, which would otherwise look like a clean result.
SELECT
    MIN(sessions_in_chronic_window) AS min_sessions_in_window,
    MAX(sessions_in_chronic_window) AS max_sessions_in_window
FROM acwr_daily
;

-- Hand-verification targets. Compute acute and chronic manually from training_session for these rows and compare.
--   - a dense athlete mid-series, where the frame is full
--   - athlete 13, where the guard should fire
--   - a day immediately after a long gap, where ROWS and RANGE diverge most
SELECT *
FROM acwr_daily
WHERE athlete_id = 5
  AND acwr_status = 'ok'
;

-- Raw sessions in and around the 28-day chronic frame for that day.
-- in_acute / in_chronic mark which rows each window should include, so the
-- hand computation is a sum of a marked column rather than a date comparison
-- done twice. Rows just outside the frame are included deliberately: an
-- off-by-one boundary shows up as a row marked 0 that should be 1.
SET @target = '2020-01-02';   -- replace with the date from the query above

SELECT
    DATE(end_time) AS calendar_date,
    rpe,
    duration_min,
    session_load,
    DATEDIFF(@target, DATE(end_time)) AS days_before_target,
    DATEDIFF(@target, DATE(end_time)) BETWEEN 0 AND 6  AS in_acute,
    DATEDIFF(@target, DATE(end_time)) BETWEEN 0 AND 27 AS in_chronic
FROM training_session
WHERE athlete_id = 5
  AND DATE(end_time) BETWEEN @target - INTERVAL 31 DAY
                         AND @target + INTERVAL 2 DAY
ORDER BY calendar_date
;

-- =====================================================
-- INJURY CORRELATION (demonstration of method)
-- =====================================================

-- Eligibility. Which injury-reporting athletes produce usable ACWR rows?
-- Athletes 3 and 9 have no 'ok' days and athlete 13 has one, so the
-- 9-athlete injury subset may not survive intact.
SELECT
    i.athlete_id,
    COUNT(DISTINCT i.reported_at) AS injury_check_ins,
    COUNT(*)                      AS injury_rows,
    a.ok_days
FROM injuries AS i
LEFT JOIN (
    SELECT athlete_id, SUM(acwr_status = 'ok') AS ok_days
    FROM acwr_daily
    GROUP BY athlete_id
) AS a ON a.athlete_id = i.athlete_id
GROUP BY i.athlete_id, a.ok_days
ORDER BY a.ok_days
;

-- Join yield. How much of the injury data actually lands on an ACWR row?
-- This is the headline number: the correlation can only speak to the rows
-- that survive both the spine bounds and the sparse-window guard.
SELECT
    COUNT(*)                                        AS total_injury_rows,
    SUM(d.calendar_date IS NOT NULL)                AS rows_on_spine,
    SUM(d.acwr IS NOT NULL)                         AS rows_with_acwr,
    COUNT(DISTINCT i.athlete_id, i.reported_at)     AS total_check_ins,
    COUNT(DISTINCT CASE WHEN d.acwr IS NOT NULL
                        THEN CONCAT(i.athlete_id, '|', i.reported_at) END)
                                                    AS check_ins_with_acwr
FROM injuries AS i
LEFT JOIN acwr_daily AS d
       ON d.athlete_id    = i.athlete_id
      AND d.calendar_date = DATE(i.reported_at)
;

-- The demonstration. ACWR on injury-report days against all other days.
-- Reported alongside acute and chronic separately: the ratio discards what
-- its components say apart, and 300->450 AU and 3000->4500 AU give the same
-- 1.5 while describing different situations.
--
-- n is small enough that this compares distributions, not populations.
-- It demonstrates the join, not an association.
SELECT
    CASE WHEN i.report_date IS NULL THEN 'no_injury_report'
         ELSE 'injury_report' END        AS day_type,
    COUNT(*)                             AS athlete_days,
    ROUND(AVG(d.acwr), 3)                AS mean_acwr,
    ROUND(MIN(d.acwr), 3)                AS min_acwr,
    ROUND(MAX(d.acwr), 3)                AS max_acwr,
    SUM(d.acwr > 1.5)                    AS days_above_1_5,
    ROUND(AVG(d.acute_load), 1)          AS mean_acute,
    ROUND(AVG(d.chronic_load), 1)        AS mean_chronic
FROM acwr_daily AS d
LEFT JOIN (
    SELECT DISTINCT athlete_id, DATE(reported_at) AS report_date
    FROM injuries
) AS i ON i.athlete_id  = d.athlete_id
      AND i.report_date = d.calendar_date
WHERE d.acwr IS NOT NULL
GROUP BY day_type
;