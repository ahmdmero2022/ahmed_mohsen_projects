-- =============================================================================
-- Package BODIES (1/3): notification, approval, user, hr_sync, course
-- Oracle 19c | STATUS: written, NOT compiled. Requires 01-05.
-- =============================================================================

-- -------------------------------------------------------- NOTIFICATION -------
CREATE OR REPLACE PACKAGE BODY lms_notification_pkg AS

  PROCEDURE enqueue(p_user_id IN NUMBER, p_template_code IN VARCHAR2, p_payload IN VARCHAR2 DEFAULT NULL,
                    p_attach_kind IN VARCHAR2 DEFAULT NULL, p_attach_ref IN NUMBER DEFAULT NULL,
                    p_attach_method IN VARCHAR2 DEFAULT NULL) IS
  BEGIN
    IF p_user_id IS NULL THEN RETURN; END IF;
    INSERT INTO lms_notification_queue (user_id, template_code, payload, attach_kind, attach_ref, attach_method)
    VALUES (p_user_id, p_template_code, p_payload, p_attach_kind, p_attach_ref, p_attach_method);
  END enqueue;

  /* Replaces {{key}} placeholders with values from the JSON payload. */
  PROCEDURE render(p_text IN OUT NOCOPY CLOB, p_payload IN VARCHAR2) IS
    l_obj  JSON_OBJECT_T;
    l_keys JSON_KEY_LIST;
  BEGIN
    IF p_payload IS NULL THEN RETURN; END IF;
    l_obj  := JSON_OBJECT_T.parse(p_payload);
    l_keys := l_obj.get_keys;
    FOR i IN 1 .. l_keys.COUNT LOOP
      p_text := REPLACE(p_text, '{{' || l_keys(i) || '}}', NVL(l_obj.get(l_keys(i)).to_string, ''));
    END LOOP;
  END render;

  PROCEDURE process_queue(p_batch IN PLS_INTEGER DEFAULT 200) IS
    CURSOR c_due IS
      SELECT queue_id, user_id, template_code, payload, attempts, attach_kind, attach_ref, attach_method
        FROM lms_notification_queue
       WHERE status = 'PENDING' AND next_attempt_at <= SYSTIMESTAMP
       ORDER BY queue_id
         FOR UPDATE SKIP LOCKED;     -- FETCH FIRST cannot be combined with FOR UPDATE (ORA-02014)
    l_user    lms_users%ROWTYPE;
    l_subject lms_notification_templates.subject%TYPE;
    l_body    CLOB;
    l_subj    VARCHAR2(4000);
    l_link    VARCHAR2(1000);
    l_n       PLS_INTEGER := 0;
    l_wait    NUMBER;
    l_from    VARCHAR2(254) := lms_util_pkg.get_setting('MAIL_FROM');
    l_ws      VARCHAR2(100) := lms_util_pkg.get_setting('APEX_WORKSPACE');
    l_mail_id NUMBER;
    l_ics     CLOB;
  BEGIN
    -- APEX_MAIL needs a workspace context when it runs from a scheduler job.
    IF l_ws IS NOT NULL AND SYS_CONTEXT('APEX$SESSION', 'APP_ID') IS NULL THEN
      apex_util.set_security_group_id(apex_util.find_security_group_id(p_workspace => l_ws));
    END IF;

    FOR r IN c_due LOOP
      EXIT WHEN l_n >= p_batch;
      l_n := l_n + 1;
      BEGIN
        SELECT * INTO l_user FROM lms_users WHERE user_id = r.user_id;
        BEGIN
          SELECT subject, body INTO l_subject, l_body
            FROM lms_notification_templates
           WHERE template_code = r.template_code AND lang = l_user.preferred_lang AND active_flag = 'Y';
        EXCEPTION WHEN NO_DATA_FOUND THEN
          SELECT subject, body INTO l_subject, l_body
            FROM lms_notification_templates
           WHERE template_code = r.template_code AND lang = 'en' AND active_flag = 'Y';
        END;
        l_subj := l_subject;
        -- render subject through a temp CLOB so both use the same logic
        DECLARE l_s CLOB := l_subject; BEGIN render(l_s, r.payload); l_subj := SUBSTR(l_s, 1, 300); END;
        render(l_body, r.payload);
        l_link := CASE WHEN r.payload IS NOT NULL THEN JSON_OBJECT_T.parse(r.payload).get_string('link') END;

        INSERT INTO lms_notifications (user_id, template_code, title, message, link_url)
        VALUES (r.user_id, r.template_code, l_subj, SUBSTR(l_body, 1, 2000), l_link);

        IF l_user.email IS NOT NULL AND l_from IS NOT NULL THEN
          l_mail_id := apex_mail.send(p_to => l_user.email, p_from => l_from, p_subj => l_subj,
                         p_body => l_body,
                         p_body_html => '<div>' || REPLACE(apex_escape.html(l_body), CHR(10), '<br>') || '</div>');
          IF r.attach_kind = 'SESSION_ICS' THEN
            -- calendar file is built now, so it always carries the latest time/place/SEQUENCE; a failure must not lose the mail
            BEGIN
              l_ics := lms_calendar_pkg.build_ics(r.attach_ref, r.user_id, r.attach_method);
              apex_mail.add_attachment(p_mail_id => l_mail_id, p_attachment => apex_util.clob_to_blob(l_ics, 'AL32UTF8'),
                                       p_filename => 'session.ics',
                                       p_mime_type => 'text/calendar; method=' || r.attach_method || '; charset=UTF-8');
            EXCEPTION WHEN OTHERS THEN
              lms_audit_pkg.log_security('ICS_FAILED', r.user_id, NULL, r.template_code, 'WARN', SUBSTR(SQLERRM, 1, 500));
            END;
          END IF;
        END IF;

        UPDATE lms_notification_queue SET status = 'SENT', sent_at = SYSTIMESTAMP, attempts = attempts + 1,
               last_error = NULL WHERE CURRENT OF c_due;
      EXCEPTION WHEN OTHERS THEN
        l_wait := CASE r.attempts WHEN 0 THEN 1 WHEN 1 THEN 5 WHEN 2 THEN 30 ELSE 60 END;
        UPDATE lms_notification_queue
           SET attempts = attempts + 1,
               status = CASE WHEN attempts + 1 >= 5 THEN 'FAILED' ELSE 'PENDING' END,
               next_attempt_at = SYSTIMESTAMP + NUMTODSINTERVAL(l_wait, 'MINUTE'),
               last_error = SUBSTR(SQLERRM, 1, 1000)
         WHERE CURRENT OF c_due;
        IF r.attempts + 1 >= 5 THEN
          lms_audit_pkg.log_security('NOTIFICATION_FAILED', r.user_id, NULL, r.template_code, 'WARN', SUBSTR(SQLERRM, 1, 500));
        END IF;
      END;
    END LOOP;
    COMMIT;   -- JOB: this procedure owns its transaction
  END process_queue;

  PROCEDURE mark_read(p_notification_id IN NUMBER) IS
  BEGIN
    UPDATE lms_notifications SET read_flag = 'Y'
     WHERE notification_id = p_notification_id AND user_id = lms_security_pkg.current_user_id;
  END mark_read;

  PROCEDURE mark_all_read IS
  BEGIN
    UPDATE lms_notifications SET read_flag = 'Y'
     WHERE user_id = lms_security_pkg.current_user_id AND read_flag = 'N';
  END mark_all_read;

  FUNCTION unread_count RETURN NUMBER IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM lms_notifications
     WHERE user_id = lms_security_pkg.current_user_id_safe AND read_flag = 'N';
    RETURN l_n;
  END unread_count;
END lms_notification_pkg;
/

-- ------------------------------------------------------------- APPROVAL -------
CREATE OR REPLACE PACKAGE BODY lms_approval_pkg AS

  FUNCTION any_holder(p_permission IN VARCHAR2, p_exclude IN NUMBER) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    SELECT MIN(ur.user_id) INTO l_id
      FROM lms_user_roles ur
      JOIN lms_role_permissions rp ON rp.role_id = ur.role_id AND rp.scope = 'ALL'
      JOIN lms_permissions p ON p.permission_id = rp.permission_id AND p.permission_code = p_permission
      JOIN lms_users u ON u.user_id = ur.user_id AND u.status = 'ACTIVE'
     WHERE ur.user_id <> NVL(p_exclude, -1);
    RETURN l_id;
  END any_holder;

  PROCEDURE open_request(p_type IN VARCHAR2, p_entity IN NUMBER, p_requester IN NUMBER, p_approver IN NUMBER,
                         p_title IN VARCHAR2) IS
    l_days NUMBER := lms_util_pkg.get_number('APPROVAL_ESCALATE_DAYS', 3);
    l_req_name lms_users.full_name_en%TYPE;
  BEGIN
    IF p_approver IS NULL THEN
      RAISE_APPLICATION_ERROR(-20409, 'No approver is configured for this request');
    END IF;
    INSERT INTO lms_approvals (request_type, entity_id, requester_id, approver_id, due_at)
    VALUES (p_type, p_entity, p_requester, p_approver, SYSTIMESTAMP + NUMTODSINTERVAL(l_days, 'DAY'));
    SELECT full_name_en INTO l_req_name FROM lms_users WHERE user_id = p_requester;
    lms_notification_pkg.enqueue(p_approver, 'APPROVAL_REQUEST',
      lms_util_pkg.js('item', p_title, 'requester', l_req_name));
    lms_audit_pkg.log_event('APPROVAL_REQUESTED', p_type, p_entity);
  END open_request;

  PROCEDURE request_enrollment(p_enrollment_id IN NUMBER, p_requester_id IN NUMBER) IS
    l_approver NUMBER;
    l_title    VARCHAR2(250);
  BEGIN
    SELECT c.title_en, u.manager_user_id INTO l_title, l_approver
      FROM lms_enrollments e JOIN lms_courses c ON c.course_id = e.course_id
      JOIN lms_users u ON u.user_id = e.user_id
     WHERE e.enrollment_id = p_enrollment_id;
    -- manager must be active, otherwise fall back to a holder of ENROLL_APPROVE (ALL)
    IF l_approver IS NOT NULL THEN
      DECLARE l_st VARCHAR2(10); BEGIN
        SELECT status INTO l_st FROM lms_users WHERE user_id = l_approver;
        IF l_st <> 'ACTIVE' THEN l_approver := NULL; END IF;
      END;
    END IF;
    open_request('ENROLLMENT', p_enrollment_id, p_requester_id,
                 COALESCE(l_approver, any_holder('ENROLL_APPROVE', p_requester_id)), l_title);
  END request_enrollment;

  PROCEDURE request_course_publish(p_course_id IN NUMBER, p_requester_id IN NUMBER) IS
    l_title VARCHAR2(250);
  BEGIN
    SELECT title_en INTO l_title FROM lms_courses WHERE course_id = p_course_id;
    open_request('COURSE_PUBLISH', p_course_id, p_requester_id,
                 any_holder('COURSE_PUBLISH', p_requester_id), l_title);   -- SoD: never the author
  END request_course_publish;

  PROCEDURE decide(p_approval_id IN NUMBER, p_decision IN VARCHAR2, p_note IN VARCHAR2 DEFAULT NULL) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_apr   lms_approvals%ROWTYPE;
    l_ok    BOOLEAN;
    l_perm  VARCHAR2(30);
  BEGIN
    IF p_decision NOT IN ('APPROVE','REJECT') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Decision must be APPROVE or REJECT');
    END IF;
    BEGIN
      SELECT * INTO l_apr FROM lms_approvals WHERE approval_id = p_approval_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      RAISE_APPLICATION_ERROR(-20404, 'Approval request not found');
    END;
    IF l_apr.status <> 'PENDING' THEN
      RAISE_APPLICATION_ERROR(-20409, 'Request already decided');
    END IF;
    l_perm := CASE l_apr.request_type WHEN 'ENROLLMENT' THEN 'ENROLL_APPROVE' ELSE 'COURSE_PUBLISH' END;
    IF l_actor = l_apr.requester_id
       OR NOT (l_actor = l_apr.approver_id OR lms_security_pkg.permission_scope(l_perm) = 'ALL') THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'APPROVAL', p_approval_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
    IF l_actor = l_apr.approver_id AND lms_security_pkg.permission_scope(l_perm) IS NULL THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'APPROVAL', p_approval_id, 'DENIED');
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;

    l_ok := (p_decision = 'APPROVE');
    UPDATE lms_approvals
       SET status = CASE WHEN l_ok THEN 'APPROVED' ELSE 'REJECTED' END,
           decision_note = SUBSTR(p_note, 1, 1000), decided_at = SYSTIMESTAMP, decided_by = l_actor
     WHERE approval_id = p_approval_id;

    IF l_apr.request_type = 'ENROLLMENT' THEN
      lms_enrollment_pkg.apply_approval(l_apr.entity_id, l_ok);
    ELSE
      lms_course_pkg.apply_review(l_apr.entity_id, l_ok, p_note);
    END IF;
    lms_audit_pkg.log_event('APPROVAL_' || p_decision, l_apr.request_type, l_apr.entity_id);
  END decide;

  PROCEDURE escalate_overdue IS
    CURSOR c IS
      SELECT approval_id, request_type, requester_id, approver_id, entity_id
        FROM lms_approvals
       WHERE status = 'PENDING' AND due_at < SYSTIMESTAMP AND escalation_count < 3
         FOR UPDATE SKIP LOCKED;
    l_new  NUMBER;
    l_days NUMBER := lms_util_pkg.get_number('APPROVAL_ESCALATE_DAYS', 3);
  BEGIN
    FOR r IN c LOOP
      SELECT manager_user_id INTO l_new FROM lms_users WHERE user_id = r.approver_id;
      IF l_new IS NULL OR l_new = r.requester_id THEN
        l_new := any_holder(CASE r.request_type WHEN 'ENROLLMENT' THEN 'ENROLL_APPROVE' ELSE 'COURSE_PUBLISH' END,
                            r.requester_id);
      END IF;
      IF l_new IS NOT NULL AND l_new <> r.approver_id THEN
        UPDATE lms_approvals
           SET approver_id = l_new, escalation_count = escalation_count + 1,
               due_at = SYSTIMESTAMP + NUMTODSINTERVAL(l_days, 'DAY')
         WHERE CURRENT OF c;
        lms_notification_pkg.enqueue(l_new, 'APPROVAL_ESCALATED',
          lms_util_pkg.js('item', r.request_type || ' #' || r.entity_id));
        lms_audit_pkg.log_event('APPROVAL_ESCALATED', r.request_type, r.entity_id);
      END IF;
    END LOOP;
  END escalate_overdue;
END lms_approval_pkg;
/

-- ---------------------------------------------------------------- USER --------
CREATE OR REPLACE PACKAGE BODY lms_user_pkg AS

  FUNCTION would_cycle(p_user_id IN NUMBER, p_manager_user_id IN NUMBER) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    IF p_manager_user_id IS NULL THEN RETURN FALSE; END IF;
    IF p_manager_user_id = p_user_id THEN RETURN TRUE; END IF;
    -- walk up from the proposed manager; if we meet the user, the new edge closes a loop
    SELECT COUNT(*) INTO l_n FROM (
      SELECT user_id FROM lms_users
       START WITH user_id = p_manager_user_id
       CONNECT BY NOCYCLE user_id = PRIOR manager_user_id)
     WHERE user_id = p_user_id;
    RETURN l_n > 0;
  END would_cycle;

  PROCEDURE grant_role(p_user_id IN NUMBER, p_role_code IN VARCHAR2) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
    l_role  NUMBER;
  BEGIN
    lms_security_pkg.require_permission('ROLE_ADMIN');
    IF p_user_id = l_actor THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'USER_ROLE', p_user_id, 'DENIED', lms_util_pkg.js('why', 'self-grant'));
      RAISE_APPLICATION_ERROR(-20403, 'Administrators cannot change their own roles');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    BEGIN
      SELECT role_id INTO l_role FROM lms_roles WHERE role_code = p_role_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Unknown role');
    END;
    MERGE INTO lms_user_roles t
    USING (SELECT p_user_id user_id, l_role role_id FROM dual) s
       ON (t.user_id = s.user_id AND t.role_id = s.role_id)
     WHEN NOT MATCHED THEN INSERT (user_id, role_id, granted_by) VALUES (s.user_id, s.role_id, l_actor);
    lms_audit_pkg.log_event('ROLE_GRANT', 'USER', p_user_id, 'SUCCESS', lms_util_pkg.js('role', p_role_code));
  END grant_role;

  PROCEDURE revoke_role(p_user_id IN NUMBER, p_role_code IN VARCHAR2) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
  BEGIN
    lms_security_pkg.require_permission('ROLE_ADMIN');
    IF p_user_id = l_actor THEN
      RAISE_APPLICATION_ERROR(-20403, 'Administrators cannot change their own roles');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    DELETE FROM lms_user_roles
     WHERE user_id = p_user_id AND role_id = (SELECT role_id FROM lms_roles WHERE role_code = p_role_code);
    lms_audit_pkg.log_event('ROLE_REVOKE', 'USER', p_user_id, 'SUCCESS', lms_util_pkg.js('role', p_role_code));
  END revoke_role;

  PROCEDURE set_status(p_user_id IN NUMBER, p_status IN VARCHAR2) IS
    l_actor NUMBER := lms_security_pkg.current_user_id;
  BEGIN
    lms_security_pkg.require_permission('USER_ADMIN');
    IF p_status NOT IN ('ACTIVE','INACTIVE','LOCKED') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid status');
    END IF;
    IF p_user_id = l_actor AND p_status <> 'ACTIVE' THEN
      RAISE_APPLICATION_ERROR(-20403, 'You cannot deactivate your own account');
    END IF;
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_actor);
    UPDATE lms_users SET status = p_status, updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE user_id = p_user_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'User not found'); END IF;
    lms_audit_pkg.log_event('USER_STATUS', 'USER', p_user_id, 'SUCCESS', lms_util_pkg.js('status', p_status));
  END set_status;

  PROCEDURE set_manager(p_user_id IN NUMBER, p_manager_user_id IN NUMBER) IS
  BEGIN
    lms_security_pkg.require_permission('USER_ADMIN');
    IF would_cycle(p_user_id, p_manager_user_id) THEN
      RAISE_APPLICATION_ERROR(-20409, 'Manager assignment would create a reporting loop');
    END IF;
    UPDATE lms_users SET manager_user_id = p_manager_user_id, updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE user_id = p_user_id;
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'User not found'); END IF;
    lms_audit_pkg.log_event('USER_MANAGER', 'USER', p_user_id, 'SUCCESS', lms_util_pkg.js('manager', p_manager_user_id));
  END set_manager;

  PROCEDURE set_language(p_lang IN VARCHAR2) IS
  BEGIN
    IF p_lang NOT IN ('en','ar') THEN RAISE_APPLICATION_ERROR(-20400, 'Unsupported language'); END IF;
    UPDATE lms_users SET preferred_lang = p_lang, updated_at = SYSTIMESTAMP
     WHERE user_id = lms_security_pkg.current_user_id;
  END set_language;
END lms_user_pkg;
/

-- ------------------------------------------------------------- HR SYNC -------
CREATE OR REPLACE PACKAGE BODY lms_hr_sync_pkg AS
  PROCEDURE upsert_employee(p_username IN VARCHAR2, p_employee_no IN VARCHAR2,
                            p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2, p_email IN VARCHAR2,
                            p_department_code IN VARCHAR2, p_position_code IN VARCHAR2,
                            p_manager_employee_no IN VARCHAR2, p_status IN VARCHAR2 DEFAULT 'ACTIVE') IS
    l_user   VARCHAR2(100) := UPPER(TRIM(p_username));
    l_dept   NUMBER;
    l_pos    NUMBER;
    l_mgr    NUMBER;
    l_id     NUMBER;
  BEGIN
    IF l_user IS NULL OR p_employee_no IS NULL OR p_name_en IS NULL OR p_email IS NULL THEN
      RAISE_APPLICATION_ERROR(-20400, 'username, employee_no, name_en and email are required');
    END IF;
    IF p_status NOT IN ('ACTIVE','INACTIVE') THEN
      RAISE_APPLICATION_ERROR(-20400, 'HR status must be ACTIVE or INACTIVE');
    END IF;
    BEGIN SELECT department_id INTO l_dept FROM lms_departments WHERE department_code = p_department_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN l_dept := NULL; END;
    BEGIN SELECT position_id INTO l_pos FROM lms_positions WHERE position_code = p_position_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN l_pos := NULL; END;
    BEGIN SELECT user_id INTO l_mgr FROM lms_users WHERE employee_no = p_manager_employee_no;
    EXCEPTION WHEN NO_DATA_FOUND THEN l_mgr := NULL; END;

    MERGE INTO lms_users t
    USING (SELECT l_user username, p_employee_no employee_no FROM dual) s
       ON (t.employee_no = s.employee_no)
     WHEN MATCHED THEN UPDATE SET
          t.username = s.username, t.full_name_en = p_name_en, t.full_name_ar = p_name_ar, t.email = p_email,
          t.department_id = l_dept, t.position_id = l_pos,
          t.status = CASE WHEN t.status = 'LOCKED' AND p_status = 'ACTIVE' THEN 'LOCKED' ELSE p_status END,
          t.updated_at = SYSTIMESTAMP, t.row_version = t.row_version + 1
     WHEN NOT MATCHED THEN INSERT (username, employee_no, full_name_en, full_name_ar, email, department_id, position_id, status)
          VALUES (s.username, s.employee_no, p_name_en, p_name_ar, p_email, l_dept, l_pos, p_status);

    SELECT user_id INTO l_id FROM lms_users WHERE employee_no = p_employee_no;
    IF l_mgr IS NOT NULL THEN
      IF lms_user_pkg.would_cycle(l_id, l_mgr) THEN
        lms_audit_pkg.log_security('HR_SYNC_CYCLE', l_id, NULL, 'HR_SYNC', 'WARN', 'manager loop rejected');
      ELSE
        UPDATE lms_users SET manager_user_id = l_mgr WHERE user_id = l_id;
      END IF;
    END IF;
    lms_audit_pkg.log_event('HR_SYNC', 'USER', l_id);
  END upsert_employee;
END lms_hr_sync_pkg;
/

-- -------------------------------------------------------------- COURSE -------
CREATE OR REPLACE PACKAGE BODY lms_course_pkg AS

  FUNCTION can_manage_course(p_course_id IN NUMBER, p_permission IN VARCHAR2) RETURN BOOLEAN IS
    l_scope VARCHAR2(10) := lms_security_pkg.permission_scope(p_permission);
    l_user  NUMBER := lms_security_pkg.current_user_id_safe;
    l_n     NUMBER;
  BEGIN
    IF l_scope = 'ALL' THEN RETURN TRUE; END IF;
    IF l_scope IS NULL OR l_user IS NULL THEN RETURN FALSE; END IF;
    SELECT COUNT(*) INTO l_n FROM lms_courses c
     WHERE c.course_id = p_course_id
       AND (c.created_by = l_user
            OR EXISTS (SELECT 1 FROM lms_course_instructors ci WHERE ci.course_id = c.course_id AND ci.user_id = l_user));
    RETURN l_n > 0;
  END can_manage_course;

  PROCEDURE assert_manage(p_course_id IN NUMBER, p_permission IN VARCHAR2 DEFAULT 'COURSE_AUTHOR') IS
  BEGIN
    IF NOT can_manage_course(p_course_id, p_permission) THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'COURSE', p_course_id, 'DENIED', lms_util_pkg.js('permission', p_permission));
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END assert_manage;

  FUNCTION create_course(p_course_code IN VARCHAR2, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2,
                         p_category_id IN NUMBER, p_delivery_method IN VARCHAR2,
                         p_difficulty IN VARCHAR2 DEFAULT 'BEGINNER', p_duration_minutes IN NUMBER DEFAULT 0,
                         p_language_code IN VARCHAR2 DEFAULT 'en', p_capacity IN NUMBER DEFAULT NULL,
                         p_approval_required IN VARCHAR2 DEFAULT 'N',
                         p_completion_rule IN VARCHAR2 DEFAULT 'LESSONS',
                         p_certificate_eligible IN VARCHAR2 DEFAULT 'N') RETURN NUMBER IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_id   NUMBER;
  BEGIN
    lms_security_pkg.require_permission('COURSE_AUTHOR');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE', l_user);
    INSERT INTO lms_courses (course_code, title_en, title_ar, category_id, delivery_method, difficulty,
                             duration_minutes, language_code, capacity, approval_required, completion_rule,
                             certificate_eligible, created_by)
    VALUES (UPPER(TRIM(p_course_code)), p_title_en, p_title_ar, p_category_id, p_delivery_method, p_difficulty,
            p_duration_minutes, p_language_code, p_capacity, p_approval_required, p_completion_rule,
            p_certificate_eligible, l_user)
    RETURNING course_id INTO l_id;
    IF lms_security_pkg.permission_scope('COURSE_AUTHOR') = 'ASSIGNED' THEN
      INSERT INTO lms_course_instructors (course_id, user_id, instructor_role) VALUES (l_id, l_user, 'LEAD');
    END IF;
    lms_audit_pkg.log_event('COURSE_CREATE', 'COURSE', l_id);
    RETURN l_id;
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN
    RAISE_APPLICATION_ERROR(-20409, 'Course code already exists');
  END create_course;

  PROCEDURE update_course(p_course_id IN NUMBER, p_row_version IN NUMBER,
                          p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2, p_category_id IN NUMBER,
                          p_difficulty IN VARCHAR2, p_duration_minutes IN NUMBER, p_capacity IN NUMBER,
                          p_approval_required IN VARCHAR2, p_completion_rule IN VARCHAR2,
                          p_certificate_eligible IN VARCHAR2,
                          p_available_from IN DATE DEFAULT NULL, p_available_to IN DATE DEFAULT NULL,
                          p_enroll_deadline IN DATE DEFAULT NULL) IS
    l_status lms_courses.status%TYPE;
  BEGIN
    assert_manage(p_course_id);
    BEGIN
      SELECT status INTO l_status FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;
    IF l_status NOT IN ('DRAFT','SUSPENDED') THEN
      RAISE_APPLICATION_ERROR(-20409, 'Only DRAFT or SUSPENDED courses can be edited');
    END IF;
    UPDATE lms_courses
       SET title_en = p_title_en, title_ar = p_title_ar, category_id = p_category_id, difficulty = p_difficulty,
           duration_minutes = p_duration_minutes, capacity = p_capacity, approval_required = p_approval_required,
           completion_rule = p_completion_rule, certificate_eligible = p_certificate_eligible,
           available_from = p_available_from, available_to = p_available_to, enroll_deadline = p_enroll_deadline,
           updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id AND row_version = p_row_version;
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20409, 'The course was changed by another user. Reload and retry.');
    END IF;
    lms_audit_pkg.log_event('COURSE_UPDATE', 'COURSE', p_course_id);
  END update_course;

  FUNCTION add_module(p_course_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER; l_ord NUMBER;
  BEGIN
    assert_manage(p_course_id);
    SELECT NVL(MAX(sort_order), 0) + 1 INTO l_ord FROM lms_modules WHERE course_id = p_course_id;
    INSERT INTO lms_modules (course_id, title_en, title_ar, sort_order)
    VALUES (p_course_id, p_title_en, p_title_ar, l_ord) RETURNING module_id INTO l_id;
    RETURN l_id;
  END add_module;

  FUNCTION add_lesson(p_module_id IN NUMBER, p_title_en IN VARCHAR2, p_lesson_type IN VARCHAR2,
                      p_title_ar IN VARCHAR2 DEFAULT NULL, p_content_ref IN VARCHAR2 DEFAULT NULL,
                      p_duration_minutes IN NUMBER DEFAULT 0, p_required_flag IN VARCHAR2 DEFAULT 'Y',
                      p_prereq_lesson_id IN NUMBER DEFAULT NULL) RETURN NUMBER IS
    l_course NUMBER; l_id NUMBER; l_ord NUMBER;
  BEGIN
    BEGIN SELECT course_id INTO l_course FROM lms_modules WHERE module_id = p_module_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Module not found'); END;
    assert_manage(l_course);
    IF p_prereq_lesson_id IS NOT NULL THEN
      DECLARE l_n NUMBER; BEGIN
        SELECT COUNT(*) INTO l_n FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
         WHERE l.lesson_id = p_prereq_lesson_id AND m.course_id = l_course;
        IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20400, 'Prerequisite lesson must belong to the same course'); END IF;
      END;
    END IF;
    SELECT NVL(MAX(sort_order), 0) + 1 INTO l_ord FROM lms_lessons WHERE module_id = p_module_id;
    INSERT INTO lms_lessons (module_id, title_en, title_ar, lesson_type, content_ref, duration_minutes,
                             required_flag, prereq_lesson_id, sort_order)
    VALUES (p_module_id, p_title_en, p_title_ar, p_lesson_type, p_content_ref, p_duration_minutes,
            p_required_flag, p_prereq_lesson_id, l_ord) RETURNING lesson_id INTO l_id;
    RETURN l_id;
  END add_lesson;

  PROCEDURE add_prerequisite(p_course_id IN NUMBER, p_prereq_course_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    assert_manage(p_course_id);
    IF p_course_id = p_prereq_course_id THEN RAISE_APPLICATION_ERROR(-20400, 'A course cannot require itself'); END IF;
    -- cycle: starting at the prerequisite and following ITS prerequisites must never reach p_course_id
    SELECT COUNT(*) INTO l_n FROM lms_course_prerequisites
     WHERE prereq_course_id = p_course_id
     START WITH course_id = p_prereq_course_id
     CONNECT BY NOCYCLE PRIOR prereq_course_id = course_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Prerequisite would create a cycle'); END IF;
    INSERT INTO lms_course_prerequisites (course_id, prereq_course_id) VALUES (p_course_id, p_prereq_course_id);
    lms_audit_pkg.log_event('COURSE_PREREQ', 'COURSE', p_course_id);
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN NULL;   -- already linked: idempotent
  END add_prerequisite;

  PROCEDURE set_instructor(p_course_id IN NUMBER, p_user_id IN NUMBER, p_role IN VARCHAR2 DEFAULT 'LEAD') IS
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');   -- assigning instructors is an admin act
    MERGE INTO lms_course_instructors t
    USING (SELECT p_course_id course_id, p_user_id user_id FROM dual) s
       ON (t.course_id = s.course_id AND t.user_id = s.user_id)
     WHEN MATCHED THEN UPDATE SET instructor_role = p_role
     WHEN NOT MATCHED THEN INSERT (course_id, user_id, instructor_role) VALUES (s.course_id, s.user_id, p_role);
    lms_audit_pkg.log_event('COURSE_INSTRUCTOR', 'COURSE', p_course_id, 'SUCCESS', lms_util_pkg.js('user', p_user_id));
  END set_instructor;

  PROCEDURE set_certificate_template(p_course_id IN NUMBER, p_template_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    assert_editable(p_course_id);
    IF p_template_id IS NOT NULL THEN
      SELECT COUNT(*) INTO l_n FROM lms_certificate_templates WHERE template_id = p_template_id AND active_flag = 'Y';
      IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Certificate template not found'); END IF;
    END IF;
    UPDATE lms_courses SET certificate_template_id = p_template_id, updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id;
    lms_audit_pkg.log_event('COURSE_CERT_TEMPLATE', 'COURSE', p_course_id);
  END set_certificate_template;

  FUNCTION validate_publishable(p_course_id IN NUMBER) RETURN VARCHAR2 IS
    c lms_courses%ROWTYPE;
    l_n NUMBER;
    l_msg VARCHAR2(400);
  BEGIN
    BEGIN SELECT * INTO c FROM lms_courses WHERE course_id = p_course_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN 'Course not found'; END;
    SELECT COUNT(*) INTO l_n FROM lms_modules WHERE course_id = p_course_id;
    IF l_n = 0 AND c.completion_rule NOT IN ('ATTENDANCE') THEN RETURN 'Add at least one module'; END IF;
    SELECT COUNT(*) INTO l_n FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
     WHERE m.course_id = p_course_id AND l.required_flag = 'Y';
    IF l_n = 0 AND c.completion_rule IN ('LESSONS','LESSONS_ASSESSMENT','LESSONS_ATTENDANCE','INSTRUCTOR_APPROVAL') THEN
      RETURN 'Add at least one required lesson';
    END IF;
    IF c.completion_rule = 'LESSONS_ASSESSMENT' OR c.pass_score_required = 'Y' THEN
      SELECT COUNT(*) INTO l_n FROM lms_quizzes WHERE course_id = p_course_id AND required_flag = 'Y' AND active_flag = 'Y';
      IF l_n = 0 THEN RETURN 'The completion rule requires at least one required quiz'; END IF;
      SELECT COUNT(*) INTO l_n FROM lms_quizzes z WHERE z.course_id = p_course_id AND z.active_flag = 'Y'
         AND NOT EXISTS (SELECT 1 FROM lms_quiz_questions qq WHERE qq.quiz_id = z.quiz_id);
      IF l_n > 0 THEN RETURN 'A quiz has no questions'; END IF;
    END IF;
    FOR z IN (SELECT quiz_id FROM lms_quizzes WHERE course_id = p_course_id AND active_flag = 'Y') LOOP
      l_msg := lms_assessment_pkg.validate_quiz(z.quiz_id);
      IF l_msg IS NOT NULL THEN RETURN l_msg; END IF;
    END LOOP;
    IF c.completion_rule IN ('ATTENDANCE','LESSONS_ATTENDANCE') AND c.delivery_method = 'SELF_PACED' THEN
      RETURN 'Attendance rules need a classroom, virtual or blended delivery method';
    END IF;
    IF c.certificate_eligible = 'Y' AND c.certificate_template_id IS NULL
       AND lms_util_pkg.get_setting('DEFAULT_CERT_TEMPLATE') IS NULL THEN
      RETURN 'Select a certificate template';
    END IF;
    RETURN NULL;
  END validate_publishable;

  PROCEDURE submit_for_review(p_course_id IN NUMBER) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_msg  VARCHAR2(400);
    l_status lms_courses.status%TYPE;
  BEGIN
    assert_manage(p_course_id);
    BEGIN SELECT status INTO l_status FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;
    IF l_status <> 'DRAFT' THEN RAISE_APPLICATION_ERROR(-20409, 'Only DRAFT courses can be submitted'); END IF;
    l_msg := validate_publishable(p_course_id);
    IF l_msg IS NOT NULL THEN RAISE_APPLICATION_ERROR(-20409, l_msg); END IF;
    UPDATE lms_courses SET status = 'UNDER_REVIEW', updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id;
    lms_approval_pkg.request_course_publish(p_course_id, l_user);
    lms_audit_pkg.log_event('COURSE_SUBMIT', 'COURSE', p_course_id);
  END submit_for_review;

  FUNCTION snapshot_json(p_course_id IN NUMBER) RETURN CLOB IS
    l_json CLOB;
  BEGIN
    SELECT JSON_OBJECT(
             'code' VALUE c.course_code, 'title_en' VALUE c.title_en, 'title_ar' VALUE c.title_ar,
             'rule' VALUE c.completion_rule, 'duration' VALUE c.duration_minutes,
             'modules' VALUE (
               SELECT JSON_ARRAYAGG(
                        JSON_OBJECT('id' VALUE m.module_id, 'title' VALUE m.title_en,
                          'lessons' VALUE (
                            SELECT JSON_ARRAYAGG(
                                     JSON_OBJECT('id' VALUE l.lesson_id, 'title' VALUE l.title_en,
                                                 'type' VALUE l.lesson_type, 'required' VALUE l.required_flag)
                                     ORDER BY l.sort_order RETURNING CLOB)
                              FROM lms_lessons l WHERE l.module_id = m.module_id) FORMAT JSON)
                        ORDER BY m.sort_order RETURNING CLOB)
                 FROM lms_modules m WHERE m.course_id = c.course_id) FORMAT JSON
             RETURNING CLOB)
      INTO l_json
      FROM lms_courses c WHERE c.course_id = p_course_id;
    RETURN l_json;
  END snapshot_json;

  PROCEDURE apply_review(p_course_id IN NUMBER, p_approved IN BOOLEAN, p_note IN VARCHAR2 DEFAULT NULL) IS
    c lms_courses%ROWTYPE;
    l_ver NUMBER;
  BEGIN
    SELECT * INTO c FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    IF c.status <> 'UNDER_REVIEW' THEN RAISE_APPLICATION_ERROR(-20409, 'Course is not under review'); END IF;
    IF p_approved THEN
      SELECT NVL(MAX(version_no), 0) + 1 INTO l_ver FROM lms_course_versions WHERE course_id = p_course_id;
      INSERT INTO lms_course_versions (course_id, version_no, snapshot, published_by)
      VALUES (p_course_id, l_ver, snapshot_json(p_course_id), lms_security_pkg.current_user_id);
      UPDATE lms_courses SET status = 'PUBLISHED', published_at = SYSTIMESTAMP, updated_at = SYSTIMESTAMP,
             row_version = row_version + 1 WHERE course_id = p_course_id;
      lms_audit_pkg.log_event('COURSE_PUBLISH', 'COURSE', p_course_id, 'SUCCESS', lms_util_pkg.js('version', l_ver));
      lms_notification_pkg.enqueue(c.created_by, 'COURSE_APPROVED', lms_util_pkg.js('course', c.title_en));
    ELSE
      UPDATE lms_courses SET status = 'DRAFT', updated_at = SYSTIMESTAMP, row_version = row_version + 1
       WHERE course_id = p_course_id;
      lms_audit_pkg.log_event('COURSE_REJECT', 'COURSE', p_course_id);
      lms_notification_pkg.enqueue(c.created_by, 'COURSE_REJECTED',
        lms_util_pkg.js('course', c.title_en, 'note', NVL(p_note, '-')));
    END IF;
  END apply_review;

  -- Author-side guard: caller may manage the course AND the course is editable (DRAFT/SUSPENDED). Locks the row.
  PROCEDURE assert_editable(p_course_id IN NUMBER) IS
    l_status lms_courses.status%TYPE;
  BEGIN
    assert_manage(p_course_id);
    BEGIN SELECT status INTO l_status FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;
    IF l_status NOT IN ('DRAFT','SUSPENDED') THEN
      RAISE_APPLICATION_ERROR(-20409, 'Only DRAFT or SUSPENDED courses can be edited');
    END IF;
  END assert_editable;

  PROCEDURE set_course_text(p_course_id IN NUMBER, p_row_version IN NUMBER,
                            p_description_en IN CLOB, p_description_ar IN CLOB,
                            p_objectives_en IN VARCHAR2, p_objectives_ar IN VARCHAR2, p_thumbnail_ref IN VARCHAR2) IS
  BEGIN
    assert_editable(p_course_id);
    IF p_thumbnail_ref IS NOT NULL AND NOT REGEXP_LIKE(p_thumbnail_ref, '^[A-Za-z0-9/_.-]{1,500}$') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Thumbnail must be an object-store key, not a URL');
    END IF;
    UPDATE lms_courses
       SET description_en = p_description_en, description_ar = p_description_ar,
           objectives_en = p_objectives_en, objectives_ar = p_objectives_ar, thumbnail_ref = p_thumbnail_ref,
           updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id AND row_version = p_row_version;
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20409, 'The course was changed by another user. Reload and retry.');
    END IF;
    lms_audit_pkg.log_event('COURSE_TEXT', 'COURSE', p_course_id);
  END set_course_text;

  PROCEDURE set_lesson_content(p_lesson_id IN NUMBER, p_content_ref IN VARCHAR2, p_content_text IN VARCHAR2) IS
    l_course NUMBER; l_type lms_lessons.lesson_type%TYPE; l_text VARCHAR2(32767); l_ver NUMBER;
  BEGIN
    BEGIN
      SELECT m.course_id, l.lesson_type INTO l_course, l_type
        FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE l.lesson_id = p_lesson_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not found'); END;
    assert_editable(l_course);
    IF p_content_ref IS NOT NULL THEN
      IF l_type = 'URL' AND NOT REGEXP_LIKE(p_content_ref, '^https://[^[:space:]]{1,980}$', 'i') THEN
        RAISE_APPLICATION_ERROR(-20400, 'External links must start with https://');
      ELSIF l_type <> 'URL' AND NOT (REGEXP_LIKE(p_content_ref, '^[A-Za-z0-9/_.-]{1,1000}$')
                                     OR REGEXP_LIKE(p_content_ref, '^https://[^[:space:]]{1,980}$', 'i')) THEN
        RAISE_APPLICATION_ERROR(-20400, 'Content reference must be an object-store key or an https link');
      END IF;
    END IF;
    l_text := p_content_text;
    IF l_type = 'HTML' AND l_text IS NOT NULL THEN
      -- tags without attributes only: no links, images, styles or event handlers can survive
      l_text := apex_escape.html_whitelist(l_text,
        '<p>,<br>,<b>,<strong>,<i>,<em>,<u>,<ul>,<ol>,<li>,<h2>,<h3>,<h4>,<table>,<thead>,<tbody>,<tr>,<th>,<td>');
    END IF;
    SELECT NVL(MAX(version_no), 0) + 1 INTO l_ver FROM lms_content_versions WHERE lesson_id = p_lesson_id;
    INSERT INTO lms_content_versions (lesson_id, version_no, content_ref, content_text, created_by)
    VALUES (p_lesson_id, l_ver, p_content_ref, l_text, lms_security_pkg.current_user_id);
    UPDATE lms_lessons SET content_ref = p_content_ref, content_text = l_text WHERE lesson_id = p_lesson_id;
    lms_audit_pkg.log_event('LESSON_CONTENT', 'LESSON', p_lesson_id, 'SUCCESS', lms_util_pkg.js('version', l_ver));
  END set_lesson_content;

  PROCEDURE update_module(p_module_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2) IS
    l_course NUMBER;
  BEGIN
    BEGIN SELECT course_id INTO l_course FROM lms_modules WHERE module_id = p_module_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Module not found'); END;
    assert_editable(l_course);
    IF p_title_en IS NULL OR LENGTH(TRIM(p_title_en)) = 0 THEN RAISE_APPLICATION_ERROR(-20400, 'A module title is required'); END IF;
    UPDATE lms_modules SET title_en = p_title_en, title_ar = p_title_ar WHERE module_id = p_module_id;
  END update_module;

  PROCEDURE update_lesson(p_lesson_id IN NUMBER, p_title_en IN VARCHAR2, p_title_ar IN VARCHAR2,
                          p_lesson_type IN VARCHAR2, p_duration_minutes IN NUMBER, p_required_flag IN VARCHAR2,
                          p_prereq_lesson_id IN NUMBER, p_available_from IN DATE DEFAULT NULL) IS
    l_course NUMBER; l_n NUMBER;
  BEGIN
    BEGIN
      SELECT m.course_id INTO l_course FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE l.lesson_id = p_lesson_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not found'); END;
    assert_editable(l_course);
    IF p_title_en IS NULL OR LENGTH(TRIM(p_title_en)) = 0 THEN RAISE_APPLICATION_ERROR(-20400, 'A lesson title is required'); END IF;
    IF p_prereq_lesson_id IS NOT NULL THEN
      IF p_prereq_lesson_id = p_lesson_id THEN RAISE_APPLICATION_ERROR(-20400, 'A lesson cannot require itself'); END IF;
      SELECT COUNT(*) INTO l_n FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id
       WHERE l.lesson_id = p_prereq_lesson_id AND m.course_id = l_course;
      IF l_n = 0 THEN RAISE_APPLICATION_ERROR(-20400, 'Prerequisite lesson must belong to the same course'); END IF;
      -- loop check: following the prerequisite chain from the proposed prerequisite must not reach this lesson
      SELECT COUNT(*) INTO l_n FROM lms_lessons
       WHERE lesson_id = p_lesson_id
       START WITH lesson_id = p_prereq_lesson_id
       CONNECT BY NOCYCLE lesson_id = PRIOR prereq_lesson_id
       AND PRIOR prereq_lesson_id IS NOT NULL;
      IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Prerequisite would create a loop'); END IF;
    END IF;
    UPDATE lms_lessons
       SET title_en = p_title_en, title_ar = p_title_ar, lesson_type = p_lesson_type, duration_minutes = NVL(p_duration_minutes, 0),
           required_flag = p_required_flag, prereq_lesson_id = p_prereq_lesson_id, available_from = p_available_from
     WHERE lesson_id = p_lesson_id;
  END update_lesson;

  PROCEDURE add_lesson_file(p_lesson_id IN NUMBER, p_file_name IN VARCHAR2, p_mime_type IN VARCHAR2, p_blob IN BLOB) IS
    c_max CONSTANT NUMBER := 26214400;
    l_course NUMBER; l_size NUMBER; l_magic VARCHAR2(8); l_id NUMBER; l_ok BOOLEAN; l_name VARCHAR2(255); l_ver NUMBER;
  BEGIN
    BEGIN
      SELECT m.course_id INTO l_course FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE l.lesson_id = p_lesson_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not found'); END;
    assert_editable(l_course);
    l_size := NVL(DBMS_LOB.getlength(p_blob), 0);
    IF l_size = 0 OR l_size > c_max THEN RAISE_APPLICATION_ERROR(-20400, 'File must be between 1 byte and 25 MB'); END IF;
    l_magic := RAWTOHEX(DBMS_LOB.substr(p_blob, 4, 1));
    l_ok := CASE p_mime_type
              WHEN 'application/pdf' THEN l_magic LIKE '25504446%'
              WHEN 'application/vnd.openxmlformats-officedocument.presentationml.presentation' THEN l_magic LIKE '504B0304%'
              WHEN 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' THEN l_magic LIKE '504B0304%'
              WHEN 'image/png' THEN l_magic LIKE '89504E47%'
              WHEN 'image/jpeg' THEN l_magic LIKE 'FFD8FF%'
              ELSE FALSE END;
    IF NOT l_ok THEN RAISE_APPLICATION_ERROR(-20400, 'File type is not allowed or the content does not match its type'); END IF;
    l_name := SUBSTR(REGEXP_REPLACE(NVL(p_file_name, 'file'), '[^A-Za-z0-9._-]', '_'), 1, 255);
    INSERT INTO lms_lesson_content (lesson_id, storage_type, file_name, mime_type, file_size, checksum_sha256, file_blob, uploaded_by)
    VALUES (p_lesson_id, 'BLOB', l_name, p_mime_type, l_size,
            LOWER(RAWTOHEX(DBMS_CRYPTO.hash(p_blob, DBMS_CRYPTO.hash_sh256))), p_blob, lms_security_pkg.current_user_id)
    RETURNING content_id INTO l_id;
    SELECT NVL(MAX(version_no), 0) + 1 INTO l_ver FROM lms_content_versions WHERE lesson_id = p_lesson_id;
    INSERT INTO lms_content_versions (lesson_id, version_no, content_ref, created_by)
    VALUES (p_lesson_id, l_ver, 'blob:' || l_id, lms_security_pkg.current_user_id);
    UPDATE lms_lessons SET content_ref = 'blob:' || l_id WHERE lesson_id = p_lesson_id;
    lms_audit_pkg.log_event('LESSON_FILE', 'LESSON', p_lesson_id, 'SUCCESS', lms_util_pkg.js('bytes', l_size, 'mime', p_mime_type));
  END add_lesson_file;

  PROCEDURE move_module(p_module_id IN NUMBER, p_direction IN VARCHAR2) IS
    l_course NUMBER; l_ord NUMBER; l_nb NUMBER; l_nb_ord NUMBER;
  BEGIN
    IF p_direction NOT IN ('UP','DOWN') THEN RAISE_APPLICATION_ERROR(-20400, 'Direction must be UP or DOWN'); END IF;
    BEGIN SELECT course_id, sort_order INTO l_course, l_ord FROM lms_modules WHERE module_id = p_module_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Module not found'); END;
    assert_editable(l_course);
    BEGIN
      SELECT module_id, sort_order INTO l_nb, l_nb_ord FROM (
        SELECT module_id, sort_order FROM lms_modules
         WHERE course_id = l_course
           AND ((p_direction = 'UP' AND sort_order < l_ord) OR (p_direction = 'DOWN' AND sort_order > l_ord))
         ORDER BY CASE WHEN p_direction = 'UP' THEN -sort_order ELSE sort_order END)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN; END;          -- already first/last
    -- three-step swap through a negative value keeps UNIQUE (course_id, sort_order) satisfied
    UPDATE lms_modules SET sort_order = -l_ord WHERE module_id = p_module_id;
    UPDATE lms_modules SET sort_order = l_ord WHERE module_id = l_nb;
    UPDATE lms_modules SET sort_order = l_nb_ord WHERE module_id = p_module_id;
  END move_module;

  PROCEDURE move_lesson(p_lesson_id IN NUMBER, p_direction IN VARCHAR2) IS
    l_course NUMBER; l_mod NUMBER; l_ord NUMBER; l_nb NUMBER; l_nb_ord NUMBER;
  BEGIN
    IF p_direction NOT IN ('UP','DOWN') THEN RAISE_APPLICATION_ERROR(-20400, 'Direction must be UP or DOWN'); END IF;
    BEGIN
      SELECT m.course_id, l.module_id, l.sort_order INTO l_course, l_mod, l_ord
        FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE l.lesson_id = p_lesson_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not found'); END;
    assert_editable(l_course);
    BEGIN
      SELECT lesson_id, sort_order INTO l_nb, l_nb_ord FROM (
        SELECT lesson_id, sort_order FROM lms_lessons
         WHERE module_id = l_mod
           AND ((p_direction = 'UP' AND sort_order < l_ord) OR (p_direction = 'DOWN' AND sort_order > l_ord))
         ORDER BY CASE WHEN p_direction = 'UP' THEN -sort_order ELSE sort_order END)
       WHERE ROWNUM = 1;
    EXCEPTION WHEN NO_DATA_FOUND THEN RETURN; END;
    UPDATE lms_lessons SET sort_order = -l_ord WHERE lesson_id = p_lesson_id;
    UPDATE lms_lessons SET sort_order = l_ord WHERE lesson_id = l_nb;
    UPDATE lms_lessons SET sort_order = l_nb_ord WHERE lesson_id = p_lesson_id;
  END move_lesson;

  PROCEDURE remove_module(p_module_id IN NUMBER) IS
    l_course NUMBER; l_n NUMBER;
  BEGIN
    BEGIN SELECT course_id INTO l_course FROM lms_modules WHERE module_id = p_module_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Module not found'); END;
    assert_editable(l_course);
    SELECT COUNT(*) INTO l_n FROM lms_lessons WHERE module_id = p_module_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Remove the lessons of this module first'); END IF;
    DELETE FROM lms_modules WHERE module_id = p_module_id;
    lms_audit_pkg.log_event('MODULE_REMOVE', 'MODULE', p_module_id);
  END remove_module;

  PROCEDURE remove_lesson(p_lesson_id IN NUMBER) IS
    l_course NUMBER; l_n NUMBER;
  BEGIN
    BEGIN
      SELECT m.course_id INTO l_course FROM lms_lessons l JOIN lms_modules m ON m.module_id = l.module_id WHERE l.lesson_id = p_lesson_id;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Lesson not found'); END;
    assert_editable(l_course);
    SELECT COUNT(*) INTO l_n FROM lms_lesson_progress WHERE lesson_id = p_lesson_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Learners already have progress on this lesson'); END IF;
    SELECT COUNT(*) INTO l_n FROM lms_lessons WHERE prereq_lesson_id = p_lesson_id;
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Another lesson requires this lesson first'); END IF;
    DELETE FROM lms_content_versions WHERE lesson_id = p_lesson_id;
    DELETE FROM lms_lesson_content WHERE lesson_id = p_lesson_id;
    DELETE FROM lms_lessons WHERE lesson_id = p_lesson_id;
    lms_audit_pkg.log_event('LESSON_REMOVE', 'LESSON', p_lesson_id);
  END remove_lesson;

  PROCEDURE change_status(p_course_id IN NUMBER, p_from IN VARCHAR2, p_to IN VARCHAR2, p_op IN VARCHAR2) IS
    l_status lms_courses.status%TYPE;
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    BEGIN SELECT status INTO l_status FROM lms_courses WHERE course_id = p_course_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Course not found'); END;
    IF l_status <> p_from THEN
      RAISE_APPLICATION_ERROR(-20409, 'Course must be ' || p_from || ' (is ' || l_status || ')');
    END IF;
    UPDATE lms_courses SET status = p_to, updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id;
    lms_audit_pkg.log_event(p_op, 'COURSE', p_course_id);
  END change_status;

  PROCEDURE suspend(p_course_id IN NUMBER)   IS BEGIN change_status(p_course_id, 'PUBLISHED', 'SUSPENDED', 'COURSE_SUSPEND'); END;
  PROCEDURE reinstate(p_course_id IN NUMBER) IS BEGIN change_status(p_course_id, 'SUSPENDED', 'PUBLISHED', 'COURSE_REINSTATE'); END;

  PROCEDURE archive(p_course_id IN NUMBER) IS
    l_n NUMBER;
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    SELECT COUNT(*) INTO l_n FROM lms_enrollments
     WHERE course_id = p_course_id AND status IN ('PENDING','APPROVED','ENROLLED','IN_PROGRESS','WAITLISTED');
    IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Course still has open enrolments'); END IF;
    UPDATE lms_courses SET status = 'ARCHIVED', updated_at = SYSTIMESTAMP, row_version = row_version + 1
     WHERE course_id = p_course_id AND status IN ('PUBLISHED','SUSPENDED','DRAFT');
    IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20409, 'Course cannot be archived in its current status'); END IF;
    lms_audit_pkg.log_event('COURSE_ARCHIVE', 'COURSE', p_course_id);
  END archive;
END lms_course_pkg;
/
