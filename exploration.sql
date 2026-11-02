USE acwr;
-- Exploratory analysis. No expected results — output is a finding, not a pass/fail. 
-- Run once to inform the ACWR spine-bounds decision: whether per-athlete date bounds lose injury coverage relative to global bounds.

-- =====================================================
-- INJURY GAP ANALYSIS (ACWR spine bounds decision)
-- Do injury reports fall outside each athlete's training-session date range?
-- Per-athlete spine bounds leave such reports with no ACWR row to join to;
-- global bounds cover them but fabricate zero-load days at the edges.
-- =====================================================

-- Trailing edge: reports AFTER an athlete's last logged session.
-- Likely app abandonment while training continued, or a genuine layoff.
-- There was no row with a null last_session. All 9 injury-reporting athletes have sessions, so the "no session range at all" is empty.alter
-- This removes an entire failure mode from the bounds decision. Athlete 5 needs to be examined further (see below).
WITH session_bounds AS (
  SELECT
    athlete_id,
    MIN(DATE(end_time)) AS first_session,
    MAX(DATE(end_time)) AS last_session
  FROM training_session
  GROUP BY athlete_id
)
SELECT
  i.athlete_id,
  b.last_session,
  MIN(DATE(i.reported_at))                        AS earliest_late_report,
  MAX(DATE(i.reported_at))                        AS latest_late_report,
  MAX(DATEDIFF(DATE(i.reported_at), b.last_session)) AS max_days_past,
  COUNT(*)                                        AS injury_rows,
  COUNT(DISTINCT i.reported_at)                   AS check_ins
FROM injuries AS i
LEFT JOIN session_bounds AS b ON i.athlete_id = b.athlete_id
WHERE b.last_session IS NULL                        -- athlete has no sessions at all
   OR DATE(i.reported_at) > b.last_session
GROUP BY i.athlete_id, b.last_session
ORDER BY max_days_past DESC
;

-- Leading edge: reports BEFORE an athlete's first logged session.
-- Different phenomenon — likely a pre-existing injury predating logged training.
-- This is a non-issue since the three rows fall in the opening days of the collection window;
-- Under a 'null-until-28-days' rule, those athlete-days have an incomplete chronic denominator and carry a NULL ACWR regardless of bounds
WITH session_bounds AS (
  SELECT
    athlete_id,
    MIN(DATE(end_time)) AS first_session
  FROM training_session
  GROUP BY athlete_id
)
SELECT
  i.athlete_id,
  b.first_session,
  MIN(DATE(i.reported_at))                          AS earliest_early_report,
  MAX(DATEDIFF(b.first_session, DATE(i.reported_at))) AS max_days_before,
  COUNT(*)                                          AS injury_rows,
  COUNT(DISTINCT i.reported_at)                     AS check_ins
FROM injuries AS i
LEFT JOIN session_bounds AS b ON i.athlete_id = b.athlete_id
WHERE b.first_session IS NULL
   OR DATE(i.reported_at) < b.first_session
GROUP BY i.athlete_id, b.first_session
ORDER BY max_days_before DESC
;

-- Follow-up: did athlete 5 stay engaged after their last session (2020-02-13)?
-- Wellness and srpe are separate forms, so continued wellness submissions with
-- no training sessions distinguish a genuine layoff (real zero-load days) from
-- app abandonment (fabricated zero-load days). This is the evidence behind the
-- spine-bounds choice. 
-- The query below shows that athlete 5 had 0 sessions (but did submit wellness reports) after their last session,
-- which is evidence pointing to a layoff rather than app abandonment.
SELECT
  DATE(w.reported_at) AS report_date,
  w.readiness,
  w.fatigue,
  w.soreness,
  COUNT(s.session_id) AS sessions_that_day
FROM wellness AS w
LEFT JOIN training_session AS s
  ON  s.athlete_id = w.athlete_id
  AND DATE(s.end_time) = DATE(w.reported_at)
WHERE w.athlete_id = 5
  AND DATE(w.reported_at) > '2020-02-13'
GROUP BY DATE(w.reported_at), w.readiness, w.fatigue, w.soreness
ORDER BY report_date
;

-- Summary: how long did wellness logging continue past the last session?
-- 39 wellness reports over 46 days with 0 sessions. Athlete 5 remained engaged
-- with the app and did not train. 
SELECT
  COUNT(*)                 AS wellness_reports_after_last_session,
  MIN(DATE(reported_at))   AS first_after,
  MAX(DATE(reported_at))   AS last_after,
  DATEDIFF(MAX(DATE(reported_at)), '2020-02-13') AS days_of_continued_logging
FROM wellness
WHERE athlete_id = 5
  AND DATE(reported_at) > '2020-02-13'
;

-- Cohort check: do athletes' last sessions cluster in time?
-- Note, athlete 16 is not present in the table below by design (they had no sessions hence no rows)
-- 
SELECT
  t.athlete_id,
  MIN(DATE(t.end_time))  AS first_session,
  MAX(DATE(t.end_time))  AS last_session,
  COUNT(*)               AS sessions,
  w.last_wellness,
  DATEDIFF(w.last_wellness, MAX(DATE(t.end_time))) AS days_logged_past_last_session
FROM training_session AS t
LEFT JOIN (
  SELECT athlete_id, MAX(DATE(reported_at)) AS last_wellness
  FROM wellness
  GROUP BY athlete_id
) AS w ON w.athlete_id = t.athlete_id
GROUP BY t.athlete_id, w.last_wellness
ORDER BY last_session
;

-- Spine length vs. the 28-day chronic window.
-- Per-athlete spine bounds mean each athlete's ACWR series runs first session to
-- last session. An athlete whose spine is shorter than 28 days can never produce
-- a non-null ACWR under the warmup rule, so the bounds decision already excludes
-- them without a separate session-count threshold. This quantifies that.
SELECT
  athlete_id,
  COUNT(*)                                            AS sessions,
  MIN(DATE(end_time))                                 AS first_session,
  MAX(DATE(end_time))                                 AS last_session,
  DATEDIFF(MAX(DATE(end_time)), MIN(DATE(end_time))) + 1 AS spine_days,
  GREATEST(DATEDIFF(MAX(DATE(end_time)), MIN(DATE(end_time))) + 1 - 27, 0)
                                                      AS acwr_days_available,
  COUNT(DISTINCT DATE(end_time))                      AS training_days
FROM training_session
GROUP BY athlete_id
ORDER BY spine_days
;