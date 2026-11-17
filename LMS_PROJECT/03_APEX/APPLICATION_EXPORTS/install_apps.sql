-- =============================================================================
-- Install the five LMS applications (200-240) with SQLcl or SQL*Plus.
--
-- Usage, from this folder, connected as a user with APEX_ADMINISTRATOR_ROLE (or as the parsing schema):
--   @install_apps.sql <WORKSPACE_NAME> <PARSING_SCHEMA>
-- Example:
--   @install_apps.sql SCA LMS
--
-- Prerequisites: README.md in this folder (database objects installed in <PARSING_SCHEMA> first).
-- Each file replaces an existing application with the same ID in that workspace.
-- STATUS: written, NOT executed.
-- =============================================================================
set define on verify off feedback off
whenever sqlerror exit failure rollback
define WS  = '&1'
define SCH = '&2'
prompt Installing LMS applications 200-240 into workspace &WS., parsing schema &SCH.

begin apex_application_install.clear_all; apex_application_install.set_workspace(upper('&WS.')); apex_application_install.set_schema(upper('&SCH.')); end;
/
@f200.sql
set define on
begin apex_application_install.clear_all; apex_application_install.set_workspace(upper('&WS.')); apex_application_install.set_schema(upper('&SCH.')); end;
/
@f210.sql
set define on
begin apex_application_install.clear_all; apex_application_install.set_workspace(upper('&WS.')); apex_application_install.set_schema(upper('&SCH.')); end;
/
@f220.sql
set define on
begin apex_application_install.clear_all; apex_application_install.set_workspace(upper('&WS.')); apex_application_install.set_schema(upper('&SCH.')); end;
/
@f230.sql
set define on
begin apex_application_install.clear_all; apex_application_install.set_workspace(upper('&WS.')); apex_application_install.set_schema(upper('&SCH.')); end;
/
@f240.sql
prompt Done. Sign in at .../ords/r/<workspace>/lms-learning/home (application 200).
