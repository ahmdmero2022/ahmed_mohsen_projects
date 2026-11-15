-- =============================================================================
-- FULL ROLLBACK (drops every LMS object in the CURRENT schema) | Oracle 19c
-- STATUS: written, NOT executed. DESTRUCTIVE: all LMS data is lost. DEV/TEST only unless a
-- verified backup exists. For a production release rollback use the release's reverse
-- migration or RMAN/Flashback (doc 07 section 9), not this script.
-- Usage:  @12_rollback.sql YES
-- =============================================================================
SET SERVEROUTPUT ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
-- first script argument is the confirmation word (SQL*Plus/SQLcl prompt for it when omitted)
DEFINE confirm = '&1'

DECLARE
  l_confirm VARCHAR2(10) := '&confirm';
  l_user    VARCHAR2(128) := SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA');
  PROCEDURE run(p_sql VARCHAR2) IS
  BEGIN
    EXECUTE IMMEDIATE p_sql;
  EXCEPTION WHEN OTHERS THEN
    DBMS_OUTPUT.put_line('skipped: ' || p_sql || ' -> ' || SQLERRM);
  END run;
BEGIN
  IF UPPER(l_confirm) <> 'YES' THEN
    RAISE_APPLICATION_ERROR(-20998, 'Rollback not confirmed. Re-run as: @12_rollback.sql YES');
  END IF;
  DBMS_OUTPUT.put_line('Dropping LMS objects in schema ' || l_user);

  FOR r IN (SELECT job_name FROM user_scheduler_jobs WHERE job_name LIKE 'LMS\_%' ESCAPE '\') LOOP
    run('BEGIN DBMS_SCHEDULER.drop_job(job_name => ''' || r.job_name || ''', force => TRUE); END;');
  END LOOP;
  FOR r IN (SELECT object_name FROM user_objects WHERE object_type = 'PACKAGE' AND object_name LIKE 'LMS\_%' ESCAPE '\') LOOP
    run('DROP PACKAGE ' || DBMS_ASSERT.enquote_name(r.object_name, FALSE));
  END LOOP;
  FOR r IN (SELECT object_name FROM user_objects WHERE object_type = 'VIEW'
             AND (object_name LIKE 'LMS\_%' ESCAPE '\' OR object_name LIKE 'V\_LMS\_%' ESCAPE '\')) LOOP
    run('DROP VIEW ' || DBMS_ASSERT.enquote_name(r.object_name, FALSE));
  END LOOP;
  -- CASCADE CONSTRAINTS removes the foreign keys, so table order does not matter.
  FOR r IN (SELECT table_name FROM user_tables WHERE table_name LIKE 'LMS\_%' ESCAPE '\') LOOP
    run('DROP TABLE ' || DBMS_ASSERT.enquote_name(r.table_name, FALSE) || ' CASCADE CONSTRAINTS PURGE');
  END LOOP;
  DBMS_OUTPUT.put_line('Rollback complete.');
END;
/
