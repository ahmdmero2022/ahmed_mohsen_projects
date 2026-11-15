-- =============================================================================
-- Package BODIES (3/3): certification, feedback, skill, reporting
-- Oracle 19c | STATUS: written, NOT compiled. Requires 01-07.
-- JOB procedures rely on the scheduler job committing on success.
-- =============================================================================

-- ------------------------------------------------------- CERTIFICATION -------
CREATE OR REPLACE PACKAGE BODY lms_certification_pkg AS

  FUNCTION default_template RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT template_id INTO l_id FROM lms_certificate_templates
     WHERE template_code = lms_util_pkg.get_setting('DEFAULT_CERT_TEMPLATE') AND active_flag = 'Y';
    RETURN l_id;
  EXCEPTION WHEN NO_DATA_FOUND THEN RETURN NULL;
  END default_template;

  /* Inserts one certificate, retrying when a random number collides. p_enr / p_pe: exactly one is set. */
  PROCEDURE insert_cert(p_user_id IN NUMBER, p_enr IN NUMBER, p_pe IN NUMBER, p_course_id IN NUMBER,
                        p_path_id IN NUMBER, p_template_id IN NUMBER, p_title_en IN VARCHAR2,
                        p_title_ar IN VARCHAR2) IS
    l_months NUMBER;
    l_exp    DATE;
    l_no     VARCHAR2(30);
    l_exists NUMBER;
  BEGIN
    SELECT validity_months INTO l_months FROM lms_certificate_templates WHERE template_id = p_template_id;
    l_exp := CASE WHEN l_months IS NULL THEN NULL ELSE ADD_MONTHS(TRUNC(SYSDATE), l_months) END;

    FOR attempt IN 1 .. 5 LOOP
      BEGIN
        l_no := 'LMS-' || TO_CHAR(SYSDATE, 'YYYY') || '-' || lms_util_pkg.random_code(10);
        INSERT INTO lms_certificates (certificate_no, verification_code, user_id, enrollment_id, path_enrollment_id,
                                      course_id, path_id, template_id, title_en, title_ar, expires_at)
        VALUES (l_no, lms_util_pkg.random_code(16), p_user_id, p_enr, p_pe, p_course_id, p_path_id,
                p_template_id, p_title_en, p_title_ar, l_exp);
        lms_notification_pkg.enqueue(p_user_id, 'CERT_ISSUED',
          lms_util_pkg.js('title', p_title_en, 'number', l_no, 'expires', NVL(TO_CHAR(l_exp, 'YYYY-MM-DD'), 'never')));
        lms_audit_pkg.log_event('CERT_ISSUE', 'CERTIFICATE', NVL(p_enr, p_pe), 'SUCCESS', lms_util_pkg.js('number', l_no));
        RETURN;
      EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
        -- either a number/code collision (retry) or a concurrent issue for the same source (done)
        SELECT COUNT(*) INTO l_exists FROM lms_certificates
         WHERE template_id = p_template_id AND ((p_enr IS NOT NULL AND enrollment_id = p_enr)
                                             OR (p_pe  IS NOT NULL AND path_enrollment_id = p_pe));
        IF l_exists > 0 THEN RETURN; END IF;
      END;
    END LOOP;
    RAISE_APPLICATION_ERROR(-20418, 'Could not allocate a unique certificate number');
  END insert_cert;

  PROCEDURE issue_for_enrollment(p_enrollment_id IN NUMBER) IS
    l_e lms_enrollments%ROWTYPE;
    l_c lms_courses%ROWTYPE;
    l_tpl NUMBER; l_n NUMBER;
  BEGIN
    SELECT * INTO l_e FROM lms_enrollments WHERE enrollment_id = p_enrollment_id;
    SELECT * INTO l_c FROM lms_courses WHERE course_id = l_e.course_id;
    l_tpl := NVL(l_c.certificate_template_id, default_template);
    IF l_tpl IS NULL THEN
      lms_audit_pkg.log_event('CERT_SKIPPED', 'ENROLLMENT', p_enrollment_id, 'FAILURE', lms_util_pkg.js('why', 'no template'));
      RETURN;
    END IF;
    SELECT COUNT(*) INTO l_n FROM lms_certificates WHERE enrollment_id = p_enrollment_id AND template_id = l_tpl;
    IF l_n > 0 THEN RETURN; END IF;                       -- idempotent (BR-09)
    UPDATE lms_certificates SET status = 'SUPERSEDED'
     WHERE user_id = l_e.user_id AND course_id = l_e.course_id AND template_id = l_tpl AND status = 'VALID';
    insert_cert(l_e.user_id, p_enrollment_id, NULL, l_e.course_id, NULL, l_tpl, l_c.title_en, l_c.title_ar);
  END issue_for_enrollment;

  PROCEDURE issue_for_path(p_path_enrollment_id IN NUMBER) IS
    l_pe lms_path_enrollments%ROWTYPE;
    l_p  lms_learning_paths%ROWTYPE;
    l_tpl NUMBER; l_n NUMBER;
  BEGIN
    SELECT * INTO l_pe FROM lms_path_enrollments WHERE path_enrollment_id = p_path_enrollment_id;
    SELECT * INTO l_p  FROM lms_learning_paths WHERE path_id = l_pe.path_id;
    l_tpl := NVL(l_p.certificate_template_id, default_template);
    IF l_tpl IS NULL THEN
      lms_audit_pkg.log_event('CERT_SKIPPED', 'PATH_ENROLLMENT', p_path_enrollment_id, 'FAILURE', lms_util_pkg.js('why', 'no template'));
      RETURN;
    END IF;
    SELECT COUNT(*) INTO l_n FROM lms_certificates WHERE path_enrollment_id = p_path_enrollment_id AND template_id = l_tpl;
    IF l_n > 0 THEN RETURN; END IF;
    UPDATE lms_certificates SET status = 'SUPERSEDED'
     WHERE user_id = l_pe.user_id AND path_id = l_pe.path_id AND template_id = l_tpl AND status = 'VALID';
    insert_cert(l_pe.user_id, NULL, p_path_enrollment_id, NULL, l_pe.path_id, l_tpl, l_p.title_en, l_p.title_ar);
  END issue_for_path;

  PROCEDURE authorize_download(p_certificate_id IN NUMBER) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_cert lms_certificates%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_cert FROM lms_certificates WHERE certificate_id = p_certificate_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Certificate not found'); END;
    IF l_cert.user_id <> l_user AND NOT lms_security_pkg.has_permission('CERT_POLICY') THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'CERTIFICATE', p_certificate_id, 'DENIED');
      lms_audit_pkg.log_security('IDOR_ATTEMPT', l_user, NULL, 'CERT_DOWNLOAD', 'HIGH', 'certificate ' || p_certificate_id);
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_cert.status <> 'VALID' THEN RAISE_APPLICATION_ERROR(-20409, 'Certificate is ' || l_cert.status); END IF;
    lms_rate_limit_pkg.enforce_limit('CERT_GENERATE', l_user);
    lms_audit_pkg.log_event('CERT_DOWNLOAD', 'CERTIFICATE', p_certificate_id);
  END authorize_download;

  FUNCTION lookup_certificate(p_code IN VARCHAR2) RETURN SYS_REFCURSOR IS
    l_c    SYS_REFCURSOR;
    l_mode VARCHAR2(10) := UPPER(lms_util_pkg.get_setting('CERT_VERIFY_NAME', 'INITIALS'));
    l_code VARCHAR2(40) := UPPER(TRIM(SUBSTR(p_code, 1, 40)));
    l_n    NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_certificates WHERE verification_code = l_code;
    IF l_n = 0 THEN
      lms_audit_pkg.log_security('CERT_VERIFY_MISS', NULL, NULL, 'CERT_VERIFY', 'INFO', NULL);   -- code itself not logged
    END IF;
    -- BR-10: only title, status, dates and a minimal holder label are returned.
    OPEN l_c FOR
      SELECT ce.title_en, ce.title_ar,
             CASE WHEN ce.status = 'VALID' AND ce.expires_at < TRUNC(SYSDATE) THEN 'EXPIRED' ELSE ce.status END AS status,
             TRUNC(CAST(ce.issued_at AS DATE)) AS issued_on, ce.expires_at,
             CASE l_mode WHEN 'FULL' THEN u.full_name_en
                         WHEN 'INITIALS' THEN REGEXP_REPLACE(u.full_name_en, '(\S)\S*\s*', '\1.')
                         ELSE NULL END AS holder
        FROM lms_certificates ce JOIN lms_users u ON u.user_id = ce.user_id
       WHERE ce.verification_code = l_code;
    RETURN l_c;
  END lookup_certificate;

  FUNCTION verify(p_code IN VARCHAR2, p_client_key IN VARCHAR2) RETURN SYS_REFCURSOR IS
  BEGIN
    lms_rate_limit_pkg.enforce_limit('CERT_VERIFY', NULL, p_client_key);   -- anonymous callers keyed by verified client address
    RETURN lookup_certificate(p_code);
  END verify;

  PROCEDURE revoke(p_certificate_id IN NUMBER, p_reason IN VARCHAR2) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_user  NUMBER; l_title VARCHAR2(250);
  BEGIN
    lms_security_pkg.require_permission('CERT_REVOKE');
    IF p_reason IS NULL OR LENGTH(TRIM(p_reason)) < 5 THEN
      RAISE_APPLICATION_ERROR(-20400, 'A revocation reason is required');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    UPDATE lms_certificates
       SET status = 'REVOKED', revoked_at = SYSTIMESTAMP, revoked_by = l_actor, revoked_reason = SUBSTR(p_reason, 1, 500)
     WHERE certificate_id = p_certificate_id AND status = 'VALID'
    RETURNING user_id, title_en INTO l_user, l_title;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Only VALID certificates can be revoked'); END IF;
    lms_notification_pkg.enqueue(l_user, 'CERT_REVOKED', lms_util_pkg.js('title', l_title));
    lms_audit_pkg.log_event('CERT_REVOKE', 'CERTIFICATE', p_certificate_id);
  END revoke;

  PROCEDURE expire_due IS
  BEGIN
    INSERT INTO lms_notification_queue (user_id, template_code, payload)
    SELECT user_id, 'CERT_EXPIRED', JSON_OBJECT('title' VALUE title_en)
      FROM lms_certificates WHERE status = 'VALID' AND expires_at < TRUNC(SYSDATE);
    UPDATE lms_certificates SET status = 'EXPIRED' WHERE status = 'VALID' AND expires_at < TRUNC(SYSDATE);
    lms_audit_pkg.log_event('CERT_EXPIRE_JOB', 'CERTIFICATE', NULL, 'SUCCESS', lms_util_pkg.js('rows', SQL%ROWCOUNT));
  END expire_due;

  PROCEDURE renewal_sweep IS
    l_window NUMBER := lms_util_pkg.get_number('RENEWAL_WINDOW_DAYS', 90);
  BEGIN
    INSERT INTO lms_notification_queue (user_id, template_code, payload)
    SELECT ce.user_id, 'CERT_EXPIRING',
           JSON_OBJECT('title' VALUE ce.title_en, 'days' VALUE (ce.expires_at - TRUNC(SYSDATE)),
                       'expires' VALUE TO_CHAR(ce.expires_at, 'YYYY-MM-DD'))
      FROM lms_certificates ce
     WHERE ce.status = 'VALID' AND ce.expires_at IS NOT NULL
       AND (ce.expires_at - TRUNC(SYSDATE)) IN (90, 30, 7);

    FOR r IN (SELECT ce.user_id, ce.course_id, ce.expires_at
                FROM lms_certificates ce
               WHERE ce.status = 'VALID' AND ce.course_id IS NOT NULL AND ce.expires_at IS NOT NULL
                 AND ce.expires_at BETWEEN TRUNC(SYSDATE) AND TRUNC(SYSDATE) + l_window
                 AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                                  WHERE e.user_id = ce.user_id AND e.course_id = ce.course_id
                                    AND e.status IN ('PENDING','APPROVED','ENROLLED','IN_PROGRESS','WAITLISTED'))) LOOP
      SAVEPOINT sp_renew;
      BEGIN
        lms_enrollment_pkg.start_renewal(r.user_id, r.course_id, r.expires_at);
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK TO sp_renew;
        lms_audit_pkg.log_security('RENEWAL_FAILED', r.user_id, NULL, 'RENEWAL', 'WARN', SUBSTR(SQLERRM, 1, 500));
      END;
    END LOOP;
  END renewal_sweep;
END lms_certification_pkg;
/

-- ------------------------------------------------------------ FEEDBACK -------
CREATE OR REPLACE PACKAGE BODY lms_feedback_pkg AS

  -- Returns the enrolment if it belongs to the caller and satisfies the review policy.
  FUNCTION own_enrollment(p_enrollment_id IN NUMBER) RETURN lms_enrollments%ROWTYPE IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_e    lms_enrollments%ROWTYPE;
  BEGIN
    BEGIN SELECT * INTO l_e FROM lms_enrollments WHERE enrollment_id = p_enrollment_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Enrolment not found'); END;
    IF l_e.user_id <> l_user THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'ENROLLMENT', p_enrollment_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_e.status <> 'COMPLETED'
       AND (lms_util_pkg.get_setting('REVIEW_REQUIRES_COMPLETION', 'Y') = 'Y' OR l_e.status NOT IN ('IN_PROGRESS')) THEN
      RAISE_APPLICATION_ERROR(-20409, 'Feedback is available after you complete the course');
    END IF;
    RETURN l_e;
  END own_enrollment;

  PROCEDURE submit_review(p_enrollment_id IN NUMBER, p_course_rating IN NUMBER,
                          p_instructor_rating IN NUMBER DEFAULT NULL, p_review_text IN VARCHAR2 DEFAULT NULL) IS
    l_e lms_enrollments%ROWTYPE;
  BEGIN
    l_e := own_enrollment(p_enrollment_id);
    IF p_course_rating NOT BETWEEN 1 AND 5 OR (p_instructor_rating IS NOT NULL AND p_instructor_rating NOT BETWEEN 1 AND 5) THEN
      RAISE_APPLICATION_ERROR(-20400, 'Ratings must be between 1 and 5');
    END IF;
    INSERT INTO lms_course_reviews (enrollment_id, course_id, user_id, course_rating, instructor_rating, review_text)
    VALUES (p_enrollment_id, l_e.course_id, l_e.user_id, p_course_rating, p_instructor_rating, SUBSTR(p_review_text, 1, 2000));
    lms_audit_pkg.log_event('REVIEW_SUBMIT', 'COURSE', l_e.course_id);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
    RAISE_APPLICATION_ERROR(-20409, 'You have already reviewed this course');
  END submit_review;

  PROCEDURE submit_answer(p_enrollment_id IN NUMBER, p_question_id IN NUMBER,
                          p_rating IN NUMBER DEFAULT NULL, p_comment IN VARCHAR2 DEFAULT NULL) IS
    l_e lms_enrollments%ROWTYPE;
    l_n NUMBER;
  BEGIN
    l_e := own_enrollment(p_enrollment_id);
    SELECT COUNT(*) INTO l_n
      FROM lms_feedback_questions q JOIN lms_courses c ON c.feedback_form_id = q.form_id
     WHERE q.question_id = p_question_id AND c.course_id = l_e.course_id;
    IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Question does not belong to this course form'); END IF;
    IF p_rating IS NOT NULL AND p_rating NOT BETWEEN 1 AND 5 THEN RAISE_APPLICATION_ERROR(-20400, 'Rating must be 1-5'); END IF;
    IF p_rating IS NULL AND p_comment IS NULL THEN RAISE_APPLICATION_ERROR(-20400, 'An answer is required'); END IF;
    INSERT INTO lms_feedback_responses (enrollment_id, question_id, rating, comment_text)
    VALUES (p_enrollment_id, p_question_id, p_rating, SUBSTR(p_comment, 1, 2000));
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
    RAISE_APPLICATION_ERROR(-20409, 'This question was already answered');
  END submit_answer;

  PROCEDURE set_review_visibility(p_review_id IN NUMBER, p_visible IN BOOLEAN) IS
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    UPDATE lms_course_reviews SET status = CASE WHEN p_visible THEN 'PUBLISHED' ELSE 'HIDDEN' END
     WHERE review_id = p_review_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Review not found'); END IF;
    lms_audit_pkg.log_event('REVIEW_VISIBILITY', 'REVIEW', p_review_id);
  END set_review_visibility;
END lms_feedback_pkg;
/

-- --------------------------------------------------------------- SKILL -------
CREATE OR REPLACE PACKAGE BODY lms_skill_pkg AS

  PROCEDURE assess_skill(p_user_id IN NUMBER, p_skill_id IN NUMBER, p_level IN NUMBER) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
  BEGIN
    IF p_level NOT BETWEEN 0 AND 5 THEN RAISE_APPLICATION_ERROR(-20400, 'Level must be 0-5'); END IF;
    IF NOT (lms_security_pkg.has_permission('SKILL_MANAGE')
            OR lms_security_pkg.can_manage_user('REPORT_TEAM', p_user_id)) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'USER_SKILL', p_user_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    MERGE INTO lms_user_skills t
    USING (SELECT p_user_id user_id, p_skill_id skill_id FROM dual) s
       ON (t.user_id = s.user_id AND t.skill_id = s.skill_id)
     WHEN MATCHED THEN UPDATE SET t.current_level = p_level, t.assessed_by = l_actor, t.assessed_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (user_id, skill_id, current_level, assessed_by)
          VALUES (s.user_id, s.skill_id, p_level, l_actor);
    lms_audit_pkg.log_event('SKILL_ASSESS', 'USER', p_user_id, 'SUCCESS', lms_util_pkg.js('skill', p_skill_id, 'level', p_level));
  END assess_skill;

  FUNCTION recommended_courses(p_user_id IN NUMBER DEFAULT NULL) RETURN SYS_REFCURSOR IS
    l_self   NUMBER := lms_security_pkg.current_user_id;
    l_target NUMBER := NVL(p_user_id, l_self);
    l_c      SYS_REFCURSOR;
  BEGIN
    IF l_target <> l_self AND NOT (lms_security_pkg.can_manage_user('REPORT_TEAM', l_target)
                                   OR lms_security_pkg.can_manage_user('REPORT_ORG', l_target)) THEN
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    OPEN l_c FOR
      SELECT c.course_id, c.title_en, c.title_ar,
             SUM(LEAST(cs.level_gained, g.gap)) AS coverage, COUNT(*) AS skills_addressed
        FROM v_lms_skill_gaps g
        JOIN lms_course_skills cs ON cs.skill_id = g.skill_id
        JOIN lms_courses c ON c.course_id = cs.course_id AND c.status = 'PUBLISHED'
       WHERE g.user_id = l_target
         AND NOT EXISTS (SELECT 1 FROM lms_enrollments e
                          WHERE e.user_id = l_target AND e.course_id = c.course_id
                            AND e.status NOT IN ('CANCELLED','FAILED','EXPIRED'))
       GROUP BY c.course_id, c.title_en, c.title_ar
       ORDER BY coverage DESC, c.title_en
       FETCH FIRST 10 ROWS ONLY;
    RETURN l_c;
  END recommended_courses;
END lms_skill_pkg;
/

-- ----------------------------------------------------------- REPORTING -------
CREATE OR REPLACE PACKAGE BODY lms_reporting_pkg AS

  PROCEDURE refresh_summaries IS
  BEGIN
    -- Department/day facts for the last 35 days (older days are immutable once loaded).
    -- Learning hours are attributed to the day of last activity (approximation, documented in doc 06).
    MERGE INTO lms_sum_dept_daily t
    USING (SELECT department_id, day AS summary_day, SUM(enr) enrollments, SUM(comp) completions, SUM(hrs) hours
             FROM (SELECT u.department_id, TRUNC(CAST(e.enrolled_at AS DATE)) day, 1 enr, 0 comp, 0 hrs
                     FROM lms_enrollments e JOIN lms_users u ON u.user_id = e.user_id
                    WHERE e.enrolled_at >= SYSTIMESTAMP - INTERVAL '35' DAY AND u.department_id IS NOT NULL
                   UNION ALL
                   SELECT u.department_id, TRUNC(CAST(e.completed_at AS DATE)), 0, 1, 0
                     FROM lms_enrollments e JOIN lms_users u ON u.user_id = e.user_id
                    WHERE e.completed_at >= SYSTIMESTAMP - INTERVAL '35' DAY AND u.department_id IS NOT NULL
                   UNION ALL
                   SELECT u.department_id, TRUNC(CAST(e.last_activity_at AS DATE)), 0, 0, e.time_spent_sec / 3600
                     FROM lms_enrollments e JOIN lms_users u ON u.user_id = e.user_id
                    WHERE e.last_activity_at >= SYSTIMESTAMP - INTERVAL '35' DAY AND u.department_id IS NOT NULL)
            GROUP BY department_id, day) s
       ON (t.department_id = s.department_id AND t.summary_day = s.summary_day)
     WHEN MATCHED THEN UPDATE SET t.enrollments = s.enrollments, t.completions = s.completions,
                                  t.learning_hours = ROUND(s.hours, 2), t.refreshed_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (department_id, summary_day, enrollments, completions, learning_hours)
          VALUES (s.department_id, s.summary_day, s.enrollments, s.completions, ROUND(s.hours, 2));

    MERGE INTO lms_sum_course t
    USING (SELECT c.course_id, NVL(e.enrolled, 0) enrolled, NVL(e.completed, 0) completed,
                  a.avg_score, r.avg_rating, NVL(r.rating_count, 0) rating_count
             FROM lms_courses c
             LEFT JOIN (SELECT course_id, COUNT(*) enrolled,
                               SUM(CASE WHEN status = 'COMPLETED' THEN 1 ELSE 0 END) completed
                          FROM lms_enrollments
                         WHERE status NOT IN ('CANCELLED','WAITLISTED','PENDING') GROUP BY course_id) e
                    ON e.course_id = c.course_id
             LEFT JOIN (SELECT z.course_id, ROUND(AVG(qa.score_pct), 2) avg_score
                          FROM lms_quiz_attempts qa JOIN lms_quizzes z ON z.quiz_id = qa.quiz_id
                         WHERE qa.status = 'GRADED' GROUP BY z.course_id) a ON a.course_id = c.course_id
             LEFT JOIN lms_course_rating_v r ON r.course_id = c.course_id) s
       ON (t.course_id = s.course_id)
     WHEN MATCHED THEN UPDATE SET t.enrolled = s.enrolled, t.completed = s.completed, t.avg_score = s.avg_score,
                                  t.avg_rating = s.avg_rating, t.rating_count = s.rating_count, t.refreshed_at = SYSTIMESTAMP
     WHEN NOT MATCHED THEN INSERT (course_id, enrolled, completed, avg_score, avg_rating, rating_count)
          VALUES (s.course_id, s.enrolled, s.completed, s.avg_score, s.avg_rating, s.rating_count);
  END refresh_summaries;

  PROCEDURE send_reminders IS
  BEGIN
    -- learner reminders: 7 and 1 day before due, and 1/7/14 days overdue
    INSERT INTO lms_notification_queue (user_id, template_code, payload)
    SELECT e.user_id, 'MANDATORY_REMINDER',
           JSON_OBJECT('course' VALUE c.title_en, 'due' VALUE TO_CHAR(e.due_date, 'YYYY-MM-DD'))
      FROM lms_enrollments e JOIN lms_courses c ON c.course_id = e.course_id
     WHERE e.enrollment_type = 'MANDATORY' AND e.status IN ('ENROLLED','IN_PROGRESS')
       AND e.due_date IN (TRUNC(SYSDATE) + 7, TRUNC(SYSDATE) + 1, TRUNC(SYSDATE) - 1, TRUNC(SYSDATE) - 7, TRUNC(SYSDATE) - 14);
    -- escalation to the manager when overdue
    INSERT INTO lms_notification_queue (user_id, template_code, payload)
    SELECT u.manager_user_id, 'MANDATORY_OVERDUE',
           JSON_OBJECT('employee' VALUE u.full_name_en, 'course' VALUE c.title_en,
                       'days' VALUE (TRUNC(SYSDATE) - e.due_date))
      FROM lms_enrollments e JOIN lms_courses c ON c.course_id = e.course_id JOIN lms_users u ON u.user_id = e.user_id
     WHERE e.enrollment_type = 'MANDATORY' AND e.status IN ('ENROLLED','IN_PROGRESS') AND u.manager_user_id IS NOT NULL
       AND e.due_date IN (TRUNC(SYSDATE) - 1, TRUNC(SYSDATE) - 7, TRUNC(SYSDATE) - 14);
  END send_reminders;

  PROCEDURE purge_logs IS
    l_audit NUMBER := lms_util_pkg.get_number('RETAIN_AUDIT_DAYS', 2555);
    l_sec   NUMBER := lms_util_pkg.get_number('RETAIN_SECEVENT_DAYS', 730);
    l_api   NUMBER := lms_util_pkg.get_number('RETAIN_APILOG_DAYS', 90);
    l_act   NUMBER := lms_util_pkg.get_number('RETAIN_ACTIVITY_DAYS', 730);
    l_ntf   NUMBER := lms_util_pkg.get_number('RETAIN_NOTIF_DAYS', 180);
  BEGIN
    -- Each loop deletes in batches and commits (JOB owns the transaction). Run as the schema owner:
    -- the application schema has no DELETE privilege on these tables (test S-19).
    LOOP DELETE FROM lms_audit_log WHERE event_time < SYSTIMESTAMP - NUMTODSINTERVAL(l_audit, 'DAY') AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
    LOOP DELETE FROM lms_security_events WHERE event_time < SYSTIMESTAMP - NUMTODSINTERVAL(l_sec, 'DAY') AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
    LOOP DELETE FROM lms_api_request_log WHERE log_time < SYSTIMESTAMP - NUMTODSINTERVAL(l_api, 'DAY') AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
    LOOP DELETE FROM lms_learning_activity WHERE event_time < SYSTIMESTAMP - NUMTODSINTERVAL(l_act, 'DAY') AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
    LOOP DELETE FROM lms_notifications WHERE read_flag = 'Y' AND created_at < SYSTIMESTAMP - NUMTODSINTERVAL(l_ntf, 'DAY') AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
    LOOP DELETE FROM lms_notification_queue WHERE status IN ('SENT','FAILED') AND created_at < SYSTIMESTAMP - INTERVAL '90' DAY AND ROWNUM <= 10000;
         EXIT WHEN SQL%ROWCOUNT = 0; COMMIT; END LOOP;
  END purge_logs;

  FUNCTION org_kpis RETURN SYS_REFCURSOR IS
    l_c SYS_REFCURSOR;
  BEGIN
    IF lms_security_pkg.permission_scope('REPORT_ORG') <> 'ALL' OR lms_security_pkg.permission_scope('REPORT_ORG') IS NULL THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'REPORT', NULL, 'DENIED', lms_util_pkg.js('report', 'org_kpis'));
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    OPEN l_c FOR SELECT * FROM v_lms_org_kpis;     -- single definition shared with the dashboard page
    RETURN l_c;
  END org_kpis;
END lms_reporting_pkg;
/
