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

Counts: 56 tables, 91 views, 22 packages (158 public members), 7 scheduler jobs, 10 rate-limit policies, 23 bilingual notification templates.

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
