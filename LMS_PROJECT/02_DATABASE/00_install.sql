-- =============================================================================
-- LMS database installer | run as the LMS schema owner with SQLcl or SQL*Plus
-- Prerequisite (once, as DBA):  GRANT EXECUTE ON SYS.DBMS_CRYPTO TO <schema>;
--   plus APEX_MAIL usage (APEX workspace mapped to this schema) and an SMTP ACL if not using instance mail settings.
-- Encoding: files contain Arabic text. Use a UTF-8 client:  export NLS_LANG=AMERICAN_AMERICA.AL32UTF8
-- Test data (10_test_data.sql) is NOT included: DEV/TEST only.
-- STATUS: written, NOT executed.
-- =============================================================================
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
SET DEFINE OFF
SET SERVEROUTPUT ON SIZE UNLIMITED
@01_core_schema.sql
@02_packages_security_ratelimit.sql
@03_remaining_tables.sql
@04_views.sql
@05_package_specs.sql
@06_bodies_foundation.sql
@07_bodies_learning.sql
@08_bodies_outcomes.sql
@09_seed_data.sql
@13_apex_glue.sql
@14_ords_pkg.sql
@15_views_apex.sql
@16_views_lov.sql
-- NOTE: 09 runs before 13/14 on purpose (14 adds one setting + one policy). 08 (reporting) and 13 reference views created in 15/16;
-- they compile INVALID first and the compile_schema call below validates them. Package compile errors do not raise SQL errors; fail explicitly if anything is invalid:
BEGIN
  DBMS_UTILITY.compile_schema(schema => SYS_CONTEXT('USERENV','CURRENT_SCHEMA'), compile_all => FALSE);
END;
/
SHOW ERRORS
@11_validation.sql
