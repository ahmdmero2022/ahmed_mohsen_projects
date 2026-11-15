# 02_DATABASE — status: written, NOT executed against Oracle 19c

Static checks that WERE run (Python, no Oracle): every DDL/view statement parses with an Oracle-dialect SQL parser
(only the `SECUREFILE` LOB clause is outside the parser's grammar); no duplicate table/constraint/index names; no
forward or missing foreign-key targets; every package-to-package call matches a declared spec member; every spec
member has a body; the validation script's table list equals the DDL. **Not run:** compilation, any test, any query.

| Script | Contents |
|---|---|
| `00_install.sql` | Ordered installer (01 → 09, 13 → 16, compile, then 11). Excludes test data |
| `01_core_schema.sql` | 21 tables: org, RBAC, categories, courses, prerequisites, modules, lessons, enrollments, lesson progress, settings, audit, security events, rate-limit policies/counters |
| `02_packages_security_ratelimit.sql` | `LMS_UTIL_PKG`, `LMS_SECURITY_PKG`, `LMS_AUDIT_PKG`, `LMS_RATE_LIMIT_PKG`, rate-limit policy seed + purge job |
| `03_remaining_tables.sql` | 35 further tables: content/versions, approvals, assignments, activity, assessments, paths, sessions, certificates, skills, feedback, notifications, API log, summary tables |
| `04_views.sql` | 16 views incl. row-level-secured reporting views and answer-key-free assessment views |
| `05_package_specs.sql` | Specs for 15 packages (all specs before any body) |
| `06_bodies_foundation.sql` | notification, approval, user, hr_sync, course |
| `07_bodies_learning.sql` | enrollment, progress, assessment, learning path, session |
| `08_bodies_outcomes.sql` | certification, feedback, skill, reporting |
| `09_seed_data.sql` | roles, permissions, role-permission matrix, categories, settings, 23 bilingual notification templates, certificate templates, feedback form, 7 scheduler jobs |
| `10_test_data.sql` | DEV/TEST only: TD-1..TD-3 data |
| `11_validation.sql` | PASS/FAIL checks (objects valid, tables, packages, key indexes, answer-key exposure, seeds, jobs, unindexed FKs) |
| `12_rollback.sql` | Drops every LMS object in the current schema (`@12_rollback.sql YES`); destructive |
| `13_apex_glue.sql` | `LMS_SECRET_PKG` (stub), `LMS_APEX_PKG` (authorization functions, post-auth, error handler, Ajax callbacks, signed content URLs, lesson renderer, file streaming), `LMS_ADMIN_PKG` (audited admin writes) |
| `14_ords_pkg.sql` | `LMS_ORDS_PKG` (handler logic for verification, catalog, HR sync, health) + `HR_SYNC` policy, `API_LOG_ENABLED`, `CONTENT_BASE_URL` settings |
| `15_views_apex.sql` | 46 views behind the APEX pages: learner, approvals, authoring, administration, monitoring, analytics |
| `16_views_lov.sql` | 30 lookup, detail, maintenance, skills and feedback views (LOVs, course outline, prerequisites, instructors, popularity, admin lists, anonymised feedback analytics) |

Counts: 56 tables, 92 views, 23 packages (168 public members), 10 application scheduler jobs (+ the rate-limit purge), 10 rate-limit policies, 31 bilingual notification templates.

## Prerequisites
- Schema owner privileges: `CREATE SESSION/TABLE/VIEW/SEQUENCE/PROCEDURE/JOB`, tablespace quota; **no DBA role**.
- `GRANT EXECUTE ON SYS.DBMS_CRYPTO` (random codes, hashing), APEX_MAIL access for e-mail, UTF-8 client for Arabic text.
- Least-privilege runtime model (recommended): APEX parsing schema gets `EXECUTE` on the packages and `SELECT` on `V_LMS_*` views only. Grant `LMS_HR_SYNC_PKG` **only** to the integration schema. The application schema must have no DML on `LMS_AUDIT_LOG`.

## Design deviations from the first documents (decided while writing code)
1. **Open-enrolment unique index excludes COMPLETED** (not just cancelled/failed/expired), so a renewal cycle can start; re-taking a completed course by self-enrolment is blocked in `LMS_ENROLLMENT_PKG` unless the certificate is inside `RENEWAL_WINDOW_DAYS`.
2. **Added tables:** `LMS_APPROVALS`, `LMS_QUESTION_BANKS`, `LMS_VENUES`, `LMS_SUM_DEPT_DAILY`, `LMS_SUM_COURSE`. Added columns: `LMS_ENROLLMENTS.INSTRUCTOR_APPROVED_FLAG`, `LMS_COURSES.CERTIFICATE_TEMPLATE_ID`/`FEEDBACK_FORM_ID`, `LMS_LEARNING_PATHS.CERTIFICATE_TEMPLATE_ID`.
3. **`LMS_CERTIFICATES`** supports course and path certificates (exactly one source, enforced by a check); idempotency via function-based unique indexes.
4. **JSON from PL/SQL** uses `LMS_UTIL_PKG.JS` (built on `JSON_OBJECT_T`) instead of `JSON_OBJECT … VALUE` in PL/SQL expressions, which I could not confirm is legal in 19c PL/SQL. `JSON_OBJECT` is used only inside SQL statements.
5. **Internal entry points** (`complete_lesson_system`, `evaluate_completion`, `apply_approval`, `apply_review`, certificate issuing, `start_renewal`, `on_course_completed`) use `ACCESSIBLE BY`, so granting package EXECUTE to the APEX schema does not expose them.

## Items to verify on first compile (known uncertainty)
- `SYS_CONTEXT('APEX$SESSION','APP_USER')` / `'APP_ID'` namespace/attribute names in APEX 24.1; fall back to `V('APP_USER')`.
- `JSON_ELEMENT_T.TO_STRING` output for string scalars (expected without quotes) in `LMS_NOTIFICATION_PKG.RENDER`.
- `APEX_UTIL.SET_SECURITY_GROUP_ID/FIND_SECURITY_GROUP_ID` + `APEX_MAIL.SEND` from a scheduler job (workspace name from setting `APEX_WORKSPACE`).
- `UPDATE … RETURNING … BULK COLLECT` combined with `IN (… FETCH FIRST n ROWS ONLY)` subquery (waitlist promotion).
- `JSON_TABLE` with a PL/SQL variable as the document source inside `CASE WHEN EXISTS/NOT EXISTS` (assessment scoring).
- Calling `LMS_UTIL_PKG.JS` with defaulted parameters from SQL is not used; only from PL/SQL.

## Not covered by these scripts
APEX page/process definitions, ORDS modules, WAF rules, PDF layout for certificates, scheduler-job credentials, wallets. Authoring screens that edit modules/lessons through Interactive Grids need either the package procedures (`add_module`, `add_lesson`) behind custom processes or DML processes that call `LMS_COURSE_PKG.CAN_MANAGE_COURSE` first; there is no `update_lesson/reorder` API yet.

## Skills and feedback procedures (latest addition)
| Package | Procedure | Permission | Notes |
|---|---|---|---|
| `LMS_SKILL_PKG` | `save_skill`, `remove_skill` | `SKILL_MANAGE` | code upper-cased, unique; delete only when unused |
| | `set_position_skill`, `copy_position_skills` | `SKILL_MANAGE` | levels 1–5, NULL removes; copy never overwrites |
| | `set_course_skill` | `SKILL_MANAGE` or course author | completion later credits the level |
| `LMS_FEEDBACK_PKG` | `save_form`, `clone_form`, `save_form_question`, `remove_form_question` | `COURSE_PUBLISH` | answered questions are immutable (order only) |
| | `assign_form` | `COURSE_PUBLISH` or course author | refused once responses exist with another form |
| | `update_review` | review owner | window = setting `REVIEW_EDIT_DAYS` (default 0 = final) |
Settings added: `FEEDBACK_MIN_RESPONSES` (5; instructors see aggregates/comments only above this), `REVIEW_EDIT_DAYS` (0).
Tests: `06_TESTING/UNIT_TESTS/skills_feedback_tests.sql` (impersonates `TD_*` users through APEX sessions; rolls back).

## Venue maintenance and feedback reminders (latest addition)
| Package | Procedure | Rules |
|---|---|---|
| `LMS_SESSION_PKG` | `save_venue`, `remove_venue` | `SESSION_MANAGE` with **ALL** scope only (instructors excluded); unique active name; positive whole capacity; deactivation and capacity cuts refused while upcoming sessions would be affected; delete only if the venue never hosted a session |
| `LMS_SESSION_PKG` | `create_session` (extended) | refuses inactive venues and seats above the venue capacity |
| `LMS_FEEDBACK_PKG` | `send_reminders` (JOB `LMS_FEEDBACK_JOB`, daily 09:25) | one reminder per completed enrolment, `FEEDBACK_REMINDER_DAYS` (3; 0 = off) after completion and within `FEEDBACK_REMINDER_WINDOW_DAYS` (30); only while a review or a questionnaire answer is missing; active learners only; marker `LMS_ENROLLMENTS.FEEDBACK_REMINDED_AT` guarantees it is never sent twice; locks rows with `SKIP LOCKED` so overlapping runs cannot double-send |
Schema changes: `LMS_ENROLLMENTS.FEEDBACK_REMINDED_AT`, index `LMS_ENR_DONE_IX (STATUS, COMPLETED_AT)`, check `LMS_VEN_CAP_CK`. Tests: `06_TESTING/UNIT_TESTS/venues_reminders_tests.sql`.

## Session editing, completion and reminders (latest addition)
| Procedure (`LMS_SESSION_PKG`) | Rules |
|---|---|
| `update_session` | permission `SESSION_MANAGE` + course scope; upcoming (SCHEDULED/PUBLISHED, not started) sessions only; seats ≥ registered learners, ≤ venue capacity; venue active; https-only link; venue or link required; no venue/trainer double booking; attendance threshold locked once attendance exists; more seats promote the waiting list; place/link/trainer change notifies registered + waiting learners (`SESSION_CHANGED`) and the new trainer (`SESSION_ASSIGNED`) |
| `complete_session` | PUBLISHED and ended; sets COMPLETED and re-evaluates course completion for each registered learner (attendance rule) |
| `close_finished_sessions` (JOB `LMS_SESSION_CLOSE_JOB`, 03:10) | auto-completes sessions that ended more than `SESSION_AUTOCLOSE_DAYS` (7; 0 = off) ago |
| `send_reminders` (JOB `LMS_SESSION_REMINDER_JOB`, every 15 min) | REGISTERED learners only (never the waiting list): `SESSION_REMINDER_LONG_HOURS` (24) and `SESSION_REMINDER_SHORT_HOURS` (1) before the start, each once per registration; no long reminder within 3 h of registering; a short reminder suppresses a late long one; trainer reminded once at the long mark; `reschedule` and a trainer change reset the markers; rows locked with `SKIP LOCKED` |
Schema: `LMS_SESSION_ENROLLMENTS.REMINDED_LONG_AT/REMINDED_SHORT_AT`, `LMS_TRAINING_SESSIONS.INSTRUCTOR_REMINDED_AT`. New templates: `SESSION_REMINDER`, `SESSION_INSTRUCTOR_REMINDER`, `SESSION_CHANGED`, `SESSION_ASSIGNED`. Tests: `06_TESTING/UNIT_TESTS/session_edit_reminders_tests.sql`.
Known limits: reminders are sent in the session's stored time zone label (`TZR`), not converted to each learner's zone; the join link is included in e-mail text for registered learners only; no ICS attachment.

## Second feedback nudge and calendar invites (latest addition)
| Item | Behaviour |
|---|---|
| `LMS_FEEDBACK_PKG.SEND_REMINDERS` (extended) | after the first reminder, **one** final nudge `FEEDBACK_NUDGE2_DAYS` (7; 0 = off) later, only while the review/answers are still missing, within `FEEDBACK_REMINDER_WINDOW_DAYS`; marker `FEEDBACK_REMINDED2_AT`; never more than two messages per enrolment; the nudge needs a prior reminder |
| `LMS_CALENDAR_PKG.BUILD_ICS` | internal (ACCESSIBLE BY the notification package): RFC 5545 text for one attendee — `METHOD` REQUEST/CANCEL, stable `UID session-<id>@ICS_UID_DOMAIN`, `SEQUENCE` from `LMS_TRAINING_SESSIONS.ICS_SEQUENCE`, `DTSTART/DTEND` in UTC, escaped text, 75-octet folding that never splits a multi-byte character, one `ATTENDEE` (the recipient only), join link only for REQUEST, `VALARM` `ICS_ALARM_MINUTES` (60; 0 = none); a cancelled session always yields CANCEL |
| `LMS_CALENDAR_PKG.MY_SESSION_ICS` / `STREAM_MY_ICS` | "Add to calendar" for the signed-in registered learner or the trainer; waiting list refused; audited; rate limited |
| Queue | `LMS_NOTIFICATION_QUEUE.ATTACH_KIND/ATTACH_REF/ATTACH_METHOD`; the file is built when the mail is sent (always current), a build failure logs `ICS_FAILED` and the mail still goes out |
| Hooks in `LMS_SESSION_PKG` | register (REGISTERED only), waitlist promotion, unregister (`SESSION_UNREGISTERED` + CANCEL), reschedule, `update_session` (place/link/trainer; old trainer gets `SESSION_UNASSIGNED` + CANCEL), `cancel_session`, `publish_session` (trainer invite); every update bumps the sequence |
Fix found while wiring this: the waitlist-promotion mail payload lacked `status`, so `{{status}}` would have rendered literally; it now carries it.
Requirements/limits: database character set AL32UTF8 (folding uses `LENGTHB`); `ICS_UID_DOMAIN` must be set per environment and never changed later (it is part of every UID); `MAIL_FROM` is the organiser address; virtual-session join links travel in the e-mail and attachment to registered learners only.
Tests: `06_TESTING/UNIT_TESTS/feedback_nudge_invites_tests.sql`.
