-- =============================================================================
-- Packages: LMS_AUDIT_PKG, LMS_SECURITY_PKG (minimal), LMS_RATE_LIMIT_PKG,
--           LMS_ENROLLMENT_PKG (core path)           STATUS: NOT compiled/executed
-- Depends on 01_core_schema.sql. Needs: GRANT EXECUTE on SYS.DBMS_CRYPTO to the
-- schema owner (used for hashing rate-limit subjects).
-- Transaction rule: only autonomous procedures here COMMIT; callers own the txn.
-- =============================================================================

-- Compile order: both SPECS first (they are mutually dependent), then both BODIES.
-- ------------------------------------------------------------- SECURITY ----
CREATE OR REPLACE PACKAGE lms_security_pkg AS
  e_not_authenticated EXCEPTION; PRAGMA EXCEPTION_INIT(e_not_authenticated, -20401);
  e_forbidden         EXCEPTION; PRAGMA EXCEPTION_INIT(e_forbidden,         -20403);

  /* Resolves LMS_USERS.USER_ID from the authenticated APEX/DB session only. */
  FUNCTION current_user_id RETURN NUMBER;
  FUNCTION current_user_id_safe RETURN NUMBER;   -- NULL instead of raising
  FUNCTION has_permission(p_code IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL) RETURN BOOLEAN;
  PROCEDURE require_permission(p_code IN VARCHAR2);
  /* TRUE if p_target is p_actor or in p_actor's reporting subtree. */
  FUNCTION is_in_subtree(p_actor IN NUMBER, p_target IN NUMBER) RETURN BOOLEAN;
END lms_security_pkg;
/
-- ---------------------------------------------------------------- AUDIT ----
CREATE OR REPLACE PACKAGE lms_audit_pkg AS
  PROCEDURE log_event(p_operation IN VARCHAR2, p_entity IN VARCHAR2,
                      p_entity_id IN NUMBER DEFAULT NULL,
                      p_result    IN VARCHAR2 DEFAULT 'SUCCESS',
                      p_metadata  IN VARCHAR2 DEFAULT NULL);
  PROCEDURE log_security(p_event_type IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                         p_subject_key IN VARCHAR2 DEFAULT NULL,
                         p_operation IN VARCHAR2 DEFAULT NULL,
                         p_severity IN VARCHAR2 DEFAULT 'INFO',
                         p_detail IN VARCHAR2 DEFAULT NULL);
END lms_audit_pkg;
/
CREATE OR REPLACE PACKAGE BODY lms_audit_pkg AS
  -- Autonomous so that denials/failures are recorded even when the caller rolls back.
  PROCEDURE log_event(p_operation IN VARCHAR2, p_entity IN VARCHAR2,
                      p_entity_id IN NUMBER DEFAULT NULL,
                      p_result    IN VARCHAR2 DEFAULT 'SUCCESS',
                      p_metadata  IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO lms_audit_log (actor_user_id, operation, entity_name, entity_id, result, correlation_id, metadata)
    VALUES (lms_security_pkg.current_user_id_safe, p_operation, p_entity, p_entity_id, p_result,
            SYS_CONTEXT('USERENV','SID') || '-' || SYS_CONTEXT('USERENV','SESSIONID'), p_metadata);
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;  -- never let auditing break the business call; monitor via job failure log
  END log_event;

  PROCEDURE log_security(p_event_type IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                         p_subject_key IN VARCHAR2 DEFAULT NULL,
                         p_operation IN VARCHAR2 DEFAULT NULL,
                         p_severity IN VARCHAR2 DEFAULT 'INFO',
                         p_detail IN VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO lms_security_events (event_type, user_id, subject_key, operation, severity, detail)
    VALUES (p_event_type, p_user_id, p_subject_key, p_operation, p_severity, SUBSTR(p_detail,1,1000));
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
  END log_security;
END lms_audit_pkg;
/


CREATE OR REPLACE PACKAGE BODY lms_security_pkg AS
  FUNCTION current_user_id_safe RETURN NUMBER IS
    l_name VARCHAR2(255);
    l_id   NUMBER;
  BEGIN
    -- APEX session user, else DB session user (jobs / SQL Developer)
    l_name := UPPER(TRIM(COALESCE(SYS_CONTEXT('APEX$SESSION','APP_USER'), SYS_CONTEXT('USERENV','SESSION_USER'))));
    SELECT user_id INTO l_id FROM lms_users WHERE username = l_name AND status = 'ACTIVE';
    RETURN l_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RETURN NULL;
  END current_user_id_safe;

  FUNCTION current_user_id RETURN NUMBER IS
    l_id NUMBER := current_user_id_safe;
  BEGIN
    IF l_id IS NULL THEN
      RAISE_APPLICATION_ERROR(-20401, 'Not authenticated');
    END IF;
    RETURN l_id;
  END current_user_id;

  FUNCTION has_permission(p_code IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL) RETURN BOOLEAN IS
    l_user NUMBER := COALESCE(p_user_id, current_user_id_safe);
    l_cnt  NUMBER;
  BEGIN
    IF l_user IS NULL THEN RETURN FALSE; END IF;
    SELECT COUNT(*) INTO l_cnt
      FROM lms_user_roles ur
      JOIN lms_role_permissions rp ON rp.role_id = ur.role_id
      JOIN lms_permissions p       ON p.permission_id = rp.permission_id
     WHERE ur.user_id = l_user AND p.permission_code = p_code;
    RETURN l_cnt > 0;
  END has_permission;

  PROCEDURE require_permission(p_code IN VARCHAR2) IS
  BEGIN
    IF NOT has_permission(p_code) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'PERMISSION', NULL, 'DENIED',
                              JSON_OBJECT('permission' VALUE p_code));
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END require_permission;

  FUNCTION is_in_subtree(p_actor IN NUMBER, p_target IN NUMBER) RETURN BOOLEAN IS
    l_cnt NUMBER;
  BEGIN
    -- Walk up the management chain from the target and look for the actor.
    SELECT COUNT(*) INTO l_cnt
      FROM (SELECT user_id FROM lms_users
             START WITH user_id = p_target
             CONNECT BY NOCYCLE user_id = PRIOR manager_user_id)
     WHERE user_id = p_actor AND p_actor <> p_target;
    RETURN l_cnt > 0;
  END is_in_subtree;
END lms_security_pkg;
/

-- ----------------------------------------------------------- RATE LIMIT ----
CREATE OR REPLACE PACKAGE lms_rate_limit_pkg AS
  e_rate_limited EXCEPTION; PRAGMA EXCEPTION_INIT(e_rate_limited, -20429);

  /* Non-consuming check. */
  FUNCTION is_allowed(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                      p_client_key IN VARCHAR2 DEFAULT NULL) RETURN BOOLEAN;
  /* Atomically counts this request; raises -20429 when over limit.
     p_user_id is resolved server-side when NULL; never pass a browser-supplied value. */
  PROCEDURE enforce_limit(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                          p_client_key IN VARCHAR2 DEFAULT NULL);
  /* Same as enforce_limit but returns decision + retry-after (for ORDS 429 handlers). */
  PROCEDURE check_and_record(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                             p_client_key IN VARCHAR2 DEFAULT NULL,
                             p_allowed OUT BOOLEAN, p_retry_after OUT NUMBER);
  PROCEDURE record_event(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                         p_client_key IN VARCHAR2 DEFAULT NULL);
  PROCEDURE purge_expired(p_batch IN NUMBER DEFAULT 10000);
END lms_rate_limit_pkg;
/
CREATE OR REPLACE PACKAGE BODY lms_rate_limit_pkg AS

  FUNCTION epoch_now RETURN NUMBER IS
  BEGIN
    RETURN TRUNC((CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) - DATE '1970-01-01') * 86400);
  END epoch_now;

  /* Subject = hashed identity. Authenticated: user id. Anonymous: caller-supplied client key
     (ORDS passes the proxy-verified client address). Session ids are NOT used: they are
     rotatable by the attacker, so a session-based key would be trivially bypassed. */
  FUNCTION subject_for(p_user_id IN NUMBER, p_client_key IN VARCHAR2) RETURN VARCHAR2 IS
    l_user NUMBER := COALESCE(p_user_id, lms_security_pkg.current_user_id_safe);
  BEGIN
    IF l_user IS NOT NULL THEN
      RETURN 'U:' || l_user;
    ELSIF p_client_key IS NOT NULL THEN
      RETURN 'A:' || LOWER(RAWTOHEX(DBMS_CRYPTO.hash(UTL_I18N.string_to_raw(p_client_key,'AL32UTF8'),
                                                    DBMS_CRYPTO.hash_sh256)));
    ELSE
      RETURN 'A:UNKNOWN';   -- shared bucket: deliberately strict for unidentifiable callers
    END IF;
  END subject_for;

  /* Core: one atomic increment in an autonomous transaction so the count survives a
     caller rollback (a rejected/failed request must still count). */
  PROCEDURE hit(p_operation IN VARCHAR2, p_user_id IN NUMBER, p_client_key IN VARCHAR2,
                p_consume IN BOOLEAN, p_allowed OUT BOOLEAN, p_retry_after OUT NUMBER) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_pol     lms_rate_limit_policies%ROWTYPE;
    l_now     NUMBER := epoch_now;
    l_start   NUMBER;
    l_count   NUMBER;
    l_subject VARCHAR2(80);
  BEGIN
    p_allowed := TRUE; p_retry_after := 0;
    BEGIN
      SELECT * INTO l_pol FROM lms_rate_limit_policies
       WHERE operation_name = p_operation AND enabled_flag = 'Y';
    EXCEPTION WHEN NO_DATA_FOUND THEN
      RETURN;                               -- no policy = no limit
    END;

    l_subject := subject_for(p_user_id, p_client_key);
    l_start   := TRUNC(l_now / l_pol.window_seconds) * l_pol.window_seconds;

    IF p_consume THEN
      UPDATE lms_rate_limit_counters
         SET request_count = request_count + 1
       WHERE policy_id = l_pol.policy_id AND subject_key = l_subject AND window_start = l_start
      RETURNING request_count INTO l_count;

      IF SQL%ROWCOUNT = 0 THEN
        BEGIN
          INSERT INTO lms_rate_limit_counters (policy_id, subject_key, window_start, request_count, expires_at)
          VALUES (l_pol.policy_id, l_subject, l_start, 1,
                  SYSTIMESTAMP + NUMTODSINTERVAL(l_pol.window_seconds * 2, 'SECOND'));
          l_count := 1;
        EXCEPTION WHEN DUP_VAL_ON_INDEX THEN   -- lost the insert race: increment instead
          UPDATE lms_rate_limit_counters
             SET request_count = request_count + 1
           WHERE policy_id = l_pol.policy_id AND subject_key = l_subject AND window_start = l_start
          RETURNING request_count INTO l_count;
        END;
      END IF;
    ELSE
      BEGIN
        SELECT request_count INTO l_count FROM lms_rate_limit_counters
         WHERE policy_id = l_pol.policy_id AND subject_key = l_subject AND window_start = l_start;
      EXCEPTION WHEN NO_DATA_FOUND THEN l_count := 0;
      END;
    END IF;

    IF l_count > l_pol.limit_count THEN
      p_allowed     := FALSE;
      p_retry_after := GREATEST(1, l_start + l_pol.window_seconds - l_now);
      -- log once per window (first violation) to avoid log flooding
      IF l_count = l_pol.limit_count + 1 THEN
        INSERT INTO lms_security_events (event_type, user_id, subject_key, operation, severity, detail)
        VALUES ('RATE_LIMIT', p_user_id, l_subject, p_operation, 'WARN',
                'limit=' || l_pol.limit_count || '/' || l_pol.window_seconds || 's');
      END IF;
    END IF;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    ROLLBACK;
    IF l_pol.fail_mode = 'CLOSED' THEN
      p_allowed := FALSE; p_retry_after := 5;       -- sensitive operations fail closed
    ELSE
      p_allowed := TRUE;                            -- ordinary operations fail open
    END IF;
  END hit;

  FUNCTION is_allowed(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                      p_client_key IN VARCHAR2 DEFAULT NULL) RETURN BOOLEAN IS
    l_ok BOOLEAN; l_ra NUMBER;
  BEGIN
    hit(p_operation, p_user_id, p_client_key, FALSE, l_ok, l_ra);
    RETURN l_ok;
  END is_allowed;

  PROCEDURE check_and_record(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                             p_client_key IN VARCHAR2 DEFAULT NULL,
                             p_allowed OUT BOOLEAN, p_retry_after OUT NUMBER) IS
  BEGIN
    hit(p_operation, p_user_id, p_client_key, TRUE, p_allowed, p_retry_after);
  END check_and_record;

  PROCEDURE enforce_limit(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                          p_client_key IN VARCHAR2 DEFAULT NULL) IS
    l_ok BOOLEAN; l_ra NUMBER;
  BEGIN
    hit(p_operation, p_user_id, p_client_key, TRUE, l_ok, l_ra);
    IF NOT l_ok THEN
      RAISE_APPLICATION_ERROR(-20429,
        'Too many requests. Please retry in ' || l_ra || ' seconds.');
    END IF;
  END enforce_limit;

  PROCEDURE record_event(p_operation IN VARCHAR2, p_user_id IN NUMBER DEFAULT NULL,
                         p_client_key IN VARCHAR2 DEFAULT NULL) IS
    l_ok BOOLEAN; l_ra NUMBER;
  BEGIN
    hit(p_operation, p_user_id, p_client_key, TRUE, l_ok, l_ra);
  END record_event;

  PROCEDURE purge_expired(p_batch IN NUMBER DEFAULT 10000) IS
    l_rows NUMBER;
  BEGIN
    LOOP
      DELETE FROM lms_rate_limit_counters WHERE expires_at < SYSTIMESTAMP AND ROWNUM <= p_batch;
      l_rows := SQL%ROWCOUNT;
      COMMIT;
      EXIT WHEN l_rows < p_batch;
    END LOOP;
  END purge_expired;
END lms_rate_limit_pkg;
/

-- ----------------------------------------------------------- ENROLLMENT ----
CREATE OR REPLACE PACKAGE lms_enrollment_pkg AS
  /* Self-enrollment for the authenticated user. Idempotent: an existing active
     enrollment is returned instead of raising. Caller owns COMMIT. */
  PROCEDURE enroll_self(p_course_id IN NUMBER, p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2);
  /* Assignment by manager/admin (permission + scope checked). */
  PROCEDURE assign(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due_date IN DATE DEFAULT NULL,
                   p_type IN VARCHAR2 DEFAULT 'ADMIN',
                   p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2);
  PROCEDURE cancel(p_enrollment_id IN NUMBER);
  /* Promote oldest WAITLISTED rows while seats are free. Call after cancel/capacity change. */
  PROCEDURE promote_waitlist(p_course_id IN NUMBER);
END lms_enrollment_pkg;
/
CREATE OR REPLACE PACKAGE BODY lms_enrollment_pkg AS

  c_err_state   CONSTANT NUMBER := -20410;  -- course not open for enrollment
  c_err_prereq  CONSTANT NUMBER := -20411;
  c_err_closed  CONSTANT NUMBER := -20412;  -- deadline passed

  FUNCTION seats_taken(p_course_id IN NUMBER) RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_enrollments
     WHERE course_id = p_course_id AND status IN ('APPROVED','ENROLLED','IN_PROGRESS');
    RETURN l_n;
  END seats_taken;

  PROCEDURE do_enroll(p_user_id IN NUMBER, p_course_id IN NUMBER, p_due IN DATE,
                      p_type IN VARCHAR2, p_actor IN NUMBER,
                      p_enrollment_id OUT NUMBER, p_status OUT VARCHAR2) IS
    l_course  lms_courses%ROWTYPE;
    l_missing NUMBER;
    l_status  VARCHAR2(12);
  BEGIN
    -- Serialise per course: capacity decisions are made while holding this row lock.
    SELECT * INTO l_course FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;

    -- Idempotency / BR-01
    BEGIN
      SELECT enrollment_id, status INTO p_enrollment_id, p_status
        FROM lms_enrollments
       WHERE user_id = p_user_id AND course_id = p_course_id
         AND status NOT IN ('CANCELLED','FAILED','EXPIRED');
      RETURN;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;

    -- BR-03
    IF l_course.status <> 'PUBLISHED'
       OR (l_course.available_from IS NOT NULL AND TRUNC(SYSDATE) < l_course.available_from)
       OR (l_course.available_to   IS NOT NULL AND TRUNC(SYSDATE) > l_course.available_to) THEN
      RAISE_APPLICATION_ERROR(c_err_state, 'Course is not open for enrollment');
    END IF;
    IF l_course.enroll_deadline IS NOT NULL AND TRUNC(SYSDATE) > l_course.enroll_deadline
       AND p_type = 'SELF' THEN
      RAISE_APPLICATION_ERROR(c_err_closed, 'Enrollment deadline has passed');
    END IF;

    -- BR-04 (set-based, single query)
    SELECT COUNT(*) INTO l_missing
      FROM lms_course_prerequisites p
     WHERE p.course_id = p_course_id
       AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                        WHERE e.user_id = p_user_id AND e.course_id = p.prereq_course_id
                          AND e.status = 'COMPLETED');
    IF l_missing > 0 THEN
      RAISE_APPLICATION_ERROR(c_err_prereq, 'Prerequisite courses not completed');
    END IF;

    -- Decide status (BR-02)
    IF p_type = 'SELF' AND l_course.approval_required = 'Y' THEN
      l_status := 'PENDING';
    ELSIF l_course.capacity IS NOT NULL AND seats_taken(p_course_id) >= l_course.capacity THEN
      l_status := 'WAITLISTED';
    ELSE
      l_status := 'ENROLLED';
    END IF;

    INSERT INTO lms_enrollments (user_id, course_id, status, enrollment_type, assigned_by, due_date)
    VALUES (p_user_id, p_course_id, l_status, p_type, p_actor, p_due)
    RETURNING enrollment_id INTO p_enrollment_id;
    p_status := l_status;

    lms_audit_pkg.log_event('ENROLL', 'ENROLLMENT', p_enrollment_id, 'SUCCESS',
                            JSON_OBJECT('course' VALUE p_course_id, 'status' VALUE l_status));
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
  BEGIN
    lms_security_pkg.require_permission('ENROLL_ASSIGN');
    IF p_type NOT IN ('ADMIN','MANAGER','MANDATORY','BULK','RULE') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid assignment type');
    END IF;
    -- Scope: managers only within their subtree (BR-13); admins have no TEAM restriction.
    IF NOT lms_security_pkg.has_permission('REPORT_ORG')            -- admin/HR scope marker
       AND NOT lms_security_pkg.is_in_subtree(l_actor, p_user_id) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', NULL, 'DENIED',
                              JSON_OBJECT('target_user' VALUE p_user_id));
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    do_enroll(p_user_id, p_course_id, p_due_date, p_type, l_actor, p_enrollment_id, p_status);
  END assign;

  PROCEDURE cancel(p_enrollment_id IN NUMBER) IS
    l_actor  NUMBER := lms_security_pkg.current_user_id;
    l_enr    lms_enrollments%ROWTYPE;
  BEGIN
    SELECT * INTO l_enr FROM lms_enrollments WHERE enrollment_id = p_enrollment_id FOR UPDATE;
    IF l_enr.user_id <> l_actor AND NOT lms_security_pkg.has_permission('ENROLL_ASSIGN') THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_enr.status IN ('COMPLETED','CANCELLED','FAILED','EXPIRED') THEN
      RAISE_APPLICATION_ERROR(-20413, 'Enrollment cannot be cancelled in status ' || l_enr.status);
    END IF;
    UPDATE lms_enrollments SET status = 'CANCELLED', row_version = row_version + 1
     WHERE enrollment_id = p_enrollment_id;
    lms_audit_pkg.log_event('CANCEL', 'ENROLLMENT', p_enrollment_id);
    promote_waitlist(l_enr.course_id);
  END cancel;

  PROCEDURE promote_waitlist(p_course_id IN NUMBER) IS
    l_course lms_courses%ROWTYPE;
    l_free   NUMBER;
  BEGIN
    SELECT * INTO l_course FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    IF l_course.capacity IS NULL THEN
      l_free := 1000000;
    ELSE
      l_free := l_course.capacity - seats_taken(p_course_id);
    END IF;
    IF l_free > 0 THEN
      UPDATE lms_enrollments
         SET status = 'ENROLLED', row_version = row_version + 1
       WHERE enrollment_id IN (
               SELECT enrollment_id FROM lms_enrollments
                WHERE course_id = p_course_id AND status = 'WAITLISTED'
                ORDER BY enrolled_at, enrollment_id
                FETCH FIRST l_free ROWS ONLY);
    END IF;
  END promote_waitlist;
END lms_enrollment_pkg;
/

-- ---------------------------------------------------------- SEED POLICIES ----
MERGE INTO lms_rate_limit_policies t
USING (SELECT 'AUTH_ATTEMPT' op, 5 cnt, 900 win, 'CLOSED' fm FROM dual UNION ALL
       SELECT 'COURSE_SEARCH', 60, 60, 'OPEN' FROM dual UNION ALL
       SELECT 'COURSE_ENROLL', 10, 60, 'OPEN' FROM dual UNION ALL
       SELECT 'PROGRESS_UPDATE', 30, 60, 'OPEN' FROM dual UNION ALL
       SELECT 'QUIZ_SUBMIT', 5, 60, 'CLOSED' FROM dual UNION ALL
       SELECT 'CERT_GENERATE', 5, 3600, 'CLOSED' FROM dual UNION ALL
       SELECT 'FILE_DOWNLOAD', 30, 60, 'OPEN' FROM dual UNION ALL
       SELECT 'ADMIN_WRITE', 30, 60, 'OPEN' FROM dual) s
   ON (t.operation_name = s.op)
 WHEN NOT MATCHED THEN INSERT (operation_name, limit_count, window_seconds, fail_mode)
      VALUES (s.op, s.cnt, s.win, s.fm);

-- Cleanup job (every 15 minutes)
BEGIN
  DBMS_SCHEDULER.create_job(
    job_name        => 'LMS_RL_PURGE_JOB',
    job_type        => 'PLSQL_BLOCK',
    job_action      => 'BEGIN lms_rate_limit_pkg.purge_expired; END;',
    repeat_interval => 'FREQ=MINUTELY;INTERVAL=15',
    enabled         => TRUE);
END;
/
