-- =============================================================================
-- Tests: LMS_SESSION_PKG update_session, complete_session, close_finished_sessions, send_reminders
-- STATUS: written, NOT executed. Requires 00_install + 10_test_data.sql; edit &WORKSPACE. Rolls back everything.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE ON
DEFINE WORKSPACE = LMS
DECLARE
  l_fail PLS_INTEGER := 0;
  l_n NUMBER; l_pre NUMBER; l_instr NUMBER; l_hr NUMBER; l_va NUMBER; l_vb NUMBER; l_vc NUMBER;
  l_s1 NUMBER; l_s2 NUMBER; l_s5 NUMBER; l_st VARCHAR2(20); l_e NUMBER; l_sent NUMBER;
  l_u1 NUMBER; l_u2 NUMBER; l_u3 NUMBER; l_um NUMBER; l_se1 NUMBER;
  l_t0 TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;

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
  FUNCTION queued(p_template VARCHAR2, p_user NUMBER DEFAULT NULL) RETURN NUMBER IS l NUMBER;
  BEGIN SELECT COUNT(*) INTO l FROM lms_notification_queue WHERE template_code = p_template AND (p_user IS NULL OR user_id = p_user); RETURN l; END;
  PROCEDURE enrol_and_register(p_user VARCHAR2, p_session NUMBER) IS
    l_en NUMBER; l_s VARCHAR2(20); l_rs VARCHAR2(20);
  BEGIN
    as_user(p_user);
    lms_enrollment_pkg.enroll_self(l_pre, l_en, l_s);
    lms_session_pkg.register(p_session, l_rs);
  END enrol_and_register;
BEGIN
  apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => '&WORKSPACE'));
  SELECT course_id INTO l_pre FROM lms_courses WHERE course_code = 'C-PRE';
  UPDATE lms_courses SET delivery_method = 'CLASSROOM' WHERE course_id = l_pre;
  l_instr := user_id_of('TD_INSTRUCTOR'); l_hr := user_id_of('TD_HR');
  l_u1 := user_id_of('TD_LEARNER1'); l_u2 := user_id_of('TD_LEARNER2'); l_u3 := user_id_of('TD_LEARNER3'); l_um := user_id_of('TD_MANAGER');

  as_user('TD_TRAINADMIN');
  l_va := lms_session_pkg.save_venue(NULL, 'TD Hall A', NULL, NULL, 20, 'Y');
  l_vb := lms_session_pkg.save_venue(NULL, 'TD Hall B', NULL, NULL, 20, 'Y');
  l_vc := lms_session_pkg.save_venue(NULL, 'TD Hall C', NULL, NULL, 20, 'Y');
  l_s1 := lms_session_pkg.create_session(l_pre, l_va, l_instr, l_t0 + INTERVAL '10' DAY, l_t0 + INTERVAL '10' DAY + INTERVAL '2' HOUR, 2, NULL, 80);
  lms_session_pkg.publish_session(l_s1);
  enrol_and_register('TD_LEARNER1', l_s1);
  enrol_and_register('TD_LEARNER2', l_s1);
  enrol_and_register('TD_LEARNER3', l_s1);              -- seats = 2, so this one is waitlisted
  SELECT COUNT(*) INTO l_n FROM lms_session_enrollments WHERE session_id = l_s1 AND status = 'REGISTERED';
  chk(l_n = 2, 'T-SE-00 setup: 2 registered');
  SELECT COUNT(*) INTO l_n FROM lms_session_enrollments WHERE session_id = l_s1 AND user_id = l_u3 AND status = 'WAITLISTED';
  chk(l_n = 1, 'T-SE-00b setup: third learner waitlisted');

  -- ============================================================ update_session ======
  chk(code_of('TD_LEARNER1', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_va || ',' || l_instr || ',2,NULL,80);') = -20403,
      'T-SE-01 learner cannot edit a session (ORA-20403)');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_va || ',' || l_instr || ',1,NULL,80);') = -20409,
      'T-SE-02 seats below the registered count refused (ORA-20409)');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_va || ',' || l_instr || ',25,NULL,80);') = -20400,
      'T-SE-03 seats above the venue capacity refused (ORA-20400)');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_va || ',' || l_instr || ',2,''http://x.example/a'',80);') = -20400,
      'T-SE-04 non-https meeting link refused');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',NULL,' || l_instr || ',2,NULL,80);') = -20400,
      'T-SE-05 a session needs a venue or a link');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_va || ',' || l_instr || ',2,NULL,150);') = -20400,
      'T-SE-06 attendance threshold outside 0-100 refused');

  -- raising seats promotes the waiting list
  as_user('TD_TRAINADMIN');
  lms_session_pkg.update_session(l_s1, l_va, l_instr, 3, NULL, 80);
  SELECT COUNT(*) INTO l_n FROM lms_session_enrollments WHERE session_id = l_s1 AND user_id = l_u3 AND status = 'REGISTERED';
  chk(l_n = 1, 'T-SE-07 more seats promote the waitlisted learner');
  chk(queued('SESSION_REGISTERED', l_u3) >= 1, 'T-SE-08 promoted learner is notified');

  -- venue change notifies all participants, seats-only change does not
  DELETE FROM lms_notification_queue WHERE template_code = 'SESSION_CHANGED';
  lms_session_pkg.update_session(l_s1, l_va, l_instr, 3, NULL, 80);
  chk(queued('SESSION_CHANGED') = 0, 'T-SE-09 an unchanged place/link/trainer sends no notification');
  lms_session_pkg.update_session(l_s1, l_vb, l_instr, 3, NULL, 80);
  chk(queued('SESSION_CHANGED') = 4, 'T-SE-10 venue change notifies the 3 registered learners and the trainer (' || queued('SESSION_CHANGED') || ')');
  lms_session_pkg.update_session(l_s1, l_vb, l_hr, 3, NULL, 80);
  chk(queued('SESSION_ASSIGNED', l_hr) = 1, 'T-SE-11 the new trainer is notified');
  lms_session_pkg.update_session(l_s1, l_vb, l_instr, 3, NULL, 80);            -- back to TD_INSTRUCTOR

  -- double booking: s2 at the same time, other venue and trainer
  l_s2 := lms_session_pkg.create_session(l_pre, l_vc, l_hr, l_t0 + INTERVAL '10' DAY, l_t0 + INTERVAL '10' DAY + INTERVAL '2' HOUR, 5, NULL, 80);
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s2 || ',' || l_vc || ',' || l_instr || ',5,NULL,80);') = -20409,
      'T-SE-12 trainer already teaching at that time refused');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s2 || ',' || l_vb || ',' || l_hr || ',5,NULL,80);') = -20409,
      'T-SE-13 venue already booked at that time refused');

  -- attendance threshold is locked once attendance exists
  as_user('TD_TRAINADMIN');
  SELECT session_enrollment_id INTO l_se1 FROM lms_session_enrollments WHERE session_id = l_s1 AND user_id = l_u1;
  lms_session_pkg.record_attendance(l_se1, TRUNC(CAST(l_t0 AS DATE)) + 10, 'PRESENT');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_vb || ',' || l_instr || ',3,NULL,70);') = -20409,
      'T-SE-14 threshold change after attendance refused');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s1 || ',' || l_vb || ',' || l_instr || ',3,NULL,80);') = 0,
      'T-SE-15 other edits still allowed after attendance');

  -- started sessions cannot be edited
  UPDATE lms_training_sessions SET start_ts = SYSTIMESTAMP - INTERVAL '1' HOUR, end_ts = SYSTIMESTAMP + INTERVAL '1' HOUR WHERE session_id = l_s2;
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.update_session(' || l_s2 || ',' || l_vc || ',' || l_hr || ',6,NULL,80);') = -20409,
      'T-SE-16 a session that has started cannot be edited');

  -- ================================================================= reminders ======
  -- manager registers while full: ends up waitlisted and must never be reminded
  enrol_and_register('TD_MANAGER', l_s1);
  SELECT COUNT(*) INTO l_n FROM lms_session_enrollments WHERE session_id = l_s1 AND user_id = l_um AND status = 'WAITLISTED';
  chk(l_n = 1, 'T-SR-00 setup: manager waitlisted');
  UPDATE lms_training_sessions SET start_ts = SYSTIMESTAMP + INTERVAL '10' HOUR, end_ts = SYSTIMESTAMP + INTERVAL '12' HOUR,
         instructor_reminded_at = NULL WHERE session_id = l_s1;
  UPDATE lms_session_enrollments SET registered_at = SYSTIMESTAMP - INTERVAL '1' DAY, reminded_long_at = NULL, reminded_short_at = NULL
   WHERE session_id = l_s1;
  DELETE FROM lms_notification_queue WHERE template_code IN ('SESSION_REMINDER','SESSION_INSTRUCTOR_REMINDER');
  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;

  l_sent := lms_session_pkg.send_reminders;
  chk(l_sent = 4, 'T-SR-01 3 registered learners + 1 trainer reminded (got ' || l_sent || ')');
  chk(queued('SESSION_REMINDER') = 3 AND queued('SESSION_INSTRUCTOR_REMINDER', l_instr) = 1, 'T-SR-02 queue holds 3 learner and 1 trainer reminders');
  chk(queued('SESSION_REMINDER', l_um) = 0, 'T-SR-03 waitlisted learner is not reminded');
  chk(lms_session_pkg.send_reminders = 0, 'T-SR-04 second run sends nothing (once per registration)');

  -- 30 minutes before the start: the short reminder
  UPDATE lms_training_sessions SET start_ts = SYSTIMESTAMP + INTERVAL '30' MINUTE, end_ts = SYSTIMESTAMP + INTERVAL '2' HOUR WHERE session_id = l_s1;
  l_sent := lms_session_pkg.send_reminders;
  chk(l_sent = 3, 'T-SR-05 short reminder to the 3 registered learners; trainer not repeated (got ' || l_sent || ')');
  chk(queued('SESSION_REMINDER', l_u1) = 2, 'T-SR-06 learner has received both reminders');
  chk(lms_session_pkg.send_reminders = 0, 'T-SR-07 no repeats');

  -- reschedule clears the markers, so reminders are sent again for the new time
  as_user('TD_TRAINADMIN');
  lms_session_pkg.reschedule(l_s1, SYSTIMESTAMP + INTERVAL '9' HOUR, SYSTIMESTAMP + INTERVAL '11' HOUR);
  SELECT COUNT(*) INTO l_n FROM lms_session_enrollments WHERE session_id = l_s1 AND reminded_long_at IS NULL AND reminded_short_at IS NULL;
  chk(l_n = 4, 'T-SR-08 reschedule clears reminder markers (' || l_n || ' rows)');
  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
  DELETE FROM lms_notification_queue WHERE template_code IN ('SESSION_REMINDER','SESSION_INSTRUCTOR_REMINDER');
  chk(lms_session_pkg.send_reminders = 4, 'T-SR-09 reminders go out again after a reschedule');

  -- someone who registered one hour ago gets no 24 h reminder right after registering
  UPDATE lms_session_enrollments SET reminded_long_at = NULL, reminded_short_at = NULL WHERE session_id = l_s1;
  UPDATE lms_session_enrollments SET registered_at = SYSTIMESTAMP - INTERVAL '1' HOUR WHERE session_id = l_s1 AND user_id = l_u1;
  DELETE FROM lms_notification_queue WHERE template_code = 'SESSION_REMINDER';
  l_sent := lms_session_pkg.send_reminders;
  chk(queued('SESSION_REMINDER', l_u1) = 0 AND queued('SESSION_REMINDER', l_u2) = 1,
      'T-SR-10 a fresh registration is skipped, the others are reminded (sent ' || l_sent || ')');

  -- policy switches
  UPDATE lms_session_enrollments SET reminded_long_at = NULL, reminded_short_at = NULL;
  UPDATE lms_training_sessions SET instructor_reminded_at = NULL WHERE session_id = l_s1;
  UPDATE lms_system_settings SET setting_value = '0' WHERE setting_key IN ('SESSION_REMINDER_LONG_HOURS','SESSION_REMINDER_SHORT_HOURS');
  chk(lms_session_pkg.send_reminders = 0, 'T-SR-11 both reminders switched off by policy');
  UPDATE lms_system_settings SET setting_value = '24' WHERE setting_key = 'SESSION_REMINDER_LONG_HOURS';
  UPDATE lms_system_settings SET setting_value = '1'  WHERE setting_key = 'SESSION_REMINDER_SHORT_HOURS';

  -- cancelled sessions are never reminded
  UPDATE lms_session_enrollments SET reminded_long_at = NULL, reminded_short_at = NULL WHERE session_id = l_s1;
  UPDATE lms_training_sessions SET status = 'CANCELLED' WHERE session_id = l_s1;
  chk(lms_session_pkg.send_reminders = 0, 'T-SR-12 cancelled sessions send no reminders');
  UPDATE lms_training_sessions SET status = 'PUBLISHED' WHERE session_id = l_s1;

  -- ================================================================== completion ======
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.complete_session(' || l_s1 || ');') = -20409,
      'T-SC-01 a session that has not ended cannot be completed');
  UPDATE lms_training_sessions SET start_ts = SYSTIMESTAMP - INTERVAL '2' DAY, end_ts = SYSTIMESTAMP - INTERVAL '1' DAY WHERE session_id = l_s1;
  chk(code_of('TD_LEARNER1', 'lms_session_pkg.complete_session(' || l_s1 || ');') = -20403, 'T-SC-02 learner cannot complete a session (ORA-20403)');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.complete_session(' || l_s1 || ');') = 0, 'T-SC-03 training admin completes an ended session');
  SELECT COUNT(*) INTO l_n FROM lms_training_sessions WHERE session_id = l_s1 AND status = 'COMPLETED';
  chk(l_n = 1, 'T-SC-04 status is COMPLETED');
  chk(code_of('TD_TRAINADMIN', 'lms_session_pkg.complete_session(' || l_s1 || ');') = -20409, 'T-SC-05 completing twice refused');

  -- nightly auto-close (sessions that ended > SESSION_AUTOCLOSE_DAYS ago)
  as_user('TD_TRAINADMIN');
  l_s5 := lms_session_pkg.create_session(l_pre, l_va, l_instr, SYSTIMESTAMP - INTERVAL '12' DAY, SYSTIMESTAMP - INTERVAL '12' DAY + INTERVAL '2' HOUR, 5, NULL, 80);
  lms_session_pkg.publish_session(l_s5);
  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
  UPDATE lms_system_settings SET setting_value = '0' WHERE setting_key = 'SESSION_AUTOCLOSE_DAYS';
  chk(lms_session_pkg.close_finished_sessions = 0, 'T-SC-06 auto-close off by policy');
  UPDATE lms_system_settings SET setting_value = '7' WHERE setting_key = 'SESSION_AUTOCLOSE_DAYS';
  chk(lms_session_pkg.close_finished_sessions >= 1, 'T-SC-07 auto-close completes sessions that ended more than 7 days ago');
  SELECT COUNT(*) INTO l_n FROM lms_training_sessions WHERE session_id = l_s5 AND status = 'COMPLETED';
  chk(l_n = 1, 'T-SC-08 the old session is COMPLETED');

  SELECT COUNT(*) INTO l_n FROM lms_notification_templates WHERE template_code IN ('SESSION_REMINDER','SESSION_INSTRUCTOR_REMINDER','SESSION_CHANGED','SESSION_ASSIGNED');
  chk(l_n = 8, 'T-SC-09 the four new templates exist in English and Arabic');

  ROLLBACK;
  DBMS_OUTPUT.put_line(CASE WHEN l_fail = 0 THEN 'ALL TESTS PASSED' ELSE l_fail || ' TEST(S) FAILED' END);
  IF l_fail > 0 THEN RAISE_APPLICATION_ERROR(-20999, l_fail || ' test(s) failed'); END IF;
END;
/
