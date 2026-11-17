-- =============================================================================
-- Install the single LMS application (500, all five modules) with SQLcl or SQL*Plus.
-- Usage, from this folder:  @install_single_app.sql <WORKSPACE_NAME> <PARSING_SCHEMA>
-- Prerequisites: README.md (database objects installed in <PARSING_SCHEMA> first).
-- STATUS: written, NOT executed.
-- =============================================================================
set define on verify off feedback off
whenever sqlerror exit failure rollback
begin
  apex_application_install.clear_all;
  apex_application_install.set_workspace(upper('&1'));
  apex_application_install.set_schema(upper('&2'));
end;
/
@f500.sql
prompt Done. Sign in at .../ords/r/<workspace>/lms-portal/home
