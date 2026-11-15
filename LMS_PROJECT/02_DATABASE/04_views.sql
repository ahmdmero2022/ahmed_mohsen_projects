-- =============================================================================
-- Views | Oracle 19c | STATUS: written, NOT executed
-- Requires 01, 02, 03. Row-level security is applied INSIDE the views through
-- LMS_SECURITY_PKG; the scalar subquery (select ... from dual) makes Oracle evaluate
-- the function once per statement instead of once per row.
-- =============================================================================

CREATE OR REPLACE VIEW lms_course_rating_v AS
SELECT course_id,
       ROUND(AVG(course_rating), 2) AS avg_rating,
       COUNT(*)                     AS rating_count
  FROM lms_course_reviews
 WHERE status = 'PUBLISHED'
 GROUP BY course_id;

-- Users the current user may see in reports: everyone (REPORT_ORG scope ALL) or self + subtree (REPORT_TEAM).
CREATE OR REPLACE VIEW v_lms_visible_users AS
SELECT u.user_id
  FROM lms_users u
 WHERE (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL'
UNION
SELECT u.user_id
  FROM lms_users u
 WHERE (SELECT lms_security_pkg.permission_scope('REPORT_TEAM') FROM dual) IS NOT NULL
 START WITH u.manager_user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
 CONNECT BY NOCYCLE PRIOR u.user_id = u.manager_user_id
UNION
SELECT lms_security_pkg.current_user_id_safe FROM dual
 WHERE lms_security_pkg.current_user_id_safe IS NOT NULL;

CREATE OR REPLACE VIEW v_lms_my_enrollments AS
SELECT e.enrollment_id, e.course_id, c.course_code, c.title_en, c.title_ar, c.duration_minutes,
       e.status, e.enrollment_type, e.due_date, e.enrolled_at, e.started_at,
       e.last_activity_at, e.completed_at, e.progress_pct,
       CASE WHEN e.enrollment_type = 'MANDATORY' THEN 'Y' ELSE 'N' END AS mandatory_flag,
       CASE WHEN e.due_date < TRUNC(SYSDATE) AND e.status NOT IN ('COMPLETED','CANCELLED','FAILED','EXPIRED')
            THEN 'Y' ELSE 'N' END AS overdue_flag,
       c.thumbnail_ref
  FROM lms_enrollments e
  JOIN lms_courses c ON c.course_id = e.course_id
 WHERE e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_catalog AS
SELECT c.course_id, c.course_code, c.title_en, c.title_ar,
       c.description_en, c.description_ar, c.objectives_en, c.objectives_ar,
       c.category_id, cat.name_en AS category_en, cat.name_ar AS category_ar,
       c.difficulty, c.duration_minutes, c.language_code, c.delivery_method,
       c.featured_flag, c.published_at, c.thumbnail_ref, c.certificate_eligible, c.approval_required, c.completion_rule,
       r.avg_rating, NVL(r.rating_count, 0) AS rating_count,
       (SELECT e.status FROM lms_enrollments e
         WHERE e.course_id = c.course_id
           AND e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
           AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED')
           AND ROWNUM = 1) AS my_status,
       CASE WHEN c.capacity IS NULL THEN NULL
            ELSE GREATEST(c.capacity - (SELECT COUNT(*) FROM lms_enrollments s
                                         WHERE s.course_id = c.course_id
                                           AND s.status IN ('APPROVED','ENROLLED','IN_PROGRESS')), 0)
       END AS seats_left
  FROM lms_courses c
  JOIN lms_categories cat ON cat.category_id = c.category_id
  LEFT JOIN lms_course_rating_v r ON r.course_id = c.course_id
 WHERE c.status = 'PUBLISHED'
   AND (c.available_to IS NULL OR c.available_to >= TRUNC(SYSDATE));

CREATE OR REPLACE VIEW v_lms_my_certs AS
SELECT ce.certificate_id, ce.certificate_no, ce.verification_code, ce.title_en, ce.title_ar,
       ce.issued_at, ce.expires_at,
       CASE WHEN ce.status = 'VALID' AND ce.expires_at < TRUNC(SYSDATE) THEN 'EXPIRED' ELSE ce.status END AS status
  FROM lms_certificates ce
 WHERE ce.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_my_notifications AS
SELECT notification_id, template_code, title, message, link_url, read_flag, created_at
  FROM lms_notifications
 WHERE user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

-- Team/organisation enrolments the current user is allowed to see.
CREATE OR REPLACE VIEW v_lms_team_enrollments AS
SELECT e.enrollment_id, e.user_id, u.full_name_en, u.full_name_ar, u.department_id,
       d.name_en AS department_en, e.course_id, c.course_code, c.title_en AS course_title_en,
       e.status, e.enrollment_type, e.due_date, e.progress_pct, e.completed_at,
       CASE WHEN e.due_date < TRUNC(SYSDATE) AND e.status NOT IN ('COMPLETED','CANCELLED','FAILED','EXPIRED')
            THEN 'Y' ELSE 'N' END AS overdue_flag
  FROM lms_enrollments e
  JOIN lms_users u   ON u.user_id = e.user_id
  JOIN lms_courses c ON c.course_id = e.course_id
  LEFT JOIN lms_departments d ON d.department_id = u.department_id
 WHERE e.user_id IN (SELECT user_id FROM v_lms_visible_users);

CREATE OR REPLACE VIEW v_lms_mandatory_compliance AS
SELECT u.department_id, d.name_en AS department_en,
       COUNT(*) AS assigned,
       SUM(CASE WHEN e.status = 'COMPLETED' THEN 1 ELSE 0 END) AS completed,
       SUM(CASE WHEN e.status <> 'COMPLETED' AND e.due_date < TRUNC(SYSDATE) THEN 1 ELSE 0 END) AS overdue,
       ROUND(100 * SUM(CASE WHEN e.status = 'COMPLETED' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS compliance_pct
  FROM lms_enrollments e
  JOIN lms_users u ON u.user_id = e.user_id
  LEFT JOIN lms_departments d ON d.department_id = u.department_id
 WHERE e.enrollment_type = 'MANDATORY'
   AND e.status NOT IN ('CANCELLED','EXPIRED')
   AND e.user_id IN (SELECT user_id FROM v_lms_visible_users)
 GROUP BY u.department_id, d.name_en;

CREATE OR REPLACE VIEW v_lms_skill_gaps AS
SELECT u.user_id, u.full_name_en, u.department_id, ps.skill_id, s.name_en AS skill_en,
       ps.required_level, NVL(us.current_level, 0) AS current_level,
       ps.required_level - NVL(us.current_level, 0) AS gap
  FROM lms_users u
  JOIN lms_position_skills ps ON ps.position_id = u.position_id
  JOIN lms_skills s ON s.skill_id = ps.skill_id
  LEFT JOIN lms_user_skills us ON us.user_id = u.user_id AND us.skill_id = ps.skill_id
 WHERE ps.required_level > NVL(us.current_level, 0)
   AND u.user_id IN (SELECT user_id FROM v_lms_visible_users);

CREATE OR REPLACE VIEW v_lms_cert_expiring AS
SELECT ce.certificate_id, ce.user_id, u.full_name_en, u.department_id, ce.title_en, ce.expires_at,
       ce.expires_at - TRUNC(SYSDATE) AS days_left
  FROM lms_certificates ce
  JOIN lms_users u ON u.user_id = ce.user_id
 WHERE ce.status = 'VALID' AND ce.expires_at IS NOT NULL
   AND ce.user_id IN (SELECT user_id FROM v_lms_visible_users);

-- ----------------------- Assessment views: NEVER expose answer keys ---------------------------
-- Learner sees only their own running attempt. SHORT/ESSAY options (accepted answers) are excluded.
CREATE OR REPLACE VIEW v_lms_attempt_questions AS
SELECT r.attempt_id, r.question_id, r.sort_order, q.question_type, q.points,
       q.text_en, q.text_ar, r.answer_json
  FROM lms_quiz_responses r
  JOIN lms_quiz_attempts a ON a.attempt_id = r.attempt_id
  JOIN lms_questions q     ON q.question_id = r.question_id
 WHERE a.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND a.status = 'IN_PROGRESS';

CREATE OR REPLACE VIEW v_lms_attempt_options AS
SELECT r.attempt_id, o.question_id, o.option_id, o.option_text_en, o.option_text_ar,
       CASE WHEN z.randomize_a = 'Y' THEN ORA_HASH(r.attempt_id || '-' || o.option_id) ELSE o.sort_order END AS display_order
  FROM lms_quiz_responses r
  JOIN lms_quiz_attempts a ON a.attempt_id = r.attempt_id
  JOIN lms_quizzes z       ON z.quiz_id = a.quiz_id
  JOIN lms_questions q     ON q.question_id = r.question_id
  JOIN lms_question_options o ON o.question_id = r.question_id
 WHERE a.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND a.status = 'IN_PROGRESS'
   AND q.question_type IN ('MCQ','MULTI','TF','MATCH');

-- Right-hand side choices of MATCH questions, shuffled and NOT linked to option ids.
CREATE OR REPLACE VIEW v_lms_attempt_match_choices AS
SELECT DISTINCT r.attempt_id, o.question_id, o.match_key AS choice_text,
       ORA_HASH(r.attempt_id || '-' || o.match_key) AS display_order
  FROM lms_quiz_responses r
  JOIN lms_quiz_attempts a ON a.attempt_id = r.attempt_id
  JOIN lms_questions q     ON q.question_id = r.question_id AND q.question_type = 'MATCH'
  JOIN lms_question_options o ON o.question_id = r.question_id
 WHERE a.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND a.status = 'IN_PROGRESS' AND o.match_key IS NOT NULL;

-- Post-submission review: only own attempts, only if the quiz allows review, only once graded.
CREATE OR REPLACE VIEW v_lms_attempt_review AS
SELECT r.attempt_id, r.question_id, r.sort_order, q.question_type, q.text_en, q.text_ar,
       r.answer_json, r.points_awarded, q.points AS max_points, r.feedback,
       o.option_id, o.option_text_en, o.is_correct
  FROM lms_quiz_responses r
  JOIN lms_quiz_attempts a ON a.attempt_id = r.attempt_id
  JOIN lms_quizzes z       ON z.quiz_id = a.quiz_id AND z.show_review = 'Y'
  JOIN lms_questions q     ON q.question_id = r.question_id
  LEFT JOIN lms_question_options o ON o.question_id = r.question_id
 WHERE a.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND a.status = 'GRADED';

-- Instructor grading queue (own courses only).
CREATE OR REPLACE VIEW v_lms_grading_queue AS
SELECT a.attempt_id, a.quiz_id, z.title_en AS quiz_title, z.course_id, a.user_id,
       u.full_name_en AS learner, a.submitted_at
  FROM lms_quiz_attempts a
  JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
  JOIN lms_users u   ON u.user_id = a.user_id
 WHERE a.status = 'PENDING_GRADING'
   AND ((SELECT lms_security_pkg.permission_scope('GRADE') FROM dual) = 'ALL'
        OR EXISTS (SELECT 1 FROM lms_course_instructors ci
                    WHERE ci.course_id = z.course_id
                      AND ci.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)));

-- Certificate printing: owner only (use as the source of the PDF report layout).
CREATE OR REPLACE VIEW v_lms_certificate_print AS
SELECT ce.certificate_id, ce.certificate_no, ce.verification_code,
       u.full_name_en, u.full_name_ar, ce.title_en, ce.title_ar,
       ce.issued_at, ce.expires_at, t.body_html
  FROM lms_certificates ce
  JOIN lms_users u ON u.user_id = ce.user_id
  JOIN lms_certificate_templates t ON t.template_id = ce.template_id
 WHERE ce.status = 'VALID'
   AND ce.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);
