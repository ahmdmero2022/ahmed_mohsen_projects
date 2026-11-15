# 01 — Executive Overview and Requirements

## 1. Executive Solution Overview (Step 1)

### 1.1 What is being built
A bilingual (English/Arabic, LTR/RTL) enterprise Learning Management System for roughly 10,000 employees, covering self-paced and instructor-led learning, assessments, learning paths, certifications, skills/competencies, feedback, notifications and analytics. It is functionally comparable to the core of Oracle Learning Cloud but is an original design.

### 1.2 Architectural approach
- **Database-centric.** Business rules live in PL/SQL packages (`LMS_*_PKG`); integrity is enforced by constraints; APEX pages call packages and never hold business state only in the browser.
- **Five APEX applications on one schema** (recommended over one monolith):

| App | ID (proposed) | Audience | Content |
|---|---|---|---|
| LMS Learning Portal | 200 | Learner | Dashboard, catalog, player, my learning, certificates |
| LMS Instructor Portal | 210 | Instructor | Course builder, quizzes, grading, sessions |
| LMS Administration | 220 | Training admin, System admin | Catalog, enrollments, policies, users, audit, rate limits |
| LMS Management | 230 | Managers, HR | Team status, approvals, skill gaps |
| LMS Analytics | 240 | Executives, HR | KPIs, trends, compliance |

Benefits: independent authorization boundaries, smaller deployments, parallel team work, reduced blast radius. Cost: shared navigation and theme must be maintained through a **Shared Components subscription** (master app 200 publishes theme, authorization schemes, LOVs; others subscribe). Cross-app links use `APEX_PAGE.GET_URL` with the session carried by shared SSO.
- **Layered rate limiting** (WAF → ORDS → PL/SQL), see doc 06.
- **Native APEX first:** Cards, Faceted Search, Interactive Report/Grid, Charts, Approvals/Workflow components, `APEX_MAIL`, `APEX_AUTOMATION`, `DBMS_SCHEDULER`.

### 1.3 Major design decisions

| ID | Decision | Rationale | Alternative rejected |
|---|---|---|---|
| DD-01 | Five APEX apps, one schema | Separation of duty, maintainability | Single app: authorization sprawl |
| DD-02 | Videos external, metadata in DB | 10k users × video bandwidth would dominate DB I/O and backup size | BLOB for all media |
| DD-03 | Row lock on `LMS_COURSES` for enrollment capacity | Simple, correct, contention only per course | Counter column (drift risk), serializable isolation |
| DD-04 | Progress derived server-side from `LMS_LESSON_PROGRESS` events | Client events untrusted | Client-reported percentage |
| DD-05 | Permission tables + APEX authorization schemes calling `LMS_SECURITY_PKG` | Single source of truth, server enforced | Hardcoded role names in pages |
| DD-06 | Fixed-window counters (autonomous transaction) for business-operation limits | Cheap, atomic, simple in 19c | Token bucket in tables (more writes) |
| DD-07 | Identity columns, `TIMESTAMP WITH TIME ZONE` for events, `DATE` for business dates | Multi-timezone audit accuracy | `SYSDATE` everywhere |
| DD-08 | Materialized summary tables refreshed by scheduler for dashboards | Dashboards must not scan 1M+ activity rows | Live aggregation |
| DD-09 | Bilingual columns (`*_EN`, `*_AR`) for catalog data; APEX Text Messages for UI strings | Simple querying, no join per language | Generic translation table (revisit if >2 languages) |

### 1.4 Module list
M01 Users & Organization · M02 Catalog · M03 Course Management · M04 Content · M05 Enrollment · M06 Progress · M07 Assessments · M08 Learning Paths · M09 Instructor-Led Training · M10 Certifications · M11 Skills · M12 Feedback · M13 Notifications · M14 Reporting · M15 Administration.

### 1.5 Platform constraints verified against documented behaviour (to re-verify in your environment)
- Identity columns, `MERGE`, `FETCH FIRST`, `JSON` in VARCHAR2/CLOB (`IS JSON`) — available in 19c.
- Not used because not in 19c/24.1: `IF NOT EXISTS` DDL, `BOOLEAN` SQL columns, annotations, JSON Duality Views, `VECTOR`.
- APEX 24.1 requires a supported ORDS release; check the Oracle APEX 24.1 installation guide for the exact minimum before provisioning.
- Table partitioning requires Enterprise Edition + Partitioning option (extra licence).
- Advanced Security (TDE) is a licensed option on-premises; flagged in doc 06.

### 1.6 Assumptions (A-xx)

| ID | Assumption | Impact if wrong |
|---|---|---|
| A-01 | 10k registered, 2k DAU, 500 concurrent *active* users (not 500 DB sessions) | Sizing |
| A-02 | Corporate SSO (OIDC/SAML) available for production | Fall back to local auth with hardening |
| A-03 | Video hosted on approved object store/CDN or streaming platform | Storage design |
| A-04 | One organisation (single tenant) | Multi-tenant needs `ORG_ID` in every table |
| A-05 | Arabic and English only | More languages → translation table |
| A-06 | HR system exposes REST/CSV employee feed | Manual user admin otherwise |
| A-07 | SMTP relay available to `APEX_MAIL` | Notification channel |
| A-08 | Enterprise Edition with Partitioning is *not* assumed; partitioning is optional | Log retention by delete jobs instead |

---

## 2. Requirements (Step 2)

Priority uses MoSCoW. IDs are referenced by tables, pages and tests.

### 2.1 Functional requirements

| ID | Requirement | Pri | Module |
|---|---|---|---|
| FR-USR-01 | Maintain user profile (employee no., names EN/AR, email, department, position, manager, status) | M | M01 |
| FR-USR-02 | Hierarchical departments; manager relationships; activate/deactivate users without deleting history | M | M01 |
| FR-USR-03 | Users hold multiple roles | M | M01 |
| FR-USR-04 | Synchronise employees from HR feed (insert/update/deactivate) | S | M01 |
| FR-CAT-01 | Configurable categories/subcategories (no hardcoding) | M | M02 |
| FR-CAT-02 | Search, filter (category, difficulty, duration, language), sort, paginate catalog | M | M02 |
| FR-CAT-03 | Featured, popular, recently added, recommended courses | S | M02 |
| FR-CRS-01 | Create/edit courses with properties listed in prompt §M3 | M | M03 |
| FR-CRS-02 | Course status lifecycle Draft→Under Review→Published→Suspended→Archived; configurable approval | M | M03 |
| FR-CRS-03 | Course versioning on publish | S | M03 |
| FR-CNT-01 | Course→Module→Lesson hierarchy with ordering | M | M04 |
| FR-CNT-02 | Lesson types: video, PDF, presentation, text, HTML, URL, download, interactive, assessment, assignment, live session | M | M04 |
| FR-CNT-03 | Content versions, availability dates, prerequisite lessons, resume position | M/S | M04 |
| FR-ENR-01 | Enrollment methods: self, admin, manager, mandatory, bulk, rule-based | M | M05 |
| FR-ENR-02 | Block duplicate active enrollment (database-enforced) | M | M05 |
| FR-ENR-03 | Verify prerequisites, capacity, deadlines, approval; waitlist | M | M05 |
| FR-ENR-04 | Capacity cannot be exceeded under concurrency | M | M05 |
| FR-PRG-01 | Track start, last activity, completed lessons, %, time spent, completion date | M | M06 |
| FR-PRG-02 | Completion rule per course: ALL_REQUIRED_LESSONS, +PASS_ASSESSMENT, +ATTENDANCE, +INSTRUCTOR_APPROVAL (combinable) | M | M06 |
| FR-PRG-03 | Server-side validation and deduplication of progress events | M | M06 |
| FR-ASM-01 | Question types: MCQ, multi-answer, true/false, matching, short answer, essay | M | M07 |
| FR-ASM-02 | Passing score, time limit, max attempts, randomisation, question banks, availability | M | M07 |
| FR-ASM-03 | Auto-grade objective items; manual grading for essay/short | M | M07 |
| FR-ASM-04 | Correct answers never sent to client before submission; time/attempt limits server-enforced | M | M07 |
| FR-PTH-01 | Learning paths: ordered courses, prerequisites, assignment, overall progress, certificate | S | M08 |
| FR-ILT-01 | Sessions with schedule, venue/virtual link, seats, waitlist, attendance, cancel/reschedule, calendar view | M | M09 |
| FR-CER-01 | Templates, unique certificate numbers, PDF, verification (minimal PII), expiry, renewal, revocation | M | M10 |
| FR-SKL-01 | Skills catalog, position skill requirements, employee assessments, gap analysis, recommended courses | S | M11 |
| FR-FDB-01 | Course/instructor ratings, reviews, configurable questionnaires; one review per completion (configurable) | S | M12 |
| FR-NTF-01 | In-app and email notifications from templates; async queue; retry and failure log | M | M13 |
| FR-RPT-01 | Role-specific dashboards and KPIs (list in doc 05) | M | M14 |
| FR-RPT-02 | Row-level authorization on every report/export; export to CSV/Excel | M | M14 |
| FR-ADM-01 | Manage settings, categories, policies, users, roles, templates, rate limits, integrations; view audit logs | M | M15 |
| FR-I18N-01 | English + Arabic UI; RTL layout in Arabic | M | all |
| FR-WFL-01 | Approval workflow with escalation for enrollment and course publication | M | M05/M03 |

### 2.2 Non-functional requirements

| ID | Requirement (measurable) | Verification |
|---|---|---|
| NFR-PERF-01 | Standard page p95 < 2 s at 500 concurrent active users | JMeter/k6 |
| NFR-PERF-02 | Course search p95 < 3 s with 5,000 courses | Load test |
| NFR-PERF-03 | Enrollment p95 < 2 s; Assessment submit p95 < 3 s | Load test |
| NFR-REL-01 | ≥ 99.5 % successful requests in the agreed workload (429s reported separately) | Load test |
| NFR-SEC-01 | All authorization decisions made server-side; OWASP ASVS L2 targeted | Pen test |
| NFR-SEC-02 | TLS 1.2+ end to end; no secrets in source control | Config review |
| NFR-AUD-01 | Audit record for logins, role changes, publish, enrollment changes, submissions, certificates, approvals, admin changes, violations | Test |
| NFR-A11Y-01 | WCAG 2.2 AA where feasible | Manual + axe |
| NFR-I18N-01 | All UI strings via APEX Text Messages; no hardcoded literals | Code scan |
| NFR-BCK-01 | Proposed RPO ≤ 15 min, RTO ≤ 4 h (business decision) | DR drill |
| NFR-MNT-01 | Naming conventions and package-based logic; no business SQL duplicated across pages | Review |
| NFR-CAP-01 | Capacity parameters configurable in `LMS_SYSTEM_SETTINGS` | Config |
| NFR-RET-01 | Audit 7 y (configurable), API log 90 d, security events 2 y, rate-limit counters 24 h after expiry | Job test |

### 2.3 Business rules

| ID | Rule |
|---|---|
| BR-01 | A user may have at most one *active* enrollment per course (active = not CANCELLED, FAILED, EXPIRED). |
| BR-02 | Seats are consumed by APPROVED, ENROLLED and IN_PROGRESS enrollments. PENDING does not reserve a seat; WAITLISTED promotes FIFO when a seat frees. |
| BR-03 | Only PUBLISHED courses within availability dates accept enrollment. |
| BR-04 | Prerequisite courses must have a COMPLETED enrollment (or valid certificate when `REQUIRE_CERT=Y`). |
| BR-05 | Progress % = completed required lessons ÷ total required lessons × 100, computed only from server-recorded `LMS_LESSON_PROGRESS` rows. |
| BR-06 | Course completes when all configured completion rules in `LMS_COURSES.COMPLETION_RULE` are satisfied; completion is idempotent. |
| BR-07 | A quiz attempt is valid only if started server-side, within time limit + grace (default 10 s), and attempts < max. |
| BR-08 | Correct-answer flags are readable only through `LMS_ASSESSMENT_PKG` after the attempt is SUBMITTED and policy allows review. |
| BR-09 | Certificate issuance is idempotent per (enrollment, template version); numbers are unique and non-sequential-guessable (`LMS-YYYY-` + 10 random base-32 chars). |
| BR-10 | Verification page returns only certificate title, holder initials/name per policy, issue/expiry, status. |
| BR-11 | Managers see only users in their reporting subtree. |
| BR-12 | Archived courses keep history; no physical delete of courses with enrollments. |
| BR-13 | Manager may assign mandatory training only to direct/indirect reports. |
| BR-14 | Approval overdue > N days (setting) escalates to the approver's manager. |

### 2.4 Role–permission matrix

Legend: ● full, ◐ own/limited scope, ○ none. Permissions are rows in `LMS_PERMISSIONS`; roles map through `LMS_ROLE_PERMISSIONS`.

| Permission code | Learner | Instructor | Dept Manager | Training Admin | HR/L&D | Sys Admin |
|---|---|---|---|---|---|---|
| CATALOG_VIEW | ● | ● | ● | ● | ● | ● |
| ENROLL_SELF | ● | ● | ● | ○ | ● | ○ |
| ENROLL_ASSIGN | ○ | ○ | ◐ (team) | ● | ● | ○ |
| ENROLL_APPROVE | ○ | ○ | ◐ (team) | ● | ○ | ○ |
| COURSE_AUTHOR | ○ | ◐ (assigned) | ○ | ● | ○ | ○ |
| COURSE_PUBLISH | ○ | ○ | ○ | ● | ○ | ○ |
| QUIZ_TAKE | ● | ● | ● | ○ | ● | ○ |
| QUIZ_AUTHOR | ○ | ◐ | ○ | ● | ○ | ○ |
| GRADE | ○ | ◐ | ○ | ● | ○ | ○ |
| SESSION_MANAGE | ○ | ◐ | ○ | ● | ○ | ○ |
| CERT_VIEW_OWN | ● | ● | ● | ● | ● | ○ |
| CERT_POLICY | ○ | ○ | ○ | ● | ○ | ○ |
| CERT_REVOKE | ○ | ○ | ○ | ● | ○ | ○ |
| SKILL_MANAGE | ○ | ○ | ○ | ○ | ● | ○ |
| REPORT_TEAM | ○ | ◐ (course) | ◐ | ● | ● | ○ |
| REPORT_ORG | ○ | ○ | ○ | ● | ● | ○ |
| USER_ADMIN | ○ | ○ | ○ | ○ | ○ | ● |
| ROLE_ADMIN | ○ | ○ | ○ | ○ | ○ | ● |
| SETTINGS_ADMIN | ○ | ○ | ○ | ○ | ○ | ● |
| AUDIT_VIEW | ○ | ○ | ○ | ○ | ○ | ● |
| RATELIMIT_ADMIN | ○ | ○ | ○ | ○ | ○ | ● |
| NOTIF_TEMPLATE_ADMIN | ○ | ○ | ○ | ◐ | ○ | ● |

Segregation of duty: a System Admin cannot enroll or publish; a course author cannot approve their own publication (enforced in `LMS_COURSE_PKG.approve`).

### 2.5 Page and operation authorization matrices
Page-level matrix is embedded in the page table of doc 05 (column "Authorization"). Operation-level authorization is the permission code that each package procedure passes to `LMS_SECURITY_PKG.REQUIRE_PERMISSION(p_code, p_scope_user_id, p_scope_course_id)`; row-level restrictions are in `LMS_SECURITY_PKG.VISIBLE_USERS_V` (manager subtree via `CONNECT BY` on `LMS_USERS.MANAGER_USER_ID`).

### 2.6 Traceability convention
`FR/NFR/BR` → `UC-xx` (use case) → `P<app>:<page>` → `LMS_*` table/package → `TC-xxx` test. A full matrix is generated from doc 07 test IDs, which carry the requirement ID they verify.
