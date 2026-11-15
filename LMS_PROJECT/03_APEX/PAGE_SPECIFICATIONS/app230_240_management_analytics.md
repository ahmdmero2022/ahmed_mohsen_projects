# Apps 230 (Management) and 240 (Analytics): page specifications

Status: specification, not built. Conventions: `../SHARED_COMPONENTS/README.md`. Both apps contain **no learner-facing content** and perform
almost no writes. Row scope is applied inside the views through `V_LMS_VISIBLE_USERS`: everyone (scope `REPORT_ORG`=ALL), or self + reporting subtree
(`REPORT_TEAM` TEAM scope). A report page can therefore never show someone outside the caller's scope even if its authorization scheme is wrong.
Every download (CSV/Excel/PDF) of an Interactive Report has a **Before Download** process: `lms_audit_pkg.log_event('EXPORT', 'REPORT', null, 'SUCCESS', lms_util_pkg.js('page', :APP_PAGE_ID));`
and a row limit of 10,000 (Report Attributes → Maximum Rows).

---
> **`*_l10n` notation.** Wherever a spec writes `X_l10n` (e.g. `title_l10n`, `module_title_l10n`, `full_name_l10n`) it stands for the language expression
> `case when :LMS_LANG = 'ar' and X_ar is not null then X_ar else X_en end` over the view's `X_en` / `X_ar` columns. Write it out in the region SQL
> (or as a Cards/IR *computed column*); there is deliberately no PL/SQL function for it, to avoid a context switch per row.

# App 230 — LMS Management (department managers, HR)

Default scheme `LMS_AUTH_MANAGER` (HR users also pass `LMS_AUTH_HR` / `LMS_AUTH_REPORT_ORG`, which switches the views to organisation scope).
**Navigation**: Dashboard (1) · Team learning (10) · Approvals (20) · Assign training (30) · Skill gaps (40) · *Skills framework* (42–44, HR only, condition `LMS_AUTH_HR`).

## Page 1 — Manager dashboard
| Static ID | Source |
|---|---|
| `R_KPIS` | `select (select count(*) from v_lms_visible_users) team_size, count(case when status='COMPLETED' then 1 end) completed, round(100*count(case when status='COMPLETED' then 1 end)/nullif(count(*),0),1) completion_pct, count(case when overdue_flag='Y' then 1 end) overdue, (select count(*) from v_lms_approvals_inbox) pending_approvals from v_lms_team_enrollments where status not in ('CANCELLED','WAITLISTED')` — tiles: *Team size*, *Completion %*, *Overdue mandatory* (red + text when > 0), *Pending approvals* (link → 20) |
| `R_PARTICIPATION` Chart (bar) | `select department_en, employees, active_90d, with_completion from v_lms_dept_participation order by department_en` ("Employee participation") |
| `R_MANDATORY` Chart (bar) + report | `select department_en, assigned, completed, overdue, compliance_pct from v_lms_mandatory_compliance` |
| `R_APPROVALS` Classic report (top 5) | `select approval_id, item_en, requester_en, due_at, overdue_flag from v_lms_approvals_inbox order by due_at fetch first 5 rows only` |
| `R_EFFECTIVENESS` Classic report | training effectiveness = pass rate and average score of the team's graded quizzes: `select course_en, count(*) attempts, round(100*avg(case when passed_flag='Y' then 1 else 0 end),1) pass_rate_pct, round(avg(score_pct),1) avg_score from v_lms_team_results group by course_en order by attempts desc fetch first 10 rows only` |
| `R_GAPS` Chart (horizontal bar, top 8 skills) | `select skill_en, count(*) employees, round(avg(gap),1) avg_gap from v_lms_skill_gaps group by skill_en order by employees desc fetch first 8 rows only` |
All below the KPI row: Lazy Loading = Yes. Empty state: "Your team has no training activity yet."

## Page 10 — Team learning
IR on `v_lms_team_enrollments` (employee, department, course, status, type, due, progress %, overdue, completed). Facets/saved reports: *Overdue*, *In progress*, *Completed this quarter*. Row action *Assign another course* → 30 with the employee preselected (`P30_USER_ID`); *Cancel enrolment* (own-team only → `lms_enrollment_pkg.cancel`, confirm; the package enforces TEAM scope). Download allowed (audited).

## Pages 20/21 — Approvals
**20**: IR on `v_lms_approvals_inbox` (managers see enrolment requests of their reports; admins/HR holding the ALL-scope permission see all). **21** (dialog, `P21_APPROVAL_ID` protected): note + *Approve*/*Reject* → `lms_approval_pkg.decide(:P21_APPROVAL_ID, :P21_DECISION, :P21_NOTE);` (reject requires a note; a requester can never decide their own request; overdue items escalate automatically after `APPROVAL_ESCALATE_DAYS`).

## Page 30 — Assign training (dialog)
`P30_USER_ID` (Popup LOV `v_lms_lov_users` — only visible/active people), `P30_COURSE_ID` (select from `v_lms_catalog` published courses), `P30_DUE_DATE`, `P30_MANDATORY` (switch → type `MANDATORY`, else `MANAGER`). Process: `lms_enrollment_pkg.assign(:P30_USER_ID, :P30_COURSE_ID, :P30_DUE_DATE, case when :P30_MANDATORY='Y' then 'MANDATORY' else 'MANAGER' end, :P30_ENR_ID, :P30_STATUS);` Errors: outside scope → "not authorized" (audited `ACCESS_DENIED`), prerequisites, closed course. A manager can assign **individuals**; group assignments are admin-only (`create_assignment` requires ALL scope).

## Pages 40/41 — Skill gaps
**40**: IR on `v_lms_skill_gaps` (employee, department, skill, required, current, gap) + side region *Recommended courses*: `select title_en, full_name_en, coverage from v_lms_team_recommended where user_id = :P40_USER_ID order by coverage desc fetch first 10 rows only` (employee picked from the IR row). **41** (dialog): HR/manager records an assessment: `P41_USER_ID` (protected), `P41_SKILL_ID` (`v_lms_lov_skills`), `P41_LEVEL` (0–5) → `lms_skill_pkg.assess_skill(:P41_USER_ID, :P41_SKILL_ID, :P41_LEVEL);` (allowed for `SKILL_MANAGE` holders and for managers on their own team; audited). Skill levels also rise automatically when a learner completes a course tagged with that skill. 
## Pages 42/43/44 — Skills framework (HR, scheme `LMS_AUTH_HR`)
**42 Skills catalogue**: IG on `v_lms_skills_admin` (code, names EN/AR, group, active; read-only `positions_using`, `courses_using`, `people_assessed`). Save: `:SKILL_ID := lms_skill_pkg.save_skill(:SKILL_ID, :SKILL_CODE, :NAME_EN, :NAME_AR, :SKILL_GROUP, :ACTIVE_FLAG);` Delete (offered only when all three counts are 0): `lms_skill_pkg.remove_skill(:SKILL_ID)`; otherwise deactivate. Duplicate codes → "already exists".
**43 Position requirements**: master select `P43_POSITION_ID` (`v_lms_lov_positions`); IG on `v_lms_position_skills_admin` filtered by position (skill select from `v_lms_lov_skills`, required level 1–5). Save per row: `lms_skill_pkg.set_position_skill(:P43_POSITION_ID, :SKILL_ID, :REQUIRED_LEVEL);` delete row → same call with `null`. Button *Copy from position…* (dialog: source position) → `:P43_ADDED := lms_skill_pkg.copy_position_skills(:P43_FROM, :P43_POSITION_ID);` shows "n requirements added" (never overwrites). Effects are immediate in the gap views and dashboards.
**44 Course skills**: IG on `v_lms_course_skills_edit` with a course selector → `lms_skill_pkg.set_course_skill(:COURSE_ID, :SKILL_ID, :LEVEL_GAINED)` (null removes). The same grid is embedded in the instructor course builder (scoped to the author's courses).
Every change is audited (`SKILL_SAVE`, `POSITION_SKILL`, `COURSE_SKILL`, …). Grouping above skills is only the text column `skill_group`; a separate competency-framework table is not modelled.

---
# App 240 — LMS Analytics (executives, HR, training admins)

Default scheme `LMS_AUTH_REPORT_ORG` (organisation scope). Training admins and HR hold it; executives need a role granted `REPORT_ORG` ALL
(the seed has no separate Executive role: grant them the `HR_LD` role, or add an `EXECUTIVE` role with `CATALOG_VIEW` + `REPORT_ORG` through page 220:73).
**Navigation**: Executive dashboard (1) · Reports (10) · Drill-down (20).

## Page 1 — Executive dashboard
Freshness label on the page (`select 'Data refreshed ' || to_char(summaries_refreshed_at,'DD Mon HH24:MI') from v_lms_org_kpis`): all trend/aggregate regions read the hourly summary tables, KPI counts are live (cheap indexed counts). Date range item `P1_RANGE` (30/90/365 days) and department filter `P1_DEPT` (`v_lms_lov_departments`).

| Static ID | Type | Source |
|---|---|---|
| `R_KPI_ROW1` | 6 KPI tiles | `select total_learners, active_learners, total_courses, published_courses, total_enrollments, completion_rate_pct from v_lms_org_kpis` |
| `R_KPI_ROW2` | 6 KPI tiles | `select avg_assessment_score, mandatory_compliance_pct, certificates_issued, certificates_expired, learning_hours, avg_course_rating from v_lms_org_kpis` — tile colour/text thresholds: compliance < 90 % warn, < 75 % bad (text *"Below target"* as well) |
| `R_TREND` Line chart | completion trend | `select trunc(summary_day,'IW') week, sum(enrollments) enrollments, sum(completions) completions from v_lms_exec_dept_trend where summary_day >= trunc(sysdate) - :P1_RANGE and (:P1_DEPT is null or department_id = :P1_DEPT) group by trunc(summary_day,'IW') order by 1` (summary table keeps 35 days; longer ranges need the history backfill described in doc 06 §4.5) |
| `R_DEPT` Bar chart | department comparison | `select department_en, sum(completions) completions, sum(enrollments) enrollments, round(sum(learning_hours)) hours from v_lms_exec_dept_trend where summary_day >= trunc(sysdate) - :P1_RANGE group by department_en order by completions desc` |
| `R_UTIL` Bar | training utilisation | learning hours per department (same view) and `v_lms_dept_participation` (active 90 d ÷ employees) |
| `R_TOP` Classic report | most popular courses | `select title_en, enrolled, completed, completion_pct, avg_score, avg_rating from v_lms_exec_courses order by enrolled desc fetch first 10 rows only` |
| `R_COMPLIANCE` Chart + report | compliance indicators | `select department_en, assigned, completed, overdue, compliance_pct from v_lms_mandatory_compliance order by compliance_pct` |
| `R_CERTS_EXP` Report | certifications expiring ≤ 90 days | `select full_name_en, title_en, expires_at, days_left from v_lms_cert_expiring where days_left <= 90 order by expires_at` |
| `R_SKILLS` Bar | skills indicator | `select department_en, gap_index, employees_with_gaps from v_lms_skill_gap_by_dept order by gap_index desc` — **a skills *trend* cannot be shown**: only current levels are stored (no history table); add `LMS_USER_SKILL_HISTORY` if the business needs trends |
Lazy loading: all regions except `R_KPI_ROW1/2`. Chart accessibility: each chart has a hidden data table alternative (Chart attribute *Show Data Table*), colour never the only encoding.
Performance: KPI view runs ~10 aggregate scalar subqueries (100k enrolments, indexed) ≈ < 300 ms; if > 1 s under load, switch the heaviest counts to the summary tables (documented in doc 06 §4.5) rather than caching per user.

## Page 10 — Reports
Region selector `P10_REPORT` (Select List/Tabs) toggling Interactive Reports (Server-side condition on `P10_REPORT`): 
1. Enrolments & completions — `v_lms_team_enrollments`; 2. Assessment results — `v_lms_team_results`; 3. Certificates (expiring/expired) — `v_lms_cert_expiring`; 4. Mandatory compliance — `v_lms_mandatory_compliance`; 5. Skill gaps — `v_lms_skill_gaps`; 6. Course performance — `v_lms_exec_courses`.
Common: saved public reports per audience; filters and control breaks on department/course; CSV/XLSX/PDF download enabled for 1–6, audited, row limit 10,000; PDF needs a configured print server (Arabic caveat as in app 200 page 61). Printable view = IR *Print* with `@media print` rules.

## Page 20 — Drill-down
Three linked regions with context items: `P20_DEPT` → `P20_COURSE` → learner list.
`R_DEPTS` (from `v_lms_dept_participation`, row link sets `P20_DEPT`, checksum) → `R_COURSES` (`select course_id, course_title, count(*) enrolled, count(case when status='COMPLETED' then 1 end) completed, count(case when overdue_flag='Y' then 1 end) overdue from (select e.course_id, e.course_title_en course_title, e.status, e.overdue_flag from v_lms_team_enrollments e where e.department_id = :P20_DEPT) group by course_id, course_title`; row link sets `P20_COURSE`) → `R_LEARNERS` (`select full_name_en, status, progress_pct, due_date, completed_at from v_lms_team_enrollments where department_id=:P20_DEPT and course_id=:P20_COURSE`). Each level re-applies row scope (the views). Learner-level view is available only to users whose scope includes those learners; for organisation-wide executives who must **not** see individuals, create a role with `REPORT_ORG` but a separate view with the `R_LEARNERS` level removed (privacy-aware reporting, doc 06 §1) — decision for the business (OQ-10).
