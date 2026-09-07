USE acwr;

-- Precondition: strict mode must be on for the enum arguments below to hold.
-- In non-strict mode an out-of-domain enum value inserts as '' instead of raising.
-- The enum declarations in schema.sql and the successful load demonstrate the enum domains post-load.
SELECT @@sql_mode;


-- =====================================================
-- 1. VALIDATING ROW COUNTS
-- =====================================================

-- Validated row count to ensure it matches the notebook row counts;
SELECT 'athlete' AS table_name, COUNT(*) AS row_count FROM athlete
UNION ALL SELECT 'body_part', COUNT(*) FROM body_part
UNION ALL SELECT 'injuries', COUNT(*) FROM injuries
UNION ALL SELECT 'session_activity', COUNT(*) FROM session_activity
UNION ALL SELECT 'soreness_report', COUNT(*) FROM soreness_report
UNION ALL SELECT 'training_session', COUNT(*) FROM training_session
UNION ALL SELECT 'wellness', COUNT(*) FROM wellness
;

-- =====================================================
-- 2. ORPHAN CHECKS
-- Checking for orphans between parent and child
-- These confirm that the FK constraints hold post-load. The FKs reject orphans at insert, so 0s are expected when looking for orphans
-- =====================================================

SELECT 'injuries->athlete' AS check_name, COUNT(*) AS orphans -- Between athlete and injuries
FROM injuries -- child first
LEFT JOIN athlete ON injuries.athlete_id = athlete.athlete_id
WHERE athlete.athlete_id IS NULL
UNION ALL

SELECT 'wellness->athlete' AS check_name, COUNT(*) AS orphans -- Between wellness and athlete
FROM wellness
LEFT JOIN athlete ON wellness.athlete_id = athlete.athlete_id
WHERE athlete.athlete_id IS NULL
UNION ALL

SELECT 'training_session->athlete' AS check_name, COUNT(*) AS orphans -- Between training_session and athlete
FROM training_session 
LEFT JOIN athlete ON training_session.athlete_id = athlete.athlete_id
WHERE athlete.athlete_id IS NULL
UNION ALL

SELECT 'soreness_report->wellness' AS check_name, COUNT(*) AS orphans -- Between wellness and soreness_report
FROM soreness_report 
LEFT JOIN wellness ON soreness_report.wellness_id = wellness.wellness_id
WHERE wellness.wellness_id IS NULL
UNION ALL

SELECT 'soreness_report->body_part' AS check_name, COUNT(*) AS orphans -- Between soreness_report and body_part
FROM soreness_report 
LEFT JOIN body_part ON soreness_report.body_part_code = body_part.body_part_code
WHERE body_part.body_part_code IS NULL
UNION ALL

SELECT 'session_activity->training_session' AS check_name, COUNT(*) AS orphans -- Between session_activity and training_session
FROM session_activity 
LEFT JOIN training_session ON session_activity.session_id = training_session.session_id
WHERE training_session.session_id IS NULL
;

-- Checking for childless parents to view legitimately empty rows (opposite direction of the orphan checks)
-- Session 528 does not have child row
SELECT training_session.*
FROM training_session 
LEFT JOIN session_activity ON training_session.session_id = session_activity.session_id
WHERE session_activity.session_id IS NULL
;

-- 1370 wellness reports have no soreness codes
-- 1745 total rows - 1370 childless rows = 375 reports (matches length distribution found in the notebook)
SELECT COUNT(*) AS num_reports_no_soreness
FROM wellness
LEFT JOIN soreness_report ON wellness.wellness_id = soreness_report.wellness_id
WHERE soreness_report.wellness_id IS NULL
;

-- =====================================================
-- 3. NULL AUDIT CHECKS
-- =====================================================

-- 0 nulls
SELECT COUNT(*) - COUNT(severity) AS severity_nulls
FROM injuries
;

-- 0 nulls
SELECT COUNT(*) - COUNT(body_part_name) AS body_part_name_nulls
FROM body_part
;

-- 0 nulls (except for max_heart_rate)
SELECT
  COUNT(*) - COUNT(age)              AS age_nulls,
  COUNT(*) - COUNT(height_cm)        AS height_cm_nulls,
  COUNT(*) - COUNT(gender)           AS gender_nulls,
  COUNT(*) - COUNT(personality_type) AS personality_type_nulls,
  COUNT(*) - COUNT(athlete.max_heart_rate) AS max_heart_rate_nulls  -- 3 nulls
FROM athlete
;

-- 0 nulls
SELECT
  COUNT(*) - COUNT(fatigue)          AS fatigue_nulls,
  COUNT(*) - COUNT(mood)             AS mood_nulls,
  COUNT(*) - COUNT(readiness)        AS readiness_nulls,
  COUNT(*) - COUNT(sleep_quality)    AS sleep_quality_nulls,
  COUNT(*) - COUNT(stress)           AS stress_nulls,
  COUNT(*) - COUNT(soreness)         AS soreness_nulls,
  COUNT(*) - COUNT(sleep_duration_h) AS sleep_duration_h_nulls
FROM wellness
;

-- 0 nulls
SELECT
  COUNT(*) - COUNT(rpe)          AS rpe_nulls,
  COUNT(*) - COUNT(duration_min)             AS duration_min_nulls,
  COUNT(*) - COUNT(session_load)        AS session_load_nulls,
  COUNT(*) - COUNT(participation_mode)           AS participation_mode_nulls
FROM training_session
;

-- =====================================================
-- 4. DISTRIBUTION CHECKS
-- =====================================================

-- Distribution check for # of activities per session
-- 705 sessions with 1 activity, 62 with 2 and 4 with 3
SELECT activities, COUNT(*) AS sessions
FROM (
  SELECT session_id, COUNT(*) AS activities
  FROM session_activity
  GROUP BY session_id
) AS per_session
GROUP BY activities
ORDER BY activities
;

-- Distribution check for soreness codes per report
-- From 1 to 7 soreness codes per report (mode is 2 codes with 133 reports)
SELECT codes, COUNT(*) AS reports
FROM (
SELECT wellness_id, COUNT(*) AS codes
FROM soreness_report
GROUP BY wellness_id
) AS per_report
GROUP BY codes
ORDER BY codes
;

-- Distribution check for number of sessions per athlete
-- p16 does not have any training sessions logged hence won't appear in this query
SELECT athlete_id, COUNT(*) AS sessions
FROM training_session
GROUP BY athlete_id
ORDER BY sessions
;

-- Distribution check for number of injury reports per athlete
-- Only 9 athletes have reported injuries
SELECT athlete_id, COUNT(*) AS injury_reports
FROM injuries
GROUP BY athlete_id
ORDER BY injury_reports
;

-- Distribution check for number of wellness reports per athlete
-- All 16 athletes have reported wellness ranging from 72 - 147
SELECT athlete_id, COUNT(*) AS wellness_reports
FROM wellness
GROUP BY athlete_id
ORDER BY wellness_reports
;


-- Do athletes log multiple sessions in a day?
-- 1 or 2 sessions max a day
SELECT sessions, COUNT(*) AS days
FROM (
  SELECT athlete_id, COUNT(*) AS sessions
  FROM training_session
  GROUP BY athlete_id, DATE(end_time)
) AS per_athlete_day
GROUP BY sessions
ORDER BY sessions
;

-- The athlete-day distribution must account for all 772 sessions.
-- SUM(sessions * days) collapses the distribution back to a session count.
-- Any mismatch means the grouping lost or duplicated rows.
-- All 772 sessions found
SELECT SUM(sessions * days) AS sessions_reconciled
FROM (
  SELECT sessions, COUNT(*) AS days
  FROM (
    SELECT athlete_id, COUNT(*) AS sessions
    FROM training_session
    GROUP BY athlete_id, DATE(end_time)
  ) AS per_athlete_day
  GROUP BY sessions
) AS distribution
;

-- =====================================================
-- 5. DOMAIN INTEGRITY (paper-defined scales and derived columns)
--    These can genuinely fail: the schema stores bare ints and enforces none of the source's scale definitions.
-- =====================================================

-- session_load is materialized in pandas as rpe * duration_min. Nothing in the schema enforces the relationship, so a transform bug would load silently and
-- flow straight into ACWR. The NULL clauses matter: `session_load <> rpe * duration_min` evaluates to NULL when any input is NULL, and NULL does not satisfy a WHERE,
-- so those rows would be skipped rather than flagged.
-- 0 rows where the derived column disagrees with the inputs
SELECT COUNT(*) AS session_load_mismatches
FROM training_session
WHERE session_load <> rpe * duration_min
   OR rpe          IS NULL
   OR duration_min IS NULL
   OR session_load IS NULL
;

-- The paper defines fatigue, mood, sleep_quality, soreness and stress on a 1-5
-- scale and readiness on 0-10. All are stored as bare `int`, so nothing enforces
-- those domains. 0 is admitted below for the five-point columns as a preserved
-- source sentinel (see notebook: lone zeros are preserved, not interpreted),
-- NOT as a valid scale point. Readiness includes 0 legitimately.
-- 0 out of range
SELECT
  SUM(fatigue          NOT BETWEEN 0 AND 5)  AS fatigue_out_of_range,
  SUM(mood             NOT BETWEEN 0 AND 5)  AS mood_out_of_range,
  SUM(sleep_quality    NOT BETWEEN 0 AND 5)  AS sleep_quality_out_of_range,
  SUM(soreness         NOT BETWEEN 0 AND 5)  AS soreness_out_of_range,
  SUM(stress           NOT BETWEEN 0 AND 5)  AS stress_out_of_range,
  SUM(readiness        NOT BETWEEN 0 AND 10) AS readiness_out_of_range,
  SUM(sleep_duration_h NOT BETWEEN 0 AND 24) AS sleep_duration_out_of_range
FROM wellness
;

-- RPE is 1-10 per the paper. Duration is unbounded there, but a non-positive
-- duration is physically impossible and would produce a zero or negative
-- session_load feeding the ACWR windows.
-- 0 out of range
SELECT
  SUM(rpe NOT BETWEEN 1 AND 10) AS rpe_out_of_range,
  SUM(duration_min <= 0)        AS duration_nonpositive
FROM training_session
;