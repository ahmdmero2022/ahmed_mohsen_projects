-- =============================================================================
-- Lookup views for APEX LOVs / facets | Oracle 19c | STATUS: written, NOT executed. Requires 01-09, 15.
-- Pages must not read base tables; these views carry no sensitive data (names of categories/departments/positions)
-- or are filtered through V_LMS_VISIBLE_USERS.
-- =============================================================================
CREATE OR REPLACE VIEW v_lms_categories AS
SELECT category_id, parent_category_id, name_en, name_ar, sort_order FROM lms_categories WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_departments AS
SELECT department_id, department_code, name_en, name_ar FROM lms_departments WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_positions AS
SELECT position_id, position_code, job_title_en, job_title_ar FROM lms_positions WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_users AS
SELECT u.user_id, u.employee_no, u.full_name_en, u.full_name_ar, u.department_id
  FROM lms_users u
 WHERE u.status = 'ACTIVE' AND u.user_id IN (SELECT user_id FROM v_lms_visible_users);

-- instructors/admins pick course instructors and session trainers from people holding an authoring role
CREATE OR REPLACE VIEW v_lms_lov_instructors AS
SELECT u.user_id, u.full_name_en, u.full_name_ar
  FROM lms_users u
 WHERE u.status = 'ACTIVE'
   AND EXISTS (SELECT 1 FROM lms_user_roles ur JOIN lms_roles r ON r.role_id = ur.role_id
                WHERE ur.user_id = u.user_id AND r.role_code IN ('INSTRUCTOR','TRAINING_ADMIN'))
   AND (SELECT lms_security_pkg.permission_scope('SESSION_MANAGE') FROM dual) IS NOT NULL;

CREATE OR REPLACE VIEW v_lms_lov_venues AS
SELECT venue_id, name_en, name_ar, capacity FROM lms_venues WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_skills AS
SELECT skill_id, skill_code, name_en, name_ar, skill_group FROM lms_skills WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_templates AS
SELECT template_id, template_code, name_en, name_ar FROM lms_certificate_templates WHERE active_flag = 'Y';

CREATE OR REPLACE VIEW v_lms_lov_roles AS
SELECT role_code, name_en, name_ar FROM lms_roles
 WHERE (SELECT lms_security_pkg.permission_scope('ROLE_ADMIN') FROM dual) = 'ALL';

-- ---- course detail page (published courses only; titles and counts, never lesson content) --------------------
CREATE OR REPLACE VIEW v_lms_course_outline AS
SELECT c.course_id, m.module_id, m.title_en AS module_title_en, m.title_ar AS module_title_ar, m.sort_order AS module_order,
       l.lesson_id, l.title_en AS lesson_title_en, l.title_ar AS lesson_title_ar, l.lesson_type, l.duration_minutes,
       l.required_flag, l.sort_order AS lesson_order
  FROM lms_courses c
  JOIN lms_modules m ON m.course_id = c.course_id
  LEFT JOIN lms_lessons l ON l.module_id = m.module_id
 WHERE c.status = 'PUBLISHED';

CREATE OR REPLACE VIEW v_lms_course_prereqs AS
SELECT cp.course_id, pc.course_id AS prereq_course_id, pc.course_code, pc.title_en, pc.title_ar,
       CASE WHEN EXISTS (SELECT 1 FROM lms_enrollments e
                          WHERE e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
                            AND e.course_id = pc.course_id AND e.status = 'COMPLETED') THEN 'Y' ELSE 'N' END AS met_flag
  FROM lms_course_prerequisites cp JOIN lms_courses pc ON pc.course_id = cp.prereq_course_id
 WHERE cp.course_id IN (SELECT course_id FROM lms_courses WHERE status = 'PUBLISHED');

CREATE OR REPLACE VIEW v_lms_course_instructors AS
SELECT ci.course_id, u.user_id, u.full_name_en, u.full_name_ar, ci.instructor_role, p.job_title_en AS position_en, p.job_title_ar AS position_ar
  FROM lms_course_instructors ci
  JOIN lms_users u ON u.user_id = ci.user_id AND u.status = 'ACTIVE'
  LEFT JOIN lms_positions p ON p.position_id = u.position_id
 WHERE ci.course_id IN (SELECT course_id FROM lms_courses WHERE status = 'PUBLISHED');

-- popularity for catalog sorting (counts only, no personal data)
CREATE OR REPLACE VIEW v_lms_course_popularity AS
SELECT course_id, enrolled, completed FROM lms_sum_course;

-- admin maintenance lists (include inactive rows; permission checked in the view)
CREATE OR REPLACE VIEW v_lms_categories_admin AS
SELECT category_id, parent_category_id, name_en, name_ar, sort_order, active_flag FROM lms_categories
 WHERE (SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_templates_cert AS
SELECT template_id, template_code, name_en, name_ar, validity_months, body_html AS body_text, active_flag FROM lms_certificate_templates
 WHERE (SELECT lms_security_pkg.permission_scope('CERT_POLICY') FROM dual) = 'ALL';

-- =============================================================================
-- Skills framework (HR) and feedback (learner, author, instructor) views
-- =============================================================================
CREATE OR REPLACE VIEW v_lms_skills_admin AS
SELECT sk.skill_id, sk.skill_code, sk.name_en, sk.name_ar, sk.skill_group, sk.active_flag,
       (SELECT COUNT(*) FROM lms_position_skills x WHERE x.skill_id = sk.skill_id) AS positions_using,
       (SELECT COUNT(*) FROM lms_course_skills x WHERE x.skill_id = sk.skill_id)   AS courses_using,
       (SELECT COUNT(*) FROM lms_user_skills x WHERE x.skill_id = sk.skill_id)     AS people_assessed
  FROM lms_skills sk
 WHERE (SELECT lms_security_pkg.permission_scope('SKILL_MANAGE') FROM dual) IS NOT NULL;

CREATE OR REPLACE VIEW v_lms_position_skills_admin AS
SELECT ps.position_id, p.position_code, p.job_title_en, ps.skill_id, sk.skill_code, sk.name_en AS skill_en, ps.required_level
  FROM lms_position_skills ps
  JOIN lms_positions p ON p.position_id = ps.position_id
  JOIN lms_skills sk ON sk.skill_id = ps.skill_id
 WHERE (SELECT lms_security_pkg.permission_scope('SKILL_MANAGE') FROM dual) IS NOT NULL;

-- course -> skill links the caller may edit (HR: all; authors: their courses)
CREATE OR REPLACE VIEW v_lms_course_skills_edit AS
SELECT cs.course_id, cs.skill_id, sk.skill_code, sk.name_en AS skill_en, sk.name_ar AS skill_ar, cs.level_gained
  FROM lms_course_skills cs JOIN lms_skills sk ON sk.skill_id = cs.skill_id
 WHERE (SELECT lms_security_pkg.permission_scope('SKILL_MANAGE') FROM dual) IS NOT NULL
    OR cs.course_id IN (SELECT course_id FROM v_lms_my_courses);

-- an employee's own assessed levels vs. what their position requires (learner "My skills" card)
CREATE OR REPLACE VIEW v_lms_my_skills AS
SELECT sk.skill_id, sk.name_en, sk.name_ar, NVL(us.current_level, 0) AS current_level, ps.required_level,
       GREATEST(NVL(ps.required_level, 0) - NVL(us.current_level, 0), 0) AS gap
  FROM lms_skills sk
  LEFT JOIN lms_user_skills us ON us.skill_id = sk.skill_id
       AND us.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
  LEFT JOIN lms_position_skills ps ON ps.skill_id = sk.skill_id
       AND ps.position_id = (SELECT position_id FROM lms_users WHERE user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual))
 WHERE us.user_id IS NOT NULL OR ps.position_id IS NOT NULL;

-- ---- feedback: authoring ------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_lms_feedback_forms_admin AS
SELECT f.form_id, f.name_en, f.name_ar, f.active_flag,
       (SELECT COUNT(*) FROM lms_feedback_questions q WHERE q.form_id = f.form_id) AS questions,
       (SELECT COUNT(*) FROM lms_courses c WHERE c.feedback_form_id = f.form_id)   AS courses_using,
       (SELECT COUNT(*) FROM lms_feedback_responses r JOIN lms_feedback_questions q ON q.question_id = r.question_id
         WHERE q.form_id = f.form_id) AS responses
  FROM lms_feedback_forms f
 WHERE (SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_feedback_questions_admin AS
SELECT q.question_id, q.form_id, q.text_en, q.text_ar, q.answer_type, q.sort_order,
       (SELECT COUNT(*) FROM lms_feedback_responses r WHERE r.question_id = q.question_id) AS responses
  FROM lms_feedback_questions q
 WHERE (SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) = 'ALL';

-- forms an author may attach to a course
CREATE OR REPLACE VIEW v_lms_lov_feedback_forms AS
SELECT form_id, name_en, name_ar FROM lms_feedback_forms WHERE active_flag = 'Y'
 AND ((SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) IS NOT NULL
   OR (SELECT lms_security_pkg.permission_scope('COURSE_AUTHOR') FROM dual) IS NOT NULL);

-- ---- feedback: learner ---------------------------------------------------------------------------------------
-- completed enrolments that still need a review or have unanswered questionnaire items
CREATE OR REPLACE VIEW v_lms_my_feedback_todo AS
SELECT e.enrollment_id, e.course_id, c.title_en, c.title_ar, e.completed_at,
       CASE WHEN EXISTS (SELECT 1 FROM lms_course_reviews r WHERE r.enrollment_id = e.enrollment_id) THEN 'Y' ELSE 'N' END AS reviewed_flag,
       (SELECT COUNT(*) FROM lms_feedback_questions q WHERE q.form_id = c.feedback_form_id) AS form_questions,
       (SELECT COUNT(*) FROM lms_feedback_responses r WHERE r.enrollment_id = e.enrollment_id) AS answered
  FROM lms_enrollments e JOIN lms_courses c ON c.course_id = e.course_id
 WHERE e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual) AND e.status = 'COMPLETED'
   AND (NOT EXISTS (SELECT 1 FROM lms_course_reviews r WHERE r.enrollment_id = e.enrollment_id)
        OR (SELECT COUNT(*) FROM lms_feedback_responses r WHERE r.enrollment_id = e.enrollment_id)
           < (SELECT COUNT(*) FROM lms_feedback_questions q WHERE q.form_id = c.feedback_form_id));

CREATE OR REPLACE VIEW v_lms_my_feedback_form AS
SELECT e.enrollment_id, q.question_id, q.text_en, q.text_ar, q.answer_type, q.sort_order, r.rating, r.comment_text
  FROM lms_enrollments e
  JOIN lms_courses c ON c.course_id = e.course_id AND c.feedback_form_id IS NOT NULL
  JOIN lms_feedback_questions q ON q.form_id = c.feedback_form_id
  LEFT JOIN lms_feedback_responses r ON r.enrollment_id = e.enrollment_id AND r.question_id = q.question_id
 WHERE e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_my_reviews AS
SELECT r.review_id, r.enrollment_id, r.course_id, c.title_en, c.title_ar, r.course_rating, r.instructor_rating, r.review_text, r.created_at,
       CASE WHEN lms_util_pkg.get_number('REVIEW_EDIT_DAYS', 0) > 0
             AND r.created_at >= SYSTIMESTAMP - NUMTODSINTERVAL(lms_util_pkg.get_number('REVIEW_EDIT_DAYS', 0), 'DAY')
            THEN 'Y' ELSE 'N' END AS editable_flag
  FROM lms_course_reviews r JOIN lms_courses c ON c.course_id = r.course_id
 WHERE r.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

-- public reviews on the course details page: initials only, hidden reviews excluded
CREATE OR REPLACE VIEW v_lms_course_reviews_public AS
SELECT r.review_id, r.course_id, r.course_rating, r.instructor_rating, r.review_text,
       TRUNC(CAST(r.created_at AS DATE)) AS review_date,
       REGEXP_REPLACE(u.full_name_en, '(\S)\S*\s*', '\1.') AS reviewer
  FROM lms_course_reviews r
  JOIN lms_users u ON u.user_id = r.user_id
  JOIN lms_courses c ON c.course_id = r.course_id AND c.status = 'PUBLISHED'
 WHERE r.status = 'PUBLISHED';

-- ---- feedback: analytics (anonymity threshold FEEDBACK_MIN_RESPONSES) -----------------------------------------------
-- Aggregates only, shown to course managers (and organisation-wide reporters), and only when enough people answered.
CREATE OR REPLACE VIEW v_lms_course_feedback_summary AS
SELECT c.course_id, c.title_en AS course_en, q.question_id, q.text_en AS question_en, q.sort_order,
       COUNT(r.rating) AS responses, ROUND(AVG(r.rating), 2) AS avg_rating,
       COUNT(CASE WHEN r.rating >= 4 THEN 1 END) AS favourable, COUNT(CASE WHEN r.rating <= 2 THEN 1 END) AS unfavourable
  FROM lms_courses c
  JOIN lms_feedback_questions q ON q.form_id = c.feedback_form_id AND q.answer_type = 'RATING'
  JOIN lms_feedback_responses r ON r.question_id = q.question_id
  JOIN lms_enrollments e ON e.enrollment_id = r.enrollment_id AND e.course_id = c.course_id
 WHERE (c.course_id IN (SELECT course_id FROM v_lms_my_courses)
        OR (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL')
 GROUP BY c.course_id, c.title_en, q.question_id, q.text_en, q.sort_order
HAVING COUNT(r.rating) >= lms_util_pkg.get_number('FEEDBACK_MIN_RESPONSES', 5);

CREATE OR REPLACE VIEW v_lms_course_review_summary AS
SELECT c.course_id, c.title_en AS course_en, COUNT(*) AS reviews, ROUND(AVG(r.course_rating), 2) AS avg_course_rating,
       ROUND(AVG(r.instructor_rating), 2) AS avg_instructor_rating
  FROM lms_courses c JOIN lms_course_reviews r ON r.course_id = c.course_id AND r.status = 'PUBLISHED'
 WHERE (c.course_id IN (SELECT course_id FROM v_lms_my_courses)
        OR (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL')
 GROUP BY c.course_id, c.title_en
HAVING COUNT(*) >= lms_util_pkg.get_number('FEEDBACK_MIN_RESPONSES', 5);

-- comments WITHOUT identity (no user id, no enrolment id, no timestamp finer than the month) and only for courses over the threshold
CREATE OR REPLACE VIEW v_lms_course_feedback_comments AS
SELECT x.course_id, x.source, x.comment_text, x.comment_month
  FROM (SELECT e.course_id, 'FORM' AS source, r.comment_text, TRUNC(CAST(r.submitted_at AS DATE), 'MM') AS comment_month
          FROM lms_feedback_responses r JOIN lms_enrollments e ON e.enrollment_id = r.enrollment_id
         WHERE r.comment_text IS NOT NULL
        UNION ALL
        SELECT rv.course_id, 'REVIEW', rv.review_text, TRUNC(CAST(rv.created_at AS DATE), 'MM')
          FROM lms_course_reviews rv WHERE rv.review_text IS NOT NULL AND rv.status = 'PUBLISHED') x
 WHERE (x.course_id IN (SELECT course_id FROM v_lms_my_courses)
        OR (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL')
   AND (SELECT COUNT(*) FROM lms_enrollments e2 JOIN lms_feedback_responses r2 ON r2.enrollment_id = e2.enrollment_id
         WHERE e2.course_id = x.course_id)
     + (SELECT COUNT(*) FROM lms_course_reviews r3 WHERE r3.course_id = x.course_id)
       >= lms_util_pkg.get_number('FEEDBACK_MIN_RESPONSES', 5);

-- moderation list (includes hidden reviews); training admins only
CREATE OR REPLACE VIEW v_lms_reviews_moderation AS
SELECT r.review_id, r.course_id, c.title_en AS course_en, r.course_rating, r.instructor_rating, r.review_text, r.status, r.created_at
  FROM lms_course_reviews r JOIN lms_courses c ON c.course_id = r.course_id
 WHERE (SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) = 'ALL';
