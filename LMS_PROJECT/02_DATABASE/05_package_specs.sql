-- =============================================================================
-- Package SPECIFICATIONS | Oracle 19c | STATUS: written, NOT compiled
-- Run after 01-04 and BEFORE the bodies (06-08). All specs first, then all bodies,
-- because packages call each other in both directions.
--
-- Conventions
--  * Packages never COMMIT, except jobs (marked JOB) and autonomous writers
--    (LMS_AUDIT_PKG, LMS_RATE_LIMIT_PKG). The APEX page process owns the transaction.
--  * Error codes: -20400 invalid input, -20401 not authenticated, -20403 forbidden,
--    -20404 not found, -20409 state conflict, -20410..-20419 module-specific,
--    -20429 rate limited.
--  * ACCESSIBLE BY restricts internal state-changing entry points to named packages, so
--    granting EXECUTE on the package to the APEX schema does not expose them.
-- =============================================================================

-- (LMS_UTIL_PKG lives in 02_packages_security_ratelimit.sql)
CREATE OR REPLACE PACKAGE lms_notification_pkg AS
  /* Queue a notification (same transaction as the business change). p_payload = JSON object of
     placeholder values; optional key "link" becomes the in-app link. */
  PROCEDURE enqueue(p_user_id IN NUMBER, p_template_code IN VARCHAR2, p_payload IN VARCHAR2 DEFAULT NULL);
  /* JOB: renders templates (user language, English fallback), writes in-app rows, sends e-mail,
     retries with back-off 1/5/30/60 min, FAILED after 5 attempts. Commits (job owns the txn). */
  PROCEDURE process_queue(p_batch IN PLS_INTEGER DEFAULT 200);
  PROCEDURE mark_read(p_notification_id IN NUMBER);
  PROCEDURE mark_all_read;
  FUNCTION  unread_count RETURN NUMBER;
END lms_notification_pkg;
/

CREATE OR REPLACE PACKAGE lms_approval_pkg AS
  PROCEDURE request_enrollment(p_enrollment_id IN NUMBER, p_requester_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_enrollment_pkg);
  PROCEDURE request_course_publish(p_course_id IN NUMBER, p_requester_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_course_pkg);
  /* p_decision: 'APPROVE' | 'REJECT'. Approver (or holder of the approving permission) only;
     never the requester. */
  PROCEDURE decide(p_approval_id IN NUMBER, p_decision IN VARCHAR2, p_note IN VARCHAR2 DEFAULT NULL);
  /* JOB: re-route overdue approvals to the approver's manager (max 3 escalations). */
  PROCEDURE escalate_overdue;
END lms_approval_pkg;
/

CREATE OR REPLACE PACKAGE lms_user_pkg AS
  PROCEDURE grant_role(p_user_id IN NUMBER, p_role_code IN VARCHAR2);
  PROCEDURE revoke_role(p_user_id IN NUMBER, p_role_code IN VARCHAR2);
  PROCEDURE set_status(p_user_id IN NUMBER, p_status IN VARCHAR2);
  PROCEDURE set_manager(p_user_id IN NUMBER, p_manager_user_id IN NUMBER);
  PROCEDURE set_language(p_lang IN VARCHAR2);
  /* TRUE if making p_manager the manager of p_user would create a cycle. */
  FUNCTION would_cycle(p_user_id IN NUMBER, p_manager_user_id IN NUMBER) RETURN BOOLEAN;
END lms_user_pkg;
/

/* HR integration entry point. Deliberately a separate package: GRANT EXECUTE only to the
   integration schema (ORDS handler / sync job), never to the APEX parsing schema. */
CREATE OR REPLACE PACKAGE lms_hr_sync_pkg AS
  PROCEDURE upsert_employee(p_username IN VARCHAR2, p_employee_no IN VARCHAR2,
                            p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2, p_email IN VARCHAR2,
                            p_department_code IN VARCHAR2, p_position_code IN VARCHAR2,
                            p_manager_employee_no IN VARCHAR2, p_status IN VARCHAR2 DEFAULT 'ACTIVE');
END lms_hr_sync_pkg;
/

CREATE OR REPLACE PACKAGE lms_course_pkg AS
  /* Authorization helper used by APEX schemes and other packages: ALL scope, or ASSIGNED scope
     and the user is creator/instructor of the course. */
  FUNCTION can_manage_course(p_course_id IN NUMBER, p_permission IN VARCHAR2) RETURN BOOLEAN;

  FUNCTION create_course(p_course_code IN VARCHAR2, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2,
                         p_category_id IN NUMBER, p_delivery_method IN VARCHAR2,
                         p_difficulty IN VARCHAR2 DEFAULT 'BEGINNER', p_duration_minutes IN NUMBER DEFAULT 0,
                         p_language_code IN VARCHAR2 DEFAULT 'en', p_capacity IN NUMBER DEFAULT NULL,
                         p_approval_required IN VARCHAR2 DEFAULT 'N',
                         p_completion_rule IN VARCHAR2 DEFAULT 'LESSONS',
                         p_certificate_eligible IN VARCHAR2 DEFAULT 'N') RETURN NUMBER;
  /* Optimistic locking: raises -20409 if p_row_version is stale. Editable in DRAFT/SUSPENDED only. */
  PROCEDURE update_course(p_course_id IN NUMBER, p_row_version IN NUMBER,
                          p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2, p_category_id IN NUMBER,
                          p_difficulty IN VARCHAR2, p_duration_minutes IN NUMBER, p_capacity IN NUMBER,
                          p_approval_required IN VARCHAR2, p_completion_rule IN VARCHAR2,
                          p_certificate_eligible IN VARCHAR2,
                          p_available_from IN DATE DEFAULT NULL, p_available_to IN DATE DEFAULT NULL,
                          p_enroll_deadline IN DATE DEFAULT NULL);
  FUNCTION add_module(p_course_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  FUNCTION add_lesson(p_module_id IN NUMBER, p_title_en IN VARCHAR2, p_lesson_type IN VARCHAR2,
                      p_title_ar IN VARCHAR2 DEFAULT NULL, p_content_ref IN VARCHAR2 DEFAULT NULL,
                      p_duration_minutes IN NUMBER DEFAULT 0, p_required_flag IN VARCHAR2 DEFAULT 'Y',
                      p_prereq_lesson_id IN NUMBER DEFAULT NULL) RETURN NUMBER;
  PROCEDURE add_prerequisite(p_course_id IN NUMBER, p_prereq_course_id IN NUMBER);
  PROCEDURE set_instructor(p_course_id IN NUMBER, p_user_id IN NUMBER, p_role IN VARCHAR2 DEFAULT 'LEAD');
  PROCEDURE set_certificate_template(p_course_id IN NUMBER, p_template_id IN NUMBER);
  /* NULL when publishable, otherwise a message naming the first problem. */
  FUNCTION validate_publishable(p_course_id IN NUMBER) RETURN VARCHAR2;
  PROCEDURE submit_for_review(p_course_id IN NUMBER);
  PROCEDURE apply_review(p_course_id IN NUMBER, p_approved IN BOOLEAN, p_note IN VARCHAR2 DEFAULT NULL)
    ACCESSIBLE BY (PACKAGE lms_approval_pkg);
  /* Descriptive text is stored as PLAIN TEXT and must be escaped on output. p_thumbnail_ref = object-store key. */
  PROCEDURE set_course_text(p_course_id IN NUMBER, p_row_version IN NUMBER,
                            p_description_en IN CLOB, p_description_ar IN CLOB,
                            p_objectives_en IN VARCHAR2, p_objectives_ar IN VARCHAR2, p_thumbnail_ref IN VARCHAR2);
  /* Sets reference/text of a lesson, sanitises HTML lessons, writes a LMS_CONTENT_VERSIONS row. */
  PROCEDURE set_lesson_content(p_lesson_id IN NUMBER, p_content_ref IN VARCHAR2, p_content_text IN VARCHAR2);
  PROCEDURE update_module(p_module_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2);
  PROCEDURE update_lesson(p_lesson_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2,
                          p_lesson_type IN VARCHAR2, p_duration_minutes IN NUMBER, p_required_flag IN VARCHAR2,
                          p_prereq_lesson_id IN NUMBER, p_available_from IN DATE DEFAULT NULL);
  /* Document upload (<= 25 MB, allow-listed types, magic-byte check, SHA-256 stored). Storing a file does NOT replace the
     virus scan your policy may require: run the scan on the upload before calling this (see doc 06). */
  PROCEDURE add_lesson_file(p_lesson_id IN NUMBER, p_file_name IN VARCHAR2, p_mime_type IN VARCHAR2, p_blob IN BLOB);
  PROCEDURE move_module(p_module_id IN NUMBER, p_direction IN VARCHAR2);      -- 'UP' | 'DOWN'
  PROCEDURE move_lesson(p_lesson_id IN NUMBER, p_direction IN VARCHAR2);
  PROCEDURE remove_module(p_module_id IN NUMBER);                             -- only when empty
  PROCEDURE remove_lesson(p_lesson_id IN NUMBER);                             -- only without learner progress
  PROCEDURE suspend(p_course_id IN NUMBER);
  PROCEDURE reinstate(p_course_id IN NUMBER);
  PROCEDURE archive(p_course_id IN NUMBER);
END lms_course_pkg;
/

CREATE OR REPLACE PACKAGE lms_enrollment_pkg AS
  /* Self-enrolment for the authenticated user. Idempotent: an open enrolment is returned. */
  PROCEDURE enroll_self(p_course_id IN NUMBER, p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2);
  /* Assignment by manager (TEAM scope) or administrator (ALL scope). */
  PROCEDURE assign(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due_date IN DATE DEFAULT NULL,
                   p_type IN VARCHAR2 DEFAULT 'ADMIN',
                   p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2);
  PROCEDURE cancel(p_enrollment_id IN NUMBER);
  PROCEDURE promote_waitlist(p_course_id IN NUMBER);
  /* Mandatory/bulk assignment header + immediate set-based expansion. Returns assignment id. */
  FUNCTION create_assignment(p_course_id IN NUMBER, p_target_type IN VARCHAR2, p_target_id IN NUMBER,
                             p_due_date IN DATE) RETURN NUMBER;
  /* JOB: re-expand all ACTIVE assignments (new hires, users meeting prerequisites since). */
  PROCEDURE close_assignment(p_assignment_id IN NUMBER);
  PROCEDURE sync_assignments;
  PROCEDURE apply_approval(p_enrollment_id IN NUMBER, p_approved IN BOOLEAN)
    ACCESSIBLE BY (PACKAGE lms_approval_pkg);
  PROCEDURE start_renewal(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due_date IN DATE)
    ACCESSIBLE BY (PACKAGE lms_certification_pkg);
END lms_enrollment_pkg;
/

CREATE OR REPLACE PACKAGE lms_progress_pkg AS
  /* Server-validated progress event. p_event_type START|HEARTBEAT|COMPLETE; p_event_uuid is the
     client-generated id used to de-duplicate retries. */
  PROCEDURE record_event(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER, p_event_type IN VARCHAR2,
                         p_event_uuid IN VARCHAR2, p_position IN NUMBER DEFAULT 0,
                         p_seconds IN NUMBER DEFAULT 0,
                         p_progress_pct OUT NUMBER, p_status OUT VARCHAR2);
  FUNCTION get_resume_position(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN NUMBER;
  /* Instructor/admin confirmation for courses with the INSTRUCTOR_APPROVAL rule. */
  PROCEDURE approve_completion(p_enrollment_id IN NUMBER);
  PROCEDURE complete_lesson_system(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_assessment_pkg);
  PROCEDURE evaluate_completion(p_enrollment_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_assessment_pkg, PACKAGE lms_session_pkg);
END lms_progress_pkg;
/

CREATE OR REPLACE PACKAGE lms_assessment_pkg AS
  FUNCTION create_quiz(p_course_id IN NUMBER, p_title_en IN VARCHAR2, p_pass_score IN NUMBER DEFAULT 70,
                       p_time_limit_min IN NUMBER DEFAULT NULL, p_max_attempts IN NUMBER DEFAULT 3,
                       p_lesson_id IN NUMBER DEFAULT NULL) RETURN NUMBER;
  PROCEDURE link_question(p_quiz_id IN NUMBER, p_question_id IN NUMBER, p_sort_order IN NUMBER DEFAULT 0);
  PROCEDURE update_quiz(p_quiz_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2, p_pass_score IN NUMBER,
                        p_time_limit_min IN NUMBER, p_max_attempts IN NUMBER, p_question_count IN NUMBER,
                        p_randomize_q IN VARCHAR2, p_randomize_a IN VARCHAR2, p_show_review IN VARCHAR2,
                        p_required_flag IN VARCHAR2, p_available_from IN DATE, p_available_to IN DATE,
                        p_active_flag IN VARCHAR2, p_lesson_id IN NUMBER DEFAULT NULL);
  PROCEDURE unlink_question(p_quiz_id IN NUMBER, p_question_id IN NUMBER);
  FUNCTION create_bank(p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  /* p_question_id NULL = create. Questions already answered in any attempt are immutable (clone_question instead). */
  FUNCTION save_question(p_question_id IN NUMBER, p_bank_id IN NUMBER, p_question_type IN VARCHAR2,
                         p_text_en IN VARCHAR2, p_text_ar IN VARCHAR2, p_points IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER;
  FUNCTION save_option(p_option_id IN NUMBER, p_question_id IN NUMBER, p_text_en IN VARCHAR2, p_text_ar IN VARCHAR2,
                       p_is_correct IN VARCHAR2, p_match_key IN VARCHAR2, p_sort_order IN NUMBER DEFAULT 0) RETURN NUMBER;
  PROCEDURE remove_option(p_option_id IN NUMBER);
  PROCEDURE remove_question(p_question_id IN NUMBER);
  FUNCTION clone_question(p_question_id IN NUMBER) RETURN NUMBER;
  /* NULL when every active question of the quiz is answerable and has a consistent key, else the first problem. */
  FUNCTION validate_quiz(p_quiz_id IN NUMBER) RETURN VARCHAR2;
  /* Returns the (new or resumed) attempt id. Eligibility, attempt limit and deadline are decided here. */
  FUNCTION start_attempt(p_quiz_id IN NUMBER) RETURN NUMBER;
  /* p_answer_json formats: {"selected":[optionId,...]} | {"pairs":[{"option":id,"choice":"text"}]} | {"text":"..."} */
  PROCEDURE save_answer(p_attempt_id IN NUMBER, p_question_id IN NUMBER, p_answer_json IN VARCHAR2);
  PROCEDURE submit_attempt(p_attempt_id IN NUMBER, p_status OUT VARCHAR2, p_score_pct OUT NUMBER,
                           p_passed OUT VARCHAR2);
  PROCEDURE grade_response(p_attempt_id IN NUMBER, p_question_id IN NUMBER, p_points IN NUMBER,
                           p_feedback IN VARCHAR2 DEFAULT NULL);
END lms_assessment_pkg;
/

CREATE OR REPLACE PACKAGE lms_learning_path_pkg AS
  FUNCTION create_path(p_path_code IN VARCHAR2, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2 DEFAULT NULL,
                       p_certificate_eligible IN VARCHAR2 DEFAULT 'N',
                       p_certificate_template_id IN NUMBER DEFAULT NULL) RETURN NUMBER;
  PROCEDURE add_course(p_path_id IN NUMBER, p_course_id IN NUMBER, p_sequence_no IN NUMBER,
                       p_required_flag IN VARCHAR2 DEFAULT 'Y');
  PROCEDURE publish_path(p_path_id IN NUMBER);
  FUNCTION enroll_path(p_path_id IN NUMBER) RETURN NUMBER;
  /* Enrols the learner in the next incomplete course of the path (sequence order). */
  PROCEDURE start_next_course(p_path_enrollment_id IN NUMBER, p_course_id OUT NUMBER,
                              p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2);
  PROCEDURE on_course_completed(p_user_id IN NUMBER, p_course_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_progress_pkg);
END lms_learning_path_pkg;
/

CREATE OR REPLACE PACKAGE lms_session_pkg AS
  FUNCTION create_session(p_course_id IN NUMBER, p_venue_id IN NUMBER, p_instructor_id IN NUMBER,
                          p_start_ts IN TIMESTAMP WITH TIME ZONE, p_end_ts IN TIMESTAMP WITH TIME ZONE,
                          p_seats IN NUMBER, p_meeting_url IN VARCHAR2 DEFAULT NULL,
                          p_min_attendance_pct IN NUMBER DEFAULT 80) RETURN NUMBER;
  PROCEDURE publish_session(p_session_id IN NUMBER);
  /* ---- venues (SESSION_MANAGE with ALL scope: training administrators) ---- */
  /* p_venue_id NULL = create. Deactivating, or lowering the capacity below the seats of an upcoming session, is refused. */
  FUNCTION save_venue(p_venue_id IN NUMBER, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2, p_address IN VARCHAR2,
                      p_capacity IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER;
  /* Only a venue that never hosted a session can be deleted; otherwise deactivate it. */
  PROCEDURE remove_venue(p_venue_id IN NUMBER);
  PROCEDURE register(p_session_id IN NUMBER, p_status OUT VARCHAR2);
  PROCEDURE cancel_registration(p_session_enrollment_id IN NUMBER);
  PROCEDURE cancel_session(p_session_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT NULL);
  PROCEDURE reschedule(p_session_id IN NUMBER, p_start_ts IN TIMESTAMP WITH TIME ZONE,
                       p_end_ts IN TIMESTAMP WITH TIME ZONE);
  PROCEDURE record_attendance(p_session_enrollment_id IN NUMBER, p_day IN DATE, p_status IN VARCHAR2);
  /* Edit an UPCOMING session (SCHEDULED/PUBLISHED, not started). Refuses seats below the registered count, an inactive or too small
     venue, a double-booked venue/trainer, and a change of the attendance threshold once attendance has been recorded.
     Participants are notified when the place, link or trainer changes; extra seats promote the waiting list. */
  PROCEDURE update_session(p_session_id IN NUMBER, p_venue_id IN NUMBER, p_instructor_id IN NUMBER, p_seats IN NUMBER,
                           p_meeting_url IN VARCHAR2, p_min_attendance_pct IN NUMBER);
  /* Close a PUBLISHED session after it ended and re-evaluate course completion of every registered learner. */
  PROCEDURE complete_session(p_session_id IN NUMBER);
  /* JOB (daily): completes PUBLISHED sessions that ended more than SESSION_AUTOCLOSE_DAYS ago (0 = off). Returns sessions closed. */
  FUNCTION close_finished_sessions RETURN NUMBER;
  /* JOB (every 15 min): reminders SESSION_REMINDER_LONG_HOURS (24) and SESSION_REMINDER_SHORT_HOURS (1) before the start to
     REGISTERED learners (never waiting list), plus one trainer reminder. Each is sent once per registration. Returns reminders queued. */
  FUNCTION send_reminders RETURN NUMBER;
END lms_session_pkg;
/

CREATE OR REPLACE PACKAGE lms_certification_pkg AS
  PROCEDURE issue_for_enrollment(p_enrollment_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_progress_pkg);
  PROCEDURE issue_for_path(p_path_enrollment_id IN NUMBER)
    ACCESSIBLE BY (PACKAGE lms_learning_path_pkg);
  /* Call from the page before rendering/downloading a PDF: ownership (or CERT_POLICY) + CERT_GENERATE limit. */
  PROCEDURE authorize_download(p_certificate_id IN NUMBER);
  /* Public verification. p_client_key = proxy-verified client address (hashed by the limiter).
     Returns title, status, dates and a minimal holder label only. */
  FUNCTION verify(p_code IN VARCHAR2, p_client_key IN VARCHAR2) RETURN SYS_REFCURSOR;
  /* Same result without throttling. Only the ORDS package may call it: it applies the limiter itself so it can
     answer HTTP 429 with Retry-After. Keeping it ACCESSIBLE BY prevents bypassing the limit from APEX/SQL. */
  FUNCTION lookup_certificate(p_code IN VARCHAR2) RETURN SYS_REFCURSOR
    ACCESSIBLE BY (PACKAGE lms_ords_pkg, PACKAGE lms_certification_pkg);
  PROCEDURE revoke(p_certificate_id IN NUMBER, p_reason IN VARCHAR2);
  /* JOB */
  PROCEDURE expire_due;
  /* JOB: expiry warnings (90/30/7 days) and renewal enrolment inside RENEWAL_WINDOW_DAYS. */
  PROCEDURE renewal_sweep;
END lms_certification_pkg;
/

CREATE OR REPLACE PACKAGE lms_feedback_pkg AS
  PROCEDURE submit_review(p_enrollment_id IN NUMBER, p_course_rating IN NUMBER,
                          p_instructor_rating IN NUMBER DEFAULT NULL, p_review_text IN VARCHAR2 DEFAULT NULL);
  PROCEDURE submit_answer(p_enrollment_id IN NUMBER, p_question_id IN NUMBER,
                          p_rating IN NUMBER DEFAULT NULL, p_comment IN VARCHAR2 DEFAULT NULL);
  PROCEDURE set_review_visibility(p_review_id IN NUMBER, p_visible IN BOOLEAN);
  /* JOB (daily): one reminder per completed enrolment, FEEDBACK_REMINDER_DAYS after completion (0 = off) and not older than
     FEEDBACK_REMINDER_WINDOW_DAYS, only while a review or a questionnaire answer is still missing and the learner is ACTIVE.
     Returns the number of reminders queued (for the job log). */
  FUNCTION send_reminders RETURN NUMBER;
  /* Owner may edit a review for REVIEW_EDIT_DAYS days after it was written (0 = reviews are final). */
  PROCEDURE update_review(p_review_id IN NUMBER, p_course_rating IN NUMBER,
                          p_instructor_rating IN NUMBER DEFAULT NULL, p_review_text IN VARCHAR2 DEFAULT NULL);
  /* ---- questionnaire authoring (permission COURSE_PUBLISH) ---- */
  FUNCTION save_form(p_form_id IN NUMBER, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2, p_active_flag IN VARCHAR2) RETURN NUMBER;
  /* New form with copies of all questions; use it to change a form that already has responses. */
  FUNCTION clone_form(p_form_id IN NUMBER) RETURN NUMBER;
  /* p_question_id NULL = create. When responses exist only SORT_ORDER may change. */
  FUNCTION save_form_question(p_question_id IN NUMBER, p_form_id IN NUMBER, p_text_en IN VARCHAR2, p_text_ar IN VARCHAR2,
                              p_answer_type IN VARCHAR2, p_sort_order IN NUMBER) RETURN NUMBER;
  PROCEDURE remove_form_question(p_question_id IN NUMBER);
  /* Attach (or with NULL detach) a form to a course. Refused once feedback was collected with a different form. */
  PROCEDURE assign_form(p_course_id IN NUMBER, p_form_id IN NUMBER);
END lms_feedback_pkg;
/

CREATE OR REPLACE PACKAGE lms_skill_pkg AS
  PROCEDURE assess_skill(p_user_id IN NUMBER, p_skill_id IN NUMBER, p_level IN NUMBER);
  /* Courses that close the user's skill gaps (self, or a user the caller may see). */
  FUNCTION recommended_courses(p_user_id IN NUMBER DEFAULT NULL) RETURN SYS_REFCURSOR;
  /* ---- skills framework maintenance (permission SKILL_MANAGE) ---- */
  /* p_skill_id NULL = create. Code is upper-cased; A-Z 0-9 _ - only. */
  FUNCTION save_skill(p_skill_id IN NUMBER, p_skill_code IN VARCHAR2, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2,
                      p_skill_group IN VARCHAR2, p_active_flag IN VARCHAR2) RETURN NUMBER;
  /* Only an unused skill can be deleted; otherwise deactivate it with save_skill. */
  PROCEDURE remove_skill(p_skill_id IN NUMBER);
  /* Employees -> Positions -> Required skills. p_required_level NULL removes the requirement (levels 1-5). */
  PROCEDURE set_position_skill(p_position_id IN NUMBER, p_skill_id IN NUMBER, p_required_level IN NUMBER);
  /* Courses -> Skills they build. Allowed for SKILL_MANAGE or the course's authors. NULL removes the link. */
  PROCEDURE set_course_skill(p_course_id IN NUMBER, p_skill_id IN NUMBER, p_level_gained IN NUMBER);
  /* Adds the skill requirements of one position to another (never overwrites existing requirements). Returns rows added. */
  FUNCTION copy_position_skills(p_from_position IN NUMBER, p_to_position IN NUMBER) RETURN NUMBER;
END lms_skill_pkg;
/

CREATE OR REPLACE PACKAGE lms_reporting_pkg AS
  /* JOB */
  PROCEDURE refresh_summaries;
  /* JOB: mandatory-training reminders (7 and 1 days before due) and manager escalation when overdue. */
  PROCEDURE send_reminders;
  /* JOB: retention purge in batches, driven by LMS_SYSTEM_SETTINGS. */
  PROCEDURE purge_logs;
  /* Organisation KPIs (requires REPORT_ORG with scope ALL). */
  FUNCTION org_kpis RETURN SYS_REFCURSOR;
END lms_reporting_pkg;
/
