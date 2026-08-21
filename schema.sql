CREATE DATABASE IF NOT EXISTS acwr;
USE acwr;
DROP TABLE IF EXISTS session_activity, soreness_report, injuries, wellness, training_session, body_part, athlete;

CREATE TABLE `athlete` (
  `athlete_id` int NOT NULL,
  `source_id` varchar(4) NOT NULL,
  `age` int DEFAULT NULL,
  `height_cm` int DEFAULT NULL,
  `gender` enum('male','female') DEFAULT NULL,
  `personality_type` enum('A','B') DEFAULT NULL,
  `max_heart_rate` int DEFAULT NULL,
  PRIMARY KEY (`athlete_id`),
  UNIQUE KEY `source_id` (`source_id`)
);

CREATE TABLE `body_part` (
  `body_part_code` int NOT NULL,
  `body_part_name` varchar(50) DEFAULT NULL,
  PRIMARY KEY (`body_part_code`)
);

CREATE TABLE `injuries` (
  `injury_id` int NOT NULL,
  `athlete_id` int NOT NULL,
  `reported_at` datetime NOT NULL,
  `injury_area` varchar(50) NOT NULL,
  `severity` enum('minor','major') DEFAULT NULL,
  PRIMARY KEY (`injury_id`),
  UNIQUE KEY `uq_injuries_nk` (`athlete_id`,`reported_at`,`injury_area`),
  CONSTRAINT `injuries_ibfk_1` FOREIGN KEY (`athlete_id`) REFERENCES `athlete` (`athlete_id`)
);

CREATE TABLE `wellness` (
  `wellness_id` int NOT NULL,
  `athlete_id` int NOT NULL,
  `reported_at` DATETIME NOT NULL,
  `fatigue` int DEFAULT NULL,
  `mood` int DEFAULT NULL,
  `readiness` int DEFAULT NULL,
  `sleep_quality` int DEFAULT NULL,
  `stress` int DEFAULT NULL,
  `soreness` int DEFAULT NULL,
  `sleep_duration_h` int DEFAULT NULL,
  PRIMARY KEY (`wellness_id`),
  UNIQUE KEY athlete_id (`athlete_id`, `reported_at`),
  CONSTRAINT `wellness_ibfk_1` FOREIGN KEY (`athlete_id`) REFERENCES `athlete` (`athlete_id`)
);

CREATE TABLE `training_session` (
  `session_id` int NOT NULL,
  `athlete_id` int NOT NULL,
  `end_time` datetime NOT NULL,
  `rpe` int DEFAULT NULL,
  `duration_min` int DEFAULT NULL,
  `session_load` int DEFAULT NULL,
  `participation_mode` enum('individual','team') DEFAULT NULL,
  PRIMARY KEY (`session_id`),
  UNIQUE KEY uq_training_nk (`athlete_id`, `end_time`),
  CONSTRAINT `training_session_ibfk_1` FOREIGN KEY (`athlete_id`) REFERENCES `athlete` (`athlete_id`)
);

CREATE TABLE `soreness_report` (
  `wellness_id` int NOT NULL,
  `body_part_code` int NOT NULL,
  PRIMARY KEY (`wellness_id`,`body_part_code`),
  KEY `body_part_code` (`body_part_code`),
  CONSTRAINT `soreness_report_ibfk_1` FOREIGN KEY (`wellness_id`) REFERENCES `wellness` (`wellness_id`),
  CONSTRAINT `soreness_report_ibfk_2` FOREIGN KEY (`body_part_code`) REFERENCES `body_part` (`body_part_code`)
);

CREATE TABLE `session_activity` (
  `session_id` int NOT NULL,
  `activity_type` enum('endurance','strength','running','soccer') NOT NULL,
  PRIMARY KEY (`session_id`,`activity_type`),
  CONSTRAINT `session_activity_ibfk_1` FOREIGN KEY (`session_id`) REFERENCES `training_session` (`session_id`)
);

SHOW CREATE TABLE athlete;
SHOW CREATE TABLE body_part;
SHOW CREATE TABLE injuries;
SHOW CREATE TABLE wellness; 
SHOW CREATE TABLE training_session;
SHOW CREATE TABLE soreness_report;
SHOW CREATE TABLE session_activity;
