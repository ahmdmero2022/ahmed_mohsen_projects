-- =============================================================================
-- Database validation | Oracle 19c | STATUS: written, NOT executed
-- Run after every deployment as the schema owner. Prints PASS/FAIL lines; the final
-- RAISE_APPLICATION_ERROR makes a CI run fail when any check fails.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
DECLARE
  l_fail PLS_INTEGER := 0;
  l_n    NUMBER;

  PROCEDURE chk(p_ok BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.put_line(CASE WHEN p_ok THEN 'PASS  ' ELSE 'FAIL  ' END || p_msg);
    IF NOT p_ok THEN l_fail := l_fail + 1; END IF;
  END chk;
BEGIN
  -- 1. nothing invalid
  SELECT COUNT(*) INTO l_n FROM user_objects WHERE status <> 'VALID' AND object_name LIKE 'LMS\_%' ESCAPE '\'
     OR (status <> 'VALID' AND object_name LIKE 'V\_LMS\_%' ESCAPE '\');
  chk(l_n = 0, 'no invalid LMS objects (found ' || l_n || ')');

  -- 2. expected tables
  FOR r IN (SELECT column_value t FROM TABLE(sys.odcivarchar2list(
      'LMS_DEPARTMENTS','LMS_POSITIONS','LMS_USERS','LMS_ROLES','LMS_PERMISSIONS','LMS_ROLE_PERMISSIONS','LMS_USER_ROLES',
      'LMS_CATEGORIES','LMS_COURSES','LMS_COURSE_PREREQUISITES','LMS_MODULES','LMS_LESSONS','LMS_ENROLLMENTS',
      'LMS_LESSON_PROGRESS','LMS_SYSTEM_SETTINGS','LMS_AUDIT_LOG','LMS_SECURITY_EVENTS','LMS_RATE_LIMIT_POLICIES',
      'LMS_RATE_LIMIT_COUNTERS','LMS_COURSE_INSTRUCTORS','LMS_COURSE_VERSIONS','LMS_CONTENT_VERSIONS','LMS_LESSON_CONTENT',
      'LMS_APPROVALS','LMS_LEARNING_ASSIGNMENTS','LMS_LEARNING_ACTIVITY','LMS_QUESTION_BANKS','LMS_QUESTIONS',
      'LMS_QUESTION_OPTIONS','LMS_QUIZZES','LMS_QUIZ_QUESTIONS','LMS_QUIZ_ATTEMPTS','LMS_QUIZ_RESPONSES',
      'LMS_LEARNING_PATHS','LMS_PATH_COURSES','LMS_PATH_ENROLLMENTS','LMS_VENUES','LMS_TRAINING_SESSIONS',
      'LMS_SESSION_ENROLLMENTS','LMS_ATTENDANCE','LMS_CERTIFICATE_TEMPLATES','LMS_CERTIFICATES','LMS_SKILLS',
      'LMS_POSITION_SKILLS','LMS_USER_SKILLS','LMS_COURSE_SKILLS','LMS_FEEDBACK_FORMS','LMS_FEEDBACK_QUESTIONS',
      'LMS_FEEDBACK_RESPONSES','LMS_COURSE_REVIEWS','LMS_NOTIFICATION_TEMPLATES','LMS_NOTIFICATIONS',
      'LMS_NOTIFICATION_QUEUE','LMS_API_REQUEST_LOG','LMS_SUM_DEPT_DAILY','LMS_SUM_COURSE'))) LOOP
    SELECT COUNT(*) INTO l_n FROM user_tables WHERE table_name = r.t;
    chk(l_n = 1, 'table ' || r.t);
  END LOOP;

  -- 3. expected packages (spec + body valid)
  FOR r IN (SELECT column_value p FROM TABLE(sys.odcivarchar2list(
      'LMS_UTIL_PKG','LMS_SECURITY_PKG','LMS_AUDIT_PKG','LMS_RATE_LIMIT_PKG','LMS_NOTIFICATION_PKG','LMS_APPROVAL_PKG',
      'LMS_USER_PKG','LMS_HR_SYNC_PKG','LMS_COURSE_PKG','LMS_ENROLLMENT_PKG','LMS_PROGRESS_PKG','LMS_ASSESSMENT_PKG',
      'LMS_LEARNING_PATH_PKG','LMS_SESSION_PKG','LMS_CERTIFICATION_PKG','LMS_FEEDBACK_PKG','LMS_SKILL_PKG','LMS_REPORTING_PKG'))) LOOP
    SELECT COUNT(*) INTO l_n FROM user_objects
     WHERE object_name = r.p AND object_type IN ('PACKAGE','PACKAGE BODY') AND status = 'VALID';
    chk(l_n = 2, 'package ' || r.p || ' (spec+body valid)');
  END LOOP;

  -- 4. key integrity structures
  SELECT COUNT(*) INTO l_n FROM user_indexes WHERE index_name = 'LMS_ENR_ACTIVE_UK' AND uniqueness = 'UNIQUE';
  chk(l_n = 1, 'unique open-enrolment index (BR-01)');
  SELECT COUNT(*) INTO l_n FROM user_indexes WHERE index_name IN ('LMS_CERT_ENR_UK','LMS_CERT_PE_UK','LMS_QA_OPEN_UK','LMS_APR_OPEN_UK') AND uniqueness = 'UNIQUE';
  chk(l_n = 4, 'idempotency unique indexes (certificates, open attempt, open approval)');

  -- 5. answer keys must not be exposed by learner-facing views
  SELECT COUNT(*) INTO l_n FROM user_tab_columns
   WHERE table_name IN ('V_LMS_ATTEMPT_QUESTIONS','V_LMS_ATTEMPT_OPTIONS')
     AND column_name IN ('IS_CORRECT','MATCH_KEY');
  chk(l_n = 0, 'attempt views expose no answer key columns');
  SELECT COUNT(*) INTO l_n FROM user_tab_columns WHERE table_name = 'V_LMS_ATTEMPT_MATCH_CHOICES' AND column_name = 'OPTION_ID';
  chk(l_n = 0, 'match-choice view is not linked to option ids');

  -- 6. seed data
  SELECT COUNT(*) INTO l_n FROM lms_roles;                     chk(l_n >= 6,  'roles seeded (' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM lms_permissions;               chk(l_n >= 22, 'permissions seeded (' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM lms_role_permissions;          chk(l_n >= 50, 'role-permission rows seeded (' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM lms_rate_limit_policies WHERE enabled_flag = 'Y'; chk(l_n >= 9, 'rate-limit policies (' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM lms_notification_templates;    chk(l_n >= 46, 'notification templates en+ar (' || l_n || ')');
  SELECT COUNT(DISTINCT template_code) INTO l_n FROM lms_notification_templates t
   WHERE (SELECT COUNT(*) FROM lms_notification_templates x WHERE x.template_code = t.template_code) = 2;
  chk(l_n >= 23, 'every template has both languages (' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM lms_system_settings WHERE setting_key IN ('RETAIN_AUDIT_DAYS','QUIZ_GRACE_SECONDS','RENEWAL_WINDOW_DAYS');
  chk(l_n = 3, 'core settings present');

  -- 7. jobs
  SELECT COUNT(*) INTO l_n FROM user_scheduler_jobs WHERE job_name LIKE 'LMS\_%' ESCAPE '\' AND enabled = 'TRUE';
  chk(l_n >= 8, 'scheduler jobs enabled (' || l_n || ')');

  -- 8. every foreign key column should be indexed (lock/perf hygiene)
  SELECT COUNT(*) INTO l_n FROM (
    SELECT c.constraint_name
      FROM user_constraints c
      JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name AND cc.position = 1
     WHERE c.constraint_type = 'R' AND c.table_name LIKE 'LMS\_%' ESCAPE '\'
       AND NOT EXISTS (SELECT 1 FROM user_ind_columns ic
                        WHERE ic.table_name = c.table_name AND ic.column_name = cc.column_name AND ic.column_position = 1));
  chk(l_n = 0, 'foreign keys without a leading index: ' || l_n || ' (list below if > 0)');
  FOR r IN (SELECT c.table_name, cc.column_name, c.constraint_name
              FROM user_constraints c
              JOIN user_cons_columns cc ON cc.constraint_name = c.constraint_name AND cc.position = 1
             WHERE c.constraint_type = 'R' AND c.table_name LIKE 'LMS\_%' ESCAPE '\'
               AND NOT EXISTS (SELECT 1 FROM user_ind_columns ic
                                WHERE ic.table_name = c.table_name AND ic.column_name = cc.column_name AND ic.column_position = 1)) LOOP
    DBMS_OUTPUT.put_line('      unindexed FK: ' || r.table_name || '.' || r.column_name || ' (' || r.constraint_name || ')');
  END LOOP;

  DBMS_OUTPUT.put_line(CASE WHEN l_fail = 0 THEN 'ALL CHECKS PASSED' ELSE l_fail || ' CHECK(S) FAILED' END);
  IF l_fail > 0 THEN RAISE_APPLICATION_ERROR(-20999, l_fail || ' validation check(s) failed'); END IF;
END;
/
