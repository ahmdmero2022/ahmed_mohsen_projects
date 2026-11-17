-- =============================================================================
-- Step 3 - run as SYS / SYSTEM (or any user with APEX_ADMINISTRATOR_ROLE).
--   @3_create_apex_user_as_dba.sql <APEX_WORKSPACE> <USERNAME> <PASSWORD> <EMAIL>
-- Creates the APEX account you sign in to the LMS with (development sign-in = Oracle APEX Accounts).
-- Use the SAME username in step 4 (17_bootstrap_sysadmin.sql). Skip if the account already exists.
-- STATUS: written, NOT executed.
-- =============================================================================
set define on verify off
whenever sqlerror exit failure
begin
  apex_util.set_workspace(p_workspace => upper('&1'));
  apex_util.create_user(p_user_name                    => upper('&2'),
                        p_web_password                 => '&3',
                        p_email_address                => '&4',
                        p_change_password_on_first_use => 'N');
  commit;
end;
/
prompt APEX user &2 created in workspace &1.
