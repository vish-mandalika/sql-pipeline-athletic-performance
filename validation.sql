USE acwr;

-- Validated row count to ensure it matches the notebook row counts;
SELECT 'athlete' AS table_name, COUNT(*) AS row_count FROM athlete
UNION ALL SELECT 'body_part', COUNT(*) FROM body_part
UNION ALL SELECT 'injuries', COUNT(*) FROM injuries
UNION ALL SELECT 'session_activity', COUNT(*) FROM session_activity
UNION ALL SELECT 'soreness_report', COUNT(*) FROM soreness_report
UNION ALL SELECT 'training_session', COUNT(*) FROM training_session
UNION ALL SELECT 'wellness', COUNT(*) FROM wellness
;

-- Checking for orphans between parent and child
-- These confirm that the FK constraints hold post-load. The FKs reject orphans at insert, so 0s are expected when looking for orphans

SELECT 'injuries->athlete' AS check_name, COUNT(*) AS orphans -- Between athlete and injuries
FROM injuries # child first
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
