-- =============================================================================
-- Tests: venue maintenance (LMS_SESSION_PKG) and feedback reminders (LMS_FEEDBACK_PKG.SEND_REMINDERS)
-- STATUS: written, NOT executed. Requires 00_install + 10_test_data.sql; edit &WORKSPACE. Rolls back everything.
-- Users are impersonated with APEX sessions (the packages read the caller from the session, never from a parameter).
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE ON
DEFINE WORKSPACE = LMS
DECLARE
  l_fail PLS_INTEGER := 0;
  l_n NUMBER; l_v NUMBER; l_v2 NUMBER; l_sess NUMBER; l_course NUMBER; l_pre NUMBER; l_inst NUMBER;
  l_enr NUMBER; l_st VARCHAR2(20); l_pct NUMBER; l_sent NUMBER; l_u1 NUMBER; l_u2 NUMBER; l_u3 NUMBER; l_um NUMBER;
  l_start TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP + INTERVAL '10' DAY;

  PROCEDURE chk(p_ok BOOLEAN, p_msg VARCHAR2) IS
  BEGIN
    DBMS_OUTPUT.put_line(CASE WHEN p_ok THEN 'PASS  ' ELSE 'FAIL  ' END || p_msg);
    IF NOT p_ok THEN l_fail := l_fail + 1; END IF;
  END chk;
  PROCEDURE as_user(p_user VARCHAR2) IS
  BEGIN
    BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
    apex_session.create_session(p_app_id => 200, p_page_id => 1, p_username => p_user);
  END as_user;
  FUNCTION code_of(p_user VARCHAR2, p_block VARCHAR2) RETURN NUMBER IS
  BEGIN
    as_user(p_user);
    EXECUTE IMMEDIATE 'BEGIN ' || p_block || ' END;';
    RETURN 0;
  EXCEPTION WHEN OTHERS THEN RETURN SQLCODE;
  END code_of;
  FUNCTION user_id_of(p_user VARCHAR2) RETURN NUMBER IS l NUMBER; BEGIN SELECT user_id INTO l FROM lms_users WHERE username = p_user; RETURN l; END;

  -- learner completes C-PRE's single lesson
  PROCEDURE complete_pre(p_user VARCHAR2) IS
    l_e NUMBER; l_s VARCHAR2(20); l_p NUMBER; l_les NUMBER;
  BEGIN
    as_user(p_user);
    lms_enrollment_pkg.enroll_self(l_pre, l_e, l_s);
    SELECT l.lesson_id INTO l_les FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE m.course_id = l_pre;
    lms_progress_pkg.record_event(l_e, l_les, 'COMPLETE', lms_util_pkg.new_uuid, 0, 20, l_p, l_s);
  END complete_pre;
BEGIN
  apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => '&WORKSPACE'));
  SELECT course_id INTO l_course FROM lms_courses WHERE course_code = 'C-CAP';
  SELECT course_id INTO l_pre    FROM lms_courses WHERE course_code = 'C-PRE';
  l_inst := user_id_of('TD_INSTRUCTOR');
  UPDATE lms_courses SET delivery_method = 'CLASSROOM' WHERE course_id = l_course;       -- sessions need a non-self-paced course

  -- ================================================================== venues ======
  chk(code_of('TD_LEARNER1', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(NULL,''V'',NULL,NULL,10,''Y''); END;') = -20403,
      'T-VN-01 learner cannot maintain venues (ORA-20403)');
  chk(code_of('TD_INSTRUCTOR', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(NULL,''V'',NULL,NULL,10,''Y''); END;') = -20403,
      'T-VN-02 instructor (ASSIGNED scope) cannot maintain venues (ORA-20403)');
  as_user('TD_TRAINADMIN');
  l_v  := lms_session_pkg.save_venue(NULL, ' TD Room A ', 'قاعة أ', 'Floor 2', 20, 'Y');
  SELECT COUNT(*) INTO l_n FROM lms_venues WHERE venue_id = l_v AND name_en = 'TD Room A';
  chk(l_n = 1, 'T-VN-03 training admin creates a venue; name is trimmed');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(NULL,''td room a'',NULL,NULL,5,''Y''); END;') = -20409,
      'T-VN-04 duplicate active name (case-insensitive) rejected');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(NULL,''TD Bad'',NULL,NULL,0,''Y''); END;') = -20400,
      'T-VN-05 capacity 0 rejected (ORA-20400)');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(NULL,''TD Bad2'',NULL,NULL,7.5,''Y''); END;') = -20400,
      'T-VN-06 fractional capacity rejected');

  as_user('TD_TRAINADMIN');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.create_session(' || l_course || ',' || l_v || ',' || l_inst
        || ', SYSTIMESTAMP + INTERVAL ''10'' DAY, SYSTIMESTAMP + INTERVAL ''10'' DAY + INTERVAL ''2'' HOUR, 25, NULL, 80); END;') = -20400,
      'T-VN-07 session with more seats than the venue capacity rejected');
  as_user('TD_TRAINADMIN');
  l_sess := lms_session_pkg.create_session(l_course, l_v, l_inst, l_start, l_start + INTERVAL '2' HOUR, 15, NULL, 80);
  chk(l_sess IS NOT NULL, 'T-VN-08 session within capacity is created');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(' || l_v || ',''TD Room A'',NULL,NULL,10,''Y''); END;') = -20409,
      'T-VN-09 capacity below the seats of an upcoming session refused');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.save_venue(' || l_v || ',''TD Room A'',NULL,NULL,20,''N''); END;') = -20409,
      'T-VN-10 venue with an upcoming session cannot be deactivated');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.remove_venue(' || l_v || ');') = -20409,
      'T-VN-11 venue that hosted a session cannot be deleted');
  as_user('TD_TRAINADMIN');
  lms_session_pkg.cancel_session(l_sess, 'test');
  -- after cancelling, only past/cancelled sessions remain, so deactivation is allowed
  as_user('TD_TRAINADMIN');
  l_v := lms_session_pkg.save_venue(l_v, 'TD Room A', 'قاعة أ', 'Floor 2', 20, 'N');
  SELECT COUNT(*) INTO l_n FROM lms_venues WHERE venue_id = l_v AND active_flag = 'N';
  chk(l_n = 1, 'T-VN-13 venue can be deactivated once its sessions are cancelled');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_session_pkg.create_session(' || l_course || ',' || l_v || ',' || l_inst
        || ', SYSTIMESTAMP + INTERVAL ''20'' DAY, SYSTIMESTAMP + INTERVAL ''20'' DAY + INTERVAL ''2'' HOUR, 5, NULL, 80); END;') = -20409,
      'T-VN-14 sessions cannot be created in an inactive venue');
  as_user('TD_TRAINADMIN');
  l_v2 := lms_session_pkg.save_venue(NULL, 'TD Room B', NULL, NULL, NULL, 'Y');           -- unlimited capacity, never used
  lms_session_pkg.remove_venue(l_v2);
  SELECT COUNT(*) INTO l_n FROM lms_venues WHERE venue_id = l_v2;
  chk(l_n = 0, 'T-VN-15 an unused venue can be deleted');
  SELECT COUNT(*) INTO l_n FROM v_lms_venues_admin WHERE venue_id = l_v AND sessions_total = 1 AND sessions_upcoming = 0;
  chk(l_n = 1, 'T-VN-16 maintenance view reports usage');
  as_user('TD_LEARNER1');
  SELECT COUNT(*) INTO l_n FROM v_lms_venues_admin;
  chk(l_n = 0, 'T-VN-17 learners see no rows in the venue maintenance view');

  -- ========================================================= feedback reminders ===
  l_u1 := user_id_of('TD_LEARNER1'); l_u2 := user_id_of('TD_LEARNER2'); l_u3 := user_id_of('TD_LEARNER3'); l_um := user_id_of('TD_MANAGER');
  complete_pre('TD_LEARNER1'); complete_pre('TD_LEARNER2'); complete_pre('TD_LEARNER3'); complete_pre('TD_MANAGER');
  SELECT COUNT(*) INTO l_n FROM lms_enrollments WHERE course_id = l_pre AND status = 'COMPLETED';
  chk(l_n = 4, 'T-FR-01 four completions prepared (' || l_n || ')');

  -- learner 2 already reviewed; learner 3 completed long ago; manager is deactivated; learner 1 is the one to remind
  as_user('TD_LEARNER2');
  SELECT enrollment_id INTO l_enr FROM lms_enrollments WHERE user_id = l_u2 AND course_id = l_pre;
  lms_feedback_pkg.submit_review(l_enr, 5, NULL, 'ok');
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '4' DAY WHERE course_id = l_pre AND user_id IN (l_u1, l_u2, l_um);
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '60' DAY WHERE course_id = l_pre AND user_id = l_u3;
  UPDATE lms_users SET status = 'INACTIVE' WHERE user_id = l_um;
  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;

  l_sent := lms_feedback_pkg.send_reminders;
  chk(l_sent = 1, 'T-FR-02 exactly one reminder queued (got ' || l_sent || ')');
  SELECT COUNT(*) INTO l_n FROM lms_notification_queue WHERE template_code = 'FEEDBACK_REMINDER' AND user_id = l_u1;
  chk(l_n = 1, 'T-FR-03 the learner with no review is reminded');
  SELECT COUNT(*) INTO l_n FROM lms_notification_queue WHERE template_code = 'FEEDBACK_REMINDER' AND user_id IN (l_u2, l_u3, l_um);
  chk(l_n = 0, 'T-FR-04 reviewed, out-of-window and inactive users are not reminded');
  SELECT COUNT(*) INTO l_n FROM lms_enrollments WHERE user_id = l_u1 AND course_id = l_pre AND feedback_reminded_at IS NOT NULL;
  chk(l_n = 1, 'T-FR-05 reminder marker stored on the enrolment');
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FR-06 second run sends nothing (one reminder per enrolment)');

  -- too early: completion yesterday is inside the grace period
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '1' DAY, feedback_reminded_at = NULL
   WHERE course_id = l_pre AND user_id = l_u1;
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FR-07 completions younger than FEEDBACK_REMINDER_DAYS are not reminded yet');
  -- policy switch
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '5' DAY WHERE course_id = l_pre AND user_id = l_u1;
  UPDATE lms_system_settings SET setting_value = '0' WHERE setting_key = 'FEEDBACK_REMINDER_DAYS';
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FR-08 FEEDBACK_REMINDER_DAYS = 0 switches reminders off');
  UPDATE lms_system_settings SET setting_value = '3' WHERE setting_key = 'FEEDBACK_REMINDER_DAYS';
  chk(lms_feedback_pkg.send_reminders = 1, 'T-FR-09 re-enabled: the pending learner is reminded');
  SELECT COUNT(*) INTO l_n FROM lms_notification_templates WHERE template_code = 'FEEDBACK_REMINDER';
  chk(l_n = 2, 'T-FR-10 reminder template exists in English and Arabic');

  ROLLBACK;
  DBMS_OUTPUT.put_line(CASE WHEN l_fail = 0 THEN 'ALL TESTS PASSED' ELSE l_fail || ' TEST(S) FAILED' END);
  IF l_fail > 0 THEN RAISE_APPLICATION_ERROR(-20999, l_fail || ' test(s) failed'); END IF;
END;
/
