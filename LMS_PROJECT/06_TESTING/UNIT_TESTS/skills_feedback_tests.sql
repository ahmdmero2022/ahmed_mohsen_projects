-- =============================================================================
-- Tests for LMS_SKILL_PKG and LMS_FEEDBACK_PKG   STATUS: written, NOT executed
-- Requires: 02_DATABASE 00_install + 10_test_data.sql loaded (TD_* users, courses C-CAP / C-QUIZ).
-- Runs as the schema owner and impersonates users with an APEX session, because the packages derive the caller
-- from the authenticated APEX session (never from a parameter). Edit &WORKSPACE for your environment.
-- Everything is rolled back at the end. Output: PASS/FAIL lines, final error if any FAIL.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE ON
DEFINE WORKSPACE = LMS
DECLARE
  l_fail   PLS_INTEGER := 0;
  l_n      NUMBER;
  l_skill  NUMBER; l_skill2 NUMBER; l_form NUMBER; l_form2 NUMBER; l_q1 NUMBER; l_q2 NUMBER;
  l_course NUMBER; l_enr NUMBER; l_st VARCHAR2(20); l_pct NUMBER; l_review NUMBER;
  l_pos    NUMBER; l_pos2 NUMBER; l_cat NUMBER;

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

  /* Runs a PL/SQL block as the given user and returns the SQLCODE it raised (0 = none). Test code only. */
  FUNCTION code_of(p_user VARCHAR2, p_block VARCHAR2) RETURN NUMBER IS
  BEGIN
    as_user(p_user);
    EXECUTE IMMEDIATE 'BEGIN ' || p_block || ' END;';
    RETURN 0;
  EXCEPTION WHEN OTHERS THEN RETURN SQLCODE;
  END code_of;
BEGIN
  apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => '&WORKSPACE'));
  SELECT course_id INTO l_course FROM lms_courses WHERE course_code = 'C-CAP';
  SELECT MIN(category_id) INTO l_cat FROM lms_categories;
  SELECT position_id INTO l_pos  FROM lms_positions WHERE position_code = 'TD-ANALYST';
  SELECT position_id INTO l_pos2 FROM lms_positions WHERE position_code = 'TD-LEAD';

  -- ============================================================== skills ======
  chk(code_of('TD_LEARNER1', 'DECLARE x NUMBER; BEGIN x := lms_skill_pkg.save_skill(NULL,''X1'',''x'',NULL,NULL,''Y''); END;') = -20403,
      'T-SK-01 learner cannot create a skill (ORA-20403)');
  chk(code_of('TD_INSTRUCTOR', 'DECLARE x NUMBER; BEGIN x := lms_skill_pkg.save_skill(NULL,''X1'',''x'',NULL,NULL,''Y''); END;') = -20403,
      'T-SK-02 instructor cannot maintain the framework (ORA-20403)');

  as_user('TD_HR');
  l_skill  := lms_skill_pkg.save_skill(NULL, ' td-sql ', 'SQL', 'لغة SQL', 'Technical', 'Y');
  l_skill2 := lms_skill_pkg.save_skill(NULL, 'TD-COMM', 'Communication', NULL, 'Soft', 'Y');
  SELECT COUNT(*) INTO l_n FROM lms_skills WHERE skill_id = l_skill AND skill_code = 'TD-SQL';
  chk(l_n = 1, 'T-SK-03 HR creates a skill; code is trimmed and upper-cased');
  chk(code_of('TD_HR', 'DECLARE x NUMBER; BEGIN x := lms_skill_pkg.save_skill(NULL,''TD-SQL'',''dup'',NULL,NULL,''Y''); END;') = -20409,
      'T-SK-04 duplicate skill code is rejected (ORA-20409)');
  chk(code_of('TD_HR', 'DECLARE x NUMBER; BEGIN x := lms_skill_pkg.save_skill(NULL,''bad code!'',''x'',NULL,NULL,''Y''); END;') = -20400,
      'T-SK-05 invalid code characters rejected (ORA-20400)');

  as_user('TD_HR');
  lms_skill_pkg.set_position_skill(l_pos, l_skill, 3);
  lms_skill_pkg.set_position_skill(l_pos, l_skill2, 2);
  SELECT required_level INTO l_n FROM lms_position_skills WHERE position_id = l_pos AND skill_id = l_skill;
  chk(l_n = 3, 'T-SK-06 position requirement saved');
  lms_skill_pkg.set_position_skill(l_pos, l_skill, 4);                       -- update, not duplicate
  SELECT COUNT(*) INTO l_n FROM lms_position_skills WHERE position_id = l_pos AND skill_id = l_skill AND required_level = 4;
  chk(l_n = 1, 'T-SK-07 requirement update is idempotent (MERGE)');
  chk(code_of('TD_HR', 'lms_skill_pkg.set_position_skill(' || l_pos || ',' || l_skill || ',6);') = -20400,
      'T-SK-08 level 6 rejected (ORA-20400)');
  chk(code_of('TD_HR', 'lms_skill_pkg.set_position_skill(' || l_pos || ',' || l_skill || ',2.5);') = -20400,
      'T-SK-09 fractional level rejected');
  chk(code_of('TD_HR', 'lms_skill_pkg.remove_skill(' || l_skill || ');') = -20409,
      'T-SK-10 a skill in use cannot be deleted (ORA-20409)');
  as_user('TD_HR');
  l_n := lms_skill_pkg.copy_position_skills(l_pos, l_pos2);
  chk(l_n = 2, 'T-SK-11 copy_position_skills adds the 2 requirements to the target (added ' || l_n || ')');
  chk(lms_skill_pkg.copy_position_skills(l_pos, l_pos2) = 0, 'T-SK-12 second copy adds nothing (never overwrites)');
  lms_skill_pkg.set_position_skill(l_pos2, l_skill, NULL);
  SELECT COUNT(*) INTO l_n FROM lms_position_skills WHERE position_id = l_pos2 AND skill_id = l_skill;
  chk(l_n = 0, 'T-SK-13 NULL level removes the requirement');
  l_n := lms_skill_pkg.save_skill(l_skill2, 'TD-COMM', 'Communication', NULL, 'Soft', 'N');   -- deactivate
  chk(code_of('TD_HR', 'lms_skill_pkg.set_position_skill(' || l_pos2 || ',' || l_skill2 || ',2);') = -20409,
      'T-SK-14 inactive skill cannot be required (ORA-20409)');

  -- course -> skill links: authors of the course, not strangers
  chk(code_of('TD_INSTRUCTOR', 'lms_skill_pkg.set_course_skill(' || l_course || ',' || l_skill || ',2);') = 0,
      'T-SK-15 instructor tags skills on a course they teach');
  chk(code_of('TD_LEARNER2', 'lms_skill_pkg.set_course_skill(' || l_course || ',' || l_skill || ',2);') = -20403,
      'T-SK-16 learner cannot tag course skills (ORA-20403)');

  -- completion credits the skill and closes the gap (Employee -> Course -> Skill)
  UPDATE lms_users SET position_id = l_pos WHERE username = 'TD_LEARNER1';
  as_user('TD_LEARNER1');
  lms_enrollment_pkg.enroll_self(l_course, l_enr, l_st);
  FOR r IN (SELECT l.lesson_id FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
             WHERE m.course_id = l_course AND l.required_flag = 'Y' ORDER BY m.sort_order, l.sort_order) LOOP
    lms_progress_pkg.record_event(l_enr, r.lesson_id, 'COMPLETE', lms_util_pkg.new_uuid, 0, 30, l_pct, l_st);
  END LOOP;
  chk(l_st = 'COMPLETED', 'T-SK-17 course completed (status ' || l_st || ')');
  SELECT NVL(MAX(current_level), 0) INTO l_n FROM lms_user_skills us
    JOIN lms_users u ON u.user_id = us.user_id WHERE u.username = 'TD_LEARNER1' AND us.skill_id = l_skill;
  chk(l_n = 2, 'T-SK-18 completion credited level 2 (got ' || l_n || ')');
  SELECT COUNT(*) INTO l_n FROM v_lms_my_skills WHERE skill_id = l_skill AND gap = 2;      -- required 4, has 2
  chk(l_n = 1, 'T-SK-19 learner sees remaining gap of 2 for the skill');

  -- ============================================================ feedback ======
  chk(code_of('TD_LEARNER1', 'DECLARE x NUMBER; BEGIN x := lms_feedback_pkg.save_form(NULL,''x'',NULL,''Y''); END;') = -20403,
      'T-FB-01 learner cannot author forms (ORA-20403)');
  as_user('TD_TRAINADMIN');
  l_form := lms_feedback_pkg.save_form(NULL, 'TD form', 'نموذج', 'Y');
  l_q1 := lms_feedback_pkg.save_form_question(NULL, l_form, 'Content was relevant', NULL, 'RATING', 1);
  l_q2 := lms_feedback_pkg.save_form_question(NULL, l_form, 'Comments?', NULL, 'TEXT', 2);
  chk(l_q1 IS NOT NULL AND l_q2 IS NOT NULL, 'T-FB-02 training admin builds a form with two questions');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_feedback_pkg.save_form_question(NULL,' || l_form || ',''x'',NULL,''STARS'',3); END;') = -20400,
      'T-FB-03 invalid answer type rejected');
  lms_feedback_pkg.assign_form(l_course, l_form);
  SELECT COUNT(*) INTO l_n FROM lms_courses WHERE course_id = l_course AND feedback_form_id = l_form;
  chk(l_n = 1, 'T-FB-04 form assigned to the course');

  -- learner has completed C-CAP (above)
  as_user('TD_LEARNER1');
  SELECT COUNT(*) INTO l_n FROM v_lms_my_feedback_todo WHERE enrollment_id = l_enr;
  chk(l_n = 1, 'T-FB-05 completed course appears in the learner''s feedback to-do list');
  lms_feedback_pkg.submit_answer(l_enr, l_q1, 5, NULL);
  lms_feedback_pkg.submit_answer(l_enr, l_q2, NULL, 'Very useful');
  chk(code_of('TD_LEARNER1', 'lms_feedback_pkg.submit_answer(' || l_enr || ',' || l_q1 || ',4,NULL);') = -20409,
      'T-FB-06 duplicate answer rejected (ORA-20409)');
  chk(code_of('TD_LEARNER2', 'lms_feedback_pkg.submit_answer(' || l_enr || ',' || l_q1 || ',4,NULL);') = -20403,
      'T-FB-07 another learner cannot answer on this enrolment (ORA-20403)');
  chk(code_of('TD_LEARNER1', 'lms_feedback_pkg.submit_answer(' || l_enr || ',-1,4,NULL);') = -20404,
      'T-FB-08 question not on the course form rejected (ORA-20404)');

  as_user('TD_TRAINADMIN');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_feedback_pkg.save_form_question(' || l_q1 || ',' || l_form || ',''Changed wording'',NULL,''RATING'',1); END;') = -20409,
      'T-FB-09 wording of an answered question is immutable');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_feedback_pkg.save_form_question(' || l_q1 || ',' || l_form || ',''Content was relevant'',NULL,''RATING'',9); END;') = 0,
      'T-FB-10 only the order of an answered question may change');
  chk(code_of('TD_TRAINADMIN', 'lms_feedback_pkg.remove_form_question(' || l_q1 || ');') = -20409,
      'T-FB-11 answered question cannot be removed');
  as_user('TD_TRAINADMIN');
  l_form2 := lms_feedback_pkg.clone_form(l_form);
  SELECT COUNT(*) INTO l_n FROM lms_feedback_questions WHERE form_id = l_form2;
  chk(l_n = 2, 'T-FB-12 clone_form copies the questions');
  chk(code_of('TD_TRAINADMIN', 'lms_feedback_pkg.assign_form(' || l_course || ',' || l_form2 || ');') = -20409,
      'T-FB-13 form cannot be swapped after feedback was collected');
  chk(code_of('TD_TRAINADMIN', 'DECLARE x NUMBER; BEGIN x := lms_feedback_pkg.save_form(' || l_form || ',''TD form'',NULL,''N''); END;') = -20409,
      'T-FB-14 form used by a published course cannot be deactivated');

  -- reviews
  as_user('TD_LEARNER1');
  lms_feedback_pkg.submit_review(l_enr, 4, 5, 'Good course');
  SELECT review_id INTO l_review FROM lms_course_reviews WHERE enrollment_id = l_enr;
  chk(code_of('TD_LEARNER1', 'lms_feedback_pkg.submit_review(' || l_enr || ',5,5,''again'');') = -20409,
      'T-FB-15 one review per completed enrolment (ORA-20409)');
  chk(code_of('TD_LEARNER1', 'lms_feedback_pkg.update_review(' || l_review || ',5,5,''edit'');') = -20409,
      'T-FB-16 reviews are final when REVIEW_EDIT_DAYS = 0');
  UPDATE lms_system_settings SET setting_value = '7' WHERE setting_key = 'REVIEW_EDIT_DAYS';
  chk(code_of('TD_LEARNER1', 'lms_feedback_pkg.update_review(' || l_review || ',5,5,''edited'');') = 0,
      'T-FB-17 owner can edit inside the configured window');
  chk(code_of('TD_LEARNER2', 'lms_feedback_pkg.update_review(' || l_review || ',1,1,''vandal'');') = -20403,
      'T-FB-18 other users cannot edit someone else''s review (ORA-20403)');

  -- anonymity threshold: 1 response < FEEDBACK_MIN_RESPONSES (5) => nothing shown to the instructor
  as_user('TD_INSTRUCTOR');
  SELECT COUNT(*) INTO l_n FROM v_lms_course_feedback_summary WHERE course_id = l_course;
  chk(l_n = 0, 'T-FB-19 summary hidden below the minimum number of responses');
  SELECT COUNT(*) INTO l_n FROM v_lms_course_feedback_comments WHERE course_id = l_course;
  chk(l_n = 0, 'T-FB-20 comments hidden below the minimum number of responses');
  UPDATE lms_system_settings SET setting_value = '1' WHERE setting_key = 'FEEDBACK_MIN_RESPONSES';
  SELECT COUNT(*) INTO l_n FROM v_lms_course_feedback_summary WHERE course_id = l_course AND responses = 1;
  chk(l_n = 1, 'T-FB-21 summary visible to the course instructor when the threshold is met');
  SELECT COUNT(*) INTO l_n FROM user_tab_columns WHERE table_name = 'V_LMS_COURSE_FEEDBACK_COMMENTS'
     AND column_name IN ('USER_ID','ENROLLMENT_ID','USERNAME','FULL_NAME_EN');
  chk(l_n = 0, 'T-FB-22 comments view carries no identity columns');
  as_user('TD_LEARNER2');
  SELECT COUNT(*) INTO l_n FROM v_lms_course_feedback_summary;
  chk(l_n = 0, 'T-FB-23 a learner sees no course feedback analytics');

  BEGIN apex_session.delete_session; EXCEPTION WHEN OTHERS THEN NULL; END;
  ROLLBACK;
  DBMS_OUTPUT.put_line(CASE WHEN l_fail = 0 THEN 'ALL TESTS PASSED' ELSE l_fail || ' TEST(S) FAILED' END);
  IF l_fail > 0 THEN RAISE_APPLICATION_ERROR(-20999, l_fail || ' test(s) failed'); END IF;
END;
/
