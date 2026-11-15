# 07 — Testing, Deployment, Monitoring, Backup (Steps 12 & 13)

Status: **no test has been executed.** Every "Actual" cell is intentionally blank. Pass criterion for all rows: actual result equals expected result with no unhandled error. Priority H/M/L. Test data: TD-1 = 10 users (one per role plus two learners with manager chain), TD-2 = 50 courses, one published capacity-2 course "C-CAP", one prerequisite pair, TD-3 = quiz with 10 questions.

Columns: ID · Module · Title · Preconditions/Data · Steps · Expected · Pri · Req · Actual.

## 1. Functional (32)

| ID | Module | Title | Pre / Steps | Expected | Pri | Req |
|---|---|---|---|---|---|---|
| F-01 | Enroll | Learner enrolls in available course | Published, seat free, prereqs met. Catalog→Enroll→Confirm | Row ENROLLED, notification queued, appears in My Learning | H | FR-ENR-01 |
| F-02 | Enroll | Duplicate enrollment | Already enrolled; Enroll again | Existing enrollment returned, no 2nd row | H | FR-ENR-02 |
| F-03 | Enroll | Capacity full → waitlist | C-CAP has 2 ENROLLED; 3rd learner enrolls | Status WAITLISTED | H | FR-ENR-03 |
| F-04 | Enroll | Cancel promotes waitlist | After F-03 cancel one | Oldest waitlisted becomes ENROLLED | H | FR-ENR-03 |
| F-05 | Enroll | Prerequisite unmet | Learner without prereq | Error -20411, no row | H | BR-04 |
| F-06 | Enroll | Unpublished course | DRAFT course id via URL tamper | Error -20410, no row | H | BR-03 |
| F-07 | Enroll | Deadline passed | enroll_deadline yesterday | Error -20412 | M | FR-ENR-03 |
| F-08 | Enroll | Approval required | approval_required=Y | PENDING + approval task to manager | H | FR-WFL-01 |
| F-09 | Enroll | Manager assigns to report | Manager→own report | Enrollment type MANAGER created | H | BR-13 |
| F-10 | Enroll | Manager assigns outside subtree | Manager→other dept user | Denied, audit DENIED | H | BR-13 |
| F-11 | Enroll | Bulk assignment | Admin assigns dept (50 users) | 50 enrollments, set-based, notifications queued | M | FR-ENR-01 |
| F-12 | Progress | Complete lesson | Open lesson→Mark complete | lesson COMPLETED, % updated | H | FR-PRG-01 |
| F-13 | Progress | Event replay | Send same event_uuid twice | One state change, no double count | H | FR-PRG-03 |
| F-14 | Progress | Complete lesson of another's enrollment | Tamper enrollment id | Rejected | H | FR-PRG-03 |
| F-15 | Progress | Lesson prerequisite | Complete lesson 3 before 2 | Rejected with message | M | FR-CNT-03 |
| F-16 | Progress | Resume | Leave at 120 s, reopen | Starts at 120 s | M | FR-CNT-03 |
| F-17 | Progress | Course completion | Finish all required | Enrollment COMPLETED once | H | FR-PRG-02 |
| F-18 | Progress | Completion with quiz rule | Lessons done, quiz not passed | Stays IN_PROGRESS | H | FR-PRG-02 |
| F-19 | Assess | Auto-grade MCQ | Submit known answers | Score matches key | H | FR-ASM-03 |
| F-20 | Assess | Max attempts | Attempt max+1 | Rejected | H | FR-ASM-04 |
| F-21 | Assess | Time limit | Submit after deadline+grace | Rejected/marked late per policy | H | FR-ASM-04 |
| F-22 | Assess | Essay manual grading | Essay answer; instructor grades | Status PENDING_GRADING→GRADED, score final | M | FR-ASM-03 |
| F-23 | Assess | Correct answers hidden | Inspect page source/network | No `is_correct` data before submit | H | BR-08 |
| F-24 | Cert | Certificate issued once | Complete course twice (re-run completion) | One certificate | H | BR-09 |
| F-25 | Cert | Verification | Enter valid code | Shows title, dates, status only | H | BR-10 |
| F-26 | Cert | Revocation | Admin revokes | Verification shows REVOKED | M | FR-CER-01 |
| F-27 | Course | Publish approval SoD | Author approves own course | Denied | H | FR-CRS-02 |
| F-28 | Course | Prerequisite cycle | A→B and B→A | Rejected | M | FR-CRS-01 |
| F-29 | Path | Path completion | Complete all path courses | Path COMPLETED, cert if configured | M | FR-PTH-01 |
| F-30 | ILT | Attendance completion | Mark attendance ≥ threshold | Course COMPLETED | M | FR-ILT-01 |
| F-31 | I18N | Arabic RTL | Switch to Arabic | Layout mirrored, strings translated | H | FR-I18N-01 |
| F-32 | Notif | Failure retry | SMTP down | Attempts increment with backoff, failure logged | M | FR-NTF-01 |

## 2. Security (20)

| ID | Title | Steps | Expected | Pri |
|---|---|---|---|---|
| S-01 | SQL injection in catalog search | Search `' OR 1=1--`, `%'; drop` | No error leak, normal empty/literal result | H |
| S-02 | SQLi in IR filters / URL items | Tamper item values | Bound as data; no behaviour change | H |
| S-03 | Stored XSS in review/lesson HTML | Submit `<script>` / `onerror` | Escaped or stripped; no execution | H |
| S-04 | Reflected XSS in page items | Payload in URL | Escaped | H |
| S-05 | CSRF on enroll/cancel | Forge cross-site POST | Rejected (checksum/session) | H |
| S-06 | IDOR: other user's enrollment on player | Change `P20_ENROLLMENT_ID` | Denied; audit | H |
| S-07 | IDOR: certificate download of another user | Change cert id | Denied | H |
| S-08 | Broken access: learner opens admin page by URL | Direct URL | Access denied | H |
| S-09 | Privilege escalation: learner calls `assign` via AJAX | Craft callback | `ORA-20403` | H |
| S-10 | Session state tampering | Alter protected item | Checksum failure | H |
| S-11 | Session fixation/hijack | Reuse cookie after logout; steal cookie flags | Session invalid; cookies Secure/HttpOnly | H |
| S-12 | Unauthorised file download | Guess content id/URL | Denied; signed URL expires | H |
| S-13 | Signed URL reuse after expiry | Replay | 403 | M |
| S-14 | Answer disclosure via API | Inspect ORDS/AJAX | No correct flags | H |
| S-15 | Manager data scope | Manager views other dept report/export | Only subtree rows | H |
| S-16 | Verification endpoint PII | Inspect response | Only allowed fields | M |
| S-17 | User enumeration at login | Compare responses | Identical generic response/timing | M |
| S-18 | Error handling | Force ORA error | Friendly message, no stack/ORA detail | M |
| S-19 | Audit integrity | Attempt DELETE/UPDATE on audit as app user | Privilege denied | M |
| S-20 | Concurrent-request abuse | 50 parallel enroll/submit | Single enrollment/attempt result; rate limit effective | H |

## 3. Performance (15)

SLO acceptance (to validate): standard page p95 < 2 s; search p95 < 3 s; enroll p95 < 2 s; quiz submit p95 < 3 s; success ≥ 99.5 % (429 reported separately). Tools: k6 or JMeter against UAT with production-size data (5k courses, 100k enrollments, 1M activity).

| ID | Scenario | Load | Measure | Pri |
|---|---|---|---|---|
| P-01 | Learner dashboard | 100 users, 10 min | p95, DB time | H |
| P-02 | Mixed workload (60 % browse, 20 % player, 10 % search, 5 % enroll, 5 % quiz) | 250 | p95, errors, CPU | H |
| P-03 | Mixed workload | 500 | same | H |
| P-04 | Stress | 1,000 | degradation point, errors | M |
| P-05 | Catalog search/facets | 100 req/s | p95 < 3 s | H |
| P-06 | Enrollment burst on one course (cap 100) | 500 simultaneous | no overbooking, p95 | H |
| P-07 | Quiz submit burst | 300 within 1 min | p95 < 3 s | H |
| P-08 | Progress heartbeats | 500 users/30 s | row contention, waits | H |
| P-09 | Dashboard summary pages | 50 concurrent execs | p95 | M |
| P-10 | Report export 100k rows | 5 concurrent | memory, time, authz | M |
| P-11 | Soak | 250 for 4 h | memory/leaks, pool, session growth | M |
| P-12 | Notification queue drain | 50k queued | throughput, no duplicates | M |
| P-13 | Summary refresh while online | refresh + 250 users | blocking/lock waits | M |
| P-14 | Pool exhaustion | reduce pool | graceful queueing, no errors storm | L |
| P-15 | Plan check | top-20 SQL | no unexpected FTS; `DISPLAY_CURSOR` saved | H |

## 4. Rate limiting (15)

| ID | Case | Expected |
|---|---|---|
| R-01 | 5 enroll calls < limit 10 | All allowed |
| R-02 | Exactly 10 in window | All allowed |
| R-03 | 11th in window | `ORA-20429`; no enrollment row created; event logged once |
| R-04 | Window rollover | After window start moves, allowed again |
| R-05 | 50 parallel sessions same user, limit 10 | Exactly 10 succeed |
| R-06 | Multiple browser sessions/new login | Same quota (keyed by user) |
| R-07 | Two ORDS nodes concurrently | Global limit holds |
| R-08 | Anonymous client keys A,B | Independent quotas |
| R-09 | Authenticated vs anonymous | Independent subjects |
| R-10 | Different operations | Independent counters |
| R-11 | Cleanup job | Expired rows purged, live rows kept |
| R-12 | Limiter failure, fail_mode OPEN (e.g. COURSE_SEARCH) | Request proceeds, error logged |
| R-13 | Limiter failure, CLOSED (QUIZ_SUBMIT) | Request rejected |
| R-14 | HTTP 429 | ORDS returns 429 with `Retry-After` |
| R-15 | Forged client-IP header | Ignored; key unchanged |

Concurrency script sketch (SQL*Plus/`DBMS_SCHEDULER`): spawn N jobs each calling `lms_rate_limit_pkg.enforce_limit('COURSE_ENROLL', :uid)` inside `BEGIN…EXCEPTION WHEN OTHERS THEN` recording success/ failure to a temp table; assert `count(success)=limit`.

## 5. Integration (20)

| ID | Test | Expected |
|---|---|---|
| I-01 | APEX process → `enroll_self` | Rows + messages correct |
| I-02 | Error handling function maps ORA-20xxx | Translated message |
| I-03 | Authorization schemes vs package permissions | Consistent |
| I-04 | SSO login maps to `LMS_USERS` | Roles loaded |
| I-05 | Unmapped SSO user | Denied, event logged |
| I-06 | ORDS GET course list | JSON, paged, authz applied |
| I-07 | ORDS verify certificate | Minimal fields; 429 when limited |
| I-08 | HR employee sync insert | User created INACTIVE→ACTIVE per rule |
| I-09 | HR sync update manager | Hierarchy updated, cycle rejected |
| I-10 | HR sync terminated employee | User INACTIVE, enrollments retained |
| I-11 | Email via `APEX_MAIL` | Delivered, queue SENT |
| I-12 | Email bounce/failure | Retry/failure log |
| I-13 | Notification template per language | Arabic user gets Arabic |
| I-14 | Signed URL generation + CDN fetch | Works, expires |
| I-15 | File upload validation | Wrong type/oversize rejected |
| I-16 | Certificate PDF generation | PDF valid, content correct |
| I-17 | Scheduler jobs | Run, record outcome |
| I-18 | Summary refresh | KPIs match source counts |
| I-19 | Virtual classroom link | Visible only to enrolled |
| I-20 | Cross-app navigation (200↔220) | SSO session retained, authz re-evaluated |

### Executable artefacts now available for these tests
- `06_TESTING/INTEGRATION_TESTS/ords_smoke_test.sh` (not yet run): covers I-06, I-07, I-08, I-09, I-10, R-14, R-15, S-16, S-17 against the proxy URL.
- `02_DATABASE/11_validation.sql` (not yet run): object validity, FK indexes, answer-key exposure (S-14 partial), seeds, jobs.
- `06_TESTING/UNIT_TESTS/skills_feedback_tests.sql` (not yet run): 42 assertions for skills and feedback (authorization, duplicates, immutability, completion skill credit, review policy, anonymity threshold).
- `06_TESTING/UNIT_TESTS/venues_reminders_tests.sql` (not yet run): 26 assertions for venue rules and feedback reminders (window, idempotency, policy switch, inactive users).
- Authorization checks S-08/S-09 can be scripted in SQL by creating an APEX session as `TD_LEARNER1` (`apex_session.create_session`) and calling `lms_enrollment_pkg.assign` / `lms_admin_pkg.set_setting`; expected `ORA-20403`.

## 6. UAT scenarios (summary)
Learner: find→enroll→learn→pass→download certificate. Instructor: build→submit→grade. Manager: approve, assign, view gaps. Training Admin: schedule session, bulk assign, monitor. System Admin: create user/role, tune rate limit, review audit. Each is signed off against the F-/I- tests.

## 7. Accessibility tests
Keyboard-only run of top 10 pages, NVDA/VoiceOver smoke, zoom 200 %/400 %, contrast audit with axe, form labels/errors, RTL review of every page, focus order in dialogs.

## 8. Unit tests (utPLSQL if approved; otherwise script)
Plain-script pattern (works without extra install):
```sql
set serveroutput on
declare
  l_id number; l_st varchar2(12); l_n number;
  procedure assert(p_ok boolean, p_msg varchar2) is begin
    dbms_output.put_line(case when p_ok then 'PASS ' else 'FAIL ' end || p_msg); end;
begin
  -- precondition: APEX session created for a TD-1 learner (apex_session.create_session),
  -- &course_id = published course with capacity 1 from TD-2
  lms_enrollment_pkg.enroll_self(&course_id, l_id, l_st);
  assert(l_st = 'ENROLLED', 'first enroll');
  lms_enrollment_pkg.enroll_self(&course_id, l_id, l_st);   -- idempotent
  select count(*) into l_n from lms_enrollments where course_id = &course_id;
  assert(l_n = 1, 'no duplicate');
  rollback;
end;
/
```
Real tests will live in `06_TESTING/UNIT_TESTS/` (not yet written).

## 9. Deployment

### Environments and artefacts
| Env | Purpose | Data |
|---|---|---|
| DEV | development | synthetic |
| TEST | integration/automation | synthetic |
| UAT | acceptance, load tests | production-like, masked |
| PROD | live | real |

Source control layout: `02_DATABASE/` (numbered scripts + migrations with Liquibase/Flyway-style versioning or plain `V###__name.sql`), APEX exports (`apex export -applicationid 200 -split`, SQLcl `apex export`), static files, ORDS module definitions (`ORDS.EXPORT_MODULE`), test scripts, docs.

### Deployment checklist
1. Tag release `vMAJOR.MINOR.PATCH`; confirm change log. 2. Full backup (RMAN) + export APEX apps. 3. Run DB scripts as `LMS_OWNER` in order (fail on first error: `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`). 4. `UTL_RECOMP.RECOMP_SERIAL` and check `USER_ERRORS`/`USER_OBJECTS` invalid = 0. 5. Run validation script (`20_database_validation.sql`: compile status, constraint counts, seed rows). 6. Import APEX apps (SQLcl `@f200.sql`) with environment substitution (workspace, parsing schema, alias). 7. Deploy ORDS modules; verify TLS and proxy header handling. 8. Update `LMS_SYSTEM_SETTINGS` for the environment (SMTP, URLs, storage); secrets from wallet/vault. 9. Smoke tests (login, catalog, enroll, player, quiz). 10. Enable scheduler jobs. 11. Monitor 1 h. 12. Sign-off.
Rollback: restore previous APEX export, run reverse migration scripts (`21_rollback.sql` per release, e.g. drop new columns only if unused), or restore from backup/Flashback database (if enabled) — decide per release; data-destructive migrations require expand/contract.

Privileges: `LMS_OWNER` — CREATE SESSION/TABLE/SEQUENCE/VIEW/PROCEDURE/TRIGGER/JOB, quota on tablespace, `EXECUTE` on `DBMS_CRYPTO`, `APEX_MAIL` role/ACL for SMTP (`DBMS_NETWORK_ACL_ADMIN` for the SMTP host if not using APEX instance mail settings). `LMS_APP` (parsing schema): `EXECUTE` on packages, `SELECT` on views.

## 10. Monitoring and operations

| What | Source | Alert |
|---|---|---|
| Active sessions, slow pages | `APEX_WORKSPACE_ACTIVITY_LOG`, `APEX_ACTIVITY_LOG` | p95 > 3 s 5 min |
| Slow SQL | `V$SQL` (elapsed/exec), AWR if licensed | > 5 s average |
| Failed requests / errors | `APEX_DEBUG_MESSAGES`, ORDS logs | error rate > 1 % |
| Login failures, rate-limit violations | `LMS_SECURITY_EVENTS` | > 50/5 min |
| Job failures | `DBA_/USER_SCHEDULER_JOB_RUN_DETAILS` | any FAILED |
| Notification failures | `LMS_NOTIFICATION_QUEUE` status FAILED | > 20/h |
| Tablespace growth | `USER_SEGMENTS`/DBA views | > 80 % |
| Long transactions / locks | `V$TRANSACTION`, `V$LOCK` | > 5 min |
| Expiring certificates | `LMS_CERTIFICATES` | info report weekly |
Admin monitoring dashboard = page 220:95 with KPI cards from these views. Privileges: some views need `SELECT_CATALOG_ROLE` or specific grants; AWR/ASH require Diagnostics Pack licence. Retention via settings (`RETAIN_AUDIT_DAYS`, `RETAIN_SECEVENT_DAYS`, `RETAIN_APILOG_DAYS`).

## 11. Backup and DR
- **Proposed** RPO 15 min (archive logs shipped/Data Guard), RTO 4 h — business to confirm.
- RMAN: weekly level 0, daily level 1 incremental, archive log backups every 15 min, block-change tracking, backup validation (`RESTORE VALIDATE`), encrypted backups, copy offsite; retention 30 days.
- APEX exports nightly via SQLcl into source control/backup bucket; ORDS config; static files; external content in object store with versioning/replication; certificate PDFs regenerate from data (or are backed up if stored).
- Recovery procedure: provision DB → restore control file/datafiles → recover to target time → open resetlogs → verify APEX/ORDS → run validation + smoke tests.
- Restore test: quarterly to a scratch host; DR drill: annual full failover. Checklist: backups succeeded, restore time measured vs RTO, data consistency counts, app login, certificate verification, record outcomes.
