# App 220 — LMS Administration: page specifications

Status: specification, not built. Conventions: `../SHARED_COMPONENTS/README.md`. App scheme `LMS_AUTH_ACTIVE`. **Two audiences, two scheme tiers:**
training administrators (course/enrolment/schedule/certificate pages, `LMS_AUTH_TRAINING_ADMIN`) and system administrators
(users/roles/settings/audit/rate limits/monitoring, specific `LMS_AUTH_*` per page). A system administrator cannot enrol, approve or publish
(segregation of duties is in the seed permissions, not only in the menu).
Every list reads a `V_LMS_*` view that **itself checks the permission** (a mis-assigned page scheme still returns no rows). Every write is a package call that re-checks permission and is rate limited (`ADMIN_WRITE` 30/min).

> **`*_l10n` notation.** Wherever a spec writes `X_l10n` (e.g. `title_l10n`, `module_title_l10n`, `full_name_l10n`) it stands for the language expression
> `case when :LMS_LANG = 'ar' and X_ar is not null then X_ar else X_en end` over the view's `X_en` / `X_ar` columns. Write it out in the region SQL
> (or as a Cards/IR *computed column*); there is deliberately no PL/SQL function for it, to avoid a context switch per row.

**Navigation (training admin)**: Dashboard (1) · Courses (10) · Approvals (12) · Reviews (14) · Feedback forms (15) · Enrolments (20) · Assignments (25) · Sessions (30) · Venues (31) · Certificates (40) · Categories (50).
**Navigation (system admin)**: Settings (60) · Notification templates (61) · Users (70) · Roles & permissions (73) · Audit (80) · Security events (81) · Integration logs (82) · Rate limits (90) · Monitoring (95).

| Pg | Name | Scheme | Pg | Name | Scheme |
|---|---|---|---|---|---|
| 1 | Admin dashboard | either | 61 | Notification templates | TEMPLATES |
| 10 / 11 | Courses / Course admin dialog | TRAINING_ADMIN | 70 / 71 / 72 | Users / User dialog / Roles dialog | SYSADMIN |
| 12 | Approvals inbox | APPROVER | 73 | Roles & permissions matrix | ROLE_ADMIN |
| 20 / 21 | Enrolments / Assign dialog | ENROLL_ASSIGN | 80 | Audit log | AUDIT |
| 25 / 26 | Mandatory assignments / New assignment | ENROLL_ASSIGN | 81 | Security events | AUDIT |
| 30 / 31 | Training schedule (sessions) / Venues | SESSION_MANAGE | 82 | Integration logs | AUDIT |
| 40 / 41 / 42 | Certificates / Revoke dialog / Templates | CERT_POLICY | 90 | Rate-limit policies | RATELIMIT |
| 50 | Categories | TRAINING_ADMIN | 95 | Monitoring dashboard | AUDIT |
| 14 / 15 | Reviews moderation / Feedback forms & questions | TRAINING_ADMIN | | | |
| 60 | System settings | SETTINGS | | | |

## Page 1 — Admin dashboard
`R_KPIS` (KPI tiles) from `lms_reporting_pkg.org_kpis` is a REF CURSOR and cannot back a region directly; use
`select * from v_lms_exec_courses` aggregates for training admins (scheme `REPORT_ORG`), and `V_LMS_QUEUE_STATUS`/`V_LMS_JOB_STATUS` for system admins (those two views return rows only to `AUDIT_VIEW` holders). Tiles shown depend on the caller's schemes (region-level authorization): pending approvals (`select count(*) from v_lms_approvals_inbox`), overdue mandatory enrolments (`select count(*) from v_lms_team_enrollments where overdue_flag='Y'`), courses under review, failed notifications (24 h), job failures.

## Page 10/11 — Courses
**10**: IR on `v_lms_my_courses` (training admins get ALL scope → every course). Columns: code, title, category, status badge, delivery, active learners, pending grading, updated. Row actions: *Open builder* (→ app 210 page 11 via `apex_page.get_url(p_application=>210, p_page=>11, p_items=>'P11_COURSE_ID', p_values=>:COURSE_ID)`), *Admin…* → 11. Facets: status, category, delivery.
**11** (modal, `P11_COURSE_ID` protected): status actions as buttons shown by status: PUBLISHED → *Suspend*; SUSPENDED → *Reinstate*; any non-archived with no open enrolments → *Archive* (confirm); instructors sub-IG (`lms_course_pkg.set_instructor(:COURSE_ID, :USER_ID, :ROLE)`, user select `v_lms_lov_instructors`). Processes call `lms_course_pkg.suspend / reinstate / archive`. Deleting courses is not offered (BR-12).

## Page 12 — Approvals inbox
IR on `v_lms_approvals_inbox` (course publication + enrolments the caller may decide; never their own requests). Columns: type, item, requester, requested, due, overdue (text), escalations. Row button → **dialog 13** (`P13_APPROVAL_ID` protected) with note textarea and buttons *Approve* / *Reject* (reject requires a note — validation): `lms_approval_pkg.decide(:P13_APPROVAL_ID, 'APPROVE'|'REJECT', :P13_NOTE);`. For course publication show a *Review* link that opens the course read-only (app 210 page 16). Approving a course creates a version snapshot and publishes it; rejecting returns it to DRAFT with the note.

## Pages 14/15 — Reviews moderation and feedback forms
**14** (Reviews): IR on `v_lms_reviews_moderation` (all reviews incl. hidden: course, rating, text, status; `COURSE_PUBLISH` ALL only). Row action *Hide/Show* → `lms_feedback_pkg.set_review_visibility(:REVIEW_ID, :SHOW = 'Y')`; audited.
**15** (Feedback forms): master-detail. Master IG on `v_lms_feedback_forms_admin` (name EN/AR, active; read-only `questions`, `courses_using`, `responses`): save `:FORM_ID := lms_feedback_pkg.save_form(:FORM_ID, :NAME_EN, :NAME_AR, :ACTIVE_FLAG);` (deactivation refused while published courses use the form); row button *Clone* → `lms_feedback_pkg.clone_form(:FORM_ID)` (the way to change a form that already has responses). Detail IG on `v_lms_feedback_questions_admin` for the selected form (text EN/AR, answer type RATING/TEXT, order; read-only `responses`): save `:QUESTION_ID := lms_feedback_pkg.save_form_question(:QUESTION_ID, :P15_FORM_ID, :TEXT_EN, :TEXT_AR, :ANSWER_TYPE, :SORT_ORDER);` delete → `lms_feedback_pkg.remove_form_question(:QUESTION_ID);`. Questions that already have responses are locked except for their order. Attaching a form to a course: app 210 page 15 (authors) or `lms_feedback_pkg.assign_form` by training admins.

## Pages 20/21 — Enrolment management
**20**: IR on `v_lms_team_enrollments` (scope ALL for admins): user, department, course, status, type, due, progress, overdue. Facets: status, type, department (`v_lms_lov_departments`), overdue. Row actions: *Cancel* (`lms_enrollment_pkg.cancel`, confirm), *Promote waitlist* for the course (`lms_enrollment_pkg.promote_waitlist`). Download CSV/Excel enabled (Before Download process audits `EXPORT`; the view already limits rows).
**21** (dialog *Assign*): `P21_USER_ID` (Popup LOV `v_lms_lov_users`), `P21_COURSE_ID` (published courses), `P21_DUE_DATE`, `P21_TYPE` (ADMIN / MANDATORY). Process `lms_enrollment_pkg.assign(:P21_USER_ID, :P21_COURSE_ID, :P21_DUE_DATE, :P21_TYPE, :P21_ENR_ID, :P21_STATUS);`. Bulk selection: IG row selection + button → loops the same call with a savepoint per row, collecting failures into a result report (never stop at the first error).

## Pages 25/26 — Mandatory assignments
**25**: IR on `v_lms_assignments_admin` (target, course, due, enrolled, completed, % complete); *Close assignment* → `lms_enrollment_pkg.close_assignment(:ASSIGNMENT_ID)` (existing enrolments are kept; the nightly sync stops adding people). **26**: dialog `P26_COURSE_ID`, `P26_TARGET_TYPE` (USER/DEPARTMENT/POSITION), `P26_TARGET_ID` (cascading select by type), `P26_DUE_DATE` (≥ today, validation); process `:P26_ASSIGNMENT_ID := lms_enrollment_pkg.create_assignment(:P26_COURSE_ID, :P26_TARGET_TYPE, :P26_TARGET_ID, :P26_DUE_DATE);` (set-based expansion; people who do not yet meet the prerequisites are picked up by the nightly `LMS_ASSIGN_SYNC_JOB`). Compliance chart: `select department_en, compliance_pct from v_lms_mandatory_compliance`.

## Page 30 — Training schedule
Calendar + IR on `v_lms_sessions_manage` (admins: scope ALL; columns include registered/waitlisted counts); *New session* / *Publish* / *Cancel* / *Reschedule* / *Attendance* open app 210 pages 41/42 (same package calls). Facets: course, instructor, venue, status.

## Page 31 — Venues
Authorization `LMS_AUTH_SESSION_MANAGE` **and** a region condition on scope ALL (instructors hold the permission with ASSIGNED scope and cannot maintain venues; the view returns no rows to them and the package refuses). IG on `v_lms_venues_admin`: name EN/AR, address, capacity (empty = unlimited), active; read-only `sessions_total`, `sessions_upcoming`, `max_upcoming_seats` (shown so the administrator sees why a change will be refused).
Save per row: `:VENUE_ID := lms_session_pkg.save_venue(:VENUE_ID, :NAME_EN, :NAME_AR, :ADDRESS, :CAPACITY, :ACTIVE_FLAG);`
Delete (offered only when `sessions_total = 0`): `lms_session_pkg.remove_venue(:VENUE_ID);` — otherwise deactivate.
Rules enforced in the package (the grid only explains them): unique active name (case-insensitive), capacity a positive whole number, **no deactivation or capacity cut below the seats of an upcoming session**, no deletion of a venue that ever hosted a session. Session creation (app 210 page 41) also refuses inactive venues and seats above the venue capacity.

## Pages 40/41/42 — Certificates
**40**: IR on `v_lms_certificates_admin` (number, holder, title, issued, expires, status). Row action *Revoke* → **41** (dialog, `P41_CERTIFICATE_ID` protected, reason required ≥ 5 chars): `lms_certification_pkg.revoke(:P41_CERTIFICATE_ID, :P41_REASON);` (rate limited, audited, learner notified). **42**: certificate templates IG on `v_lms_templates_cert` (code, names, validity months, wording text, active); save → `:TEMPLATE_ID := lms_admin_pkg.save_certificate_template(:TEMPLATE_ID, :TEMPLATE_CODE, :NAME_EN, :NAME_AR, :VALIDITY_MONTHS, :BODY_TEXT, :ACTIVE_FLAG);` (plain-text wording only; layout is page 61 of app 200).

## Page 50 — Categories
IG on `v_lms_categories_admin` (names EN/AR, parent, sort order, active — includes inactive rows). Save → `:CATEGORY_ID := lms_admin_pkg.save_category(:CATEGORY_ID, :PARENT_CATEGORY_ID, :NAME_EN, :NAME_AR, :SORT_ORDER, :ACTIVE_FLAG);` (loop check; permission `COURSE_PUBLISH`). Categories in use cannot be deleted (FK); deactivate instead.

## Page 60 — System settings
IG (editable value column only) on `v_lms_settings`. Save process per changed row: `lms_admin_pkg.set_setting(:SETTING_KEY, :SETTING_VALUE);` (validates numeric/enum settings; audits old → new). Secrets must never be entered here (help text; no secret settings exist). Page shows a warning banner for `MAIL_FROM = lms-noreply@example.invalid` (unconfigured).

## Page 61 — Notification templates
IG on `v_lms_templates_admin` (code, language, subject, body, active): body Textarea (4,000), a side region lists the placeholders each template receives (from doc 04/seed: e.g. `{{course}}`, `{{due}}`). Save: `lms_admin_pkg.save_template(:TEMPLATE_CODE, :LANG, :SUBJECT, :BODY, :ACTIVE_FLAG);` (plain text only; HTML rejected). Preview button renders with sample values in the user's language.

## Pages 70/71/72 — Users
**70**: IR on `v_lms_users_admin` (name, username, employee no., department, position, manager, status, roles). Facets: status, department, role. **71** (modal): view of the user + buttons *Activate/Deactivate/Lock* (`lms_user_pkg.set_status`), *Set manager* (`lms_user_pkg.set_manager(:USER_ID, :MANAGER_ID)`; loops rejected), language. **72** (modal): roles shuttle → `lms_user_pkg.grant_role / revoke_role` per change (own roles cannot be changed; each change audited). **User creation is by HR sync** (`POST /hr/employees`), not by hand; manual creation is intentionally not offered (single source of truth).

## Page 73 — Roles & permissions matrix
Read/write IG on `v_lms_role_matrix` (rows: permissions; columns: roles via PIVOT in SQL or a flat IG role × permission with a scope select list ALL/TEAM/OWN/ASSIGNED/blank). Save per cell: `lms_admin_pkg.set_role_permission(:ROLE_CODE, :PERMISSION_CODE, :SCOPE);` (blank removes; the SYS_ADMIN lock-out guard is in the package). Beside it, an *"Effective permissions of user X"* report on `v_lms_effective_permissions` for access reviews.

## Pages 80/81/82 — Audit and logs
**80**: IR on `v_lms_audit` (time, actor, operation, entity, entity id, result, metadata; filters by date range/operation/result; default last 24 h, `event_time` index). Large-table rules: **default filter is mandatory** (a saved report with a date predicate), row limit 10,000 for downloads, download audited. `metadata` rendered escaped. **81**: IR on `v_lms_security_events_admin` (severity badge text, type, user, operation, hashed subject, detail). **82**: two regions: `v_lms_api_log_admin` (route, status, duration; chart of status codes per hour) and `v_lms_queue_failures` (failed notifications with `last_error`).

## Page 90 — Rate-limit policies
IG on `v_lms_rate_policies` (operation read-only; editable: limit, window seconds, burst, fail mode, enabled). Save: `lms_admin_pkg.set_rate_limit_policy(:POLICY_ID, :LIMIT_COUNT, :WINDOW_SECONDS, :BURST_LIMIT, :FAIL_MODE, :ENABLED_FLAG);` — the package blocks disabling/fail-open on `AUTH_ATTEMPT`, `QUIZ_SUBMIT`, `CERT_GENERATE`. Companion chart: `select hour_start, operation, violations from v_lms_rate_violations` (last 7 days) so changes are made with evidence. Help text: limits are assumptions to be tuned after load tests (doc 06 §3).

## Page 95 — Monitoring dashboard
`R_JOBS` IR `v_lms_job_status` (job, state, last status, next run — failed rows flagged with text "Failed"; includes the 15-minute `LMS_SESSION_REMINDER_JOB`, so a stalled reminder job is visible); `R_QUEUE` `v_lms_queue_status` (pending/sent/failed counts, oldest due); `R_RATE` chart `v_lms_rate_violations`; `R_SECURITY` count of `HIGH` severity events in 24 h (`select count(*) from v_lms_security_events_admin where severity='HIGH' and event_time > systimestamp - interval '1' day`); `R_AUTH` login failures/denials (`event_type in ('LOGIN_DENIED')`); `R_HEALTH` link to `GET /ords/lms/ops/health`. Alert thresholds are documented in doc 07 §10 (alerting itself is done by the monitoring system consuming `/ops/health` and the DB views, not by APEX).
Active sessions / slow pages are Builder-level (`APEX_WORKSPACE_ACTIVITY_LOG`, Monitor Activity) and are **not** surfaced to the application schema; operators use the APEX Administration/Workspace *Monitor Activity* reports.

---
## Remaining items for this app
Two small views used above: `V_LMS_TEMPLATES_CERT` and `V_LMS_CATEGORIES_ADMIN` (same columns as the tables, filtered by `CERT_POLICY` / `COURSE_PUBLISH` scope respectively). They are in `02_DATABASE/16_views_lov.sql`.
