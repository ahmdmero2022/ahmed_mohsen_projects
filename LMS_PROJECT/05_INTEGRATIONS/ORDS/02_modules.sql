-- =============================================================================
-- ORDS step 2: REST modules (public verification, catalog, HR sync, ops health)
-- STATUS: written, NOT executed. Requires 01_enable_roles_clients.sql and DB scripts 01-14.
-- Run as the REST-enabled schema. Substitution variables: &owner (schema that owns the LMS packages;
-- use the same value as the REST schema when they are one schema) and &allowed_origin (CORS origin for /public).
--
-- Handler contract (see lms_ords_pkg): the package writes the JSON body and returns the HTTP status and
-- Retry-After through OUT parameters; the handler copies them into :status_code and the Retry-After response
-- header parameter. Confirm on your ORDS version that :status_code and HEADER/OUT parameters behave this way
-- for plsql/block handlers (see TEST I-06/I-07/R-14 in 06_TESTING/INTEGRATION_TESTS/ords_smoke_test.sh).
-- =============================================================================
SET DEFINE ON
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

-- Re-runnable: drop the modules first (ignore "not found").
BEGIN
  FOR m IN (SELECT column_value n FROM TABLE(sys.odcivarchar2list('lms.public','lms.catalog','lms.hr','lms.ops'))) LOOP
    BEGIN ORDS.delete_module(p_module_name => m.n); EXCEPTION WHEN OTHERS THEN NULL; END;
  END LOOP;
  COMMIT;
END;
/

-- =============================== lms.public  /lms/public/ ===========================
BEGIN
  ORDS.define_module(p_module_name => 'lms.public', p_base_path => '/public/', p_items_per_page => 0,
                     p_status => 'PUBLISHED', p_comments => 'Unauthenticated, rate-limited, minimal-disclosure endpoints');
  ORDS.define_template(p_module_name => 'lms.public', p_pattern => 'certificates/:code');
  ORDS.define_handler(p_module_name => 'lms.public', p_pattern => 'certificates/:code', p_method => 'GET',
                      p_source_type => ORDS.source_type_plsql, p_items_per_page => 0,
                      p_comments => 'Verify a certificate by its verification code',
                      p_source => q'[DECLARE
  l_status NUMBER; l_retry NUMBER;
BEGIN
  &owner..lms_ords_pkg.verify_certificate(:code, :client_ip, l_status, l_retry);
  :status_code := l_status;
  IF l_retry IS NOT NULL THEN :retry_after := TO_CHAR(l_retry); END IF;
END;]');
  ORDS.define_parameter(p_module_name => 'lms.public', p_pattern => 'certificates/:code', p_method => 'GET',
                        p_name => 'X-LMS-Client-IP', p_bind_variable_name => 'client_ip',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.define_parameter(p_module_name => 'lms.public', p_pattern => 'certificates/:code', p_method => 'GET',
                        p_name => 'Retry-After', p_bind_variable_name => 'retry_after',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'OUT');
  ORDS.set_module_origins_allowed(p_module_name => 'lms.public', p_origins_allowed => '&allowed_origin');
  COMMIT;
END;
/

-- =============================== lms.catalog /lms/catalog/ ==========================
BEGIN
  ORDS.define_module(p_module_name => 'lms.catalog', p_base_path => '/catalog/', p_items_per_page => 0,
                     p_status => 'PUBLISHED', p_comments => 'Read-only published course catalog (OAuth2: lms.catalog_read)');

  ORDS.define_template(p_module_name => 'lms.catalog', p_pattern => 'courses');
  ORDS.define_handler(p_module_name => 'lms.catalog', p_pattern => 'courses', p_method => 'GET',
                      p_source_type => ORDS.source_type_plsql, p_items_per_page => 0,
                      p_comments => 'Search published courses',
                      p_source => q'[DECLARE
  l_status NUMBER; l_retry NUMBER;
BEGIN
  &owner..lms_ords_pkg.catalog_search(:q, :category, :limit, :offset, :client_ip, l_status, l_retry);
  :status_code := l_status;
  IF l_retry IS NOT NULL THEN :retry_after := TO_CHAR(l_retry); END IF;
END;]');
  FOR p IN (SELECT column_value n FROM TABLE(sys.odcivarchar2list('q','category','limit','offset'))) LOOP
    ORDS.define_parameter(p_module_name => 'lms.catalog', p_pattern => 'courses', p_method => 'GET',
                          p_name => p.n, p_bind_variable_name => p.n, p_source_type => 'URI',
                          p_param_type => 'STRING', p_access_method => 'IN');
  END LOOP;
  ORDS.define_parameter(p_module_name => 'lms.catalog', p_pattern => 'courses', p_method => 'GET',
                        p_name => 'X-LMS-Client-IP', p_bind_variable_name => 'client_ip',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.define_parameter(p_module_name => 'lms.catalog', p_pattern => 'courses', p_method => 'GET',
                        p_name => 'Retry-After', p_bind_variable_name => 'retry_after',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'OUT');

  ORDS.define_template(p_module_name => 'lms.catalog', p_pattern => 'courses/:id');
  ORDS.define_handler(p_module_name => 'lms.catalog', p_pattern => 'courses/:id', p_method => 'GET',
                      p_source_type => ORDS.source_type_plsql, p_items_per_page => 0,
                      p_comments => 'Published course details',
                      p_source => q'[DECLARE
  l_status NUMBER; l_retry NUMBER;
BEGIN
  &owner..lms_ords_pkg.catalog_course(:id, :client_ip, l_status, l_retry);
  :status_code := l_status;
  IF l_retry IS NOT NULL THEN :retry_after := TO_CHAR(l_retry); END IF;
END;]');
  ORDS.define_parameter(p_module_name => 'lms.catalog', p_pattern => 'courses/:id', p_method => 'GET',
                        p_name => 'X-LMS-Client-IP', p_bind_variable_name => 'client_ip',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.define_parameter(p_module_name => 'lms.catalog', p_pattern => 'courses/:id', p_method => 'GET',
                        p_name => 'Retry-After', p_bind_variable_name => 'retry_after',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'OUT');
  COMMIT;
END;
/

-- =============================== lms.hr  /lms/hr/ ===================================
BEGIN
  ORDS.define_module(p_module_name => 'lms.hr', p_base_path => '/hr/', p_items_per_page => 0,
                     p_status => 'PUBLISHED', p_comments => 'HR system integration (OAuth2: lms.hr_sync)');
  ORDS.define_template(p_module_name => 'lms.hr', p_pattern => 'employees');
  ORDS.define_handler(p_module_name => 'lms.hr', p_pattern => 'employees', p_method => 'POST',
                      p_source_type => ORDS.source_type_plsql, p_items_per_page => 0,
                      p_mimes_allowed => 'application/json',
                      p_comments => 'Upsert up to 500 employees; 200 all ok, 207 partial, 400 malformed',
                      p_source => q'[DECLARE
  l_status NUMBER; l_retry NUMBER;
BEGIN
  &owner..lms_ords_pkg.hr_sync(:body_text, :client_ip, l_status, l_retry);
  :status_code := l_status;
  IF l_retry IS NOT NULL THEN :retry_after := TO_CHAR(l_retry); END IF;
END;]');
  ORDS.define_parameter(p_module_name => 'lms.hr', p_pattern => 'employees', p_method => 'POST',
                        p_name => 'X-LMS-Client-IP', p_bind_variable_name => 'client_ip',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'IN');
  ORDS.define_parameter(p_module_name => 'lms.hr', p_pattern => 'employees', p_method => 'POST',
                        p_name => 'Retry-After', p_bind_variable_name => 'retry_after',
                        p_source_type => 'HEADER', p_param_type => 'STRING', p_access_method => 'OUT');
  COMMIT;
END;
/

-- =============================== lms.ops  /lms/ops/ =================================
BEGIN
  ORDS.define_module(p_module_name => 'lms.ops', p_base_path => '/ops/', p_items_per_page => 0,
                     p_status => 'PUBLISHED', p_comments => 'Operational health (OAuth2: lms.ops)');
  ORDS.define_template(p_module_name => 'lms.ops', p_pattern => 'health');
  ORDS.define_handler(p_module_name => 'lms.ops', p_pattern => 'health', p_method => 'GET',
                      p_source_type => ORDS.source_type_plsql, p_items_per_page => 0,
                      p_comments => '200 ok/degraded, 503 when LMS objects are invalid',
                      p_source => q'[DECLARE
  l_status NUMBER;
BEGIN
  &owner..lms_ords_pkg.health(l_status);
  :status_code := l_status;
END;]');
  COMMIT;
END;
/

-- Resulting endpoints (base path /ords/lms):
--   GET  /ords/lms/public/certificates/{code}
--   GET  /ords/lms/catalog/courses?q=&category=&limit=&offset=
--   GET  /ords/lms/catalog/courses/{id}
--   POST /ords/lms/hr/employees
--   GET  /ords/lms/ops/health
-- Needed grants when the REST schema differs from the owner schema (run as the OWNER):
--   GRANT EXECUTE ON lms_ords_pkg TO <rest_schema>;     -- nothing else: no table, view or other package grants
