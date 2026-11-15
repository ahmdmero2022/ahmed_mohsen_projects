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
