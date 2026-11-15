-- =============================================================================
-- Views that back the APEX pages | Oracle 19c | STATUS: written, NOT executed. Requires 01-09, 13.
-- Rule: the APEX parsing schema gets SELECT on V_LMS_* only. Every view that exposes more than the caller's own data
-- checks the permission INSIDE the view, so a page that is mis-authorised still returns no rows.
-- ((SELECT ... FROM dual) lets Oracle evaluate the function once per statement.)
-- =============================================================================

-- ------------------------------------------------------------- learner ----------
CREATE OR REPLACE VIEW v_lms_curriculum AS
SELECT e.enrollment_id, m.module_id, m.title_en AS module_title_en, m.title_ar AS module_title_ar, m.sort_order AS module_order,
       l.lesson_id, l.title_en, l.title_ar, l.lesson_type, l.required_flag, l.sort_order AS lesson_order, l.duration_minutes,
       NVL(lp.status, 'NOT_STARTED') AS progress_status, NVL(lp.resume_position, 0) AS resume_position,
       CASE WHEN l.available_from > TRUNC(SYSDATE) THEN 'Y'
            WHEN l.prereq_lesson_id IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM lms_lesson_progress pp
                                  WHERE pp.enrollment_id = e.enrollment_id AND pp.lesson_id = l.prereq_lesson_id
                                    AND pp.status = 'COMPLETED') THEN 'Y'
            ELSE 'N' END AS locked_flag
  FROM lms_enrollments e
  JOIN lms_modules m ON m.course_id = e.course_id
  JOIN lms_lessons l ON l.module_id = m.module_id
  LEFT JOIN lms_lesson_progress lp ON lp.enrollment_id = e.enrollment_id AND lp.lesson_id = l.lesson_id
 WHERE e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND e.status IN ('ENROLLED','IN_PROGRESS','COMPLETED');

CREATE OR REPLACE VIEW v_lms_resume_lesson AS
SELECT enrollment_id, lesson_id
  FROM (SELECT c.enrollment_id, c.lesson_id,
               ROW_NUMBER() OVER (PARTITION BY c.enrollment_id ORDER BY c.module_order, c.lesson_order) AS rn
          FROM v_lms_curriculum c
         WHERE c.progress_status <> 'COMPLETED' AND c.locked_flag = 'N')
 WHERE rn = 1;

CREATE OR REPLACE VIEW v_lms_my_sessions AS
SELECT se.session_enrollment_id, s.session_id, s.course_id, c.title_en, c.title_ar, s.start_ts, s.end_ts,
       v.name_en AS venue_en, v.name_ar AS venue_ar,
       CASE WHEN se.status = 'REGISTERED' THEN s.meeting_url END AS meeting_url,   -- link only for registered learners
       se.status
  FROM lms_session_enrollments se
  JOIN lms_training_sessions s ON s.session_id = se.session_id
  JOIN lms_courses c ON c.course_id = s.course_id
  LEFT JOIN lms_venues v ON v.venue_id = s.venue_id
 WHERE se.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND se.status IN ('REGISTERED','WAITLISTED') AND s.status <> 'CANCELLED';

CREATE OR REPLACE VIEW v_lms_session_catalog AS
SELECT s.session_id, s.course_id, c.title_en, c.title_ar, s.start_ts, s.end_ts, s.seats,
       s.seats - (SELECT COUNT(*) FROM lms_session_enrollments x WHERE x.session_id = s.session_id AND x.status = 'REGISTERED') AS seats_left,
       v.name_en AS venue_en, v.name_ar AS venue_ar,
       (SELECT x.status FROM lms_session_enrollments x
         WHERE x.session_id = s.session_id AND x.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
           AND x.status <> 'CANCELLED') AS my_status
  FROM lms_training_sessions s
  JOIN lms_courses c ON c.course_id = s.course_id
  LEFT JOIN lms_venues v ON v.venue_id = s.venue_id
 WHERE s.status = 'PUBLISHED' AND s.start_ts > SYSTIMESTAMP;

CREATE OR REPLACE VIEW v_lms_my_paths AS
SELECT pe.path_enrollment_id, p.path_id, p.title_en, p.title_ar, p.description_en, p.description_ar,
       pe.status, pe.progress_pct, pe.enrolled_at, pe.completed_at,
       (SELECT COUNT(*) FROM lms_path_courses pc WHERE pc.path_id = p.path_id) AS course_count
  FROM lms_path_enrollments pe JOIN lms_learning_paths p ON p.path_id = pe.path_id
 WHERE pe.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_path_courses AS
SELECT pe.path_enrollment_id, pc.sequence_no, c.course_id, c.title_en, c.title_ar, pc.required_flag,
       (SELECT e.status FROM lms_enrollments e
         WHERE e.user_id = pe.user_id AND e.course_id = c.course_id AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED')
           AND ROWNUM = 1) AS course_status
  FROM lms_path_enrollments pe
  JOIN lms_path_courses pc ON pc.path_id = pe.path_id
  JOIN lms_courses c ON c.course_id = pc.course_id
 WHERE pe.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_path_catalog AS
SELECT p.path_id, p.title_en, p.title_ar, p.description_en, p.description_ar, p.certificate_eligible,
       (SELECT COUNT(*) FROM lms_path_courses pc WHERE pc.path_id = p.path_id) AS course_count,
       (SELECT pe.status FROM lms_path_enrollments pe
         WHERE pe.path_id = p.path_id AND pe.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
           AND pe.status <> 'CANCELLED' AND ROWNUM = 1) AS my_status
  FROM lms_learning_paths p WHERE p.status = 'PUBLISHED';

CREATE OR REPLACE VIEW v_lms_my_quizzes AS
SELECT z.quiz_id, z.course_id, z.title_en, z.title_ar, z.pass_score, z.time_limit_min, z.max_attempts,
       (SELECT COUNT(*) FROM lms_quiz_attempts a WHERE a.quiz_id = z.quiz_id AND a.user_id = e.user_id) AS attempts_used,
       (SELECT MAX(a.score_pct) FROM lms_quiz_attempts a WHERE a.quiz_id = z.quiz_id AND a.user_id = e.user_id AND a.status = 'GRADED') AS best_score,
       (SELECT a.attempt_id FROM lms_quiz_attempts a WHERE a.quiz_id = z.quiz_id AND a.user_id = e.user_id AND a.status = 'IN_PROGRESS') AS open_attempt_id,
       e.enrollment_id
  FROM lms_quizzes z
  JOIN lms_enrollments e ON e.course_id = z.course_id
 WHERE z.active_flag = 'Y' AND e.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND e.status IN ('ENROLLED','IN_PROGRESS','COMPLETED');

CREATE OR REPLACE VIEW v_lms_my_attempts AS
SELECT a.attempt_id, a.quiz_id, z.title_en, z.title_ar, a.attempt_no, a.status, a.score_pct, a.passed_flag,
       a.started_at, a.submitted_at, a.deadline_at, z.show_review, z.pass_score, z.time_limit_min
  FROM lms_quiz_attempts a JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
 WHERE a.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_my_recommended AS
SELECT c.course_id, c.title_en, c.title_ar, c.duration_minutes, c.difficulty, c.thumbnail_ref,
       SUM(LEAST(cs.level_gained, g.gap)) AS coverage
  FROM v_lms_skill_gaps g
  JOIN lms_course_skills cs ON cs.skill_id = g.skill_id
  JOIN lms_courses c ON c.course_id = cs.course_id AND c.status = 'PUBLISHED'
 WHERE g.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
   AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                    WHERE e.user_id = g.user_id AND e.course_id = c.course_id AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED'))
 GROUP BY c.course_id, c.title_en, c.title_ar, c.duration_minutes, c.difficulty, c.thumbnail_ref;

-- ------------------------------------------------------ approvals / authoring ----------
CREATE OR REPLACE VIEW v_lms_approvals_inbox AS
SELECT a.approval_id, a.request_type, a.entity_id, a.requested_at, a.due_at, a.escalation_count,
       r.full_name_en AS requester_en, r.full_name_ar AS requester_ar,
       NVL(c.title_en, '#' || a.entity_id) AS item_en, c.title_ar AS item_ar,
       CASE WHEN a.due_at < SYSTIMESTAMP THEN 'Y' ELSE 'N' END AS overdue_flag
  FROM lms_approvals a
  JOIN lms_users r ON r.user_id = a.requester_id
  LEFT JOIN lms_enrollments e ON a.request_type = 'ENROLLMENT' AND e.enrollment_id = a.entity_id
  LEFT JOIN lms_courses c ON c.course_id = CASE WHEN a.request_type = 'ENROLLMENT' THEN e.course_id ELSE a.entity_id END
 WHERE a.status = 'PENDING'
   AND a.requester_id <> (SELECT NVL(lms_security_pkg.current_user_id_safe, -1) FROM dual)
   AND (a.approver_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
        OR (a.request_type = 'ENROLLMENT'     AND (SELECT lms_security_pkg.permission_scope('ENROLL_APPROVE') FROM dual) = 'ALL')
        OR (a.request_type = 'COURSE_PUBLISH' AND (SELECT lms_security_pkg.permission_scope('COURSE_PUBLISH') FROM dual) = 'ALL'));

CREATE OR REPLACE VIEW v_lms_my_courses AS
SELECT c.course_id, c.course_code, c.title_en, c.title_ar, c.status, c.delivery_method, c.completion_rule,
       c.row_version, c.updated_at, cat.name_en AS category_en,
       (SELECT COUNT(*) FROM lms_enrollments e WHERE e.course_id = c.course_id AND e.status IN ('ENROLLED','IN_PROGRESS')) AS active_learners,
       (SELECT COUNT(*) FROM lms_quiz_attempts a JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
         WHERE z.course_id = c.course_id AND a.status = 'PENDING_GRADING') AS pending_grading
  FROM lms_courses c JOIN lms_categories cat ON cat.category_id = c.category_id
 WHERE (SELECT lms_security_pkg.permission_scope('COURSE_AUTHOR') FROM dual) = 'ALL'
    OR (c.created_by = (SELECT lms_security_pkg.current_user_id_safe FROM dual)
        OR EXISTS (SELECT 1 FROM lms_course_instructors ci
                    WHERE ci.course_id = c.course_id AND ci.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual)));

CREATE OR REPLACE VIEW v_lms_course_learners AS
SELECT e.enrollment_id, e.course_id, u.user_id, u.full_name_en, u.full_name_ar, d.name_en AS department_en,
       e.status, e.progress_pct, e.started_at, e.last_activity_at, e.completed_at, e.time_spent_sec, e.instructor_approved_flag,
       (SELECT MAX(a.score_pct) FROM lms_quiz_attempts a JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
         WHERE z.course_id = e.course_id AND a.user_id = e.user_id AND a.status = 'GRADED') AS best_score
  FROM lms_enrollments e JOIN lms_users u ON u.user_id = e.user_id LEFT JOIN lms_departments d ON d.department_id = u.department_id
 WHERE e.course_id IN (SELECT course_id FROM v_lms_my_courses);

CREATE OR REPLACE VIEW v_lms_question_authoring AS
SELECT q.question_id, q.bank_id, b.name_en AS bank_en, q.question_type, q.text_en, q.text_ar, q.points, q.active_flag
  FROM lms_questions q JOIN lms_question_banks b ON b.bank_id = q.bank_id
 WHERE (SELECT lms_security_pkg.permission_scope('QUIZ_AUTHOR') FROM dual) = 'ALL'
    OR b.owner_user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

CREATE OR REPLACE VIEW v_lms_sessions_manage AS
SELECT s.session_id, s.course_id, c.title_en, c.title_ar, s.start_ts, s.end_ts, s.seats, s.status, s.instructor_id,
       i.full_name_en AS instructor_en, v.name_en AS venue_en, s.meeting_url, s.min_attendance_pct,
       (SELECT COUNT(*) FROM lms_session_enrollments x WHERE x.session_id = s.session_id AND x.status = 'REGISTERED') AS registered,
       (SELECT COUNT(*) FROM lms_session_enrollments x WHERE x.session_id = s.session_id AND x.status = 'WAITLISTED') AS waitlisted
  FROM lms_training_sessions s
  JOIN lms_courses c ON c.course_id = s.course_id
  JOIN lms_users i ON i.user_id = s.instructor_id
  LEFT JOIN lms_venues v ON v.venue_id = s.venue_id
 WHERE s.course_id IN (SELECT course_id FROM v_lms_my_courses)
    OR (SELECT lms_security_pkg.permission_scope('SESSION_MANAGE') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_session_roster AS
SELECT se.session_enrollment_id, se.session_id, u.user_id, u.full_name_en, u.full_name_ar, se.status, se.registered_at
  FROM lms_session_enrollments se JOIN lms_users u ON u.user_id = se.user_id
 WHERE se.session_id IN (SELECT session_id FROM v_lms_sessions_manage);

-- --------------------------------------------------------------- administration ----------
CREATE OR REPLACE VIEW v_lms_users_admin AS
SELECT u.user_id, u.username, u.employee_no, u.full_name_en, u.full_name_ar, u.email, u.status, u.preferred_lang,
       u.department_id, d.name_en AS department_en, u.position_id, p.job_title_en AS position_en,
       u.manager_user_id, m.full_name_en AS manager_en, u.row_version,
       (SELECT LISTAGG(r.role_code, ', ') WITHIN GROUP (ORDER BY r.role_code)
          FROM lms_user_roles ur JOIN lms_roles r ON r.role_id = ur.role_id WHERE ur.user_id = u.user_id) AS roles
  FROM lms_users u
  LEFT JOIN lms_departments d ON d.department_id = u.department_id
  LEFT JOIN lms_positions p ON p.position_id = u.position_id
  LEFT JOIN lms_users m ON m.user_id = u.manager_user_id
 WHERE (SELECT lms_security_pkg.permission_scope('USER_ADMIN') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_role_matrix AS
SELECT r.role_code, p.permission_code, rp.scope
  FROM lms_roles r CROSS JOIN lms_permissions p
  LEFT JOIN lms_role_permissions rp ON rp.role_id = r.role_id AND rp.permission_id = p.permission_id
 WHERE (SELECT lms_security_pkg.permission_scope('ROLE_ADMIN') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_assignments_admin AS
SELECT la.assignment_id, la.course_id, c.title_en AS course_en, la.target_type, la.target_id,
       CASE la.target_type WHEN 'USER' THEN (SELECT u.full_name_en FROM lms_users u WHERE u.user_id = la.target_id)
                           WHEN 'DEPARTMENT' THEN (SELECT d.name_en FROM lms_departments d WHERE d.department_id = la.target_id)
                           WHEN 'POSITION' THEN (SELECT p.job_title_en FROM lms_positions p WHERE p.position_id = la.target_id) END AS target_en,
       la.due_date, la.status, la.created_at,
       (SELECT COUNT(*) FROM lms_enrollments e WHERE e.course_id = la.course_id AND e.enrollment_type = 'MANDATORY' AND e.due_date = la.due_date) AS enrolled,
       (SELECT COUNT(*) FROM lms_enrollments e WHERE e.course_id = la.course_id AND e.enrollment_type = 'MANDATORY' AND e.due_date = la.due_date AND e.status = 'COMPLETED') AS completed
  FROM lms_learning_assignments la JOIN lms_courses c ON c.course_id = la.course_id
 WHERE (SELECT lms_security_pkg.permission_scope('ENROLL_ASSIGN') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_certificates_admin AS
SELECT ce.certificate_id, ce.certificate_no, ce.verification_code, u.full_name_en, ce.title_en, ce.issued_at, ce.expires_at,
       ce.status, ce.revoked_reason
  FROM lms_certificates ce JOIN lms_users u ON u.user_id = ce.user_id
 WHERE (SELECT lms_security_pkg.permission_scope('CERT_POLICY') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_settings AS
SELECT setting_key, setting_value, description, updated_at FROM lms_system_settings
 WHERE (SELECT lms_security_pkg.permission_scope('SETTINGS_ADMIN') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_rate_policies AS
SELECT policy_id, operation_name, limit_count, window_seconds, burst_limit, fail_mode, enabled_flag, updated_at
  FROM lms_rate_limit_policies
 WHERE (SELECT lms_security_pkg.permission_scope('RATELIMIT_ADMIN') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_templates_admin AS
SELECT template_id, template_code, lang, subject, body, active_flag FROM lms_notification_templates
 WHERE (SELECT lms_security_pkg.permission_scope('NOTIF_TEMPLATE_ADMIN') FROM dual) IS NOT NULL;

CREATE OR REPLACE VIEW v_lms_audit AS
SELECT a.audit_id, a.event_time, a.actor_user_id, u.username AS actor, a.operation, a.entity_name, a.entity_id,
       a.result, a.correlation_id, a.metadata
  FROM lms_audit_log a LEFT JOIN lms_users u ON u.user_id = a.actor_user_id
 WHERE (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_security_events_admin AS
SELECT e.event_id, e.event_time, e.event_type, e.severity, u.username AS app_user, e.operation, e.subject_key, e.detail
  FROM lms_security_events e LEFT JOIN lms_users u ON u.user_id = e.user_id
 WHERE (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_api_log_admin AS
SELECT log_id, log_time, route, http_method, http_status, duration_ms, subject_key FROM lms_api_request_log
 WHERE (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_queue_status AS
SELECT status, COUNT(*) AS cnt, MIN(next_attempt_at) AS oldest_due, MAX(attempts) AS max_attempts
  FROM lms_notification_queue
 WHERE (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL'
 GROUP BY status;

CREATE OR REPLACE VIEW v_lms_queue_failures AS
SELECT q.queue_id, q.template_code, u.username AS recipient, q.attempts, q.last_error, q.created_at
  FROM lms_notification_queue q JOIN lms_users u ON u.user_id = q.user_id
 WHERE q.status = 'FAILED' AND (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_job_status AS
SELECT j.job_name, j.enabled, j.repeat_interval, j.last_start_date, j.next_run_date, j.state,
       (SELECT d.status FROM user_scheduler_job_run_details d WHERE d.job_name = j.job_name
         ORDER BY d.log_date DESC FETCH FIRST 1 ROW ONLY) AS last_status
  FROM user_scheduler_jobs j
 WHERE j.job_name LIKE 'LMS\_%' ESCAPE '\' AND (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_rate_violations AS
SELECT TRUNC(CAST(event_time AS DATE), 'HH24') AS hour_start, operation, COUNT(*) AS violations, COUNT(DISTINCT subject_key) AS subjects
  FROM lms_security_events
 WHERE event_type = 'RATE_LIMIT' AND event_time > SYSTIMESTAMP - INTERVAL '7' DAY
   AND (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL'
 GROUP BY TRUNC(CAST(event_time AS DATE), 'HH24'), operation;

-- ------------------------------------------------------------------- analytics ----------
CREATE OR REPLACE VIEW v_lms_exec_dept_trend AS
SELECT s.summary_day, d.department_id, d.name_en AS department_en, d.name_ar AS department_ar,
       s.enrollments, s.completions, s.learning_hours, s.refreshed_at
  FROM lms_sum_dept_daily s JOIN lms_departments d ON d.department_id = s.department_id
 WHERE (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_exec_courses AS
SELECT c.course_id, c.course_code, c.title_en, c.title_ar, c.status, s.enrolled, s.completed,
       ROUND(100 * s.completed / NULLIF(s.enrolled, 0), 1) AS completion_pct, s.avg_score, s.avg_rating, s.rating_count, s.refreshed_at
  FROM lms_courses c JOIN lms_sum_course s ON s.course_id = c.course_id
 WHERE (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL';

CREATE OR REPLACE VIEW v_lms_dept_participation AS
SELECT d.department_id, d.name_en AS department_en,
       COUNT(DISTINCT u.user_id) AS employees,
       COUNT(DISTINCT CASE WHEN e.last_activity_at >= SYSTIMESTAMP - INTERVAL '90' DAY THEN u.user_id END) AS active_90d,
       COUNT(DISTINCT CASE WHEN e.status = 'COMPLETED' THEN u.user_id END) AS with_completion
  FROM lms_departments d
  JOIN lms_users u ON u.department_id = d.department_id AND u.status = 'ACTIVE'
  LEFT JOIN lms_enrollments e ON e.user_id = u.user_id
 WHERE u.user_id IN (SELECT user_id FROM v_lms_visible_users)
 GROUP BY d.department_id, d.name_en;

CREATE OR REPLACE VIEW v_lms_my_profile AS
SELECT u.user_id, u.username, u.employee_no, u.full_name_en, u.full_name_ar, u.email, u.preferred_lang,
       d.name_en AS department_en, d.name_ar AS department_ar, p.job_title_en AS position_en, p.job_title_ar AS position_ar,
       m.full_name_en AS manager_en, m.full_name_ar AS manager_ar,
       (SELECT LISTAGG(r.role_code, ',') WITHIN GROUP (ORDER BY r.role_code)
          FROM lms_user_roles ur JOIN lms_roles r ON r.role_id = ur.role_id WHERE ur.user_id = u.user_id) AS roles
  FROM lms_users u
  LEFT JOIN lms_departments d ON d.department_id = u.department_id
  LEFT JOIN lms_positions p ON p.position_id = u.position_id
  LEFT JOIN lms_users m ON m.user_id = u.manager_user_id
 WHERE u.user_id = (SELECT lms_security_pkg.current_user_id_safe FROM dual);

-- ------------------------------------------------------------------- authoring (app 210) ----------
CREATE OR REPLACE VIEW v_lms_course_edit AS
SELECT c.course_id, c.course_code, c.title_en, c.title_ar, c.description_en, c.description_ar, c.objectives_en, c.objectives_ar,
       c.category_id, c.delivery_method, c.difficulty, c.duration_minutes, c.language_code, c.capacity, c.approval_required,
       c.completion_rule, c.pass_score_required, c.certificate_eligible, c.certificate_template_id,
       c.available_from, c.available_to, c.enroll_deadline, c.thumbnail_ref, c.status, c.row_version
  FROM lms_courses c WHERE c.course_id IN (SELECT course_id FROM v_lms_my_courses);

CREATE OR REPLACE VIEW v_lms_modules_edit AS
SELECT m.module_id, m.course_id, m.title_en, m.title_ar, m.sort_order
  FROM lms_modules m WHERE m.course_id IN (SELECT course_id FROM v_lms_my_courses);

CREATE OR REPLACE VIEW v_lms_lessons_edit AS
SELECT l.lesson_id, l.module_id, m.course_id, m.title_en AS module_title_en, m.sort_order AS module_order,
       l.title_en, l.title_ar, l.lesson_type, l.content_ref, l.duration_minutes, l.required_flag, l.prereq_lesson_id,
       l.sort_order, l.available_from,
       CASE WHEN l.content_ref IS NOT NULL OR l.content_text IS NOT NULL THEN 'Y' ELSE 'N' END AS has_content
  FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
 WHERE m.course_id IN (SELECT course_id FROM v_lms_my_courses);

CREATE OR REPLACE VIEW v_lms_quizzes_edit AS
SELECT z.quiz_id, z.course_id, z.lesson_id, z.title_en, z.title_ar, z.pass_score, z.time_limit_min, z.max_attempts,
       z.question_count, z.randomize_q, z.randomize_a, z.show_review, z.required_flag, z.available_from, z.available_to, z.active_flag,
       (SELECT COUNT(*) FROM lms_quiz_questions qq WHERE qq.quiz_id = z.quiz_id) AS linked_questions,
       (SELECT COUNT(*) FROM lms_quiz_attempts a WHERE a.quiz_id = z.quiz_id) AS attempts
  FROM lms_quizzes z WHERE z.course_id IN (SELECT course_id FROM v_lms_my_courses);

CREATE OR REPLACE VIEW v_lms_question_options_edit AS
SELECT o.option_id, o.question_id, o.option_text_en, o.option_text_ar, o.is_correct, o.match_key, o.sort_order
  FROM lms_question_options o WHERE o.question_id IN (SELECT question_id FROM v_lms_question_authoring);

-- manual grading detail: only items still needing a grade, only for courses the caller manages
CREATE OR REPLACE VIEW v_lms_grading_detail AS
SELECT r.attempt_id, r.question_id, r.sort_order, q.question_type, q.text_en, q.text_ar, q.points AS max_points,
       r.answer_json, r.points_awarded, r.feedback
  FROM lms_quiz_responses r
  JOIN lms_questions q ON q.question_id = r.question_id
 WHERE r.attempt_id IN (SELECT attempt_id FROM v_lms_grading_queue)
   AND q.question_type IN ('ESSAY','SHORT');

CREATE OR REPLACE VIEW v_lms_effective_permissions AS
SELECT u.user_id, u.username, u.full_name_en, p.permission_code, rp.scope, r.role_code
  FROM lms_users u
  JOIN lms_user_roles ur ON ur.user_id = u.user_id
  JOIN lms_roles r ON r.role_id = ur.role_id
  JOIN lms_role_permissions rp ON rp.role_id = r.role_id
  JOIN lms_permissions p ON p.permission_id = rp.permission_id
 WHERE (SELECT lms_security_pkg.permission_scope('ROLE_ADMIN') FROM dual) = 'ALL'
    OR (SELECT lms_security_pkg.permission_scope('AUDIT_VIEW') FROM dual) = 'ALL';

-- ------------------------------------------------------------------- managers / analytics ----------
CREATE OR REPLACE VIEW v_lms_team_results AS
SELECT a.attempt_id, a.user_id, u.full_name_en, u.full_name_ar, u.department_id, z.course_id, c.title_en AS course_en, c.title_ar AS course_ar,
       z.title_en AS quiz_en, a.attempt_no, a.score_pct, a.passed_flag, a.submitted_at
  FROM lms_quiz_attempts a
  JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
  JOIN lms_courses c ON c.course_id = z.course_id
  JOIN lms_users u ON u.user_id = a.user_id
 WHERE a.status = 'GRADED' AND a.user_id IN (SELECT user_id FROM v_lms_visible_users);

CREATE OR REPLACE VIEW v_lms_team_recommended AS
SELECT g.user_id, g.full_name_en, c.course_id, c.title_en, c.title_ar, SUM(LEAST(cs.level_gained, g.gap)) AS coverage
  FROM v_lms_skill_gaps g
  JOIN lms_course_skills cs ON cs.skill_id = g.skill_id
  JOIN lms_courses c ON c.course_id = cs.course_id AND c.status = 'PUBLISHED'
 WHERE NOT EXISTS (SELECT 1 FROM lms_enrollments e WHERE e.user_id = g.user_id AND e.course_id = c.course_id
                    AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED'))
 GROUP BY g.user_id, g.full_name_en, c.course_id, c.title_en, c.title_ar;

-- skill-gap index per department: average of gap / required level (0 = no gap, 100 = nothing acquired)
CREATE OR REPLACE VIEW v_lms_skill_gap_by_dept AS
SELECT d.department_id, d.name_en AS department_en, COUNT(DISTINCT g.user_id) AS employees_with_gaps,
       ROUND(100 * AVG(g.gap / g.required_level), 1) AS gap_index
  FROM v_lms_skill_gaps g JOIN lms_departments d ON d.department_id = g.department_id
 GROUP BY d.department_id, d.name_en;

-- single source for organisation KPIs (page 240:1 and LMS_REPORTING_PKG.ORG_KPIS)
CREATE OR REPLACE VIEW v_lms_org_kpis AS
SELECT (SELECT COUNT(*) FROM lms_users WHERE status = 'ACTIVE')                                         AS total_learners,
       (SELECT COUNT(DISTINCT user_id) FROM lms_enrollments WHERE last_activity_at >= SYSTIMESTAMP - INTERVAL '30' DAY) AS active_learners,
       (SELECT COUNT(*) FROM lms_courses)                                                               AS total_courses,
       (SELECT COUNT(*) FROM lms_courses WHERE status = 'PUBLISHED')                                    AS published_courses,
       (SELECT COUNT(*) FROM lms_enrollments WHERE status NOT IN ('CANCELLED','WAITLISTED'))            AS total_enrollments,
       (SELECT ROUND(100 * SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1)
          FROM lms_enrollments WHERE status NOT IN ('CANCELLED','WAITLISTED','PENDING'))                AS completion_rate_pct,
       (SELECT ROUND(AVG(avg_score), 1) FROM lms_sum_course)                                            AS avg_assessment_score,
       (SELECT ROUND(100 * SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1)
          FROM lms_enrollments WHERE enrollment_type = 'MANDATORY' AND status NOT IN ('CANCELLED','EXPIRED')) AS mandatory_compliance_pct,
       (SELECT COUNT(*) FROM lms_certificates WHERE status IN ('VALID','EXPIRED','REVOKED'))            AS certificates_issued,
       (SELECT COUNT(*) FROM lms_certificates WHERE status = 'EXPIRED')                                 AS certificates_expired,
       (SELECT ROUND(SUM(time_spent_sec) / 3600, 1) FROM lms_enrollments)                               AS learning_hours,
       (SELECT ROUND(AVG(avg_rating), 2) FROM lms_sum_course WHERE avg_rating IS NOT NULL)              AS avg_course_rating,
       (SELECT MAX(refreshed_at) FROM lms_sum_course)                                                   AS summaries_refreshed_at
  FROM dual
 WHERE (SELECT lms_security_pkg.permission_scope('REPORT_ORG') FROM dual) = 'ALL';
