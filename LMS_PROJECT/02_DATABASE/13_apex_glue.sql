-- =============================================================================
-- APEX glue + administration packages | Oracle 19c / APEX 24.1
-- STATUS: written, NOT compiled. Requires 01-09.
--   LMS_SECRET_PKG  - environment-specific secret STUB (real body deployed by DevOps, never committed)
--   LMS_APEX_PKG    - authorization-scheme functions, post-authentication, error handler,
--                     Ajax callbacks, guarded content URLs, soft rate limit for pages
--   LMS_ADMIN_PKG   - audited administration writes (settings, rate limits, role matrix, templates)
-- =============================================================================

-- ------------------------------------------------------------------ SECRET -----
CREATE OR REPLACE PACKAGE lms_secret_pkg AS
  /* HMAC key for signed content URLs. The repository ships a STUB that fails closed.
     DevOps replaces the BODY per environment with a key read from a wallet/vault.
     Never store the key in LMS_SYSTEM_SETTINGS or in source control. */
  FUNCTION content_signing_key RETURN RAW;
END lms_secret_pkg;
/
CREATE OR REPLACE PACKAGE BODY lms_secret_pkg AS
  FUNCTION content_signing_key RETURN RAW IS
  BEGIN
    RAISE_APPLICATION_ERROR(-20500, 'Content signing key is not configured for this environment');
  END content_signing_key;
END lms_secret_pkg;
/

-- -------------------------------------------------------------------- APEX -----
CREATE OR REPLACE PACKAGE lms_apex_pkg AS
  -- ---- Authorization scheme functions (Shared Components > Authorization Schemes) ----
  FUNCTION is_active_user RETURN BOOLEAN;                         -- app-level scheme LMS_AUTH_ACTIVE
  FUNCTION has_perm(p_code IN VARCHAR2) RETURN BOOLEAN;
  FUNCTION has_scope(p_code IN VARCHAR2, p_scope IN VARCHAR2) RETURN BOOLEAN;   -- exact scope match
  FUNCTION is_manager RETURN BOOLEAN;                             -- TEAM/ALL scope for team reports
  /* Item values arrive as strings. Non-numeric or NULL -> FALSE (never raises). */
  FUNCTION is_enrolled(p_enrollment_id IN VARCHAR2) RETURN BOOLEAN;
  FUNCTION can_manage_course(p_course_id IN VARCHAR2, p_permission IN VARCHAR2 DEFAULT 'COURSE_AUTHOR') RETURN BOOLEAN;
  FUNCTION owns_certificate(p_certificate_id IN VARCHAR2) RETURN BOOLEAN;

  -- ---- Authentication ----
  /* Post-Authentication Procedure Name of the authentication scheme. */
  PROCEDURE post_auth;

  -- ---- Error handling (Application > Definition > Error Handling Function) ----
  FUNCTION error_handler(p_error IN apex_error.t_error) RETURN apex_error.t_error_handling_result;

  -- ---- Ajax callbacks (Page Designer > Ajax Callback process, PL/SQL: BEGIN lms_apex_pkg.ajax_xxx; END;) ----
  PROCEDURE ajax_progress;       -- x01 enrollment, x02 lesson, x03 event type, x04 uuid, x05 position, x06 seconds
  PROCEDURE ajax_save_answer;    -- x01 attempt, x02 question, x03 answer json
  PROCEDURE ajax_unread;         -- notification badge

  -- ---- Content access ----
  /* Raises if the caller may not open the lesson (owner, active enrolment, lesson in course, available). */
  PROCEDURE authorize_lesson_access(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER);
  /* Short-lived signed URL for object-store content, or the external URL itself for URL lessons. */
  FUNCTION content_url(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN VARCHAR2;
  /* HTML for the player viewer region (PL/SQL Dynamic Content: apex_util.prn(lms_apex_pkg.lesson_html(:P20_ENROLLMENT_ID, :P20_LESSON_ID), false);).
     Authorises first. Text is escaped, HTML lessons are re-sanitised, media/PDF use short-lived signed URLs,
     interactive content is sandboxed, external links open in a new context with noopener. */
  FUNCTION lesson_html(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN CLOB;
  /* Page process on page 21: streams a database-stored document (BLOB) after authorisation and the FILE_DOWNLOAD limit. */
  PROCEDURE stream_lesson_file(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER);

  -- ---- Pages ----
  /* 'Y' when the COURSE_SEARCH quota allows this request, 'N' when throttled (no exception). */
  FUNCTION search_allowed RETURN VARCHAR2;
  /* Human label of an enrolment/attempt status in the current session language. */
  FUNCTION status_label(p_status IN VARCHAR2) RETURN VARCHAR2;
END lms_apex_pkg;
/

CREATE OR REPLACE PACKAGE BODY lms_apex_pkg AS

  FUNCTION to_num(p_value IN VARCHAR2) RETURN NUMBER IS
  BEGIN
    IF p_value IS NULL OR VALIDATE_CONVERSION(p_value AS NUMBER) = 0 THEN RETURN NULL; END IF;
    RETURN TO_NUMBER(p_value);
  END to_num;

  -- ---------------------------------------------------------- authorization -----
  FUNCTION is_active_user RETURN BOOLEAN IS
  BEGIN
    RETURN CASE WHEN lms_security_pkg.current_user_id_safe IS NOT NULL THEN TRUE ELSE FALSE END;
  END is_active_user;

  FUNCTION has_perm(p_code IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN lms_security_pkg.has_permission(p_code);
  END has_perm;

  FUNCTION has_scope(p_code IN VARCHAR2, p_scope IN VARCHAR2) RETURN BOOLEAN IS
  BEGIN
    RETURN CASE WHEN lms_security_pkg.permission_scope(p_code) = p_scope THEN TRUE ELSE FALSE END;
  END has_scope;

  FUNCTION is_manager RETURN BOOLEAN IS
  BEGIN
    RETURN CASE WHEN lms_security_pkg.permission_scope('REPORT_TEAM') IN ('TEAM', 'ALL') THEN TRUE ELSE FALSE END;
  END is_manager;

  FUNCTION is_enrolled(p_enrollment_id IN VARCHAR2) RETURN BOOLEAN IS
    l_id NUMBER := to_num(p_enrollment_id);
    l_n  NUMBER;
  BEGIN
    IF l_id IS NULL THEN RETURN FALSE; END IF;
    SELECT COUNT(*) INTO l_n FROM lms_enrollments
     WHERE enrollment_id = l_id AND user_id = lms_security_pkg.current_user_id_safe
       AND status IN ('ENROLLED','IN_PROGRESS','COMPLETED');
    RETURN l_n > 0;
  END is_enrolled;

  FUNCTION can_manage_course(p_course_id IN VARCHAR2, p_permission IN VARCHAR2 DEFAULT 'COURSE_AUTHOR') RETURN BOOLEAN IS
    l_id NUMBER := to_num(p_course_id);
  BEGIN
    IF l_id IS NULL THEN RETURN FALSE; END IF;
    RETURN lms_course_pkg.can_manage_course(l_id, p_permission);
  END can_manage_course;

  FUNCTION owns_certificate(p_certificate_id IN VARCHAR2) RETURN BOOLEAN IS
    l_id NUMBER := to_num(p_certificate_id);
    l_n  NUMBER;
  BEGIN
    IF l_id IS NULL THEN RETURN FALSE; END IF;
    SELECT COUNT(*) INTO l_n FROM lms_certificates
     WHERE certificate_id = l_id AND user_id = lms_security_pkg.current_user_id_safe;
    RETURN l_n > 0;
  END owns_certificate;

  -- ------------------------------------------------------------ authentication -----
  PROCEDURE post_auth IS
    l_name VARCHAR2(255) := UPPER(TRIM(apex_application.g_user));
    l_user lms_users%ROWTYPE;
  BEGIN
    BEGIN
      SELECT * INTO l_user FROM lms_users WHERE username = l_name;
    EXCEPTION WHEN NO_DATA_FOUND THEN l_user.user_id := NULL; END;

    IF l_user.user_id IS NULL OR l_user.status <> 'ACTIVE' THEN
      -- Not mapped / not active: record it and send the person to the generic access page.
      -- The application-level scheme LMS_AUTH_ACTIVE also blocks every page, so this is defence in depth.
      lms_audit_pkg.log_security('LOGIN_DENIED', l_user.user_id, NULL, 'LOGIN', 'WARN',
                                 CASE WHEN l_user.user_id IS NULL THEN 'unmapped identity' ELSE 'status ' || l_user.status END);
      apex_util.redirect_url(p_url => apex_page.get_url(p_page => 9998));
      apex_application.stop_apex_engine;
    END IF;

    apex_util.set_session_state('LMS_USER_ID', l_user.user_id);          -- protected item, set server side only
    apex_util.set_session_state('LMS_LANG', l_user.preferred_lang);
    apex_util.set_session_lang(p_lang => l_user.preferred_lang);          -- verify availability in 24.1
    lms_audit_pkg.log_security('LOGIN_SUCCESS', l_user.user_id, NULL, 'LOGIN', 'INFO', NULL);
  END post_auth;

  -- ------------------------------------------------------------ error handling -----
  FUNCTION msg_or(p_key IN VARCHAR2, p_fallback IN VARCHAR2) RETURN VARCHAR2 IS
    l_t VARCHAR2(4000);
  BEGIN
    l_t := apex_lang.message(p_key);
    RETURN CASE WHEN l_t IS NULL OR l_t = p_key OR INSTR(l_t, p_key) > 0 THEN p_fallback ELSE l_t END;
  END msg_or;

  FUNCTION error_handler(p_error IN apex_error.t_error) RETURN apex_error.t_error_handling_result IS
    l_result apex_error.t_error_handling_result;
    l_text   VARCHAR2(4000);
  BEGIN
    l_result := apex_error.init_error_result(p_error => p_error);

    IF p_error.is_internal_error THEN
      -- Unexpected: show a generic text only; the technical detail goes to the security log.
      IF NOT p_error.is_common_runtime_error THEN
        lms_audit_pkg.log_security('APP_ERROR', lms_security_pkg.current_user_id_safe, NULL, NULL, 'WARN',
                                   SUBSTR(p_error.ora_sqlerrm, 1, 800));
        l_result.message         := msg_or('LMS_ERR_INTERNAL', 'An unexpected error occurred. Please try again or contact support.');
        l_result.additional_info := NULL;
      END IF;
    ELSE
      IF l_result.display_location = apex_error.c_on_error_page THEN
        l_result.display_location := apex_error.c_inline_in_notification;
      END IF;
      IF p_error.ora_sqlcode IS NOT NULL THEN
        l_text := apex_error.get_first_ora_error_text(p_error => p_error);
        IF p_error.ora_sqlcode = -20429 THEN
          l_result.message := msg_or('LMS_ERR_RATE_LIMIT', l_text);
        ELSIF p_error.ora_sqlcode IN (-20401, -20403) THEN
          l_result.message := msg_or('LMS_ERR_FORBIDDEN', 'You are not allowed to perform this action.');
        ELSIF p_error.ora_sqlcode BETWEEN -20999 AND -20400 THEN
          l_result.message := l_text;                                     -- business rule text raised by the packages
        ELSIF p_error.ora_sqlcode = -1 THEN
          l_result.message := msg_or('LMS_ERR_DUPLICATE', 'This record already exists.');
        ELSIF p_error.ora_sqlcode IN (-2291, -2292) THEN
          l_result.message := msg_or('LMS_ERR_RELATED', 'The record is referenced by, or refers to, other data.');
        ELSIF p_error.ora_sqlcode = -2290 THEN
          l_result.message := msg_or('LMS_ERR_INVALID', 'A value is outside the allowed range.');
        END IF;
        IF p_error.ora_sqlcode IN (-1, -2290, -2291, -2292) THEN
          l_result.additional_info := NULL;
        END IF;
      END IF;
    END IF;
    RETURN l_result;
  END error_handler;

  -- ------------------------------------------------------------------- Ajax -----
  PROCEDURE json_error IS
    l_code NUMBER := SQLCODE;
    l_msg  VARCHAR2(1000);
  BEGIN
    IF l_code BETWEEN -20999 AND -20400 THEN
      l_msg := SUBSTR(SQLERRM, INSTR(SQLERRM, ':') + 2, 500);
    ELSE
      lms_audit_pkg.log_security('AJAX_ERROR', lms_security_pkg.current_user_id_safe, NULL, NULL, 'WARN', SUBSTR(SQLERRM, 1, 800));
      l_code := -20000;
      l_msg  := msg_or('LMS_ERR_INTERNAL', 'An unexpected error occurred.');
    END IF;
    apex_json.open_object;
    apex_json.write('ok', FALSE);
    apex_json.write('code', ABS(l_code));
    apex_json.write('message', l_msg);
    apex_json.close_object;
  END json_error;

  PROCEDURE ajax_progress IS
    l_pct NUMBER; l_status VARCHAR2(20);
  BEGIN
    lms_progress_pkg.record_event(
      p_enrollment_id => TO_NUMBER(apex_application.g_x01), p_lesson_id => TO_NUMBER(apex_application.g_x02),
      p_event_type    => apex_application.g_x03,           p_event_uuid => apex_application.g_x04,
      p_position      => NVL(to_num(apex_application.g_x05), 0), p_seconds => NVL(to_num(apex_application.g_x06), 0),
      p_progress_pct  => l_pct, p_status => l_status);
    apex_json.open_object;
    apex_json.write('ok', TRUE);
    apex_json.write('percent', l_pct);
    apex_json.write('status', l_status);
    apex_json.close_object;
  EXCEPTION WHEN OTHERS THEN json_error;
  END ajax_progress;

  PROCEDURE ajax_save_answer IS
  BEGIN
    lms_assessment_pkg.save_answer(TO_NUMBER(apex_application.g_x01), TO_NUMBER(apex_application.g_x02), apex_application.g_x03);
    apex_json.open_object;
    apex_json.write('ok', TRUE);
    apex_json.close_object;
  EXCEPTION WHEN OTHERS THEN json_error;
  END ajax_save_answer;

  PROCEDURE ajax_unread IS
  BEGIN
    apex_json.open_object;
    apex_json.write('ok', TRUE);
    apex_json.write('unread', lms_notification_pkg.unread_count);
    apex_json.close_object;
  EXCEPTION WHEN OTHERS THEN json_error;
  END ajax_unread;

  -- --------------------------------------------------------------- content -----
  PROCEDURE authorize_lesson_access(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_n    NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n
      FROM lms_enrollments e
      JOIN lms_modules m ON m.course_id = e.course_id
      JOIN lms_lessons l ON l.module_id = m.module_id AND l.lesson_id = p_lesson_id
     WHERE e.enrollment_id = p_enrollment_id AND e.user_id = l_user
       AND e.status IN ('ENROLLED','IN_PROGRESS','COMPLETED')
       AND (l.available_from IS NULL OR l.available_from <= TRUNC(SYSDATE));
    IF l_n = 0 THEN
      lms_audit_pkg.log_event('ACCESS_DENIED', 'LESSON', p_lesson_id, 'DENIED');
      lms_audit_pkg.log_security('IDOR_ATTEMPT', l_user, NULL, 'CONTENT', 'HIGH', 'lesson ' || p_lesson_id);
      RAISE_APPLICATION_ERROR(-20403, 'Not authorized');
    END IF;
  END authorize_lesson_access;

  FUNCTION content_url(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN VARCHAR2 IS
    l_user NUMBER := lms_security_pkg.current_user_id;
    l_ref  lms_lessons.content_ref%TYPE;
    l_type lms_lessons.lesson_type%TYPE;
    l_base VARCHAR2(500) := lms_util_pkg.get_setting('CONTENT_BASE_URL');
    l_exp  NUMBER;
    l_sig  VARCHAR2(64);
  BEGIN
    authorize_lesson_access(p_enrollment_id, p_lesson_id);
    lms_rate_limit_pkg.enforce_limit('FILE_DOWNLOAD', l_user);
    SELECT content_ref, lesson_type INTO l_ref, l_type FROM lms_lessons WHERE lesson_id = p_lesson_id;
    IF l_ref IS NULL THEN RETURN NULL; END IF;
    IF l_type = 'URL' THEN
      -- external URL lessons: only http(s) is ever rendered
      IF NOT REGEXP_LIKE(l_ref, '^https?://', 'i') THEN RAISE_APPLICATION_ERROR(-20409, 'Invalid content link'); END IF;
      RETURN l_ref;
    END IF;
    IF l_base IS NULL THEN RAISE_APPLICATION_ERROR(-20409, 'Content storage is not configured'); END IF;
    l_exp := TRUNC((CAST(SYS_EXTRACT_UTC(SYSTIMESTAMP) AS DATE) - DATE '1970-01-01') * 86400) + 300;   -- valid 5 minutes
    l_sig := LOWER(RAWTOHEX(DBMS_CRYPTO.mac(
               UTL_I18N.string_to_raw(l_ref || '|' || l_exp, 'AL32UTF8'),
               DBMS_CRYPTO.hmac_sh256,
               lms_secret_pkg.content_signing_key)));
    lms_audit_pkg.log_event('CONTENT_URL', 'LESSON', p_lesson_id);
    RETURN RTRIM(l_base, '/') || '/' || UTL_URL.escape(l_ref, FALSE) || '?exp=' || l_exp || '&sig=' || l_sig;
  END content_url;

  FUNCTION file_src(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER, p_ref IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_ref LIKE 'blob:%' THEN        -- database-stored document: streamed by page 21 (checks again on every request)
      authorize_lesson_access(p_enrollment_id, p_lesson_id);
      RETURN apex_page.get_url(p_page => 21, p_items => 'P21_ENROLLMENT_ID,P21_LESSON_ID', p_values => p_enrollment_id || ',' || p_lesson_id);
    END IF;
    RETURN content_url(p_enrollment_id, p_lesson_id);
  END file_src;

  PROCEDURE stream_lesson_file(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) IS
    l_c    lms_lesson_content%ROWTYPE;
    l_user NUMBER := lms_security_pkg.current_user_id;
  BEGIN
    authorize_lesson_access(p_enrollment_id, p_lesson_id);
    lms_rate_limit_pkg.enforce_limit('FILE_DOWNLOAD', l_user);
    BEGIN
      SELECT * INTO l_c FROM lms_lesson_content WHERE lesson_id = p_lesson_id AND storage_type = 'BLOB'
       ORDER BY content_id DESC FETCH FIRST 1 ROW ONLY;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'File not found'); END;
    lms_audit_pkg.log_event('FILE_STREAM', 'LESSON', p_lesson_id);
    sys.htp.init;
    sys.owa_util.mime_header(l_c.mime_type, FALSE);
    sys.htp.p('Content-Length: ' || DBMS_LOB.getlength(l_c.file_blob));
    sys.htp.p('Content-Disposition: inline; filename="' || REGEXP_REPLACE(l_c.file_name, '[^A-Za-z0-9._-]', '_') || '"');
    sys.htp.p('X-Content-Type-Options: nosniff');
    sys.htp.p('Cache-Control: private, no-store');
    sys.owa_util.http_header_close;
    sys.wpg_docload.download_file(l_c.file_blob);
    apex_application.stop_apex_engine;
  END stream_lesson_file;

  FUNCTION lesson_html(p_enrollment_id IN NUMBER, p_lesson_id IN NUMBER) RETURN CLOB IS
    l_les  lms_lessons%ROWTYPE;
    l_url  VARCHAR2(2000);
    l_html CLOB;
    l_quiz NUMBER;
    c_tags CONSTANT VARCHAR2(300) := '<p>,<br>,<b>,<strong>,<i>,<em>,<u>,<ul>,<ol>,<li>,<h2>,<h3>,<h4>,<table>,<thead>,<tbody>,<tr>,<th>,<td>';
    l_title VARCHAR2(500);
  BEGIN
    authorize_lesson_access(p_enrollment_id, p_lesson_id);
    SELECT * INTO l_les FROM lms_lessons WHERE lesson_id = p_lesson_id;
    l_title := apex_escape.html(l_les.title_en);
    CASE l_les.lesson_type
      WHEN 'TEXT' THEN
        l_html := '<div class="lms-text">' || REPLACE(apex_escape.html(l_les.content_text), CHR(10), '<br>') || '</div>';
      WHEN 'HTML' THEN
        l_html := '<div class="lms-text">' || apex_escape.html_whitelist(SUBSTR(l_les.content_text, 1, 30000), c_tags) || '</div>';
      WHEN 'VIDEO' THEN
        l_url := content_url(p_enrollment_id, p_lesson_id);
        l_html := '<video id="lms-media" controls controlsList="nodownload" preload="metadata" playsinline src="'
                  || apex_escape.html_attribute(l_url) || '"><track kind="captions" /></video>';
      WHEN 'PDF' THEN
        l_url := file_src(p_enrollment_id, p_lesson_id, l_les.content_ref);
        l_html := '<iframe title="' || l_title || '" src="' || apex_escape.html_attribute(l_url) || '"></iframe>';
      WHEN 'PRESENTATION' THEN
        l_url := file_src(p_enrollment_id, p_lesson_id, l_les.content_ref);
        l_html := '<iframe title="' || l_title || '" src="' || apex_escape.html_attribute(l_url) || '"></iframe>';
      WHEN 'INTERACTIVE' THEN
        l_url := file_src(p_enrollment_id, p_lesson_id, l_les.content_ref);
        l_html := '<iframe title="' || l_title || '" sandbox="allow-scripts allow-forms allow-popups" referrerpolicy="no-referrer" src="'
                  || apex_escape.html_attribute(l_url) || '"></iframe>';
      WHEN 'DOWNLOAD' THEN
        l_url := file_src(p_enrollment_id, p_lesson_id, l_les.content_ref);
        l_html := '<p><a class="t-Button t-Button--hot" href="' || apex_escape.html_attribute(l_url) || '" download rel="noopener">'
                  || apex_escape.html(msg_or('LMS_LESSON_DOWNLOAD', 'Download')) || '</a></p>';
      WHEN 'URL' THEN
        l_url := content_url(p_enrollment_id, p_lesson_id);
        l_html := '<p><a class="t-Button t-Button--hot" href="' || apex_escape.html_attribute(l_url)
                  || '" target="_blank" rel="noopener noreferrer">' || apex_escape.html(msg_or('LMS_LESSON_URL', 'Open link')) || '</a></p>';
      WHEN 'ASSESSMENT' THEN
        BEGIN SELECT quiz_id INTO l_quiz FROM lms_quizzes WHERE lesson_id = p_lesson_id AND active_flag = 'Y' AND ROWNUM = 1;
        EXCEPTION WHEN NO_DATA_FOUND THEN l_quiz := NULL; END;
        l_html := CASE WHEN l_quiz IS NULL THEN '<p>' || apex_escape.html(msg_or('LMS_NO_QUIZ', 'No quiz is attached to this lesson.')) || '</p>'
                       ELSE '<p><a class="t-Button t-Button--hot" href="'
                            || apex_escape.html_attribute(apex_page.get_url(p_page => 40, p_items => 'P40_QUIZ_ID', p_values => l_quiz))
                            || '">' || apex_escape.html(msg_or('LMS_START_QUIZ', 'Start the quiz')) || '</a></p>' END;
      WHEN 'LIVE_SESSION' THEN
        l_html := '<p><a class="t-Button t-Button--hot" href="' || apex_escape.html_attribute(apex_page.get_url(p_page => 55))
                  || '">' || apex_escape.html(msg_or('LMS_VIEW_SESSIONS', 'View sessions')) || '</a></p>';
      ELSE
        -- ASSIGNMENT and any future type: text instructions only; completion is by the instructor (rule INSTRUCTOR_APPROVAL)
        l_html := '<div class="lms-text">' || REPLACE(apex_escape.html(l_les.content_text), CHR(10), '<br>') || '</div>';
    END CASE;
    RETURN l_html;
  END lesson_html;

  -- ------------------------------------------------------------------ pages -----
  FUNCTION search_allowed RETURN VARCHAR2 IS
  BEGIN
    lms_rate_limit_pkg.enforce_limit('COURSE_SEARCH');
    RETURN 'Y';
  EXCEPTION WHEN OTHERS THEN
    IF SQLCODE = -20429 THEN RETURN 'N'; END IF;
    RAISE;
  END search_allowed;

  FUNCTION status_label(p_status IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN msg_or('LMS_STATUS_' || p_status, INITCAP(REPLACE(p_status, '_', ' ')));
  END status_label;
END lms_apex_pkg;
/

-- ------------------------------------------------------------------- ADMIN -----
CREATE OR REPLACE PACKAGE lms_admin_pkg AS
  /* Only existing keys can be changed; numeric keys are range checked. */
  PROCEDURE set_setting(p_key IN VARCHAR2, p_value IN VARCHAR2);
  PROCEDURE set_rate_limit_policy(p_policy_id IN NUMBER, p_limit_count IN NUMBER, p_window_seconds IN NUMBER,
                                  p_burst_limit IN NUMBER, p_fail_mode IN VARCHAR2, p_enabled IN VARCHAR2);
  /* p_scope NULL removes the grant. */
  PROCEDURE set_role_permission(p_role_code IN VARCHAR2, p_permission_code IN VARCHAR2, p_scope IN VARCHAR2);
  PROCEDURE save_template(p_code IN VARCHAR2, p_lang IN VARCHAR2, p_subject IN VARCHAR2, p_body IN VARCHAR2,
                          p_active IN VARCHAR2 DEFAULT 'Y');
  /* p_category_id NULL = create. Requires COURSE_PUBLISH. A category cannot be its own ancestor. */
  FUNCTION save_category(p_category_id IN NUMBER, p_parent_id IN NUMBER, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2,
                         p_sort_order IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER;
  /* p_template_id NULL = create. Requires CERT_POLICY. The wording is plain text; the layout is the print page. */
  FUNCTION save_certificate_template(p_template_id IN NUMBER, p_code IN VARCHAR2, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2,
                                     p_validity_months IN NUMBER, p_body_text IN VARCHAR2, p_active_flag IN VARCHAR2) RETURN NUMBER;
END lms_admin_pkg;
/

CREATE OR REPLACE PACKAGE BODY lms_admin_pkg AS

  PROCEDURE set_setting(p_key IN VARCHAR2, p_value IN VARCHAR2) IS
    l_old lms_system_settings.setting_value%TYPE;
  BEGIN
    lms_security_pkg.require_permission('SETTINGS_ADMIN');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    IF p_value IS NULL OR LENGTH(p_value) > 1000 THEN RAISE_APPLICATION_ERROR(-20400, 'Value is required (max 1000 characters)'); END IF;
    BEGIN
      SELECT setting_value INTO l_old FROM lms_system_settings WHERE setting_key = p_key FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Unknown setting'); END;
    IF (p_key LIKE 'RETAIN\_%' ESCAPE '\' OR p_key IN ('QUIZ_GRACE_SECONDS','PROGRESS_MAX_DELTA_SEC','APPROVAL_ESCALATE_DAYS','RENEWAL_WINDOW_DAYS','FEEDBACK_MIN_RESPONSES','REVIEW_EDIT_DAYS'))
       AND (VALIDATE_CONVERSION(p_value AS NUMBER) = 0 OR TO_NUMBER(p_value) < 0 OR TO_NUMBER(p_value) <> TRUNC(TO_NUMBER(p_value))) THEN
      RAISE_APPLICATION_ERROR(-20400, 'This setting must be a whole number >= 0');
    END IF;
    IF p_key = 'CERT_VERIFY_NAME' AND p_value NOT IN ('FULL','INITIALS','NONE') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Allowed values: FULL, INITIALS, NONE');
    END IF;
    IF p_key IN ('REVIEW_REQUIRES_COMPLETION') AND p_value NOT IN ('Y','N') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Allowed values: Y, N');
    END IF;
    UPDATE lms_system_settings SET setting_value = p_value, updated_at = SYSTIMESTAMP WHERE setting_key = p_key;
    lms_audit_pkg.log_event('SETTING_CHANGE', 'SETTING', NULL, 'SUCCESS',
                            lms_util_pkg.js('key', p_key, 'old', SUBSTR(l_old, 1, 200), 'new', SUBSTR(p_value, 1, 200)));
  END set_setting;

  PROCEDURE set_rate_limit_policy(p_policy_id IN NUMBER, p_limit_count IN NUMBER, p_window_seconds IN NUMBER,
                                  p_burst_limit IN NUMBER, p_fail_mode IN VARCHAR2, p_enabled IN VARCHAR2) IS
    l_p lms_rate_limit_policies%ROWTYPE;
  BEGIN
    lms_security_pkg.require_permission('RATELIMIT_ADMIN');
    IF p_limit_count < 1 OR p_window_seconds NOT BETWEEN 1 AND 86400
       OR p_fail_mode NOT IN ('OPEN','CLOSED') OR p_enabled NOT IN ('Y','N')
       OR (p_burst_limit IS NOT NULL AND p_burst_limit < 1) THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid rate-limit policy values');
    END IF;
    BEGIN SELECT * INTO l_p FROM lms_rate_limit_policies WHERE policy_id = p_policy_id FOR UPDATE;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Policy not found'); END;
    -- Safety rail: security-critical operations must not be switched off or opened by mistake.
    IF l_p.operation_name IN ('AUTH_ATTEMPT','QUIZ_SUBMIT','CERT_GENERATE') AND (p_enabled = 'N' OR p_fail_mode = 'OPEN') THEN
      RAISE_APPLICATION_ERROR(-20409, 'This policy cannot be disabled or set to fail open');
    END IF;
    UPDATE lms_rate_limit_policies
       SET limit_count = p_limit_count, window_seconds = p_window_seconds, burst_limit = p_burst_limit,
           fail_mode = p_fail_mode, enabled_flag = p_enabled, updated_at = SYSTIMESTAMP
     WHERE policy_id = p_policy_id;
    lms_audit_pkg.log_event('RATELIMIT_CHANGE', 'POLICY', p_policy_id, 'SUCCESS',
      lms_util_pkg.js('op', l_p.operation_name, 'limit', p_limit_count, 'window', p_window_seconds,
                      'fail', p_fail_mode, 'enabled', p_enabled));
  END set_rate_limit_policy;

  PROCEDURE set_role_permission(p_role_code IN VARCHAR2, p_permission_code IN VARCHAR2, p_scope IN VARCHAR2) IS
    l_role NUMBER; l_perm NUMBER;
  BEGIN
    lms_security_pkg.require_permission('ROLE_ADMIN');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    BEGIN SELECT role_id INTO l_role FROM lms_roles WHERE role_code = p_role_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Unknown role'); END;
    BEGIN SELECT permission_id INTO l_perm FROM lms_permissions WHERE permission_code = p_permission_code;
    EXCEPTION WHEN NO_DATA_FOUND THEN RAISE_APPLICATION_ERROR(-20404, 'Unknown permission'); END;
    IF p_scope IS NOT NULL AND p_scope NOT IN ('ALL','TEAM','OWN','ASSIGNED') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid scope');
    END IF;
    -- lock-out guard: the system administrator role must keep user/role administration
    IF p_role_code = 'SYS_ADMIN' AND p_permission_code IN ('USER_ADMIN','ROLE_ADMIN') AND (p_scope IS NULL OR p_scope <> 'ALL') THEN
      RAISE_APPLICATION_ERROR(-20409, 'SYS_ADMIN must keep USER_ADMIN and ROLE_ADMIN with ALL scope');
    END IF;
    IF p_scope IS NULL THEN
      DELETE FROM lms_role_permissions WHERE role_id = l_role AND permission_id = l_perm;
    ELSE
      MERGE INTO lms_role_permissions t
      USING (SELECT l_role role_id, l_perm permission_id FROM dual) s
         ON (t.role_id = s.role_id AND t.permission_id = s.permission_id)
       WHEN MATCHED THEN UPDATE SET t.scope = p_scope
       WHEN NOT MATCHED THEN INSERT (role_id, permission_id, scope) VALUES (s.role_id, s.permission_id, p_scope);
    END IF;
    lms_audit_pkg.log_event('ROLE_PERMISSION', 'ROLE', l_role, 'SUCCESS',
                            lms_util_pkg.js('permission', p_permission_code, 'scope', NVL(p_scope, 'REMOVED')));
  END set_role_permission;

  PROCEDURE save_template(p_code IN VARCHAR2, p_lang IN VARCHAR2, p_subject IN VARCHAR2, p_body IN VARCHAR2,
                          p_active IN VARCHAR2 DEFAULT 'Y') IS
  BEGIN
    lms_security_pkg.require_permission('NOTIF_TEMPLATE_ADMIN');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    IF p_lang NOT IN ('en','ar') OR p_active NOT IN ('Y','N') OR p_subject IS NULL OR p_body IS NULL
       OR LENGTH(p_subject) > 300 OR LENGTH(p_body) > 4000 THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid template');
    END IF;
    -- templates are plain text; markup is escaped on output, so reject it here to avoid surprises
    IF REGEXP_LIKE(p_subject || p_body, '<[a-zA-Z/!]') THEN
      RAISE_APPLICATION_ERROR(-20400, 'HTML is not allowed in notification templates');
    END IF;
    MERGE INTO lms_notification_templates t
    USING (SELECT p_code code, p_lang lang FROM dual) s
       ON (t.template_code = s.code AND t.lang = s.lang)
     WHEN MATCHED THEN UPDATE SET t.subject = p_subject, t.body = p_body, t.active_flag = p_active
     WHEN NOT MATCHED THEN INSERT (template_code, lang, subject, body, active_flag)
          VALUES (p_code, p_lang, p_subject, p_body, p_active);
    lms_audit_pkg.log_event('TEMPLATE_SAVE', 'TEMPLATE', NULL, 'SUCCESS', lms_util_pkg.js('code', p_code, 'lang', p_lang));
  END save_template;

  FUNCTION save_category(p_category_id IN NUMBER, p_parent_id IN NUMBER, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2,
                         p_sort_order IN NUMBER, p_active_flag IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER := p_category_id; l_n NUMBER;
  BEGIN
    lms_security_pkg.require_permission('COURSE_PUBLISH');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    IF p_name_en IS NULL OR LENGTH(TRIM(p_name_en)) = 0 OR p_active_flag NOT IN ('Y','N') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid category');
    END IF;
    IF l_id IS NOT NULL AND p_parent_id IS NOT NULL THEN
      IF p_parent_id = l_id THEN RAISE_APPLICATION_ERROR(-20409, 'A category cannot be its own parent'); END IF;
      SELECT COUNT(*) INTO l_n FROM lms_categories WHERE category_id = l_id
       START WITH category_id = p_parent_id CONNECT BY NOCYCLE category_id = PRIOR parent_category_id;
      IF l_n > 0 THEN RAISE_APPLICATION_ERROR(-20409, 'That parent would create a loop'); END IF;
    END IF;
    IF l_id IS NULL THEN
      INSERT INTO lms_categories (parent_category_id, name_en, name_ar, sort_order, active_flag)
      VALUES (p_parent_id, p_name_en, p_name_ar, NVL(p_sort_order, 0), p_active_flag) RETURNING category_id INTO l_id;
    ELSE
      UPDATE lms_categories SET parent_category_id = p_parent_id, name_en = p_name_en, name_ar = p_name_ar,
             sort_order = NVL(p_sort_order, 0), active_flag = p_active_flag WHERE category_id = l_id;
      IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Category not found'); END IF;
    END IF;
    lms_audit_pkg.log_event('CATEGORY_SAVE', 'CATEGORY', l_id);
    RETURN l_id;
  END save_category;

  FUNCTION save_certificate_template(p_template_id IN NUMBER, p_code IN VARCHAR2, p_name_en IN VARCHAR2, p_name_ar IN VARCHAR2,
                                     p_validity_months IN NUMBER, p_body_text IN VARCHAR2, p_active_flag IN VARCHAR2) RETURN NUMBER IS
    l_id NUMBER := p_template_id;
  BEGIN
    lms_security_pkg.require_permission('CERT_POLICY');
    lms_rate_limit_pkg.enforce_limit('ADMIN_WRITE');
    IF p_code IS NULL OR NOT REGEXP_LIKE(p_code, '^[A-Z0-9_]{3,30}$') OR p_name_en IS NULL OR p_active_flag NOT IN ('Y','N')
       OR (p_validity_months IS NOT NULL AND p_validity_months <= 0) OR REGEXP_LIKE(NVL(p_body_text, ' '), '<[a-zA-Z/!]') THEN
      RAISE_APPLICATION_ERROR(-20400, 'Invalid certificate template (code A-Z/0-9/_, positive validity, plain-text wording)');
    END IF;
    IF l_id IS NULL THEN
      INSERT INTO lms_certificate_templates (template_code, name_en, name_ar, validity_months, body_html, active_flag)
      VALUES (p_code, p_name_en, p_name_ar, p_validity_months, p_body_text, p_active_flag) RETURNING template_id INTO l_id;
    ELSE
      UPDATE lms_certificate_templates SET template_code = p_code, name_en = p_name_en, name_ar = p_name_ar,
             validity_months = p_validity_months, body_html = p_body_text, active_flag = p_active_flag
       WHERE template_id = l_id;
      IF SQL%ROWCOUNT = 0 THEN RAISE_APPLICATION_ERROR(-20404, 'Template not found'); END IF;
    END IF;
    lms_audit_pkg.log_event('CERT_TEMPLATE_SAVE', 'CERT_TEMPLATE', l_id);
    RETURN l_id;
  EXCEPTION WHEN DUP_VAL_ON_INDEX THEN RAISE_APPLICATION_ERROR(-20409, 'Template code already exists');
  END save_certificate_template;
END lms_admin_pkg;
/
