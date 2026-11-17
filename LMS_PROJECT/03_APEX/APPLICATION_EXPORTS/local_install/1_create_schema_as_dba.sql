-- =============================================================================
-- Step 1 - run as SYS (or SYSTEM) in the PDB that APEX uses.
--   @1_create_schema_as_dba.sql <SCHEMA> <SCHEMA_PASSWORD> <APEX_WORKSPACE>
--   example:  @1_create_schema_as_dba.sql LMS MyStrongPwd#1 SCA
-- Creates the schema for the LMS database objects and assigns it to your APEX workspace.
-- STATUS: written, NOT executed.
-- =============================================================================
set define on verify off
whenever sqlerror exit failure
define SCH = &1
define PWD = &2
define WS  = &3

create user &SCH identified by "&PWD" default tablespace users quota unlimited on users;
grant create session, create table, create view, create sequence, create procedure, create trigger,
      create type, create synonym, create job to &SCH;
-- needs SYS (SYSTEM cannot grant on SYS objects unless it holds the privilege with grant option)
grant execute on sys.dbms_crypto to &SCH;

begin
  apex_instance_admin.add_schema(p_workspace => upper('&WS'), p_schema => upper('&SCH'));
  commit;
end;
/
prompt Schema &SCH created and assigned to workspace &WS.
