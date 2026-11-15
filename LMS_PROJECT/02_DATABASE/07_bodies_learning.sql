-- =============================================================================
-- Package BODIES (2/3): enrollment, progress, assessment, learning path, session
-- Oracle 19c | STATUS: written, NOT compiled. Requires 01-06.
-- Lock order (to avoid deadlocks): course/quiz/session row -> enrollment row -> child rows.
-- Exception: progress/assessment lock the ENROLLMENT row only.
-- =============================================================================

-- ---------------------------------------------------------- ENROLLMENT -------
CREATE OR REPLACE PACKAGE BODY lms_enrollment_pkg AS

  c_err_state    CONSTANT NUMBER := -20410;  -- course not open for enrolment
  c_err_prereq   CONSTANT NUMBER := -20411;
  c_err_closed   CONSTANT NUMBER := -20412;  -- deadline passed
  c_err_cancel   CONSTANT NUMBER := -20413;
  c_err_done     CONSTANT NUMBER := -20414;  -- already completed

  FUNCTION seats_taken(p_course_id IN NUMBER) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_enrollments
     WHERE course_id = p_course_id AND status IN ('APPROVED','ENROLLED','IN_PROGRESS');
    RETURN l_n;
  END seats_taken;

  PROCEDURE do_enroll(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due IN DATE, p_type IN VARCHAR2,
                      p_actor IN NUMBER, p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2) IS
    l_course   lms_courses%ROWTYPE;
    l_ustatus  lms_users.status%TYPE;
    l_missing  NUMBER;
    l_done     NUMBER;
    l_exp      DATE;
    l_status   VARCHAR2(12);
    l_window   NUMBER := lms_util_pkg.get_number('RENEWAL_WINDOW_DAYS', 90);
  BEGIN
    -- Serialise per course: capacity decisions are made while holding this row lock (DD-03).
    BEGIN
      SELECT * INTO l_course FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;

    BEGIN
      SELECT status INTO l_ustatus FROM lms_users WHERE user_id = p_user_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'User not found'); END;
    IF l_ustatus <> 'ACTIVE' THEN RAISE_APPLICATION_ERROR(-20409, 'User is not active'); END IF;

    -- Idempotency / BR-01: an open enrolment is returned as is.
    BEGIN
      SELECT enrollment_id, status INTO p_enrollment_id, p_status
        FROM lms_enrollments
       WHERE user_id = p_user_id AND course_id = p_course_id
         AND status NOT IN ('CANCELLED','FAILED','EXPIRED','COMPLETED');
      RETURN;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL; END;

    -- Re-taking a completed course by self-enrolment is only allowed inside the renewal window.
    IF p_type = 'SELF' THEN
      SELECT COUNT(*) INTO l_done FROM lms_enrollments
       WHERE user_id = p_user_id AND course_id = p_course_id AND status = 'COMPLETED';
      IF l_done > 0 THEN
        SELECT MAX(expires_at) INTO l_exp FROM lms_certificates
         WHERE user_id = p_user_id AND course_id = p_course_id AND status = 'VALID';
        IF l_exp IS NULL OR l_exp > TRUNC(SYSDATE) + l_window THEN
          RAISE_APPLICATION_ERROR(c_err_done, 'You have already completed this course');
        END IF;
      END IF;
    END IF;

    -- BR-03
    IF l_course.status <> 'PUBLISHED'
       OR (l_course.available_from IS NOT NULL AND TRUNC(SYSDATE) < l_course.available_from)
       OR (l_course.available_to   IS NOT NULL AND TRUNC(SYSDATE) > l_course.available_to) THEN
      RAISE_APPLICATION_ERROR(c_err_state, 'Course is not open for enrolment');
    END IF;
    IF p_type = 'SELF' AND l_course.enroll_deadline IS NOT NULL AND TRUNC(SYSDATE) > l_course.enroll_deadline THEN
      RAISE_APPLICATION_ERROR(c_err_closed, 'Enrolment deadline has passed');
    END IF;

    -- BR-04 (set-based)
    SELECT COUNT(*) INTO l_missing FROM lms_course_prerequisites p
     WHERE p.course_id = p_course_id
       AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                        WHERE e.user_id = p_user_id AND e.course_id = p.prereq_course_id AND e.status = 'COMPLETED');
    IF l_missing > 0 THEN RAISE_APPLICATION_ERROR(c_err_prereq, 'Prerequisite courses not completed'); END IF;

    -- BR-02: mandatory assignments are not blocked by capacity or approval.
    IF p_type = 'SELF' AND l_course.approval_required = 'Y' THEN
      l_status := 'PENDING';
    ELSIF p_type <> 'MANDATORY' AND l_course.capacity IS NOT NULL AND seats_taken(p_course_id) >= l_course.capacity THEN
      l_status := 'WAITLISTED';
    ELSE
      l_status := 'ENROLLED';
    END IF;

    INSERT INTO lms_enrollments (user_id, course_id, status, enrollment_type, assigned_by, due_date)
    VALUES (p_user_id, p_course_id, l_status, p_type, p_actor, p_due)
    RETURNING enrollment_id INTO p_enrollment_id;
    p_status := l_status;

    IF l_status = 'PENDING' THEN
      lms_approval_pkg.request_enrollment(p_enrollment_id, p_user_id);
    END IF;
    lms_notification_pkg.enqueue(p_user_id,
      CASE WHEN p_type = 'MANDATORY' THEN 'MANDATORY_ASSIGNED'
           WHEN l_status = 'PENDING' THEN 'ENROLL_PENDING'
           WHEN l_status = 'WAITLISTED' THEN 'ENROLL_WAITLIST'
           ELSE 'ENROLL_CONFIRM' END,
      lms_util_pkg.js('course', l_course.title_en, 'due', TO_CHAR(p_due, 'YYYY-MM-DD')));
    lms_audit_pkg.log_event('ENROLL', 'ENROLLMENT', p_enrollment_id, 'SUCCESS',
                            lms_util_pkg.js('course', p_course_id, 'status', l_status, 'type', p_type));
  END do_enroll;

  PROCEDURE enroll_self(p_course_id IN NUMBER, p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
  BEGIN
    lms_security_pkg.require_permission('ENROLL_SELF');
    lms_rate_limit_pkg.enforce_limit('COURSE_ENROLL', l_user);
    do_enroll(l_user, p_course_id, NULL, 'SELF', l_user, p_enrollment_id, p_status);
  END enroll_self;

  PROCEDURE assign(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due_date IN DATE DEFAULT NULL,
                   p_type IN VARCHAR2 DEFAULT 'ADMIN',
                   p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_type  VARCHAR2(12) := p_type;
  BEGIN
    lms_security_pkg.require_permission('ENROLL_ASSIGN');
    IF p_type NOT IN ('ADMIN','MANAGER','MANDATORY','BULK','RULE') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid assignment type');
    END IF;
    IF NOT lms_security_pkg.can_manage_user('ENROLL_ASSIGN', p_user_id) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', NULL, 'DENIED', lms_util_pkg.js('target_user', p_user_id));
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF lms_security_pkg.permission_scope('ENROLL_ASSIGN') = 'TEAM' THEN
      l_type := CASE WHEN p_type = 'MANDATORY' THEN 'MANDATORY' ELSE 'MANAGER' END;
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    do_enroll(p_user_id, p_course_id, p_due_date, l_type, l_actor, p_enrollment_id, p_status);
  END assign;

  PROCEDURE cancel(p_enrollment_id IN NUMBER) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_enr   lms_enrollments%ROWTYPE;
  BEGIN
    BEGIN
      SELECT * INTO l_enr FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Enrolment not found'); END;
    IF l_enr.user_id <> l_actor AND NOT lms_security_pkg.can_manage_user('ENROLL_ASSIGN', l_enr.user_id) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', p_enrollment_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_enr.status NOT IN ('PENDING','APPROVED','ENROLLED','IN_PROGRESS','WAITLISTED') THEN
      RAISE_APPLICATION_ERROR(c_err_cancel, 'Enrolment cannot be cancelled in status ' || l_enr.status);
    END IF;
    UPDATE lms_enrollments SET status = 'CANCELLED', row_version = row_version + 1 WHERE enrollment_id = p_enrollment_id;
    UPDATE lms_approvals SET status = 'CANCELLED', decided_at = SYSTIMESTAMP
     WHERE request_type = 'ENROLLMENT' AND entity_id = p_enrollment_id AND status = 'PENDING';
    lms_audit_pkg.log_event('CANCEL', 'ENROLLMENT', p_enrollment_id);
    promote_waitlist(l_enr.course_id);
  END cancel;

  PROCEDURE promote_waitlist(p_course_id IN NUMBER) IS
    l_course lms_courses%ROWTYPE;
    l_free   NUMBER;
    l_users  DBMS_SQL.NUMBER_TABLE;
  BEGIN
    SELECT * INTO l_course FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    l_free := CASE WHEN l_course.capacity IS NULL THEN 1000000
                   ELSE l_course.capacity - seats_taken(p_course_id) END;
    IF l_free > 0 THEN
      UPDATE lms_enrollments
         SET status = 'ENROLLED', row_version = row_version + 1
       WHERE enrollment_id IN (
               SELECT enrollment_id FROM lms_enrollments
                WHERE course_id = p_course_id AND status = 'WAITLISTED'
                ORDER BY enrolled_at, enrollment_id
                FETCH FIRST l_free ROWS ONLY)
      RETURNING user_id BULK COLLECT INTO l_users;
      FOR i IN 1 .. l_users.COUNT LOOP
        lms_notification_pkg.enqueue(l_users(i), 'ENROLL_PROMOTED', lms_util_pkg.js('course', l_course.title_en));
      END LOOP;
    END IF;
  END promote_waitlist;

  PROCEDURE apply_approval(p_enrollment_id IN NUMBER, p_approved IN BOOLEAN) IS
    l_enr    lms_enrollments%ROWTYPE;
    l_course lms_courses%ROWTYPE;
    l_status VARCHAR2(12);
  BEGIN
    SELECT * INTO l_enr FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    IF l_enr.status <> 'PENDING' THEN RAISE_APPLICATION_ERROR(-20409, 'Enrolment is not pending approval'); END IF;
    SELECT * INTO l_course FROM lms_courses WHERE course_id = l_enr.course_id FOR UPDATE;
    IF NOT p_approved THEN
      UPDATE lms_enrollments SET status = 'CANCELLED', row_version = row_version + 1 WHERE enrollment_id = p_enrollment_id;
      lms_notification_pkg.enqueue(l_enr.user_id, 'ENROLL_REJECTED', lms_util_pkg.js('course', l_course.title_en));
      RETURN;
    END IF;
    l_status := CASE WHEN l_course.capacity IS NOT NULL AND seats_taken(l_course.course_id) >= l_course.capacity
                     THEN 'WAITLISTED' ELSE 'ENROLLED' END;
    UPDATE lms_enrollments SET status = l_status, row_version = row_version + 1 WHERE enrollment_id = p_enrollment_id;
    lms_notification_pkg.enqueue(l_enr.user_id,
      CASE l_status WHEN 'ENROLLED' THEN 'ENROLL_APPROVED' ELSE 'ENROLL_WAITLIST' END,
      lms_util_pkg.js('course', l_course.title_en));
  END apply_approval;

  PROCEDURE start_renewal(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due_date IN DATE) IS
    l_id NUMBER; l_st VARCHAR2(12);
  BEGIN
    do_enroll(p_user_id, p_course_id, p_due_date, 'MANDATORY', NULL, l_id, l_st);
  END start_renewal;

  -- Set-based expansion of one assignment header. Caller must hold no lock on the course row.
  PROCEDURE expand_assignment(p_assignment_id IN NUMBER) IS
    l_a     lms_learning_assignments%ROWTYPE;
    l_c     lms_courses%ROWTYPE;
    l_start TIMESTAMP WITH TIME ZONE := SYSTIMESTAMP;
    l_rows  NUMBER;
  BEGIN
    SELECT * INTO l_a FROM lms_learning_assignments WHERE assignment_id = p_assignment_id;
    SELECT * INTO l_c FROM lms_courses WHERE course_id = l_a.course_id FOR UPDATE;  -- same lock as do_enroll
    IF l_c.status <> 'PUBLISHED' OR l_a.status <> 'ACTIVE' THEN RETURN; END IF;

    INSERT INTO lms_enrollments (user_id, course_id, status, enrollment_type, assigned_by, due_date)
    SELECT u.user_id, l_a.course_id, 'ENROLLED', 'MANDATORY', l_a.created_by, l_a.due_date
      FROM lms_users u
     WHERE u.status = 'ACTIVE'
       AND ((l_a.target_type = 'USER'       AND u.user_id       = l_a.target_id)
         OR (l_a.target_type = 'DEPARTMENT' AND u.department_id = l_a.target_id)
         OR (l_a.target_type = 'POSITION'   AND u.position_id   = l_a.target_id))
       AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                        WHERE e.user_id = u.user_id AND e.course_id = l_a.course_id
                          AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED'))   -- open or completed
       AND NOT EXISTS (SELECT 1 FROM lms_course_prerequisites p
                        WHERE p.course_id = l_a.course_id
                          AND NOT EXISTS (SELECT 1 FROM lms_enrollments pe
                                           WHERE pe.user_id = u.user_id AND pe.course_id = p.prereq_course_id
                                             AND pe.status = 'COMPLETED'));
    l_rows := SQL%ROWCOUNT;

    IF l_rows > 0 THEN
      INSERT INTO lms_notification_queue (user_id, template_code, payload)
      SELECT e.user_id, 'MANDATORY_ASSIGNED',
             JSON_OBJECT('course' VALUE l_c.title_en, 'due' VALUE TO_CHAR(l_a.due_date, 'YYYY-MM-DD'))
        FROM lms_enrollments e
       WHERE e.course_id = l_a.course_id AND e.enrollment_type = 'MANDATORY'
         AND e.enrolled_at >= l_start AND e.due_date = l_a.due_date;
      lms_audit_pkg.log_event('ASSIGNMENT_EXPAND', 'ASSIGNMENT', p_assignment_id, 'SUCCESS',
                              lms_util_pkg.js('enrolled', l_rows));
    END IF;
  END expand_assignment;

  FUNCTION create_assignment(p_course_id IN NUMBER, p_target_type IN VARCHAR2, p_target_id IN NUMBER,
                             p_due_date IN DATE) RETURN NUMBER IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_id    NUMBER;
  BEGIN
    lms_security_pkg.require_permission('ENROLL_ASSIGN');
    IF p_due_date IS NULL OR p_due_date < TRUNC(SYSDATE) THEN
      RAISE_APPLICATION_ERROR(-20400, 'Due date must be today or later');
    END IF;
    IF p_target_type = 'USER' THEN
      IF NOT lms_security_pkg.can_manage_user('ENROLL_ASSIGN', p_target_id) THEN
        RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
      END IF;
    ELSIF p_target_type IN ('DEPARTMENT','POSITION') THEN
      IF lms_security_pkg.permission_scope('ENROLL_ASSIGN') <> 'ALL' THEN
        RAISE_APPLICATION_ERROR(-20403, 'Group assignments need administrator scope');
      END IF;
    ELSE
      RAISE_APPLICATION_ERROR(-20400, 'Invalid target type');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    INSERT INTO lms_learning_assignments (course_id, target_type, target_id, due_date, created_by)
    VALUES (p_course_id, p_target_type, p_target_id, p_due_date, l_actor)
    RETURNING assignment_id INTO l_id;
    expand_assignment(l_id);
    lms_audit_pkg.log_event('ASSIGNMENT_CREATE', 'ASSIGNMENT', l_id);
    RETURN l_id;
  END create_assignment;

  PROCEDURE close_assignment(p_assignment_id IN NUMBER) IS
  BEGIN
    lms_security_pkg.require_permission('ENROLL_ASSIGN');
    IF lms_security_pkg.permission_scope('ENROLL_ASSIGN') <> 'ALL' THEN RAISE_APPLICATION_ERROR(-20403, 'Not authorized'); END IF;
    UPDATE lms_learning_assignments SET status = 'CLOSED' WHERE assignment_id = p_assignment_id AND status = 'ACTIVE';
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Assignment not found or already closed'); END IF;
    lms_audit_pkg.log_event('ASSIGNMENT_CLOSE', 'ASSIGNMENT', p_assignment_id);
  END close_assignment;

  PROCEDURE sync_assignments IS
  BEGIN
    FOR r IN (SELECT assignment_id FROM lms_learning_assignments
               WHERE status = 'ACTIVE' AND due_date >= TRUNC(SYSDATE)) LOOP
      expand_assignment(r.assignment_id);
    END LOOP;
  END sync_assignments;
END lms_enrollment_pkg;
/

-- ------------------------------------------------------------- PROGRESS -------
CREATE OR REPLACE PACKAGE BODY lms_progress_pkg AS

  PROCEDURE lesson_counts(p_enrollment_id IN NUMBER, p_course_id IN NUMBER,
                          p_total OUT NUMBER, p_done OUT NUMBER) IS
  BEGIN
    SELECT COUNT(*), NVL(SUM(CASE WHEN lp.status = 'COMPLETED' THEN 1 ELSE 0 END), 0)
      INTO p_total, p_done
      FROM lms_lessons l
      JOIN lms_modules m ON m.module_id = l.module_id AND m.course_id = p_course_id
      LEFT JOIN lms_lesson_progress lp ON lp.lesson_id = l.lesson_id AND lp.enrollment_id = p_enrollment_id
     WHERE l.required_flag = 'Y';
  END lesson_counts;

  -- BR-05: completed required lessons / total required lessons
  FUNCTION calc_progress(p_enrollment_id IN NUMBER, p_course_id IN NUMBER) RETURN NUMBER IS
    l_total NUMBER; l_done NUMBER;
  BEGIN
    lesson_counts(p_enrollment_id, p_course_id, l_total, l_done);
    RETURN CASE WHEN l_total = 0 THEN 0 ELSE ROUND(100 * l_done / l_total, 2) END;
  END calc_progress;

  FUNCTION quizzes_ok(p_user_id IN NUMBER, p_course_id IN NUMBER) RETURN BOOLEAN IS
    l_missing NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_missing FROM lms_quizzes z
     WHERE z.course_id = p_course_id AND z.required_flag = 'Y' AND z.active_flag = 'Y'
       AND NOT EXISTS (SELECT 1 FROM lms_quiz_attempts a
                        WHERE a.quiz_id = z.quiz_id AND a.user_id = p_user_id
                          AND a.status = 'GRADED' AND a.passed_flag = 'Y');
    RETURN l_missing = 0;
  END quizzes_ok;

  FUNCTION attendance_ok(p_enrollment_id IN NUMBER) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
      FROM lms_session_enrollments se
      JOIN lms_training_sessions s ON s.session_id = se.session_id AND s.status <> 'CANCELLED'
     WHERE se.enrollment_id = p_enrollment_id AND se.status = 'REGISTERED'
       AND 100 * (SELECT COUNT(*) FROM lms_attendance a
                   WHERE a.session_enrollment_id = se.session_enrollment_id AND a.status IN ('PRESENT','LATE'))
           / (TRUNC(CAST(s.end_ts AS DATE)) - TRUNC(CAST(s.start_ts AS DATE)) + 1) >= s.min_attendance_pct;
    RETURN l_n > 0;
  END attendance_ok;

  -- Caller holds the enrolment row lock. Evaluates BR-06 and completes exactly once.
  PROCEDURE check_completion(p_enrollment_id IN NUMBER) IS
    l_e     lms_enrollments%ROWTYPE;
    l_c     lms_courses%ROWTYPE;
    l_total NUMBER; l_done NUMBER;
    l_les   BOOLEAN; l_ok BOOLEAN;
  BEGIN
    SELECT * INTO l_e FROM lms_enrollments WHERE enrollment_id = p_enrollment_id;
    IF l_e.status NOT IN ('ENROLLED','IN_PROGRESS') THEN RETURN; END IF;
    SELECT * INTO l_c FROM lms_courses WHERE course_id = l_e.course_id;

    lesson_counts(p_enrollment_id, l_e.course_id, l_total, l_done);
    l_les := (l_total = 0 OR l_done = l_total);
    l_ok := CASE l_c.completion_rule
              WHEN 'LESSONS'             THEN l_les
              WHEN 'LESSONS_ASSESSMENT'  THEN l_les AND quizzes_ok(l_e.user_id, l_e.course_id)
              WHEN 'ATTENDANCE'          THEN attendance_ok(p_enrollment_id)
              WHEN 'LESSONS_ATTENDANCE'  THEN l_les AND attendance_ok(p_enrollment_id)
              WHEN 'INSTRUCTOR_APPROVAL' THEN l_les AND l_e.instructor_approved_flag = 'Y'
              ELSE FALSE END;
    IF l_ok AND l_c.pass_score_required = 'Y' AND NOT quizzes_ok(l_e.user_id, l_e.course_id) THEN
      l_ok := FALSE;
    END IF;
    IF NOT l_ok THEN RETURN; END IF;

    UPDATE lms_enrollments
       SET status = 'COMPLETED', completed_at = SYSTIMESTAMP, progress_pct = 100,
           started_at = NVL(started_at, SYSTIMESTAMP), last_activity_at = SYSTIMESTAMP,
           row_version = row_version + 1
     WHERE enrollment_id = p_enrollment_id;
    lms_audit_pkg.log_event('COURSE_COMPLETE', 'ENROLLMENT', p_enrollment_id);
    lms_notification_pkg.enqueue(l_e.user_id, 'COURSE_COMPLETE', lms_util_pkg.js('course', l_c.title_en));
    -- skills credit: Employee -> Course -> Skill (levels only ever go up from learning)
    MERGE INTO lms_user_skills t
    USING (SELECT l_e.user_id AS user_id, cs.skill_id, cs.level_gained
             FROM lms_course_skills cs WHERE cs.course_id = l_e.course_id) s
       ON (t.user_id = s.user_id AND t.skill_id = s.skill_id)
     WHEN MATCHED THEN UPDATE SET t.current_level = GREATEST(t.current_level, s.level_gained), t.assessed_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (user_id, skill_id, current_level) VALUES (s.user_id, s.skill_id, s.level_gained);
    IF l_c.certificate_eligible = 'Y' THEN
      lms_certification_pkg.issue_for_enrollment(p_enrollment_id);
    END IF;
    lms_learning_path_pkg.on_course_completed(l_e.user_id, l_e.course_id);
  END check_completion;

  PROCEDURE record_event(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER, p_event_type IN VARCHAR2,
                         p_event_uuid IN VARCHAR2, p_position IN NUMBER DEFAULT 0,
                         p_seconds IN NUMBER DEFAULT 0,
                         p_progress_pct OUT NUMBER, p_status OUT VARCHAR2) IS
    l_user  NUMBER := lms_security_pkg.current_user_id;
    l_enr   lms_enrollments%ROWTYPE;
    l_les   lms_lessons%ROWTYPE;
    l_delta NUMBER := LEAST(GREATEST(NVL(p_seconds, 0), 0), lms_util_pkg.get_number('PROGRESS_MAX_DELTA_SEC', 120));
    l_pre   VARCHAR2(12);
  BEGIN
    lms_rate_limit_pkg.enforce_limit('PROGRESS_UPDATE', l_user);
    IF p_event_type NOT IN ('START','HEARTBEAT','COMPLETE') OR p_event_uuid IS NULL OR LENGTH(p_event_uuid) > 36 THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid progress event');
    END IF;

    BEGIN
      SELECT * INTO l_enr FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Enrolment not found'); END;
    IF l_enr.user_id <> l_user THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', p_enrollment_id, 'DENIED');
      lms_audit_pkg.log_security('IDOR_ATTEMPT', l_user, NULL, 'PROGRESS_UPDATE', 'HIGH', 'enrollment ' || p_enrollment_id);
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_enr.status NOT IN ('ENROLLED','IN_PROGRESS') THEN
      RAISE_APPLICATION_ERROR(-20409, 'Enrolment is not active (' || l_enr.status || ')');
    END IF;

    BEGIN
      SELECT l.* INTO l_les FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
       WHERE l.lesson_id = p_lesson_id AND m.course_id = l_enr.course_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not part of this course'); END;
    IF l_les.available_from IS NOT NULL AND TRUNC(SYSDATE) < l_les.available_from THEN
      RAISE_APPLICATION_ERROR(-20409, 'Lesson is not available yet');
    END IF;
    IF l_les.prereq_lesson_id IS NOT NULL THEN
      BEGIN
        SELECT status INTO l_pre FROM lms_lesson_progress
         WHERE enrollment_id = p_enrollment_id AND lesson_id = l_les.prereq_lesson_id;
      EXCEPTION WHEN NO_DATA_FOUND THEN l_pre := NULL; END;
      IF NVL(l_pre, 'X') <> 'COMPLETED' THEN
        RAISE_APPLICATION_ERROR(-20409, 'Complete the previous lesson first');
      END IF;
    END IF;
    IF p_event_type = 'COMPLETE' AND l_les.lesson_type IN ('ASSESSMENT','LIVE_SESSION') THEN
      RAISE_APPLICATION_ERROR(-20409, 'This lesson is completed by passing the quiz / attending the session');
    END IF;

    -- Deduplicate retried events: UK on event_uuid
    BEGIN
      INSERT INTO lms_learning_activity (enrollment_id, lesson_id, event_type, event_uuid)
      VALUES (p_enrollment_id, p_lesson_id, p_event_type, p_event_uuid);
    EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
      p_progress_pct := l_enr.progress_pct; p_status := l_enr.status;
      RETURN;
    END;

    MERGE INTO lms_lesson_progress t
    USING (SELECT p_enrollment_id enrollment_id, p_lesson_id lesson_id FROM dual) s
       ON (t.enrollment_id = s.enrollment_id AND t.lesson_id = s.lesson_id)
     WHEN MATCHED THEN UPDATE SET
          t.time_spent_sec  = t.time_spent_sec + l_delta,
          t.resume_position = CASE WHEN t.status = 'COMPLETED' THEN t.resume_position ELSE NVL(p_position, 0) END,
          t.last_event_uuid = p_event_uuid,
          t.status          = CASE WHEN p_event_type = 'COMPLETE' THEN 'COMPLETED' ELSE t.status END,
          t.completed_at    = CASE WHEN p_event_type = 'COMPLETE' THEN NVL(t.completed_at, SYSTIMESTAMP) ELSE t.completed_at END
     WHEN NOT MATCHED THEN INSERT (enrollment_id, lesson_id, status, resume_position, time_spent_sec,
                                   completed_at, last_event_uuid)
          VALUES (s.enrollment_id, s.lesson_id,
                  CASE WHEN p_event_type = 'COMPLETE' THEN 'COMPLETED' ELSE 'IN_PROGRESS' END,
                  NVL(p_position, 0), l_delta,
                  CASE WHEN p_event_type = 'COMPLETE' THEN SYSTIMESTAMP END, p_event_uuid);

    UPDATE lms_enrollments
       SET status = CASE WHEN status = 'ENROLLED' THEN 'IN_PROGRESS' ELSE status END,
           started_at = NVL(started_at, SYSTIMESTAMP), last_activity_at = SYSTIMESTAMP,
           time_spent_sec = time_spent_sec + l_delta,
           progress_pct = calc_progress(p_enrollment_id, l_enr.course_id),
           row_version = row_version + 1
     WHERE enrollment_id = p_enrollment_id;

    IF p_event_type = 'COMPLETE' THEN
      check_completion(p_enrollment_id);
    END IF;
    SELECT progress_pct, status INTO p_progress_pct, p_status FROM lms_enrollments WHERE enrollment_id = p_enrollment_id;
  END record_event;

  FUNCTION get_resume_position(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN NUMBER IS
    l_pos NUMBER;
  BEGIN
    SELECT lp.resume_position INTO l_pos
      FROM lms_lesson_progress lp JOIN lms_enrollments e ON e.enrollment_id = lp.enrollment_id
     WHERE lp.enrollment_id = p_enrollment_id AND lp.lesson_id = p_lesson_id
       AND e.user_id = lms_security_pkg.current_user_id;
    RETURN l_pos;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 0;
  END get_resume_position;

  PROCEDURE approve_completion(p_enrollment_id IN NUMBER) IS
    l_e lms_enrollments%ROWTYPE;
  BEGIN
    lms_security_pkg.require_permission('GRADE');
    BEGIN SELECT * INTO l_e FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Enrolment not found'); END;
    IF NOT lms_course_pkg.can_manage_course(l_e.course_id, 'GRADE') THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', p_enrollment_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    UPDATE lms_enrollments SET instructor_approved_flag = 'Y', row_version = row_version + 1
     WHERE enrollment_id = p_enrollment_id;
    lms_audit_pkg.log_event('COMPLETION_APPROVED', 'ENROLLMENT', p_enrollment_id);
    check_completion(p_enrollment_id);
  END approve_completion;

  PROCEDURE complete_lesson_system(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) IS
    l_course NUMBER;
  BEGIN
    SELECT course_id INTO l_course FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    MERGE INTO lms_lesson_progress t
    USING (SELECT p_enrollment_id enrollment_id, p_lesson_id lesson_id FROM dual) s
       ON (t.enrollment_id = s.enrollment_id AND t.lesson_id = s.lesson_id)
     WHEN MATCHED THEN UPDATE SET t.status = 'COMPLETED', t.completed_at = NVL(t.completed_at, SYSTIMESTAMP)
     WHEN NOT MATCHED THEN INSERT (enrollment_id, lesson_id, status, completed_at)
          VALUES (s.enrollment_id, s.lesson_id, 'COMPLETED', SYSTIMESTAMP);
    UPDATE lms_enrollments
       SET progress_pct = calc_progress(p_enrollment_id, l_course), last_activity_at = SYSTIMESTAMP,
           status = CASE WHEN status = 'ENROLLED' THEN 'IN_PROGRESS' ELSE status END,
           started_at = NVL(started_at, SYSTIMESTAMP), row_version = row_version + 1
     WHERE enrollment_id = p_enrollment_id;
    check_completion(p_enrollment_id);
  END complete_lesson_system;

  PROCEDURE evaluate_completion(p_enrollment_id IN NUMBER) IS
    l_dummy NUMBER;
  BEGIN
    SELECT enrollment_id INTO l_dummy FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    check_completion(p_enrollment_id);
  END evaluate_completion;
END lms_progress_pkg;
/

-- ----------------------------------------------------------- ASSESSMENT -------
CREATE OR REPLACE PACKAGE BODY lms_assessment_pkg AS

  c_err_attempts CONSTANT NUMBER := -20416;
  c_err_time     CONSTANT NUMBER := -20417;

  FUNCTION create_quiz(p_course_id IN NUMBER, p_title_en IN VARCHAR2, p_pass_score IN NUMBER DEFAULT 70,
                       p_time_limit_min IN NUMBER DEFAULT NULL, p_max_attempts IN NUMBER DEFAULT 3,
                       p_lesson_id IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    lms_security_pkg.require_permission('QUIZ_AUTHOR');
    IF NOT lms_course_pkg.can_manage_course(p_course_id, 'QUIZ_AUTHOR') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    INSERT INTO lms_quizzes (course_id, lesson_id, title_en, pass_score, time_limit_min, max_attempts)
    VALUES (p_course_id, p_lesson_id, p_title_en, p_pass_score, p_time_limit_min, p_max_attempts)
    RETURNING quiz_id INTO l_id;
    lms_audit_pkg.log_event('QUIZ_CREATE', 'QUIZ', l_id);
    RETURN l_id;
  END create_quiz;

  PROCEDURE link_question(p_quiz_id IN NUMBER, p_question_id IN NUMBER, p_sort_order IN NUMBER DEFAULT 0) IS
    l_course NUMBER;
  BEGIN
    SELECT course_id INTO l_course FROM lms_quizzes WHERE quiz_id = p_quiz_id;
    IF NOT lms_course_pkg.can_manage_course(l_course, 'QUIZ_AUTHOR') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    INSERT INTO lms_quiz_questions (quiz_id, question_id, sort_order) VALUES (p_quiz_id, p_question_id, p_sort_order);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;
  END link_question;

  -- ---- authoring helpers -----------------------------------------------------------------
  PROCEDURE assert_bank(p_bank_id IN NUMBER) IS
    l_owner NUMBER;
  BEGIN
    lms_security_pkg.require_permission('QUIZ_AUTHOR');
    BEGIN SELECT owner_user_id INTO l_owner FROM lms_question_banks WHERE bank_id = p_bank_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Question bank not found'); END;
    IF l_owner <> lms_security_pkg.current_user_id AND lms_security_pkg.permission_scope('QUIZ_AUTHOR') <> 'ALL' THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'QUESTION_BANK', p_bank_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END assert_bank;

  FUNCTION question_bank(p_question_id IN NUMBER) RETURN NUMBER IS
    l_bank NUMBER;
  BEGIN
    SELECT bank_id INTO l_bank FROM lms_questions WHERE question_id = p_question_id;
    RETURN l_bank;
  EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Question not found');
  END question_bank;

  PROCEDURE assert_mutable(p_question_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_quiz_responses WHERE question_id = p_question_id AND ROWNUM = 1;
    IF l_n > 0 THEN
      RAISE_APPLICATION_ERROR(-20409, 'This question was already answered by learners and cannot be changed. Clone it instead.');
    END IF;
  END assert_mutable;

  PROCEDURE assert_quiz_edit(p_quiz_id IN NUMBER) IS
    l_course NUMBER;
  BEGIN
    BEGIN SELECT course_id INTO l_course FROM lms_quizzes WHERE quiz_id = p_quiz_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Quiz not found'); END;
    IF NOT lms_course_pkg.can_manage_course(l_course, 'QUIZ_AUTHOR') THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'QUIZ', p_quiz_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END assert_quiz_edit;

  PROCEDURE update_quiz(p_quiz_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2, p_pass_score IN NUMBER,
                        p_time_limit_min IN NUMBER, p_max_attempts IN NUMBER, p_question_count IN NUMBER,
                        p_randomize_q IN VARCHAR2, p_randomize_a IN VARCHAR2, p_show_review IN VARCHAR2,
                        p_required_flag IN VARCHAR2, p_available_from IN DATE, p_available_to IN DATE,
                        p_active_flag IN VARCHAR2, p_lesson_id IN NUMBER DEFAULT NULL) IS
    l_attempts NUMBER;
  BEGIN
    assert_quiz_edit(p_quiz_id);
    -- changing the pass mark or attempt rules under learners who already attempted would make results inconsistent
    SELECT COUNT(*) INTO l_attempts FROM lms_quiz_attempts WHERE quiz_id = p_quiz_id AND ROWNUM = 1;
    IF l_attempts > 0 THEN
      DECLARE l_pass NUMBER; l_questions NUMBER; BEGIN
        SELECT pass_score, question_count INTO l_pass, l_questions FROM lms_quizzes WHERE quiz_id = p_quiz_id;
        IF l_pass <> p_pass_score OR NVL(l_questions, -1) <> NVL(p_question_count, -1) THEN
          RAISE_APPLICATION_ERROR(-20409, 'Pass mark and question count cannot change after learners have attempted the quiz');
        END IF;
      END;
    END IF;
    UPDATE lms_quizzes
       SET title_en = p_title_en, title_ar = p_title_ar, pass_score = p_pass_score, time_limit_min = p_time_limit_min,
           max_attempts = p_max_attempts, question_count = p_question_count, randomize_q = p_randomize_q,
           randomize_a = p_randomize_a, show_review = p_show_review, required_flag = p_required_flag,
           available_from = p_available_from, available_to = p_available_to, active_flag = p_active_flag, lesson_id = p_lesson_id
     WHERE quiz_id = p_quiz_id;
    lms_audit_pkg.log_event('QUIZ_UPDATE', 'QUIZ', p_quiz_id);
  END update_quiz;

  PROCEDURE unlink_question(p_quiz_id IN NUMBER, p_question_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    assert_quiz_edit(p_quiz_id);
    SELECT COUNT(*) INTO l_n FROM lms_quiz_attempts WHERE quiz_id = p_quiz_id AND ROWNUM = 1;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Questions cannot be removed after learners have attempted the quiz'); END IF;
    DELETE FROM lms_quiz_questions WHERE quiz_id = p_quiz_id AND question_id = p_question_id;
  END unlink_question;

  FUNCTION create_bank(p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    lms_security_pkg.require_permission('QUIZ_AUTHOR');
    IF p_name_en IS NULL OR LENGTH(TRIM(p_name_en)) = 0 THEN RAISE_APPLICATION_ERROR(-20400, 'A bank name is required'); END IF;
    INSERT INTO lms_question_banks (name_en, name_ar, owner_user_id)
    VALUES (p_name_en, p_name_ar, lms_security_pkg.current_user_id) RETURNING bank_id INTO l_id;
    RETURN l_id;
  END create_bank;

  FUNCTION save_question(p_question_id IN NUMBER, p_bank_id IN NUMBER, p_question_type IN VARCHAR2,
                         p_text_en IN VARCHAR2, p_text_ar IN VARCHAR2, p_points IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER := p_question_id;
  BEGIN
    IF p_question_type NOT IN ('MCQ','MULTI','TF','MATCH','SHORT','ESSAY') OR p_points IS NULL OR p_points <= 0
       OR p_text_en IS NULL OR LENGTH(TRIM(p_text_en)) = 0 OR p_active_flag NOT IN ('Y','N') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid question');
    END IF;
    IF l_id IS NULL THEN
      assert_bank(p_bank_id);
      INSERT INTO lms_questions (bank_id, question_type, text_en, text_ar, points, active_flag)
      VALUES (p_bank_id, p_question_type, p_text_en, p_text_ar, p_points, p_active_flag) RETURNING question_id INTO l_id;
    ELSE
      assert_bank(question_bank(l_id));
      assert_mutable(l_id);
      UPDATE lms_questions SET question_type = p_question_type, text_en = p_text_en, text_ar = p_text_ar,
             points = p_points, active_flag = p_active_flag WHERE question_id = l_id;
    END IF;
    lms_audit_pkg.log_event('QUESTION_SAVE', 'QUESTION', l_id);
    RETURN l_id;
  END save_question;

  FUNCTION save_option(p_option_id IN NUMBER, p_question_id IN NUMBER, p_text_en IN VARCHAR2, p_text_ar IN VARCHAR2,
                       p_is_correct IN VARCHAR2, p_match_key IN VARCHAR2, p_sort_order IN NUMBER DEFAULT 0) RETURN NUMBER IS
    l_id NUMBER := p_option_id;
  BEGIN
    assert_bank(question_bank(p_question_id));
    assert_mutable(p_question_id);
    IF p_text_en IS NULL OR LENGTH(TRIM(p_text_en)) = 0 OR p_is_correct NOT IN ('Y','N') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid option');
    END IF;
    IF l_id IS NULL THEN
      INSERT INTO lms_question_options (question_id, option_text_en, option_text_ar, is_correct, match_key, sort_order)
      VALUES (p_question_id, p_text_en, p_text_ar, p_is_correct, p_match_key, NVL(p_sort_order, 0)) RETURNING option_id INTO l_id;
    ELSE
      UPDATE lms_question_options SET option_text_en = p_text_en, option_text_ar = p_text_ar, is_correct = p_is_correct,
             match_key = p_match_key, sort_order = NVL(p_sort_order, 0)
       WHERE option_id = l_id AND question_id = p_question_id;
      IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Option not found'); END IF;
    END IF;
    RETURN l_id;
  END save_option;

  PROCEDURE remove_option(p_option_id IN NUMBER) IS
    l_q NUMBER;
  BEGIN
    BEGIN SELECT question_id INTO l_q FROM lms_question_options WHERE option_id = p_option_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Option not found'); END;
    assert_bank(question_bank(l_q));
    assert_mutable(l_q);
    DELETE FROM lms_question_options WHERE option_id = p_option_id;
  END remove_option;

  PROCEDURE remove_question(p_question_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    assert_bank(question_bank(p_question_id));
    assert_mutable(p_question_id);
    SELECT COUNT(*) INTO l_n FROM lms_quiz_questions WHERE question_id = p_question_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'The question is used by a quiz. Unlink it first, or deactivate it.'); END IF;
    DELETE FROM lms_question_options WHERE question_id = p_question_id;
    DELETE FROM lms_questions WHERE question_id = p_question_id;
    lms_audit_pkg.log_event('QUESTION_REMOVE', 'QUESTION', p_question_id);
  END remove_question;

  FUNCTION clone_question(p_question_id IN NUMBER) RETURN NUMBER IS
    l_new NUMBER;
  BEGIN
    assert_bank(question_bank(p_question_id));
    INSERT INTO lms_questions (bank_id, question_type, text_en, text_ar, points, active_flag)
    SELECT bank_id, question_type, text_en, text_ar, points, 'Y' FROM lms_questions WHERE question_id = p_question_id
    RETURNING question_id INTO l_new;
    INSERT INTO lms_question_options (question_id, option_text_en, option_text_ar, is_correct, match_key, sort_order)
    SELECT l_new, option_text_en, option_text_ar, is_correct, match_key, sort_order
      FROM lms_question_options WHERE question_id = p_question_id;
    lms_audit_pkg.log_event('QUESTION_CLONE', 'QUESTION', l_new, 'SUCCESS', lms_util_pkg.js('from', p_question_id));
    RETURN l_new;
  END clone_question;

  FUNCTION validate_quiz(p_quiz_id IN NUMBER) RETURN VARCHAR2 IS
  BEGIN
    FOR q IN (SELECT z.title_en quiz_title, qs.question_id, qs.question_type, qs.text_en,
                     (SELECT COUNT(*) FROM lms_question_options o WHERE o.question_id = qs.question_id) opts,
                     (SELECT COUNT(*) FROM lms_question_options o WHERE o.question_id = qs.question_id AND o.is_correct = 'Y') correct,
                     (SELECT COUNT(*) FROM lms_question_options o WHERE o.question_id = qs.question_id AND o.match_key IS NOT NULL) pairs
                FROM lms_quizzes z
                JOIN lms_quiz_questions qq ON qq.quiz_id = z.quiz_id
                JOIN lms_questions qs ON qs.question_id = qq.question_id AND qs.active_flag = 'Y'
               WHERE z.quiz_id = p_quiz_id ORDER BY qq.sort_order, qs.question_id) LOOP
      IF q.question_type IN ('MCQ','TF') AND (q.opts < 2 OR q.correct <> 1) THEN
        RETURN 'Question "' || SUBSTR(q.text_en, 1, 60) || '" needs at least 2 options and exactly 1 correct';
      ELSIF q.question_type = 'MULTI' AND (q.opts < 2 OR q.correct < 1) THEN
        RETURN 'Question "' || SUBSTR(q.text_en, 1, 60) || '" needs at least 2 options and 1 correct';
      ELSIF q.question_type = 'MATCH' AND q.pairs < 2 THEN
        RETURN 'Question "' || SUBSTR(q.text_en, 1, 60) || '" needs at least 2 pairs';
      ELSIF q.question_type = 'SHORT' AND q.correct < 1 THEN
        RETURN 'Question "' || SUBSTR(q.text_en, 1, 60) || '" needs at least 1 accepted answer';
      END IF;
    END LOOP;
    RETURN NULL;
  END validate_quiz;

  -- Scores one response. NULL = needs manual grading.
  FUNCTION score_response(p_question_id IN NUMBER, p_type IN VARCHAR2, p_answer IN VARCHAR2,
                          p_points IN NUMBER) RETURN NUMBER IS
    l_ok NUMBER := 0;
  BEGIN
    IF p_type = 'ESSAY' THEN RETURN NULL; END IF;
    IF p_answer IS NULL THEN RETURN 0; END IF;

    IF p_type IN ('MCQ','MULTI','TF') THEN
      SELECT CASE WHEN EXISTS (SELECT 1 FROM lms_question_options WHERE question_id = p_question_id AND is_correct = 'Y')
                   AND NOT EXISTS (SELECT option_id FROM lms_question_options
                                    WHERE question_id = p_question_id AND is_correct = 'Y'
                                   MINUS
                                   SELECT jt.id FROM JSON_TABLE(p_answer, '$.selected[*]' COLUMNS (id NUMBER PATH '$')) jt)
                   AND NOT EXISTS (SELECT jt.id FROM JSON_TABLE(p_answer, '$.selected[*]' COLUMNS (id NUMBER PATH '$')) jt
                                   MINUS
                                   SELECT option_id FROM lms_question_options
                                    WHERE question_id = p_question_id AND is_correct = 'Y')
                  THEN 1 ELSE 0 END
        INTO l_ok FROM dual;
    ELSIF p_type = 'MATCH' THEN
      SELECT CASE WHEN EXISTS (SELECT 1 FROM lms_question_options WHERE question_id = p_question_id AND match_key IS NOT NULL)
                   AND NOT EXISTS (
                         SELECT 1 FROM lms_question_options o
                          WHERE o.question_id = p_question_id AND o.match_key IS NOT NULL
                            AND NOT EXISTS (
                                  SELECT 1 FROM JSON_TABLE(p_answer, '$.pairs[*]'
                                           COLUMNS (opt NUMBER PATH '$.option', choice VARCHAR2(500) PATH '$.choice')) jt
                                   WHERE jt.opt = o.option_id AND UPPER(TRIM(jt.choice)) = UPPER(TRIM(o.match_key))))
                  THEN 1 ELSE 0 END
        INTO l_ok FROM dual;
    ELSIF p_type = 'SHORT' THEN
      SELECT COUNT(*) INTO l_ok FROM lms_question_options o
       WHERE o.question_id = p_question_id AND o.is_correct = 'Y'
         AND TRIM(JSON_VALUE(p_answer, '$.text')) IS NOT NULL
         AND (UPPER(TRIM(o.option_text_en)) = UPPER(TRIM(JSON_VALUE(p_answer, '$.text')))
              OR UPPER(TRIM(o.option_text_ar)) = UPPER(TRIM(JSON_VALUE(p_answer, '$.text'))));
    END IF;
    RETURN CASE WHEN l_ok > 0 THEN p_points ELSE 0 END;
  END score_response;

  -- Computes score / pass and propagates to progress. Caller holds the attempt lock.
  PROCEDURE finalize(p_attempt_id IN NUMBER) IS
    l_a       lms_quiz_attempts%ROWTYPE;
    l_z       lms_quizzes%ROWTYPE;
    l_pending NUMBER; l_total NUMBER; l_awarded NUMBER; l_score NUMBER; l_pass VARCHAR2(1);
  BEGIN
    SELECT * INTO l_a FROM lms_quiz_attempts WHERE attempt_id = p_attempt_id;
    SELECT * INTO l_z FROM lms_quizzes WHERE quiz_id = l_a.quiz_id;
    SELECT COUNT(CASE WHEN r.points_awarded IS NULL THEN 1 END), NVL(SUM(q.points), 0), NVL(SUM(r.points_awarded), 0)
      INTO l_pending, l_total, l_awarded
      FROM lms_quiz_responses r JOIN lms_questions q ON q.question_id = r.question_id
     WHERE r.attempt_id = p_attempt_id;
    IF l_pending > 0 THEN
      UPDATE lms_quiz_attempts SET status = 'PENDING_GRADING' WHERE attempt_id = p_attempt_id;
      RETURN;
    END IF;
    l_score := CASE WHEN l_total = 0 THEN 0 ELSE ROUND(100 * l_awarded / l_total, 2) END;
    l_pass  := CASE WHEN l_score >= l_z.pass_score THEN 'Y' ELSE 'N' END;
    UPDATE lms_quiz_attempts SET status = 'GRADED', score_pct = l_score, passed_flag = l_pass
     WHERE attempt_id = p_attempt_id;
    lms_audit_pkg.log_event('QUIZ_GRADED', 'ATTEMPT', p_attempt_id, 'SUCCESS',
                            lms_util_pkg.js('score', l_score, 'passed', l_pass));   -- no answers stored (BR-08)
    lms_notification_pkg.enqueue(l_a.user_id, 'ASSESSMENT_RESULT',
      lms_util_pkg.js('quiz', l_z.title_en, 'score', l_score, 'result', CASE l_pass WHEN 'Y' THEN 'Passed' ELSE 'Not passed' END));
    IF l_pass = 'Y' THEN
      IF l_z.lesson_id IS NOT NULL THEN
        lms_progress_pkg.complete_lesson_system(l_a.enrollment_id, l_z.lesson_id);
      END IF;
      lms_progress_pkg.evaluate_completion(l_a.enrollment_id);
    END IF;
  END finalize;

  -- Grades everything automatic, then finalises (or parks for manual grading).
  PROCEDURE submit_internal(p_attempt_id IN NUMBER) IS
  BEGIN
    UPDATE lms_quiz_attempts SET submitted_at = SYSTIMESTAMP WHERE attempt_id = p_attempt_id;
    FOR r IN (SELECT r.question_id, q.question_type, r.answer_json, q.points
                FROM lms_quiz_responses r JOIN lms_questions q ON q.question_id = r.question_id
               WHERE r.attempt_id = p_attempt_id) LOOP
      UPDATE lms_quiz_responses
         SET points_awarded = score_response(r.question_id, r.question_type, r.answer_json, r.points)
       WHERE attempt_id = p_attempt_id AND question_id = r.question_id;
    END LOOP;
    finalize(p_attempt_id);
  END submit_internal;

  FUNCTION start_attempt(p_quiz_id IN NUMBER) RETURN NUMBER IS
    l_user  NUMBER := lms_security_pkg.current_user_id;
    l_z     lms_quizzes%ROWTYPE;
    l_enr   NUMBER;
    l_used  NUMBER;
    l_att   NUMBER;
    l_old   lms_quiz_attempts%ROWTYPE;
    l_grace NUMBER := lms_util_pkg.get_number('QUIZ_GRACE_SECONDS', 10);
    l_n     NUMBER;
    l_have  BOOLEAN;
  BEGIN
    lms_security_pkg.require_permission('QUIZ_TAKE');
    BEGIN SELECT * INTO l_z FROM lms_quizzes WHERE quiz_id = p_quiz_id AND active_flag = 'Y';
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Quiz not found'); END;
    IF (l_z.available_from IS NOT NULL AND TRUNC(SYSDATE) < l_z.available_from)
       OR (l_z.available_to IS NOT NULL AND TRUNC(SYSDATE) > l_z.available_to) THEN
      RAISE_APPLICATION_ERROR(-20409, 'Quiz is not available');
    END IF;

    -- The enrolment row lock serialises attempt creation for this learner and course.
    BEGIN
      SELECT enrollment_id INTO l_enr FROM lms_enrollments
       WHERE user_id = l_user AND course_id = l_z.course_id AND status IN ('ENROLLED','IN_PROGRESS') FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'QUIZ', p_quiz_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'You are not enrolled in this course');
    END;

    BEGIN
      SELECT * INTO l_old FROM lms_quiz_attempts
       WHERE quiz_id = p_quiz_id AND user_id = l_user AND status = 'IN_PROGRESS';
      l_have := TRUE;
    EXCEPTION WHEN NO_DATA_FOUND THEN l_have := FALSE; END;
    IF l_have THEN
      IF l_old.deadline_at IS NULL OR SYSTIMESTAMP <= l_old.deadline_at + NUMTODSINTERVAL(l_grace, 'SECOND') THEN
        RETURN l_old.attempt_id;                       -- resume
      END IF;
      submit_internal(l_old.attempt_id);               -- expired: grade what was saved, then fall through
    END IF;

    SELECT COUNT(*) INTO l_used FROM lms_quiz_attempts WHERE quiz_id = p_quiz_id AND user_id = l_user;
    IF l_used >= l_z.max_attempts THEN RAISE_APPLICATION_ERROR(c_err_attempts, 'Maximum attempts reached'); END IF;

    INSERT INTO lms_quiz_attempts (quiz_id, user_id, enrollment_id, attempt_no, deadline_at)
    VALUES (p_quiz_id, l_user, l_enr, l_used + 1,
            CASE WHEN l_z.time_limit_min IS NOT NULL THEN SYSTIMESTAMP + NUMTODSINTERVAL(l_z.time_limit_min, 'MINUTE') END)
    RETURNING attempt_id INTO l_att;

    INSERT INTO lms_quiz_responses (attempt_id, question_id, sort_order)
    SELECT l_att, x.question_id,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN l_z.randomize_q = 'Y' OR l_z.question_count IS NOT NULL THEN x.rnd END, x.sort_order)
      FROM (SELECT qq.question_id, qq.sort_order, DBMS_RANDOM.VALUE rnd,
                   ROW_NUMBER() OVER (ORDER BY DBMS_RANDOM.VALUE) rn
              FROM lms_quiz_questions qq
              JOIN lms_questions q ON q.question_id = qq.question_id AND q.active_flag = 'Y'
             WHERE qq.quiz_id = p_quiz_id) x
     WHERE l_z.question_count IS NULL OR x.rn <= l_z.question_count;
    l_n := SQL%ROWCOUNT;
    IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Quiz has no questions'); END IF;
    lms_audit_pkg.log_event('QUIZ_START', 'ATTEMPT', l_att);
    RETURN l_att;
  END start_attempt;

  PROCEDURE save_answer(p_attempt_id IN NUMBER, p_question_id IN NUMBER, p_answer_json IN VARCHAR2) IS
    l_user  NUMBER := lms_security_pkg.current_user_id;
    l_a     lms_quiz_attempts%ROWTYPE;
  BEGIN
    IF p_answer_json IS NOT NULL AND LENGTH(p_answer_json) > 4000 THEN
      RAISE_APPLICATION_ERROR(-20400, 'Answer too long');
    END IF;
    BEGIN SELECT * INTO l_a FROM lms_quiz_attempts WHERE attempt_id = p_attempt_id AND user_id = l_user;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ATTEMPT', p_attempt_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END;
    IF l_a.status <> 'IN_PROGRESS' THEN RAISE_APPLICATION_ERROR(-20409, 'Attempt already submitted'); END IF;
    IF l_a.deadline_at IS NOT NULL AND SYSTIMESTAMP > l_a.deadline_at THEN
      RAISE_APPLICATION_ERROR(c_err_time, 'Time limit exceeded');
    END IF;
    UPDATE lms_quiz_responses SET answer_json = p_answer_json
     WHERE attempt_id = p_attempt_id AND question_id = p_question_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Question is not part of this attempt'); END IF;
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -2290 THEN RAISE_APPLICATION_ERROR(-20400, 'Answer must be valid JSON'); END IF;
    RAISE;
  END save_answer;

  PROCEDURE submit_attempt(p_attempt_id IN NUMBER, p_status OUT VARCHAR2, p_score_pct OUT NUMBER,
                           p_passed OUT VARCHAR2) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_a    lms_quiz_attempts%ROWTYPE;
  BEGIN
    lms_rate_limit_pkg.enforce_limit('QUIZ_SUBMIT', l_user);
    BEGIN SELECT * INTO l_a FROM lms_quiz_attempts WHERE attempt_id = p_attempt_id AND user_id = l_user FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ATTEMPT', p_attempt_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END;
    IF l_a.status = 'IN_PROGRESS' THEN
      submit_internal(p_attempt_id);                   -- idempotent: later calls just return the result
      SELECT * INTO l_a FROM lms_quiz_attempts WHERE attempt_id = p_attempt_id;
    END IF;
    p_status := l_a.status; p_score_pct := l_a.score_pct; p_passed := l_a.passed_flag;
  END submit_attempt;

  PROCEDURE grade_response(p_attempt_id IN NUMBER, p_question_id IN NUMBER, p_points IN NUMBER,
                           p_feedback IN VARCHAR2 DEFAULT NULL) IS
    l_actor  NUMBER := lms_security_pkg.current_user_id;
    l_course NUMBER; l_status VARCHAR2(16); l_max NUMBER;
  BEGIN
    lms_security_pkg.require_permission('GRADE');
    BEGIN
      SELECT z.course_id, a.status INTO l_course, l_status
        FROM lms_quiz_attempts a JOIN lms_quizzes z ON z.quiz_id = a.quiz_id
       WHERE a.attempt_id = p_attempt_id FOR UPDATE OF a.status;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Attempt not found'); END;
    IF NOT lms_course_pkg.can_manage_course(l_course, 'GRADE') THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ATTEMPT', p_attempt_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_status <> 'PENDING_GRADING' THEN RAISE_APPLICATION_ERROR(-20409, 'Attempt is not awaiting grading'); END IF;
    SELECT q.points INTO l_max FROM lms_questions q WHERE q.question_id = p_question_id;
    IF p_points IS NULL OR p_points < 0 OR p_points > l_max THEN
      RAISE_APPLICATION_ERROR(-20400, 'Points must be between 0 and ' || l_max);
    END IF;
    UPDATE lms_quiz_responses SET points_awarded = p_points, graded_by = l_actor, feedback = SUBSTR(p_feedback, 1, 1000)
     WHERE attempt_id = p_attempt_id AND question_id = p_question_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Question is not part of this attempt'); END IF;
    finalize(p_attempt_id);                            -- no-op until the last manual item is graded
  END grade_response;
END lms_assessment_pkg;
/

-- ------------------------------------------------------- LEARNING PATH -------
CREATE OR REPLACE PACKAGE BODY lms_learning_path_pkg AS

  FUNCTION create_path(p_path_code IN VARCHAR2, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2 DEFAULT NULL,
                       p_certificate_eligible IN VARCHAR2 DEFAULT 'N',
                       p_certificate_template_id IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    INSERT INTO lms_learning_paths (path_code, title_en, title_ar, certificate_eligible, certificate_template_id, created_by)
    VALUES (UPPER(TRIM(p_path_code)), p_title_en, p_title_ar, p_certificate_eligible, p_certificate_template_id,
            lms_security_pkg.current_user_id)
    RETURNING path_id INTO l_id;
    lms_audit_pkg.log_event('PATH_CREATE', 'PATH', l_id);
    RETURN l_id;
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN RAISE_APPLICATION_ERROR(-20409, 'Path code already exists');
  END create_path;

  PROCEDURE add_course(p_path_id IN NUMBER, p_course_id IN NUMBER, p_sequence_no IN NUMBER,
                       p_required_flag IN VARCHAR2 DEFAULT 'Y') IS
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    INSERT INTO lms_path_courses (path_id, course_id, sequence_no, required_flag)
    VALUES (p_path_id, p_course_id, p_sequence_no, p_required_flag);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN RAISE_APPLICATION_ERROR(-20409, 'Course or sequence already used in this path');
  END add_course;

  PROCEDURE publish_path(p_path_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    SELECT COUNT(*) INTO l_n FROM lms_path_courses WHERE path_id = p_path_id AND required_flag = 'Y';
    IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'A path needs at least one required course'); END IF;
    UPDATE lms_learning_paths SET status = 'PUBLISHED' WHERE path_id = p_path_id AND status = 'DRAFT';
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Only DRAFT paths can be published'); END IF;
    lms_audit_pkg.log_event('PATH_PUBLISH', 'PATH', p_path_id);
  END publish_path;

  -- Caller holds the path-enrolment row lock.
  PROCEDURE recompute(p_path_enrollment_id IN NUMBER) IS
    l_pe    lms_path_enrollments%ROWTYPE;
    l_total NUMBER; l_done NUMBER; l_pct NUMBER; l_p lms_learning_paths%ROWTYPE;
  BEGIN
    SELECT * INTO l_pe FROM lms_path_enrollments WHERE path_enrollment_id = p_path_enrollment_id;
    IF l_pe.status <> 'IN_PROGRESS' THEN RETURN; END IF;
    SELECT COUNT(*), NVL(SUM(CASE WHEN EXISTS (SELECT 1 FROM lms_enrollments e
                                                WHERE e.user_id = l_pe.user_id AND e.course_id = pc.course_id
                                                  AND e.status = 'COMPLETED') THEN 1 ELSE 0 END), 0)
      INTO l_total, l_done
      FROM lms_path_courses pc WHERE pc.path_id = l_pe.path_id AND pc.required_flag = 'Y';
    l_pct := CASE WHEN l_total = 0 THEN 0 ELSE ROUND(100 * l_done / l_total, 2) END;
    IF l_total > 0 AND l_done = l_total THEN
      UPDATE lms_path_enrollments SET status = 'COMPLETED', progress_pct = 100, completed_at = SYSTIMESTAMP
       WHERE path_enrollment_id = p_path_enrollment_id;
      SELECT * INTO l_p FROM lms_learning_paths WHERE path_id = l_pe.path_id;
      lms_audit_pkg.log_event('PATH_COMPLETE', 'PATH_ENROLLMENT', p_path_enrollment_id);
      lms_notification_pkg.enqueue(l_pe.user_id, 'PATH_COMPLETE', lms_util_pkg.js('path', l_p.title_en));
      IF l_p.certificate_eligible = 'Y' THEN
        lms_certification_pkg.issue_for_path(p_path_enrollment_id);
      END IF;
    ELSE
      UPDATE lms_path_enrollments SET progress_pct = l_pct WHERE path_enrollment_id = p_path_enrollment_id;
    END IF;
  END recompute;

  FUNCTION enroll_path(p_path_id IN NUMBER) RETURN NUMBER IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_p    lms_learning_paths%ROWTYPE;
    l_id   NUMBER;
  BEGIN
    lms_security_pkg.require_permission('ENROLL_SELF');
    lms_rate_limit_pkg.enforce_limit('COURSE_ENROLL', l_user);
    BEGIN SELECT * INTO l_p FROM lms_learning_paths WHERE path_id = p_path_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Path not found'); END;
    IF l_p.status <> 'PUBLISHED' THEN RAISE_APPLICATION_ERROR(-20409, 'Path is not open for enrolment'); END IF;
    BEGIN
      SELECT path_enrollment_id INTO l_id FROM lms_path_enrollments
       WHERE path_id = p_path_id AND user_id = l_user AND status = 'IN_PROGRESS';
      RETURN l_id;                                      -- idempotent
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL; END;
    INSERT INTO lms_path_enrollments (path_id, user_id) VALUES (p_path_id, l_user)
    RETURNING path_enrollment_id INTO l_id;
    recompute(l_id);                                    -- credit courses already completed
    lms_audit_pkg.log_event('PATH_ENROLL', 'PATH_ENROLLMENT', l_id);
    RETURN l_id;
  END enroll_path;

  PROCEDURE start_next_course(p_path_enrollment_id IN NUMBER, p_course_id OUT NUMBER,
                              p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_pe   lms_path_enrollments%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_pe FROM lms_path_enrollments
           WHERE path_enrollment_id = p_path_enrollment_id AND user_id = l_user;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20403, 'Not authorized'); END;
    IF l_pe.status <> 'IN_PROGRESS' THEN RAISE_APPLICATION_ERROR(-20409, 'Path is not in progress'); END IF;
    BEGIN
      SELECT course_id INTO p_course_id FROM (
        SELECT pc.course_id FROM lms_path_courses pc
         WHERE pc.path_id = l_pe.path_id
           AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                            WHERE e.user_id = l_user AND e.course_id = pc.course_id AND e.status = 'COMPLETED')
         ORDER BY pc.sequence_no)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20409, 'No remaining courses'); END;
    lms_enrollment_pkg.enroll_self(p_course_id, p_enrollment_id, p_status);
  END start_next_course;

  PROCEDURE on_course_completed(p_user_id IN NUMBER, p_course_id IN NUMBER) IS
    CURSOR c IS
      SELECT pe.path_enrollment_id FROM lms_path_enrollments pe
       WHERE pe.user_id = p_user_id AND pe.status = 'IN_PROGRESS'
         AND EXISTS (SELECT 1 FROM lms_path_courses pc WHERE pc.path_id = pe.path_id AND pc.course_id = p_course_id)
         FOR UPDATE OF pe.progress_pct;
  BEGIN
    FOR r IN c LOOP recompute(r.path_enrollment_id); END LOOP;
  END on_course_completed;
END lms_learning_path_pkg;
/

-- ------------------------------------------------------------- SESSION -------
CREATE OR REPLACE PACKAGE BODY lms_session_pkg AS

  FUNCTION has_conflict(p_venue_id IN NUMBER, p_instructor_id IN NUMBER,
                        p_start IN TIMESTAMP WITH TIME ZONE, p_end IN TIMESTAMP WITH TIME ZONE,
                        p_exclude_session IN NUMBER) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_training_sessions s
     WHERE s.status <> 'CANCELLED' AND s.session_id <> NVL(p_exclude_session, -1)
       AND s.start_ts < p_end AND s.end_ts > p_start
       AND ((p_venue_id IS NOT NULL AND s.venue_id = p_venue_id) OR s.instructor_id = p_instructor_id);
    RETURN l_n > 0;
  END has_conflict;

  PROCEDURE notify_participants(p_session_id IN NUMBER, p_template IN VARCHAR2) IS
  BEGIN
    INSERT INTO lms_notification_queue (user_id, template_code, payload)
    SELECT se.user_id, p_template,
           JSON_OBJECT('course' VALUE c.title_en, 'start' VALUE TO_CHAR(s.start_ts, 'YYYY-MM-DD HH24:MI TZR'))
      FROM lms_session_enrollments se
      JOIN lms_training_sessions s ON s.session_id = se.session_id
      JOIN lms_courses c ON c.course_id = s.course_id
     WHERE se.session_id = p_session_id AND se.status IN ('REGISTERED','WAITLISTED');
  END notify_participants;

  PROCEDURE promote_session_waitlist(p_session_id IN NUMBER) IS
    l_s     lms_training_sessions%ROWTYPE;
    l_free  NUMBER;
    l_users DBMS_SQL.NUMBER_TABLE;
  BEGIN
    SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = p_session_id;
    SELECT l_s.seats - COUNT(*) INTO l_free FROM lms_session_enrollments
     WHERE session_id = p_session_id AND status = 'REGISTERED';
    IF l_free > 0 THEN
      UPDATE lms_session_enrollments SET status = 'REGISTERED'
       WHERE session_enrollment_id IN (
               SELECT session_enrollment_id FROM lms_session_enrollments
                WHERE session_id = p_session_id AND status = 'WAITLISTED'
                ORDER BY registered_at, session_enrollment_id FETCH FIRST l_free ROWS ONLY)
      RETURNING user_id BULK COLLECT INTO l_users;
      FOR i IN 1 .. l_users.COUNT LOOP
        lms_notification_pkg.enqueue(l_users(i), 'SESSION_REGISTERED',
          lms_util_pkg.js('start', TO_CHAR(l_s.start_ts, 'YYYY-MM-DD HH24:MI TZR')));
      END LOOP;
    END IF;
  END promote_session_waitlist;

  -- ----------------------------------------------------------------------------- venues -----
  PROCEDURE assert_venue_admin IS
  BEGIN
    lms_security_pkg.require_permission('SESSION_MANAGE');
    IF lms_security_pkg.permission_scope('SESSION_MANAGE') <> 'ALL' THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'VENUE', NULL, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END assert_venue_admin;

  FUNCTION save_venue(p_venue_id IN NUMBER, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2, p_address IN VARCHAR2,
                      p_capacity IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER := p_venue_id; l_n NUMBER;
  BEGIN
    assert_venue_admin;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    IF p_name_en IS NULL OR LENGTH(TRIM(p_name_en)) = 0 OR p_active_flag NOT IN ('Y','N')
       OR (p_capacity IS NOT NULL AND (p_capacity <= 0 OR p_capacity <> TRUNC(p_capacity))) THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid venue (name required, capacity a positive whole number)');
    END IF;
    SELECT COUNT(*) INTO l_n FROM lms_venues
     WHERE UPPER(TRIM(name_en)) = UPPER(TRIM(p_name_en)) AND active_flag = 'Y' AND venue_id <> NVL(l_id, -1);
    IF l_n > 0 AND p_active_flag = 'Y' THEN RAISE_APPLICATION_ERROR(-20409, 'An active venue with this name already exists'); END IF;

    IF l_id IS NULL THEN
      INSERT INTO lms_venues (name_en, name_ar, address, capacity, active_flag)
      VALUES (TRIM(p_name_en), p_name_ar, SUBSTR(p_address, 1, 500), p_capacity, p_active_flag) RETURNING venue_id INTO l_id;
    ELSE
      BEGIN SELECT venue_id INTO l_n FROM lms_venues WHERE venue_id = l_id FOR UPDATE;
      EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Venue not found'); END;
      IF p_active_flag = 'N' THEN
        SELECT COUNT(*) INTO l_n FROM lms_training_sessions
         WHERE venue_id = l_id AND status IN ('SCHEDULED','PUBLISHED') AND end_ts > SYSTIMESTAMP;
        IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'The venue has upcoming sessions. Reschedule or cancel them first.'); END IF;
      END IF;
      IF p_capacity IS NOT NULL THEN
        SELECT COUNT(*) INTO l_n FROM lms_training_sessions
         WHERE venue_id = l_id AND status IN ('SCHEDULED','PUBLISHED') AND end_ts > SYSTIMESTAMP AND seats > p_capacity;
        IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'An upcoming session has more seats than the new capacity'); END IF;
      END IF;
      UPDATE lms_venues SET name_en = TRIM(p_name_en), name_ar = p_name_ar, address = SUBSTR(p_address, 1, 500),
             capacity = p_capacity, active_flag = p_active_flag WHERE venue_id = l_id;
    END IF;
    lms_audit_pkg.log_event('VENUE_SAVE', 'VENUE', l_id);
    RETURN l_id;
  END save_venue;

  PROCEDURE remove_venue(p_venue_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    assert_venue_admin;
    SELECT COUNT(*) INTO l_n FROM lms_training_sessions WHERE venue_id = p_venue_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'The venue hosted sessions and cannot be deleted. Deactivate it instead.'); END IF;
    DELETE FROM lms_venues WHERE venue_id = p_venue_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Venue not found'); END IF;
    lms_audit_pkg.log_event('VENUE_REMOVE', 'VENUE', p_venue_id);
  END remove_venue;

  FUNCTION create_session(p_course_id IN NUMBER, p_venue_id IN NUMBER, p_instructor_id IN NUMBER,
                          p_start_ts IN TIMESTAMP WITH TIME ZONE, p_end_ts IN TIMESTAMP WITH TIME ZONE,
                          p_seats IN NUMBER, p_meeting_url IN VARCHAR2 DEFAULT NULL,
                          p_min_attendance_pct IN NUMBER DEFAULT 80) RETURN NUMBER IS
    l_id NUMBER; l_deliv lms_courses.delivery_method%TYPE; l_ist lms_users.status%TYPE;
  BEGIN
    lms_security_pkg.require_permission('SESSION_MANAGE');
    IF NOT lms_course_pkg.can_manage_course(p_course_id, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    BEGIN SELECT delivery_method INTO l_deliv FROM lms_courses WHERE course_id = p_course_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;
    IF l_deliv = 'SELF_PACED' THEN RAISE_APPLICATION_ERROR(-20409, 'Self-paced courses have no sessions'); END IF;
    BEGIN SELECT status INTO l_ist FROM lms_users WHERE user_id = p_instructor_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Instructor not found'); END;
    IF l_ist <> 'ACTIVE' THEN RAISE_APPLICATION_ERROR(-20409, 'Instructor is not active'); END IF;
    IF p_venue_id IS NOT NULL THEN
      DECLARE l_cap NUMBER; l_act CHAR(1); BEGIN
        BEGIN SELECT capacity, active_flag INTO l_cap, l_act FROM lms_venues WHERE venue_id = p_venue_id;
        EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Venue not found'); END;
        IF l_act <> 'Y' THEN RAISE_APPLICATION_ERROR(-20409, 'The venue is inactive'); END IF;
        IF l_cap IS NOT NULL AND p_seats > l_cap THEN
          RAISE_APPLICATION_ERROR(-20400, 'Seats (' || p_seats || ') exceed the venue capacity (' || l_cap || ')');
        END IF;
      END;
    END IF;
    IF has_conflict(p_venue_id, p_instructor_id, p_start_ts, p_end_ts, NULL) THEN
      RAISE_APPLICATION_ERROR(-20409, 'Venue or instructor is already booked in that period');
    END IF;
    INSERT INTO lms_training_sessions (course_id, venue_id, instructor_id, start_ts, end_ts, seats,
                                       meeting_url, min_attendance_pct, created_by)
    VALUES (p_course_id, p_venue_id, p_instructor_id, p_start_ts, p_end_ts, p_seats, p_meeting_url,
            p_min_attendance_pct, lms_security_pkg.current_user_id)
    RETURNING session_id INTO l_id;
    lms_audit_pkg.log_event('SESSION_CREATE', 'SESSION', l_id);
    RETURN l_id;
  END create_session;

  PROCEDURE publish_session(p_session_id IN NUMBER) IS
    l_course NUMBER;
  BEGIN
    BEGIN SELECT course_id INTO l_course FROM lms_training_sessions WHERE session_id = p_session_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Session not found'); END;
    IF NOT lms_course_pkg.can_manage_course(l_course, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    UPDATE lms_training_sessions SET status = 'PUBLISHED' WHERE session_id = p_session_id AND status = 'SCHEDULED';
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Only SCHEDULED sessions can be published'); END IF;
    lms_audit_pkg.log_event('SESSION_PUBLISH', 'SESSION', p_session_id);
  END publish_session;

  PROCEDURE register(p_session_id IN NUMBER, p_status OUT VARCHAR2) IS
    l_user  NUMBER := lms_security_pkg.current_user_id;
    l_s     lms_training_sessions%ROWTYPE;
    l_enr   NUMBER;
    l_taken NUMBER;
    l_reg   lms_session_enrollments%ROWTYPE;
  BEGIN
    lms_security_pkg.require_permission('ENROLL_SELF');
    lms_rate_limit_pkg.enforce_limit('COURSE_ENROLL', l_user);
    BEGIN SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = p_session_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Session not found'); END;
    IF l_s.status <> 'PUBLISHED' OR l_s.start_ts <= SYSTIMESTAMP THEN
      RAISE_APPLICATION_ERROR(-20409, 'Session is not open for registration');
    END IF;
    BEGIN
      SELECT enrollment_id INTO l_enr FROM lms_enrollments
       WHERE user_id = l_user AND course_id = l_s.course_id AND status IN ('ENROLLED','IN_PROGRESS');
    EXCEPTION WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20409, 'Enrol in the course before registering for a session');
    END;
    BEGIN
      SELECT * INTO l_reg FROM lms_session_enrollments WHERE session_id = p_session_id AND user_id = l_user;
      IF l_reg.status <> 'CANCELLED' THEN p_status := l_reg.status; RETURN; END IF;   -- idempotent
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL; END;   -- l_reg stays empty

    SELECT COUNT(*) INTO l_taken FROM lms_session_enrollments WHERE session_id = p_session_id AND status = 'REGISTERED';
    p_status := CASE WHEN l_taken >= l_s.seats THEN 'WAITLISTED' ELSE 'REGISTERED' END;
    IF l_reg.session_enrollment_id IS NOT NULL THEN
      UPDATE lms_session_enrollments SET status = p_status, registered_at = SYSTIMESTAMP, enrollment_id = l_enr
       WHERE session_enrollment_id = l_reg.session_enrollment_id;
    ELSE
      INSERT INTO lms_session_enrollments (session_id, user_id, enrollment_id, status)
      VALUES (p_session_id, l_user, l_enr, p_status);
    END IF;
    lms_notification_pkg.enqueue(l_user, 'SESSION_REGISTERED',
      lms_util_pkg.js('start', TO_CHAR(l_s.start_ts, 'YYYY-MM-DD HH24:MI TZR'), 'status', p_status));
    lms_audit_pkg.log_event('SESSION_REGISTER', 'SESSION', p_session_id, 'SUCCESS', lms_util_pkg.js('status', p_status));
  END register;

  PROCEDURE cancel_registration(p_session_enrollment_id IN NUMBER) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_se    lms_session_enrollments%ROWTYPE;
    l_s     lms_training_sessions%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_se FROM lms_session_enrollments WHERE session_enrollment_id = p_session_enrollment_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Registration not found'); END;
    SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = l_se.session_id FOR UPDATE;
    IF l_se.user_id <> l_actor AND NOT lms_course_pkg.can_manage_course(l_s.course_id, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    UPDATE lms_session_enrollments SET status = 'CANCELLED'
     WHERE session_enrollment_id = p_session_enrollment_id AND status <> 'CANCELLED';
    lms_audit_pkg.log_event('SESSION_UNREGISTER', 'SESSION', l_se.session_id);
    promote_session_waitlist(l_se.session_id);
  END cancel_registration;

  PROCEDURE cancel_session(p_session_id IN NUMBER, p_reason IN VARCHAR2 DEFAULT NULL) IS
    l_s lms_training_sessions%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = p_session_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Session not found'); END;
    lms_security_pkg.require_permission('SESSION_MANAGE');
    IF NOT lms_course_pkg.can_manage_course(l_s.course_id, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_s.status IN ('CANCELLED','COMPLETED') THEN RAISE_APPLICATION_ERROR(-20409, 'Session cannot be cancelled'); END IF;
    notify_participants(p_session_id, 'SESSION_CANCELLED');
    UPDATE lms_training_sessions SET status = 'CANCELLED' WHERE session_id = p_session_id;
    lms_audit_pkg.log_event('SESSION_CANCEL', 'SESSION', p_session_id, 'SUCCESS',
                            lms_util_pkg.js('reason', SUBSTR(p_reason, 1, 200)));
  END cancel_session;

  PROCEDURE reschedule(p_session_id IN NUMBER, p_start_ts IN TIMESTAMP WITH TIME ZONE,
                       p_end_ts IN TIMESTAMP WITH TIME ZONE) IS
    l_s lms_training_sessions%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = p_session_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Session not found'); END;
    lms_security_pkg.require_permission('SESSION_MANAGE');
    IF NOT lms_course_pkg.can_manage_course(l_s.course_id, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_s.status NOT IN ('SCHEDULED','PUBLISHED') OR p_end_ts <= p_start_ts THEN
      RAISE_APPLICATION_ERROR(-20409, 'Session cannot be rescheduled');
    END IF;
    IF has_conflict(l_s.venue_id, l_s.instructor_id, p_start_ts, p_end_ts, p_session_id) THEN
      RAISE_APPLICATION_ERROR(-20409, 'Venue or instructor is already booked in that period');
    END IF;
    UPDATE lms_training_sessions SET start_ts = p_start_ts, end_ts = p_end_ts WHERE session_id = p_session_id;
    notify_participants(p_session_id, 'SESSION_RESCHEDULED');
    lms_audit_pkg.log_event('SESSION_RESCHEDULE', 'SESSION', p_session_id);
  END reschedule;

  PROCEDURE record_attendance(p_session_enrollment_id IN NUMBER, p_day IN DATE, p_status IN VARCHAR2) IS
    l_se lms_session_enrollments%ROWTYPE;
    l_s  lms_training_sessions%ROWTYPE;
  BEGIN
    lms_security_pkg.require_permission('SESSION_MANAGE');
    IF p_status NOT IN ('PRESENT','ABSENT','LATE','EXCUSED') THEN RAISE_APPLICATION_ERROR(-20400, 'Invalid status'); END IF;
    BEGIN SELECT * INTO l_se FROM lms_session_enrollments WHERE session_enrollment_id = p_session_enrollment_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Registration not found'); END;
    SELECT * INTO l_s FROM lms_training_sessions WHERE session_id = l_se.session_id;
    IF NOT lms_course_pkg.can_manage_course(l_s.course_id, 'SESSION_MANAGE') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_se.status <> 'REGISTERED' THEN RAISE_APPLICATION_ERROR(-20409, 'Learner is not registered'); END IF;
    IF TRUNC(p_day) NOT BETWEEN TRUNC(CAST(l_s.start_ts AS DATE)) AND TRUNC(CAST(l_s.end_ts AS DATE)) THEN
      RAISE_APPLICATION_ERROR(-20400, 'Day is outside the session dates');
    END IF;
    MERGE INTO lms_attendance t
    USING (SELECT p_session_enrollment_id se_id, TRUNC(p_day) d FROM dual) s
       ON (t.session_enrollment_id = s.se_id AND t.session_day = s.d)
     WHEN MATCHED THEN UPDATE SET t.status = p_status, t.recorded_by = lms_security_pkg.current_user_id,
                                  t.recorded_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (session_enrollment_id, session_day, status, recorded_by)
          VALUES (s.se_id, s.d, p_status, lms_security_pkg.current_user_id);
    lms_audit_pkg.log_event('ATTENDANCE', 'SESSION_ENROLLMENT', p_session_enrollment_id);
    lms_progress_pkg.evaluate_completion(l_se.enrollment_id);
  END record_attendance;
END lms_session_pkg;
/
