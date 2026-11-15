# 08 — Final Quality Review and Implementation Readiness (Step 14)

## 1. Verified vs proposed

| Area | Status | Evidence |
|---|---|---|
| Documents 01–07 | Written | Files in this repo |
| Mermaid diagrams | **Unverified** | Not rendered; syntax reviewed by eye only |
| `02_DATABASE/*.sql` (16 scripts, 56 tables, 92 views, 22 packages, 161 public members) | **Unverified on Oracle** | Not run or compiled. Static checks run: SQL parser on all DDL/views, name uniqueness, FK order, package call/spec/body consistency, validation list = DDL (see `02_DATABASE/README.md`) |
| `05_INTEGRATIONS/` ORDS modules, OpenAPI, smoke test | **Unverified** | ORDS API calls not executed; YAML parses; `bash -n` passes on the test script |
| `03_APEX/` page specifications, shared components, static files | **Specification** | No APEX export; `player.js`/`assessment.js` pass `node --check` but were not run in a browser; CSS not rendered |
| APEX export | **Not produced** | Page specs only |
| Test execution | **None** | All tests unexecuted |
| Performance figures | **Estimates** | Order-of-magnitude, not measured |

## 2. Review checks

| Check | Result |
|---|---|
| Architectural consistency | Layers/packages/pages consistent. Five-app split requires a shared-components subscription strategy (doc 01 §1.2) |
| Referential integrity | DDL FKs match ERD for implemented tables. Intentional no-FK audit/security columns documented |
| DDL validity | Not executed. Risks to check on first run: inline `PRIMARY KEY` after identity clause, function-based unique index with `CASE`, `CHECK … IS JSON` on `VARCHAR2` |
| Package dependencies | Mutual dependencies (audit↔security, enrollment↔approval↔course, progress↔certification↔path) resolved by creating all specs before bodies; verified statically that every cross-package call exists in a spec; `ACCESSIBLE BY` restricts internal entry points |
| APEX 24.1 compatibility | Features used (Cards, Faceted Search, IG/IR, Charts, Automations, Social Sign-In) exist in 24.1 per my knowledge; items flagged "verify" in docs (language preference API, ORDS 429 header mechanics, Approvals/Workflow component as engine) must be confirmed in a real instance |
| Oracle 19c compatibility | No 21c/23ai-only syntax used |
| Access-control enforcement | Server-side via packages; one known shortcut (see below) |
| Rate-limit correctness | Atomic increment + autonomous txn + unique key race handling; fixed-window boundary burst (≤2×) accepted |
| Testing completeness | 102 cases defined (32 F, 20 S, 15 P, 15 R, 20 I); none executed |
| Deployment readiness | Installer, seed, validation and full-drop rollback scripts written (not run); per-release reverse migrations not written |

## 3. Known defects / shortcuts in delivered code (found on self-review)

Fixed since the first draft: scope-based authorisation (`PERMISSION_SCOPE`, `CAN_MANAGE_USER`) replaces the `REPORT_ORG` stand-in; `CANCEL` now checks scope; approval transitions, notifications on waitlist promotion, and idempotent job creation are implemented; `JSON_OBJECT` is no longer used in PL/SQL expressions.

Open items:
1. **Never compiled.** Expect first-run syntax/semantic fixes. Items I am least sure of are listed in `02_DATABASE/README.md` ("Items to verify on first compile").
2. **Quiz exhausted without passing** leaves the enrolment `IN_PROGRESS`; a policy decision (fail the enrolment? allow reset?) is not implemented.
3. **`LMS_ENROLLMENT_PKG.ASSIGN`** forces type `MANAGER` for TEAM scope; mandatory assignment by managers keeps `MANDATORY`. Confirm this is the intended policy (BR-13).
4. **Anti-skip controls** (minimum watch time per video lesson) are not implemented; `PROGRESS_MAX_DELTA_SEC` only caps time credited per event.
5. **Rate-limit `HIT`**: when the policy lookup itself fails, `FAIL_MODE` is unknown and the limiter fails open even for sensitive operations.
6. **Audit retention purge** needs DELETE on `LMS_AUDIT_LOG`; run the job as the schema owner and keep that privilege away from the application schema.
7. **No lesson/module update or reorder API**; IG-based authoring must call `CAN_MANAGE_COURSE` in its DML processes.
8. **Learning hours** in `LMS_SUM_DEPT_DAILY` are attributed to the last-activity day (approximation).
9. **Certificate PDF** layout (APEX report/`APEX_PRINT`) is not built; `V_LMS_CERTIFICATE_PRINT` and `AUTHORIZE_DOWNLOAD` are the data and authorisation hooks.
10. **File type checks use magic bytes only**; there is no malware scan and no content-disarm for Office files (macros are not executed by the viewer, but the files are downloadable).
11. **Signed content URLs** need `LMS_SECRET_PKG` to be replaced per environment; the shipped stub fails closed (`ORA-20500`).
12. **`LMS_APEX_PKG.POST_AUTH`** relies on `APEX_UTIL.SET_SESSION_LANG`, `APEX_APPLICATION.STOP_APEX_ENGINE` and a redirect from a post-authentication procedure; confirm on 24.1.
13. **ERDs in doc 03** were not re-reconciled line by line after the DDL changes (section 5 of doc 03 lists the differences).

## 4. Outstanding work

| # | Work item | Prompt reference |
|---|---|---|
| 1 | Install and compile on Oracle 19c (`00_install.sql`), fix findings, run `11_validation.sql`; write and run package tests (enrolment concurrency, rate limiting, assessment integrity, authorization) | §9, §19 |
| 2 | Build the APEX applications from `03_APEX/` in a real 24.1 workspace; export; accessibility + RTL review in browsers | §13, §19.8 |
| 3 | Run the ORDS scripts, confirm API behaviour (`:status_code`, `Retry-After` header parameter, OAuth client creation/rotation), run `ords_smoke_test.sh`; configure the WAF for the chosen product | §15 |
| 4 | Content platform integration: pre-signed upload, signing-key provisioning (`LMS_SECRET_PKG` body per environment), virus scan hook | §5 M4, §14 |
| 5 | ~~Skills administration~~ — **done** (`save_skill`, `remove_skill`, `set_position_skill`, `set_course_skill`, `copy_position_skills`); remaining: bulk import of skill requirements from the HR system, competency *framework* grouping beyond the `skill_group` text | §5 M11 |
| 6 | ~~Feedback questionnaire authoring~~ — **done** (forms, questions, assignment, clone, review editing policy, anonymity threshold); venue maintenance and the daily feedback reminder are now done; remaining: session-start reminders (24 h / 1 h before) and a second feedback nudge | §5 M9, M12, M13 |
| 7 | Skills history table if a skills *trend* is required (dashboard currently shows current gap index only) | §12.14 |
| 8 | JMeter/k6 scripts and data generators for 5k courses / 100k enrolments / 1M activity rows | §19 |
| 9 | Arabic UI/notification text review by a native speaker; XLIFF translation of page text | §2 |
| 10 | Wireframes/mock-ups; re-reconcile ERDs with DDL; generate the data dictionary from `USER_TAB_COLUMNS` | §7, §11 |
| 11 | Per-release reverse-migration scripts (the supplied rollback is a full drop) | §22 |
| 12 | Business decisions: OQ-10 (may executives see individual learners?), quiz-exhaustion policy, executive role definition | doc 06 |

Closed in the latest revision: venue maintenance (`save_venue`, `remove_venue`, capacity/active checks in `create_session`), feedback reminders (`LMS_FEEDBACK_PKG.SEND_REMINDERS`, job `LMS_FEEDBACK_JOB`), `06_TESTING/UNIT_TESTS/venues_reminders_tests.sql` (26 assertions, not executed). Before that: skills framework maintenance (`LMS_SKILL_PKG`), feedback questionnaire authoring and review policy (`LMS_FEEDBACK_PKG`), anonymised feedback analytics views, `06_TESTING/UNIT_TESTS/skills_feedback_tests.sql` (42 assertions, not executed).

Closed earlier: course text/objectives, lesson content and sanitising, content versions, reorder/rename/remove of modules and lessons,
document upload with type/size/magic-byte checks, signed content URLs, question-bank authoring with immutability, quiz settings and validation,
certificate template and category administration, assignment closing, admin settings/rate-limit/role-matrix/template writes, ORDS API (verification, catalog, HR sync, health).

## 5. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Unverified code never compiled | Rework | First task: run in dev schema, fix, add CI |
| Licensing assumptions (Partitioning, TDE, AWR/ASH, Active Data Guard, VPD) | Cost/compliance | Confirm edition; designs have non-licensed fallbacks |
| Shared-NAT users hit IP limits | False 429s | Per-user limits at WAF, tune after load test |
| Legacy password scheme | Credential compromise | SSO or hardened scheme (doc 06 §2) |
| Hot course row lock on mass enrollment | Latency spikes | Measured in P-06; fallback: queue-based seat allocation |
| Five-app complexity | Maintenance | Shared components subscription, one release train |
| Video egress | Cost/perf | CDN |

## 6. Open questions
OQ-1 Which IdP/protocol? OQ-2 Video platform? OQ-3 Matrix (multiple) managers needed? OQ-4 Exact user/course volumes and growth? OQ-5 Edition and licensed options? OQ-6 Is APEX 24.1 + ORDS version fixed already? OQ-7 Must certificates follow an official government/regulatory format? OQ-8 Retention periods mandated by policy? OQ-9 Do instructors need to author from mobile?

## 7. Readiness verdict
**Database layer: complete as written, unproven.** All tables, views, packages, seeds, jobs, validation and rollback exist, but nothing has been compiled or run. **APEX layer, ORDS, WAF, load tests: not built.** Recommended next step: run `00_install.sql` in a dev 19c schema, fix compile findings, run `11_validation.sql`, then write and run package tests (starting with enrollment concurrency and rate limiting) before building APEX pages on the proven model.
