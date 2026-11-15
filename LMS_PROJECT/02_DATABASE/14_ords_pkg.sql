-- =============================================================================
-- LMS_ORDS_PKG: PL/SQL behind the ORDS handlers | Oracle 19c + ORDS
-- STATUS: written, NOT compiled. Requires 01-09 and 13.
-- Each procedure returns the HTTP status (and Retry-After) through OUT parameters; the ORDS handler copies them
-- into the implicit :status_code and the response header parameter. The JSON body is written with HTP.
-- No procedure raises to the caller: unexpected errors become a generic HTTP 500 and a security-log entry.
-- =============================================================================

CREATE OR REPLACE PACKAGE lms_ords_pkg AS
  /* GET /public/certificates/:code */
  PROCEDURE verify_certificate(p_code IN VARCHAR2, p_client_key IN VARCHAR2,
                               p_status OUT NUMBER, p_retry_after OUT NUMBER);
  /* GET /catalog/courses?q=&category=&limit=&offset= */
  PROCEDURE catalog_search(p_q IN VARCHAR2, p_category IN VARCHAR2, p_limit IN VARCHAR2, p_offset IN VARCHAR2,
                           p_client_key IN VARCHAR2, p_status OUT NUMBER, p_retry_after OUT NUMBER);
  /* GET /catalog/courses/:id */
  PROCEDURE catalog_course(p_course_id IN VARCHAR2, p_client_key IN VARCHAR2,
                           p_status OUT NUMBER, p_retry_after OUT NUMBER);
  /* POST /hr/employees   body: {"employees":[{...}]} (max 500) */
  PROCEDURE hr_sync(p_body IN CLOB, p_client_key IN VARCHAR2, p_status OUT NUMBER, p_retry_after OUT NUMBER);
  /* GET /ops/health */
  PROCEDURE health(p_status OUT NUMBER);
END lms_ords_pkg;
/

CREATE OR REPLACE PACKAGE BODY lms_ords_pkg AS

  c_max_employees CONSTANT PLS_INTEGER := 500;
  c_max_body      CONSTANT PLS_INTEGER := 2000000;      -- bytes of JSON accepted for a sync batch

  -- ------------------------------------------------------------------ helpers -----
  FUNCTION client_hash(p_client_key IN VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    IF p_client_key IS NULL THEN RETURN 'unknown'; END IF;
    RETURN SUBSTR(LOWER(RAWTOHEX(DBMS_CRYPTO.hash(UTL_I18N.string_to_raw(p_client_key, 'AL32UTF8'), DBMS_CRYPTO.hash_sh256))), 1, 16);
  END client_hash;

  PROCEDURE log_request(p_route IN VARCHAR2, p_method IN VARCHAR2, p_status IN NUMBER, p_started IN TIMESTAMP,
                        p_client_key IN VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    IF lms_util_pkg.get_setting('API_LOG_ENABLED', 'Y') <> 'Y' THEN RETURN; END IF;
    INSERT INTO lms_api_request_log (route, http_method, http_status, duration_ms, subject_key)
    VALUES (SUBSTR(p_route, 1, 200), p_method, p_status,
            ROUND(EXTRACT(SECOND FROM (SYSTIMESTAMP - p_started)) * 1000
                  + EXTRACT(MINUTE FROM (SYSTIMESTAMP - p_started)) * 60000), client_hash(p_client_key));
    COMMIT;
  EXCEPTION WHEN OTHERS THEN ROLLBACK;
  END log_request;

  /* Writes the JSON body. Called exactly once per request. */
  PROCEDURE send_json(p_json IN JSON_ELEMENT_T) IS
    l_clob CLOB := p_json.to_clob;
    l_pos  PLS_INTEGER := 1;
    l_len  PLS_INTEGER := DBMS_LOB.getlength(l_clob);
  BEGIN
    owa_util.mime_header('application/json', FALSE, 'UTF-8');
    htp.p('Cache-Control: no-store');
    owa_util.http_header_close;
    WHILE l_pos <= l_len LOOP
      htp.prn(DBMS_LOB.substr(l_clob, 8000, l_pos));
      l_pos := l_pos + 8000;
    END LOOP;
  END send_json;

  PROCEDURE send_error(p_status IN NUMBER, p_code IN VARCHAR2, p_msg IN VARCHAR2 DEFAULT NULL,
                       p_out_status OUT NUMBER) IS
    l_o JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    p_out_status := p_status;
    l_o.put('error', p_code);
    IF p_msg IS NOT NULL THEN l_o.put('message', p_msg); END IF;
    send_json(l_o);
  END send_error;

  /* Applies a policy; on rejection writes the 429 body. Returns TRUE when the request may proceed. */
  FUNCTION admit(p_operation IN VARCHAR2, p_client_key IN VARCHAR2,
                 p_status OUT NUMBER, p_retry_after OUT NUMBER) RETURN BOOLEAN IS
    l_ok BOOLEAN; l_retry NUMBER;
    l_o  JSON_OBJECT_T := JSON_OBJECT_T();
  BEGIN
    p_retry_after := NULL;
    lms_rate_limit_pkg.check_and_record(p_operation, NULL, p_client_key, l_ok, l_retry);
    IF l_ok THEN RETURN TRUE; END IF;
    p_status := 429; p_retry_after := l_retry;
    l_o.put('error', 'rate_limited');
    l_o.put('retry_after', l_retry);
    send_json(l_o);
    RETURN FALSE;
  END admit;

  PROCEDURE server_error(p_where IN VARCHAR2, p_status OUT NUMBER) IS
  BEGIN
    lms_audit_pkg.log_security('API_ERROR', NULL, NULL, p_where, 'WARN', SUBSTR(SQLERRM, 1, 800));
    send_error(500, 'internal_error', 'The request could not be processed.', p_status);
  END server_error;

  FUNCTION to_int(p_value IN VARCHAR2, p_default IN NUMBER, p_min IN NUMBER, p_max IN NUMBER) RETURN NUMBER IS
  BEGIN
    IF p_value IS NULL OR VALIDATE_CONVERSION(p_value AS NUMBER) = 0 THEN RETURN p_default; END IF;
    RETURN LEAST(GREATEST(TRUNC(TO_NUMBER(p_value)), p_min), p_max);
  END to_int;

  FUNCTION to_date_str(p_date IN DATE) RETURN VARCHAR2 IS
  BEGIN
    RETURN CASE WHEN p_date IS NULL THEN NULL ELSE TO_CHAR(p_date, 'YYYY-MM-DD') END;
  END to_date_str;

  -- -------------------------------------------------------------- verification -----
  PROCEDURE verify_certificate(p_code IN VARCHAR2, p_client_key IN VARCHAR2,
                               p_status OUT NUMBER, p_retry_after OUT NUMBER) IS
    l_t0     TIMESTAMP := SYSTIMESTAMP;
    l_c      SYS_REFCURSOR;
    l_title_en VARCHAR2(250); l_title_ar VARCHAR2(250); l_state VARCHAR2(10);
    l_issued DATE; l_expires DATE; l_holder VARCHAR2(200);
    l_o      JSON_OBJECT_T; l_t JSON_OBJECT_T;
  BEGIN
    p_status := 200;
    IF NOT admit('CERT_VERIFY', p_client_key, p_status, p_retry_after) THEN
      log_request('GET /public/certificates', 'GET', p_status, l_t0, p_client_key); RETURN;
    END IF;
    -- Malformed codes get the same 404 as unknown ones: no format oracle.
    IF p_code IS NULL OR NOT REGEXP_LIKE(UPPER(TRIM(p_code)), '^[A-Z0-9]{8,20}$') THEN
      send_error(404, 'not_found', NULL, p_status);
    ELSE
      l_c := lms_certification_pkg.lookup_certificate(p_code);
      FETCH l_c INTO l_title_en, l_title_ar, l_state, l_issued, l_expires, l_holder;
      IF l_c%NOTFOUND THEN
        send_error(404, 'not_found', NULL, p_status);
      ELSE
        l_o := JSON_OBJECT_T(); l_t := JSON_OBJECT_T();
        l_t.put('en', l_title_en); l_t.put('ar', l_title_ar);
        l_o.put('valid', l_state = 'VALID');
        l_o.put('status', l_state);
        l_o.put('title', l_t);
        l_o.put('issued_on', to_date_str(l_issued));
        l_o.put('expires_on', to_date_str(l_expires));
        l_o.put('holder', l_holder);                    -- initials / full name / null per policy CERT_VERIFY_NAME
        send_json(l_o);
      END IF;
      CLOSE l_c;
    END IF;
    log_request('GET /public/certificates', 'GET', p_status, l_t0, p_client_key);
  EXCEPTION WHEN OTHERS THEN
    IF l_c%ISOPEN THEN CLOSE l_c; END IF;
    server_error('verify_certificate', p_status);
  END verify_certificate;

  -- ------------------------------------------------------------------- catalog -----
  PROCEDURE catalog_search(p_q IN VARCHAR2, p_category IN VARCHAR2, p_limit IN VARCHAR2, p_offset IN VARCHAR2,
                           p_client_key IN VARCHAR2, p_status OUT NUMBER, p_retry_after OUT NUMBER) IS
    l_t0     TIMESTAMP := SYSTIMESTAMP;
    l_limit  NUMBER := to_int(p_limit, 20, 1, 50);
    l_offset NUMBER := to_int(p_offset, 0, 0, 100000);
    l_cat    NUMBER := to_int(p_category, NULL, 1, 999999999);
    l_q      VARCHAR2(200) := TRIM(SUBSTR(p_q, 1, 100));
    l_like   VARCHAR2(210);
    l_o      JSON_OBJECT_T := JSON_OBJECT_T();
    l_items  JSON_ARRAY_T  := JSON_ARRAY_T();
    l_i      JSON_OBJECT_T;
    l_n      PLS_INTEGER := 0;
  BEGIN
    p_status := 200;
    IF NOT admit('COURSE_SEARCH', p_client_key, p_status, p_retry_after) THEN
      log_request('GET /catalog/courses', 'GET', p_status, l_t0, p_client_key); RETURN;
    END IF;
    l_like := CASE WHEN l_q IS NULL THEN NULL
                   ELSE '%' || LOWER(REPLACE(REPLACE(REPLACE(l_q, '\', '\\'), '%', '\%'), '_', '\_')) || '%' END;
    FOR r IN (SELECT c.course_id, c.course_code, c.title_en, c.title_ar, cat.name_en AS category_en,
                     c.difficulty, c.duration_minutes, c.language_code, c.delivery_method,
                     rt.avg_rating, NVL(rt.rating_count, 0) AS rating_count
                FROM lms_courses c
                JOIN lms_categories cat ON cat.category_id = c.category_id
                LEFT JOIN lms_course_rating_v rt ON rt.course_id = c.course_id
               WHERE c.status = 'PUBLISHED' AND (c.available_to IS NULL OR c.available_to >= TRUNC(SYSDATE))
                 AND (l_like IS NULL OR LOWER(c.title_en) LIKE l_like ESCAPE '\' OR LOWER(c.title_ar) LIKE l_like ESCAPE '\'
                      OR c.course_code = UPPER(l_q))
                 AND (l_cat IS NULL OR c.category_id = l_cat)
               ORDER BY c.published_at DESC NULLS LAST, c.course_id
              OFFSET l_offset ROWS FETCH NEXT l_limit + 1 ROWS ONLY) LOOP
      l_n := l_n + 1;
      EXIT WHEN l_n > l_limit;                           -- the extra row only tells us there is a next page
      l_i := JSON_OBJECT_T();
      l_i.put('id', r.course_id);       l_i.put('code', r.course_code);
      l_i.put('title_en', r.title_en);  l_i.put('title_ar', r.title_ar);
      l_i.put('category', r.category_en); l_i.put('difficulty', r.difficulty);
      l_i.put('duration_minutes', r.duration_minutes); l_i.put('language', r.language_code);
      l_i.put('delivery', r.delivery_method);
      IF r.avg_rating IS NOT NULL THEN l_i.put('rating', r.avg_rating); END IF;
      l_i.put('rating_count', r.rating_count);
      l_items.append(l_i);
    END LOOP;
    l_o.put('items', l_items);
    l_o.put('limit', l_limit);
    l_o.put('offset', l_offset);
    l_o.put('has_more', l_n > l_limit);
    send_json(l_o);
    log_request('GET /catalog/courses', 'GET', p_status, l_t0, p_client_key);
  EXCEPTION WHEN OTHERS THEN server_error('catalog_search', p_status);
  END catalog_search;

  PROCEDURE catalog_course(p_course_id IN VARCHAR2, p_client_key IN VARCHAR2,
                           p_status OUT NUMBER, p_retry_after OUT NUMBER) IS
    l_t0  TIMESTAMP := SYSTIMESTAMP;
    l_id  NUMBER := to_int(p_course_id, NULL, 1, 999999999999);
    l_o   JSON_OBJECT_T := JSON_OBJECT_T();
    l_pre JSON_ARRAY_T  := JSON_ARRAY_T();
    l_c   lms_courses%ROWTYPE;
    l_cat VARCHAR2(150); l_mods NUMBER; l_less NUMBER; l_rating NUMBER; l_rc NUMBER;
  BEGIN
    p_status := 200;
    IF NOT admit('COURSE_SEARCH', p_client_key, p_status, p_retry_after) THEN
      log_request('GET /catalog/courses/{id}', 'GET', p_status, l_t0, p_client_key); RETURN;
    END IF;
    IF l_id IS NULL THEN
      send_error(404, 'not_found', NULL, p_status);
    ELSE
      BEGIN
        SELECT c.* INTO l_c FROM lms_courses c
         WHERE c.course_id = l_id AND c.status = 'PUBLISHED' AND (c.available_to IS NULL OR c.available_to >= TRUNC(SYSDATE));
        SELECT name_en INTO l_cat FROM lms_categories WHERE category_id = l_c.category_id;
        SELECT COUNT(DISTINCT m.module_id), COUNT(l.lesson_id) INTO l_mods, l_less
          FROM lms_modules m LEFT JOIN lms_lessons l ON l.module_id = m.module_id WHERE m.course_id = l_id;
        SELECT MAX(avg_rating), NVL(MAX(rating_count), 0) INTO l_rating, l_rc FROM lms_course_rating_v WHERE course_id = l_id;
        FOR p IN (SELECT pc.course_code FROM lms_course_prerequisites cp JOIN lms_courses pc ON pc.course_id = cp.prereq_course_id
                   WHERE cp.course_id = l_id ORDER BY pc.course_code) LOOP
          l_pre.append(p.course_code);
        END LOOP;
        l_o.put('id', l_c.course_id);          l_o.put('code', l_c.course_code);
        l_o.put('title_en', l_c.title_en);     l_o.put('title_ar', l_c.title_ar);
        l_o.put('description_en', SUBSTR(l_c.description_en, 1, 4000));
        l_o.put('description_ar', SUBSTR(l_c.description_ar, 1, 4000));
        l_o.put('category', l_cat);            l_o.put('difficulty', l_c.difficulty);
        l_o.put('duration_minutes', l_c.duration_minutes); l_o.put('language', l_c.language_code);
        l_o.put('delivery', l_c.delivery_method);
        l_o.put('modules', l_mods);            l_o.put('lessons', l_less);
        l_o.put('certificate', l_c.certificate_eligible = 'Y');
        l_o.put('prerequisites', l_pre);
        IF l_rating IS NOT NULL THEN l_o.put('rating', l_rating); END IF;
        l_o.put('rating_count', l_rc);
        send_json(l_o);
      EXCEPTION WHEN NO_DATA_FOUND THEN
        send_error(404, 'not_found', NULL, p_status);
      END;
    END IF;
    log_request('GET /catalog/courses/{id}', 'GET', p_status, l_t0, p_client_key);
  EXCEPTION WHEN OTHERS THEN server_error('catalog_course', p_status);
  END catalog_course;

  -- -------------------------------------------------------------------- HR sync -----
  PROCEDURE hr_sync(p_body IN CLOB, p_client_key IN VARCHAR2, p_status OUT NUMBER, p_retry_after OUT NUMBER) IS
    l_t0     TIMESTAMP := SYSTIMESTAMP;
    l_root   JSON_OBJECT_T;
    l_arr    JSON_ARRAY_T;
    l_e      JSON_OBJECT_T;
    l_errors JSON_ARRAY_T := JSON_ARRAY_T();
    l_err    JSON_OBJECT_T;
    l_o      JSON_OBJECT_T := JSON_OBJECT_T();
    l_ok     PLS_INTEGER := 0;
    l_emp    VARCHAR2(30);

    PROCEDURE apply_one(p_el IN JSON_OBJECT_T) IS
    BEGIN
      lms_hr_sync_pkg.upsert_employee(
        p_username => p_el.get_string('username'), p_employee_no => p_el.get_string('employee_no'),
        p_name_en => p_el.get_string('name_en'), p_name_ar => p_el.get_string('name_ar'),
        p_email => p_el.get_string('email'), p_department_code => p_el.get_string('department_code'),
        p_position_code => p_el.get_string('position_code'),
        p_manager_employee_no => p_el.get_string('manager_employee_no'),
        p_status => NVL(p_el.get_string('status'), 'ACTIVE'));
    END apply_one;
  BEGIN
    p_status := 200;
    IF NOT admit('HR_SYNC', p_client_key, p_status, p_retry_after) THEN
      log_request('POST /hr/employees', 'POST', p_status, l_t0, p_client_key); RETURN;
    END IF;
    IF p_body IS NULL OR DBMS_LOB.getlength(p_body) = 0 OR DBMS_LOB.getlength(p_body) > c_max_body THEN
      send_error(400, 'bad_request', 'Body is empty or larger than ' || c_max_body || ' characters.', p_status);
      log_request('POST /hr/employees', 'POST', p_status, l_t0, p_client_key); RETURN;
    END IF;
    BEGIN
      l_root := JSON_OBJECT_T.parse(p_body);
      l_arr  := l_root.get_array('employees');
    EXCEPTION WHEN OTHERS THEN l_arr := NULL; END;
    IF l_arr IS NULL OR l_arr.get_size = 0 OR l_arr.get_size > c_max_employees THEN
      send_error(400, 'bad_request', 'Provide {"employees":[...]} with 1 to ' || c_max_employees || ' items.', p_status);
      log_request('POST /hr/employees', 'POST', p_status, l_t0, p_client_key); RETURN;
    END IF;

    -- Pass 1: create/update everyone. Each element is isolated by a savepoint.
    FOR i IN 0 .. l_arr.get_size - 1 LOOP
      l_e := TREAT(l_arr.get(i) AS JSON_OBJECT_T);
      l_emp := SUBSTR(l_e.get_string('employee_no'), 1, 30);
      SAVEPOINT sp_emp;
      BEGIN
        apply_one(l_e);
        l_ok := l_ok + 1;
      EXCEPTION WHEN OTHERS THEN
        ROLLBACK TO sp_emp;
        l_err := JSON_OBJECT_T();
        l_err.put('employee_no', l_emp);
        l_err.put('error', CASE WHEN SQLCODE BETWEEN -20999 AND -20400 THEN SUBSTR(SQLERRM, INSTR(SQLERRM, ':') + 2, 200) ELSE 'rejected' END);
        l_errors.append(l_err);
      END;
    END LOOP;
    -- Pass 2: managers that appear later in the batch than their reports (idempotent upsert re-links them).
    FOR i IN 0 .. l_arr.get_size - 1 LOOP
      l_e := TREAT(l_arr.get(i) AS JSON_OBJECT_T);
      IF l_e.get_string('manager_employee_no') IS NOT NULL THEN
        SAVEPOINT sp_mgr;
        BEGIN apply_one(l_e); EXCEPTION WHEN OTHERS THEN ROLLBACK TO sp_mgr; END;
      END IF;
    END LOOP;

    l_o.put('processed', l_arr.get_size);
    l_o.put('succeeded', l_ok);
    l_o.put('failed', l_errors.get_size);
    l_o.put('errors', l_errors);
    IF l_errors.get_size > 0 THEN p_status := 207; END IF;      -- partial success; successful rows are committed by ORDS
    send_json(l_o);
    lms_audit_pkg.log_event('HR_SYNC_BATCH', 'USER', NULL, CASE WHEN l_errors.get_size = 0 THEN 'SUCCESS' ELSE 'FAILURE' END,
                            lms_util_pkg.js('processed', l_arr.get_size, 'failed', l_errors.get_size));
    log_request('POST /hr/employees', 'POST', p_status, l_t0, p_client_key);
  EXCEPTION WHEN OTHERS THEN server_error('hr_sync', p_status);
  END hr_sync;

  -- -------------------------------------------------------------------- health -----
  PROCEDURE health(p_status OUT NUMBER) IS
    l_invalid NUMBER; l_backlog NUMBER; l_failed_n NUMBER; l_jobs_failed NUMBER; l_oldest NUMBER;
    l_o JSON_OBJECT_T := JSON_OBJECT_T();
    l_ok BOOLEAN;
  BEGIN
    SELECT COUNT(*) INTO l_invalid FROM user_objects WHERE status <> 'VALID'
       AND (object_name LIKE 'LMS\_%' ESCAPE '\' OR object_name LIKE 'V\_LMS\_%' ESCAPE '\');
    SELECT COUNT(*), NVL(ROUND(MAX(EXTRACT(DAY FROM (SYSTIMESTAMP - next_attempt_at)) * 1440
                                 + EXTRACT(HOUR FROM (SYSTIMESTAMP - next_attempt_at)) * 60
                                 + EXTRACT(MINUTE FROM (SYSTIMESTAMP - next_attempt_at)))), 0)
      INTO l_backlog, l_oldest
      FROM lms_notification_queue WHERE status = 'PENDING' AND next_attempt_at < SYSTIMESTAMP - INTERVAL '5' MINUTE;
    SELECT COUNT(*) INTO l_failed_n FROM lms_notification_queue
     WHERE status = 'FAILED' AND created_at > SYSTIMESTAMP - INTERVAL '1' DAY;
    SELECT COUNT(*) INTO l_jobs_failed FROM user_scheduler_job_run_details
     WHERE job_name LIKE 'LMS\_%' ESCAPE '\' AND status = 'FAILED' AND log_date > SYSTIMESTAMP - INTERVAL '1' DAY;

    l_ok := (l_invalid = 0 AND l_jobs_failed = 0 AND l_oldest < 30);
    p_status := CASE WHEN l_invalid = 0 THEN 200 ELSE 503 END;
    l_o.put('status', CASE WHEN l_ok THEN 'ok' ELSE 'degraded' END);
    l_o.put('invalid_objects', l_invalid);
    l_o.put('notification_backlog', l_backlog);
    l_o.put('notification_oldest_minutes', l_oldest);
    l_o.put('notifications_failed_24h', l_failed_n);
    l_o.put('job_failures_24h', l_jobs_failed);
    l_o.put('time', TO_CHAR(SYS_EXTRACT_UTC(SYSTIMESTAMP), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
    send_json(l_o);
  EXCEPTION WHEN OTHERS THEN server_error('health', p_status);
  END health;
END lms_ords_pkg;
/

-- Settings and policies used by the ORDS layer (idempotent)
MERGE INTO lms_rate_limit_policies t USING (SELECT 'HR_SYNC' op FROM dual) s ON (t.operation_name = s.op)
 WHEN NOT MATCHED THEN INSERT (operation_name, limit_count, window_seconds, fail_mode) VALUES ('HR_SYNC', 6, 60, 'CLOSED');
MERGE INTO lms_system_settings t USING (SELECT 'API_LOG_ENABLED' k FROM dual) s ON (t.setting_key = s.k)
 WHEN NOT MATCHED THEN INSERT (setting_key, setting_value, description) VALUES ('API_LOG_ENABLED', 'Y', 'Log ORDS requests to LMS_API_REQUEST_LOG (Y/N)');
MERGE INTO lms_system_settings t USING (SELECT 'CONTENT_BASE_URL' k FROM dual) s ON (t.setting_key = s.k)
 WHEN NOT MATCHED THEN INSERT (setting_key, setting_value, description) VALUES ('CONTENT_BASE_URL', 'https://content.example.invalid', 'Object-store/CDN base URL for signed content links (set per environment)');
COMMIT;
