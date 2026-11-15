-- =============================================================================
-- Tests: second feedback nudge (LMS_FEEDBACK_PKG.SEND_REMINDERS) and calendar invites (LMS_CALENDAR_PKG + queue hooks)
-- STATUS: written, NOT executed. Requires 00_install + 10_test_data.sql; edit &WORKSPACE. Rolls back everything.
-- Mail delivery itself (APEX_MAIL + attachment) is NOT covered here: it needs a configured mail server; see doc 07.
-- LMS_CALENDAR_PKG.BUILD_ICS is ACCESSIBLE BY the notification package only, so these tests read the file through the
-- user-facing MY_SESSION_ICS under an APEX session.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE ON
DEFINE WORKSPACE = LMS
DECLARE
  l_fail PLS_INTEGER := 0;
  l_n NUMBER; l_pre NUMBER; l_adv NUMBER; l_instr NUMBER; l_hr NUMBER; l_venue NUMBER; l_s1 NUMBER; l_sent NUMBER; l_seq0 NUMBER; l_seq1 NUMBER;
  l_u1 NUMBER; l_u2 NUMBER; l_u3 NUMBER; l_um NUMBER; l_se2 NUMBER; l_ics CLOB; l_txt CLOB; l_ok BOOLEAN;
  l_t0 TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
  c_crlf CONSTANT VARCHAR2(2) := CHR(13) || CHR(10);

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
  FUNCTION queued_ics(p_template VARCHAR2, p_user NUMBER, p_method VARCHAR2) RETURN NUMBER IS l NUMBER;
  BEGIN SELECT COUNT(*) INTO l FROM lms_notification_queue
         WHERE template_code = p_template AND user_id = p_user AND attach_kind = 'SESSION_ICS' AND attach_method = p_method AND attach_ref = l_s1; RETURN l; END;
  FUNCTION seq_of(p_ics CLOB) RETURN NUMBER IS BEGIN RETURN TO_NUMBER(REGEXP_SUBSTR(p_ics, 'SEQUENCE:([0-9]+)', 1, 1, NULL, 1)); END;
  FUNCTION lines_ok(p_ics CLOB) RETURN BOOLEAN IS      -- every physical line <= 75 octets, CRLF only
    l_pos PLS_INTEGER := 1; l_end PLS_INTEGER; l_line VARCHAR2(4000);
  BEGIN
    LOOP
      l_end := INSTR(p_ics, c_crlf, l_pos);
      EXIT WHEN l_end = 0;
      l_line := SUBSTR(p_ics, l_pos, l_end - l_pos);
      IF LENGTHB(l_line) > 75 OR INSTR(l_line, CHR(10)) > 0 THEN RETURN FALSE; END IF;
      l_pos := l_end + 2;
    END LOOP;
    RETURN TRUE;
  END lines_ok;
  PROCEDURE enrol_adv(p_user VARCHAR2) IS l_e NUMBER; l_s VARCHAR2(20);   -- C-ADV requires C-PRE, which these learners completed above
  BEGIN as_user(p_user); lms_enrollment_pkg.enroll_self(l_adv, l_e, l_s); END;
  PROCEDURE complete_pre(p_user VARCHAR2) IS l_e NUMBER; l_s VARCHAR2(20); l_p NUMBER; l_les NUMBER;
  BEGIN
    as_user(p_user);
    lms_enrollment_pkg.enroll_self(l_pre, l_e, l_s);
    SELECT l.lesson_id INTO l_les FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE m.course_id = l_pre;
    lms_progress_pkg.record_event(l_e, l_les, 'COMPLETE', lms_util_pkg.new_uuid, 0, 20, l_p, l_s);
  END complete_pre;
BEGIN
  apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => '&WORKSPACE'));
  SELECT course_id INTO l_pre FROM lms_courses WHERE course_code = 'C-PRE';
  SELECT course_id INTO l_adv FROM lms_courses WHERE course_code = 'C-ADV';
  l_instr := user_id_of('TD_INSTRUCTOR'); l_hr := user_id_of('TD_HR');
  l_u1 := user_id_of('TD_LEARNER1'); l_u2 := user_id_of('TD_LEARNER2'); l_u3 := user_id_of('TD_LEARNER3'); l_um := user_id_of('TD_MANAGER');

  -- ============================================================== second feedback nudge ======
  complete_pre('TD_LEARNER1'); complete_pre('TD_LEARNER2'); complete_pre('TD_LEARNER3'); complete_pre('TD_MANAGER');
  as_user('TD_LEARNER3');
  DECLARE l_e NUMBER; BEGIN
    SELECT enrollment_id INTO l_e FROM lms_enrollments WHERE user_id = l_u3 AND course_id = l_pre;
    lms_feedback_pkg.submit_review(l_e, 4, NULL, 'fine');
  END;
  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
  -- L1: first reminder 8 days ago, nothing given  -> nudge
  -- L2: first reminder 2 days ago                  -> too early
  -- L3: reminder 8 days ago but already reviewed   -> no nudge
  -- manager: reminder 8 days ago, nudge already sent -> never twice
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '12' DAY, feedback_reminded_at = SYSTIMESTAMP - INTERVAL '8' DAY WHERE course_id = l_pre AND user_id IN (l_u1, l_u3, l_um);
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '5'  DAY, feedback_reminded_at = SYSTIMESTAMP - INTERVAL '2' DAY WHERE course_id = l_pre AND user_id = l_u2;
  UPDATE lms_enrollments SET feedback_reminded2_at = SYSTIMESTAMP - INTERVAL '1' DAY WHERE course_id = l_pre AND user_id = l_um;
  DELETE FROM lms_notification_queue WHERE template_code IN ('FEEDBACK_REMINDER','FEEDBACK_NUDGE');

  l_sent := lms_feedback_pkg.send_reminders;
  chk(l_sent = 1, 'T-FN-01 exactly one nudge sent (got ' || l_sent || ')');
  chk(queued('FEEDBACK_NUDGE', l_u1) = 1, 'T-FN-02 the learner with nothing given is nudged');
  chk(queued('FEEDBACK_NUDGE', l_u2) = 0 AND queued('FEEDBACK_NUDGE', l_u3) = 0 AND queued('FEEDBACK_NUDGE', l_um) = 0,
      'T-FN-03 too early, already reviewed and already nudged are skipped');
  SELECT COUNT(*) INTO l_n FROM lms_enrollments WHERE user_id = l_u1 AND course_id = l_pre AND feedback_reminded2_at IS NOT NULL;
  chk(l_n = 1, 'T-FN-04 nudge marker stored');
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FN-05 second run sends nothing (at most two messages per enrolment)');

  -- window and switch
  UPDATE lms_enrollments SET feedback_reminded2_at = NULL, completed_at = SYSTIMESTAMP - INTERVAL '45' DAY,
         feedback_reminded_at = SYSTIMESTAMP - INTERVAL '40' DAY WHERE course_id = l_pre AND user_id = l_u1;
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FN-06 completions older than FEEDBACK_REMINDER_WINDOW_DAYS get no nudge');
  UPDATE lms_enrollments SET completed_at = SYSTIMESTAMP - INTERVAL '12' DAY, feedback_reminded_at = SYSTIMESTAMP - INTERVAL '8' DAY WHERE course_id = l_pre AND user_id = l_u1;
  UPDATE lms_system_settings SET setting_value = '0' WHERE setting_key = 'FEEDBACK_NUDGE2_DAYS';
  chk(lms_feedback_pkg.send_reminders = 0, 'T-FN-07 FEEDBACK_NUDGE2_DAYS = 0 switches the nudge off');
  UPDATE lms_system_settings SET setting_value = '7' WHERE setting_key = 'FEEDBACK_NUDGE2_DAYS';
  chk(lms_feedback_pkg.send_reminders = 1, 'T-FN-08 back on: nudged once');
  -- the first reminder still works independently (and the nudge never fires for a row that was never reminded)
  UPDATE lms_enrollments SET feedback_reminded_at = NULL, feedback_reminded2_at = NULL, completed_at = SYSTIMESTAMP - INTERVAL '4' DAY
   WHERE course_id = l_pre AND user_id = l_u1;
  DELETE FROM lms_notification_queue WHERE template_code IN ('FEEDBACK_REMINDER','FEEDBACK_NUDGE');
  l_sent := lms_feedback_pkg.send_reminders;
  chk(queued('FEEDBACK_REMINDER', l_u1) = 1 AND queued('FEEDBACK_NUDGE', l_u1) = 0, 'T-FN-09 never-reminded learner gets the first reminder, not the nudge');
  SELECT COUNT(*) INTO l_n FROM lms_notification_templates WHERE template_code = 'FEEDBACK_NUDGE';
  chk(l_n = 2, 'T-FN-10 nudge template exists in English and Arabic');

  -- ============================================================== calendar invites ======
  UPDATE lms_courses SET delivery_method = 'CLASSROOM', title_en = 'Intro, Part 2; Basics \ Day' WHERE course_id = l_adv;
  as_user('TD_TRAINADMIN');
  l_venue := lms_session_pkg.save_venue(NULL, 'TD Hall', 'قاعة', 'Floor 2, Main; Tower', 20, 'Y');
  l_s1 := lms_session_pkg.create_session(l_adv, l_venue, l_instr, l_t0 + INTERVAL '10' DAY, l_t0 + INTERVAL '10' DAY + INTERVAL '2' HOUR, 2, 'https://meet.example.invalid/room', 80);
  DELETE FROM lms_notification_queue WHERE template_code LIKE 'SESSION\_%' ESCAPE '\';
  lms_session_pkg.publish_session(l_s1);
  chk(queued_ics('SESSION_ASSIGNED', l_instr, 'REQUEST') = 1, 'T-IC-01 publishing sends the trainer a calendar invite');

  -- enrol in C-ADV, then register (L1, L2 take the 2 seats, the manager is waitlisted)
  enrol_adv('TD_LEARNER1'); enrol_adv('TD_LEARNER2'); enrol_adv('TD_MANAGER');
  as_user('TD_LEARNER1'); DECLARE l_st VARCHAR2(20); BEGIN lms_session_pkg.register(l_s1, l_st); END;
  as_user('TD_LEARNER2'); DECLARE l_st VARCHAR2(20); BEGIN lms_session_pkg.register(l_s1, l_st); END;
  as_user('TD_MANAGER');  DECLARE l_st VARCHAR2(20); BEGIN lms_session_pkg.register(l_s1, l_st); END;
  chk(queued_ics('SESSION_REGISTERED', l_u1, 'REQUEST') = 1 AND queued_ics('SESSION_REGISTERED', l_u2, 'REQUEST') = 1,
      'T-IC-02 registration queues an invite for each registered learner');
  SELECT COUNT(*) INTO l_n FROM lms_notification_queue WHERE template_code = 'SESSION_REGISTERED' AND user_id = l_um AND attach_kind IS NULL;
  chk(l_n = 1, 'T-IC-03 the waitlisted learner gets the notice WITHOUT a calendar file');

  -- file content
  as_user('TD_LEARNER1');
  l_ics := lms_calendar_pkg.my_session_ics(l_s1);
  chk(SUBSTR(l_ics, 1, 17) = 'BEGIN:VCALENDAR' || c_crlf AND SUBSTR(l_ics, -15) = 'END:VCALENDAR' || c_crlf, 'T-IC-04 well-formed calendar envelope, CRLF endings');
  chk(INSTR(l_ics, 'METHOD:REQUEST') > 0 AND INSTR(l_ics, 'STATUS:CONFIRMED') > 0 AND INSTR(l_ics, 'UID:session-' || l_s1 || '@') > 0,
      'T-IC-05 METHOD, STATUS and a stable UID are present');
  chk(REGEXP_LIKE(l_ics, 'DTSTART:[0-9]{8}T[0-9]{6}Z' || c_crlf) AND REGEXP_LIKE(l_ics, 'DTEND:[0-9]{8}T[0-9]{6}Z' || c_crlf), 'T-IC-06 start and end are UTC timestamps');
  chk(INSTR(l_ics, 'BEGIN:VALARM') > 0 AND INSTR(l_ics, 'TRIGGER:-PT60M') > 0, 'T-IC-07 default 60-minute alarm');
  chk(INSTR(l_ics, 'td_learner1@example.invalid') > 0 AND INSTR(l_ics, 'td_learner2@example.invalid') = 0 AND INSTR(l_ics, 'td_manager@example.invalid') = 0,
      'T-IC-08 only the recipient appears as attendee (no other learner''s e-mail)');
  chk(INSTR(l_ics, 'https://meet.example.invalid/room') > 0, 'T-IC-09 registered learner receives the join link');
  l_txt := REPLACE(l_ics, c_crlf || ' ', '');                                    -- RFC 5545 unfolding
  chk(INSTR(l_txt, 'SUMMARY:Intro\, Part 2\; Basics \\ Day') > 0, 'T-IC-10 text values are escaped (comma, semicolon, backslash)');
  chk(INSTR(l_txt, 'LOCATION:TD Hall\, Floor 2\, Main\; Tower') > 0, 'T-IC-11 location escaped');
  chk(lines_ok(l_ics), 'T-IC-12 no physical line exceeds 75 octets');

  -- Arabic user: Arabic summary, folded without breaking characters
  UPDATE lms_courses SET title_ar = 'مقدمة في الأمن السيبراني للموظفين الجدد - المستوى الأول والثاني والثالث والرابع' WHERE course_id = l_adv;
  UPDATE lms_users SET preferred_lang = 'ar' WHERE user_id = l_u1;
  as_user('TD_LEARNER1');
  l_ics := lms_calendar_pkg.my_session_ics(l_s1);
  l_txt := REPLACE(l_ics, c_crlf || ' ', '');
  chk(INSTR(l_txt, 'SUMMARY:مقدمة في الأمن السيبراني للموظفين الجدد - المستوى الأول والثاني والثالث والرابع') > 0, 'T-IC-13 Arabic title survives folding intact');
  chk(lines_ok(l_ics) AND INSTR(l_ics, c_crlf || ' ') > 0, 'T-IC-14 long Arabic line is folded within 75 octets');
  UPDATE lms_users SET preferred_lang = 'en' WHERE user_id = l_u1;

  -- access rules
  chk(code_of('TD_LEARNER3', 'DECLARE x CLOB; BEGIN x := lms_calendar_pkg.my_session_ics(' || l_s1 || '); END;') = -20403,
      'T-IC-15 a user who is not registered cannot download the file (ORA-20403)');
  chk(code_of('TD_MANAGER', 'DECLARE x CLOB; BEGIN x := lms_calendar_pkg.my_session_ics(' || l_s1 || '); END;') = -20409,
      'T-IC-16 a waitlisted learner cannot download it yet (ORA-20409)');
  chk(code_of('TD_LEARNER1', 'DECLARE x CLOB; BEGIN x := lms_calendar_pkg.my_session_ics(-1); END;') = -20404, 'T-IC-17 unknown session (ORA-20404)');
  as_user('TD_INSTRUCTOR');
  l_ics := lms_calendar_pkg.my_session_ics(l_s1);
  chk(INSTR(l_ics, 'METHOD:REQUEST') > 0 AND INSTR(l_ics, 'td_instructor@example.invalid') > 0, 'T-IC-18 the session trainer can download their own entry');

  -- reschedule: updated invite with a higher SEQUENCE, registered learners only
  as_user('TD_LEARNER1'); l_seq0 := seq_of(lms_calendar_pkg.my_session_ics(l_s1));
  DELETE FROM lms_notification_queue WHERE template_code = 'SESSION_RESCHEDULED';
  as_user('TD_TRAINADMIN');
  lms_session_pkg.reschedule(l_s1, SYSTIMESTAMP + INTERVAL '11' DAY, SYSTIMESTAMP + INTERVAL '11' DAY + INTERVAL '2' HOUR);
  chk(queued_ics('SESSION_RESCHEDULED', l_u1, 'REQUEST') = 1 AND queued_ics('SESSION_RESCHEDULED', l_u2, 'REQUEST') = 1
      AND queued_ics('SESSION_RESCHEDULED', l_instr, 'REQUEST') = 1, 'T-IC-19 reschedule queues updated invites for learners and trainer');
  SELECT COUNT(*) INTO l_n FROM lms_notification_queue WHERE template_code = 'SESSION_RESCHEDULED' AND user_id = l_um AND attach_kind IS NULL;
  chk(l_n = 1, 'T-IC-20 waitlisted learner is told about the new time, without a calendar file');
  as_user('TD_LEARNER1'); l_seq1 := seq_of(lms_calendar_pkg.my_session_ics(l_s1));
  chk(l_seq1 > l_seq0, 'T-IC-21 SEQUENCE increased (' || l_seq0 || ' -> ' || l_seq1 || ')');

  -- unregistering withdraws the entry; the waitlisted learner is promoted and invited
  DELETE FROM lms_notification_queue WHERE template_code IN ('SESSION_UNREGISTERED','SESSION_REGISTERED');
  as_user('TD_LEARNER2');
  SELECT session_enrollment_id INTO l_se2 FROM lms_session_enrollments WHERE session_id = l_s1 AND user_id = l_u2;
  lms_session_pkg.cancel_registration(l_se2);
  chk(queued_ics('SESSION_UNREGISTERED', l_u2, 'CANCEL') = 1, 'T-IC-22 unregistering queues a CANCEL for that learner');
  chk(queued_ics('SESSION_REGISTERED', l_um, 'REQUEST') = 1, 'T-IC-23 the promoted learner receives an invite');
  as_user('TD_LEARNER2');
  l_ics := lms_calendar_pkg.my_session_ics(l_s1);
  chk(INSTR(l_ics, 'METHOD:CANCEL') > 0 AND INSTR(l_ics, 'STATUS:CANCELLED') > 0 AND INSTR(l_ics, 'BEGIN:VALARM') = 0 AND INSTR(l_ics, 'https://meet') = 0,
      'T-IC-24 the withdrawal carries CANCEL, no alarm and no join link');

  -- place change and trainer change
  DELETE FROM lms_notification_queue WHERE template_code IN ('SESSION_CHANGED','SESSION_ASSIGNED','SESSION_UNASSIGNED');
  as_user('TD_TRAINADMIN');
  lms_session_pkg.update_session(l_s1, l_venue, l_hr, 2, 'https://meet.example.invalid/room', 80);
  chk(queued_ics('SESSION_UNASSIGNED', l_instr, 'CANCEL') = 1 AND queued_ics('SESSION_ASSIGNED', l_hr, 'REQUEST') = 1,
      'T-IC-25 trainer change withdraws the old trainer''s entry and invites the new one');
  chk(queued_ics('SESSION_CHANGED', l_u1, 'REQUEST') = 1 AND queued_ics('SESSION_CHANGED', l_um, 'REQUEST') = 1, 'T-IC-26 registered learners receive the updated invite');

  -- settings
  UPDATE lms_system_settings SET setting_value = '0' WHERE setting_key = 'ICS_ALARM_MINUTES';
  as_user('TD_LEARNER1');
  chk(INSTR(lms_calendar_pkg.my_session_ics(l_s1), 'BEGIN:VALARM') = 0, 'T-IC-27 ICS_ALARM_MINUTES = 0 removes the alarm');

  -- cancelling the session withdraws everything
  DELETE FROM lms_notification_queue WHERE template_code = 'SESSION_CANCELLED';
  as_user('TD_TRAINADMIN');
  lms_session_pkg.cancel_session(l_s1, 'test');
  chk(queued_ics('SESSION_CANCELLED', l_u1, 'CANCEL') = 1 AND queued_ics('SESSION_CANCELLED', l_um, 'CANCEL') = 1 AND queued_ics('SESSION_CANCELLED', l_hr, 'CANCEL') = 1,
      'T-IC-28 session cancellation withdraws the entry for registered learners and the trainer');
  SELECT COUNT(*) INTO l_n FROM lms_notification_queue WHERE template_code = 'SESSION_CANCELLED' AND attach_kind IS NULL;
  chk(l_n = 0, 'T-IC-29 (no waitlisted learners remain, so every cancellation notice carries a CANCEL file)');
  as_user('TD_LEARNER1');
  chk(INSTR(lms_calendar_pkg.my_session_ics(l_s1), 'METHOD:CANCEL') > 0, 'T-IC-30 downloading after cancellation returns CANCEL');
  SELECT COUNT(*) INTO l_n FROM lms_notification_templates WHERE template_code IN ('SESSION_UNREGISTERED','SESSION_UNASSIGNED');
  chk(l_n = 4, 'T-IC-31 withdrawal templates exist in English and Arabic');

  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
  ROLLBACK;
  DBMS_OUTPUT.put_line(CASE WHEN l_fail = 0 THEN 'ALL TESTS PASSED' ELSE l_fail || ' TEST(S) FAILED' END);
  IF l_fail > 0 THEN RAISE_APPLICATION_ERROR(-20999, l_fail || ' test(s) failed'); END IF;
END;
/
