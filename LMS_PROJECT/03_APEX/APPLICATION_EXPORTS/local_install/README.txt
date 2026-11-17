LMS - install on your own PC (Oracle 19c+ with APEX 24.1 and ORDS, e.g. http://amohsen02-pc:8080/ords)
STATUS: these steps and scripts are written, NOT yet run. Report any error message and it will be fixed.

You need: SQLcl (or SQL*Plus) and the LMS_PROJECT folder (unzipped, e.g. C:\LMS\LMS_PROJECT).
Replace in the commands below:
  <db>        your database connect string, e.g.  localhost:1521/XEPDB1   (or FREEPDB1, ORCLPDB1 ...)
  <ws>        your APEX workspace name, e.g. SCA (Workspace Login page shows it)
  <pwd>       a password you choose for the new LMS schema
  <you>       the username you will sign in to the LMS with, e.g. AMOHSEN

Open a Command Prompt, then:

STEP 1  Create the LMS schema and assign it to the workspace   (as SYS)
  cd C:\LMS\LMS_PROJECT\03_APEX\APPLICATION_EXPORTS\local_install
  sql sys@<db> as sysdba
  SQL> @1_create_schema_as_dba.sql LMS <pwd> <ws>
  SQL> exit

STEP 2  Install the database objects   (as LMS; files contain Arabic, so use UTF-8)
  set NLS_LANG=AMERICAN_AMERICA.AL32UTF8
  cd C:\LMS\LMS_PROJECT\02_DATABASE
  sql LMS/<pwd>@<db>
  SQL> @00_install.sql
  SQL> exit
  The installer stops at the first error and ends with a PASS/FAIL validation list.

STEP 3  Create your APEX sign-in account   (as SYS; skip if it exists)
  cd C:\LMS\LMS_PROJECT\03_APEX\APPLICATION_EXPORTS\local_install
  sql sys@<db> as sysdba
  SQL> @3_create_apex_user_as_dba.sql <ws> <you> <your-password> you@example.com
  SQL> exit

STEP 4  Make that account the first LMS system administrator   (as LMS)
  cd C:\LMS\LMS_PROJECT\02_DATABASE
  sql LMS/<pwd>@<db>
  SQL> @17_bootstrap_sysadmin.sql <you> E0001 "Your Name" you@example.com
  SQL> exit
  (Optional demo data: @10_test_data.sql)

STEP 5  Import the application (one app, 500 "Enterprise LMS")   (as LMS)
  cd C:\LMS\LMS_PROJECT\03_APEX\APPLICATION_EXPORTS
  sql LMS/<pwd>@<db>
  SQL> @install_single_app.sql <ws> LMS
  SQL> exit
  Or in the browser: http://amohsen02-pc:8080/ords -> sign in to <ws> -> App Builder -> Import -> f500.sql
  -> parsing schema LMS -> keep application ID 500.

STEP 6  Open it
  http://amohsen02-pc:8080/ords/r/<ws>/lms-portal/home
  Sign in with <you> and your password.
  Your account is a system administrator only. Grant yourself more roles (e.g. TRAINING_ADMIN, LEARNER)
  from another administrator account, or in SQL as LMS:
    insert into lms_user_roles (user_id, role_id)
      select u.user_id, r.role_id from lms_users u, lms_roles r
       where u.username = upper('<you>') and r.role_code in ('LEARNER','TRAINING_ADMIN','INSTRUCTOR');
    commit;
  (Administrators cannot change their own roles in the application, by design.)

If something fails, copy the exact error (and the step number) and send it.
