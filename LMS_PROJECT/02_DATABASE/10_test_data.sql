-- =============================================================================
-- Test data TD-1 / TD-2 / TD-3 (DEV/TEST ONLY - never run in UAT/PROD)
-- Oracle 19c | STATUS: written, NOT executed. Requires 01-09.
-- Creates: 2 departments, 2 positions, 8 users (one per role + chain), a published
-- capacity-2 course C-CAP, a prerequisite pair C-PRE -> C-ADV, and a quiz with 3 questions.
-- =============================================================================
DECLARE
  l_n       NUMBER;
  l_dept    NUMBER; l_dept2 NUMBER; l_pos NUMBER; l_pos2 NUMBER; l_cat NUMBER;
  l_mgr     NUMBER; l_ins NUMBER; l_adm NUMBER;
  l_course  NUMBER; l_pre NUMBER; l_adv NUMBER; l_mod NUMBER; l_les NUMBER;
  l_bank    NUMBER; l_q NUMBER; l_quiz NUMBER;

  FUNCTION mk_user(p_user VARCHAR2, p_emp VARCHAR2, p_name VARCHAR2, p_dept NUMBER, p_pos NUMBER,
                   p_mgr NUMBER, p_role VARCHAR2) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    INSERT INTO lms_users (username, employee_no, full_name_en, full_name_ar, email, department_id, position_id, manager_user_id)
    VALUES (p_user, p_emp, p_name, p_name, LOWER(p_user) || '@example.invalid', p_dept, p_pos, p_mgr)
    RETURNING user_id INTO l_id;
    INSERT INTO lms_user_roles (user_id, role_id) SELECT l_id, role_id FROM lms_roles WHERE role_code = p_role;
    RETURN l_id;
  END mk_user;
BEGIN
  SELECT COUNT(*) INTO l_n FROM lms_users WHERE username LIKE 'TD\_%' ESCAPE '\';
  IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20999, 'Test data already loaded'); END IF;

  INSERT INTO lms_departments (department_code, name_en, name_ar) VALUES ('TD-OPS', 'Operations', 'العمليات') RETURNING department_id INTO l_dept;
  INSERT INTO lms_departments (department_code, name_en, name_ar) VALUES ('TD-FIN', 'Finance', 'المالية') RETURNING department_id INTO l_dept2;
  INSERT INTO lms_positions (position_code, job_title_en, job_title_ar) VALUES ('TD-ANALYST', 'Analyst', 'محلل') RETURNING position_id INTO l_pos;
  INSERT INTO lms_positions (position_code, job_title_en, job_title_ar) VALUES ('TD-LEAD', 'Team Lead', 'قائد فريق') RETURNING position_id INTO l_pos2;

  l_adm := mk_user('TD_SYSADMIN', 'TD001', 'Test SysAdmin', l_dept, l_pos2, NULL, 'SYS_ADMIN');
  l_mgr := mk_user('TD_MANAGER',  'TD002', 'Test Manager',  l_dept, l_pos2, NULL, 'MANAGER');
  l_n   := mk_user('TD_LEARNER1', 'TD003', 'Test Learner One', l_dept, l_pos, l_mgr, 'LEARNER');
  l_n   := mk_user('TD_LEARNER2', 'TD004', 'Test Learner Two', l_dept, l_pos, l_mgr, 'LEARNER');
  l_n   := mk_user('TD_LEARNER3', 'TD005', 'Test Learner Three', l_dept2, l_pos, NULL, 'LEARNER');   -- outside manager subtree
  l_ins := mk_user('TD_INSTRUCTOR', 'TD006', 'Test Instructor', l_dept, l_pos2, NULL, 'INSTRUCTOR');
  l_n   := mk_user('TD_TRAINADMIN', 'TD007', 'Test Training Admin', l_dept, l_pos2, NULL, 'TRAINING_ADMIN');
  l_n   := mk_user('TD_HR', 'TD008', 'Test HR Officer', l_dept, l_pos2, NULL, 'HR_LD');

  SELECT MIN(category_id) INTO l_cat FROM lms_categories;

  -- C-CAP: published, capacity 2, one module, two required lessons
  INSERT INTO lms_courses (course_code, title_en, title_ar, category_id, delivery_method, status, capacity, created_by, published_at)
  VALUES ('C-CAP', 'Capacity Test Course', 'دورة اختبار السعة', l_cat, 'SELF_PACED', 'PUBLISHED', 2, l_ins, SYSTIMESTAMP)
  RETURNING course_id INTO l_course;
  INSERT INTO lms_course_instructors (course_id, user_id) VALUES (l_course, l_ins);
  INSERT INTO lms_modules (course_id, title_en, sort_order) VALUES (l_course, 'Module 1', 1) RETURNING module_id INTO l_mod;
  INSERT INTO lms_lessons (module_id, title_en, lesson_type, required_flag, sort_order) VALUES (l_mod, 'Lesson 1', 'TEXT', 'Y', 1);
  INSERT INTO lms_lessons (module_id, title_en, lesson_type, required_flag, sort_order) VALUES (l_mod, 'Lesson 2', 'TEXT', 'Y', 2);

  -- prerequisite pair
  INSERT INTO lms_courses (course_code, title_en, category_id, delivery_method, status, created_by, published_at)
  VALUES ('C-PRE', 'Prerequisite Course', l_cat, 'SELF_PACED', 'PUBLISHED', l_ins, SYSTIMESTAMP) RETURNING course_id INTO l_pre;
  INSERT INTO lms_modules (course_id, title_en, sort_order) VALUES (l_pre, 'Module 1', 1) RETURNING module_id INTO l_mod;
  INSERT INTO lms_lessons (module_id, title_en, lesson_type, sort_order) VALUES (l_mod, 'Only lesson', 'TEXT', 1);
  INSERT INTO lms_courses (course_code, title_en, category_id, delivery_method, status, created_by, published_at)
  VALUES ('C-ADV', 'Advanced Course', l_cat, 'SELF_PACED', 'PUBLISHED', l_ins, SYSTIMESTAMP) RETURNING course_id INTO l_adv;
  INSERT INTO lms_course_prerequisites (course_id, prereq_course_id) VALUES (l_adv, l_pre);

  -- C-QUIZ: course with lessons + quiz (completion rule LESSONS_ASSESSMENT), certificate eligible
  INSERT INTO lms_courses (course_code, title_en, category_id, delivery_method, status, completion_rule,
                           certificate_eligible, created_by, published_at)
  VALUES ('C-QUIZ', 'Quiz Test Course', l_cat, 'SELF_PACED', 'PUBLISHED', 'LESSONS_ASSESSMENT', 'Y', l_ins, SYSTIMESTAMP)
  RETURNING course_id INTO l_course;
  INSERT INTO lms_course_instructors (course_id, user_id) VALUES (l_course, l_ins);
  INSERT INTO lms_modules (course_id, title_en, sort_order) VALUES (l_course, 'Module 1', 1) RETURNING module_id INTO l_mod;
  INSERT INTO lms_lessons (module_id, title_en, lesson_type, sort_order) VALUES (l_mod, 'Reading', 'TEXT', 1);
  INSERT INTO lms_lessons (module_id, title_en, lesson_type, sort_order) VALUES (l_mod, 'Final quiz', 'ASSESSMENT', 2) RETURNING lesson_id INTO l_les;

  INSERT INTO lms_question_banks (name_en, owner_user_id) VALUES ('TD bank', l_ins) RETURNING bank_id INTO l_bank;
  INSERT INTO lms_quizzes (course_id, lesson_id, title_en, pass_score, time_limit_min, max_attempts, show_review)
  VALUES (l_course, l_les, 'Final quiz', 60, 15, 2, 'Y') RETURNING quiz_id INTO l_quiz;

  INSERT INTO lms_questions (bank_id, question_type, text_en, points) VALUES (l_bank, 'MCQ', '2 + 2 = ?', 1) RETURNING question_id INTO l_q;
  INSERT INTO lms_question_options (question_id, option_text_en, is_correct, sort_order) VALUES (l_q, '3', 'N', 1);
  INSERT INTO lms_question_options (question_id, option_text_en, is_correct, sort_order) VALUES (l_q, '4', 'Y', 2);
  INSERT INTO lms_quiz_questions (quiz_id, question_id, sort_order) VALUES (l_quiz, l_q, 1);

  INSERT INTO lms_questions (bank_id, question_type, text_en, points) VALUES (l_bank, 'TF', 'The sky is green.', 1) RETURNING question_id INTO l_q;
  INSERT INTO lms_question_options (question_id, option_text_en, is_correct, sort_order) VALUES (l_q, 'True', 'N', 1);
  INSERT INTO lms_question_options (question_id, option_text_en, is_correct, sort_order) VALUES (l_q, 'False', 'Y', 2);
  INSERT INTO lms_quiz_questions (quiz_id, question_id, sort_order) VALUES (l_quiz, l_q, 2);

  INSERT INTO lms_questions (bank_id, question_type, text_en, points) VALUES (l_bank, 'SHORT', 'Capital of France?', 2) RETURNING question_id INTO l_q;
  INSERT INTO lms_question_options (question_id, option_text_en, is_correct, sort_order) VALUES (l_q, 'Paris', 'Y', 1);
  INSERT INTO lms_quiz_questions (quiz_id, question_id, sort_order) VALUES (l_quiz, l_q, 3);

  COMMIT;
  DBMS_OUTPUT.put_line('Test data loaded. Log in (or apex_session.create_session) as TD_* users.');
END;
/
