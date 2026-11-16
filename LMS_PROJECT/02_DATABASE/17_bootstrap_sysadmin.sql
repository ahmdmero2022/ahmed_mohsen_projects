-- =============================================================================
-- 17_bootstrap_sysadmin.sql | create the FIRST system administrator
-- Run ONCE as the LMS schema owner, after 00_install.sql, in a UTF-8 client.
--
-- Why this exists: LMS_USER_PKG.GRANT_ROLE requires the ROLE_ADMIN permission, which only
-- SYS_ADMIN holds, so the very first SYS_ADMIN cannot be granted through the application.
-- This script is the only place that writes LMS_USER_ROLES directly for that purpose.
--
-- Usage:
--   @17_bootstrap_sysadmin.sql <USERNAME> <EMPLOYEE_NO> "<FULL NAME>" <EMAIL> ["<FULL NAME AR>"] [FORCE]
--   Example:
--   @17_bootstrap_sysadmin.sql JSMITH E0001 "Jane Smith" jane.smith@example.com "جين سميث"
--
--   USERNAME  must equal the value APEX reports as APP_USER after login (SSO user name), stored
--             upper-cased. If it does not match, that person will see "no mapped active user".
--   FORCE     only to add another SYS_ADMIN while one already exists (normal rule: refuse).
--
-- Safe to re-run: an existing user is re-activated and the role grant is idempotent.
-- Writes one audit row (BOOTSTRAP_ADMIN) and one HIGH security event. Commits at the end.
-- After first login, grant further roles through the application (Administration, page 73).
-- STATUS: written, NOT executed.
-- =============================================================================
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET VERIFY OFF
SET DEFINE ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- optional arguments default to empty
COLUMN a5 NEW_VALUE 5 NOPRINT
COLUMN a6 NEW_VALUE 6 NOPRINT
SELECT '' a5, '' a6 FROM dual WHERE 1 = 0;

DECLARE
  c_user   CONSTANT VARCHAR2(100)  := UPPER(TRIM(q'[&1]'));
  c_emp    CONSTANT VARCHAR2(30)   := TRIM(q'[&2]');
  c_name   CONSTANT VARCHAR2(200)  := TRIM(q'[&3]');
  c_email  CONSTANT VARCHAR2(254)  := LOWER(TRIM(q'[&4]'));
  c_name_ar CONSTANT VARCHAR2(200) := NVL(TRIM(q'[&5]'), TRIM(q'[&3]'));
  c_force  CONSTANT BOOLEAN        := UPPER(TRIM(q'[&6]')) = 'FORCE';
  l_role   NUMBER;
  l_id     NUMBER;
  l_others NUMBER;
  l_exists BOOLEAN := TRUE;
  l_status VARCHAR2(10);
BEGIN
  -- ---- input checks -----------------------------------------------------------------------
  IF c_user IS NULL OR NOT REGEXP_LIKE(c_user, '^[^[:space:]]{3,100}$') THEN
    RAISE_APPLICATION_ERROR(-20990, 'USERNAME must be 3-100 characters with no spaces');
  END IF;
  IF c_emp IS NULL OR NOT REGEXP_LIKE(c_emp, '^[^[:space:]]{1,30}$') THEN
    RAISE_APPLICATION_ERROR(-20990, 'EMPLOYEE_NO must be 1-30 characters with no spaces');
  END IF;
  IF c_name IS NULL THEN
    RAISE_APPLICATION_ERROR(-20990, 'FULL NAME is required');
  END IF;
  IF c_email IS NULL OR NOT REGEXP_LIKE(c_email, '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$') THEN
    RAISE_APPLICATION_ERROR(-20990, 'EMAIL is not a valid address');
  END IF;

  -- ---- the role must have been seeded by 09_seed_data.sql ---------------------------------
  BEGIN
    SELECT role_id INTO l_role FROM lms_roles WHERE role_code = 'SYS_ADMIN';
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20991, 'Role SYS_ADMIN not found: run 09_seed_data.sql (00_install.sql) first');
  END;

  -- ---- refuse when another active SYS_ADMIN already exists (unless FORCE) ------------------
  SELECT COUNT(*) INTO l_others
    FROM lms_user_roles ur
    JOIN lms_users u ON u.user_id = ur.user_id
   WHERE ur.role_id = l_role AND u.status = 'ACTIVE' AND u.username <> c_user;
  IF l_others > 0 AND NOT c_force THEN
    RAISE_APPLICATION_ERROR(-20992, 'An active SYS_ADMIN already exists (' || l_others ||
      '). Grant roles through the application, or re-run with FORCE as the 6th argument.');
  END IF;

  -- ---- find or create the user -------------------------------------------------------------
  BEGIN
    SELECT user_id, status INTO l_id, l_status FROM lms_users WHERE username = c_user;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    l_exists := FALSE;
  END;

  IF l_exists THEN
    IF l_status <> 'ACTIVE' THEN
      UPDATE lms_users SET status = 'ACTIVE', updated_at = SYSTIMESTAMP, row_version = row_version + 1
       WHERE user_id = l_id;
      DBMS_OUTPUT.put_line('Existing user ' || c_user || ' re-activated (was ' || l_status || ').');
    ELSE
      DBMS_OUTPUT.put_line('Existing user ' || c_user || ' reused.');
    END IF;
  ELSE
    DECLARE l_clash NUMBER;
    BEGIN
      SELECT COUNT(*) INTO l_clash FROM lms_users WHERE employee_no = c_emp;
      IF l_clash > 0 THEN
        RAISE_APPLICATION_ERROR(-20993, 'EMPLOYEE_NO ' || c_emp || ' already belongs to another user');
      END IF;
    END;
    INSERT INTO lms_users (username, employee_no, full_name_en, full_name_ar, email, status, preferred_lang, hired_on)
    VALUES (c_user, c_emp, c_name, c_name_ar, c_email, 'ACTIVE', 'en', TRUNC(SYSDATE))
    RETURNING user_id INTO l_id;
    DBMS_OUTPUT.put_line('User ' || c_user || ' created (user_id ' || l_id || ').');
  END IF;

  -- ---- grant the role (idempotent; granted_by stays NULL = bootstrap) ----------------------
  MERGE INTO lms_user_roles t
  USING (SELECT l_id user_id, l_role role_id FROM dual) s
     ON (t.user_id = s.user_id AND t.role_id = s.role_id)
   WHEN NOT MATCHED THEN INSERT (user_id, role_id, granted_by) VALUES (s.user_id, s.role_id, NULL);

  -- ---- audit trail (autonomous writers) ----------------------------------------------------
  lms_audit_pkg.log_event('BOOTSTRAP_ADMIN', 'USER', l_id, 'SUCCESS',
                          lms_util_pkg.js('role', 'SYS_ADMIN', 'db_user', SYS_CONTEXT('USERENV', 'SESSION_USER')));
  lms_audit_pkg.log_security('BOOTSTRAP_ADMIN', l_id, NULL, 'BOOTSTRAP', 'HIGH',
                             lms_util_pkg.js('username', c_user, 'db_user', SYS_CONTEXT('USERENV', 'SESSION_USER')));

  COMMIT;
  DBMS_OUTPUT.put_line('SYS_ADMIN granted to ' || c_user || '. Sign in through APEX as this user to verify.');
END;
/

PROMPT
PROMPT Current active SYS_ADMIN users:
COLUMN username FORMAT A30
COLUMN full_name_en FORMAT A30
SELECT u.username, u.full_name_en, u.status
  FROM lms_users u
  JOIN lms_user_roles ur ON ur.user_id = u.user_id
  JOIN lms_roles r ON r.role_id = ur.role_id AND r.role_code = 'SYS_ADMIN'
 ORDER BY u.username;
