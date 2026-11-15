# 04 — Business Process Flows (Step 6)

Each workflow: flowchart + actors, preconditions, main path, alternatives/exceptions, DB operations, outputs. Mermaid not rendered in this session.

## WF-01 User authentication
```mermaid
flowchart TD
  A[Open app] --> B{Session valid?}
  B -- yes --> Z[Dashboard]
  B -- no --> C[Redirect to IdP / login]
  C --> D{Credentials valid?}
  D -- no --> E[Log LOGIN_FAIL, generic error] --> C
  D -- yes --> F{Mapped to LMS_USERS and ACTIVE?}
  F -- no --> G[Log LOGIN_DENIED, access error page]
  F -- yes --> H[Load roles, set items, log LOGIN_SUCCESS]
  H --> I[Dashboard by role]
  Z -.idle timeout.-> J[Session expired page] --> C
```
- **Actors:** any user, IdP. **Pre:** user exists/active in LMS_USERS.
- **Alt:** lockout after repeated failures is enforced by the IdP (avoid app-level account lockout → DoS risk); app-level per-IP limiting at WAF.
- **DB:** read LMS_USERS/USER_ROLES; insert LMS_AUDIT_LOG, LMS_SECURITY_EVENTS. **Out:** authenticated session.

## WF-02 Course creation
```mermaid
flowchart TD
  A[Instructor/Admin: create course DRAFT] --> B[Add modules] --> C[Add lessons] --> D[Configure quiz] --> E[Set completion rules]
  E --> F[Submit for review: UNDER_REVIEW]
  F --> G{Reviewer decision}
  G -- reject --> H[Back to DRAFT with comments, notify] --> A
  G -- approve --> I[PUBLISHED, version snapshot, audit]
```
- **Pre:** COURSE_AUTHOR. **Rules:** reviewer ≠ author (SoD); publish requires ≥1 required lesson and valid completion rule.
- **DB:** LMS_COURSES, MODULES, LESSONS, QUIZZES, COURSE_VERSIONS, APPROVALS, AUDIT. **Out:** published course visible in catalog.

## WF-03 Course enrollment
```mermaid
flowchart TD
  A[Browse catalog] --> B[Select course] --> C[Enroll]
  C --> D{Rate limit ok?}
  D -- no --> X1[429-style message]
  D -- yes --> E[Lock course row]
  E --> F{Already actively enrolled?}
  F -- yes --> R[Return existing enrollment]
  F -- no --> G{Published and in dates?}
  G -- no --> X2[Error: not open]
  G -- yes --> H{Prerequisites met?}
  H -- no --> X3[Error: prerequisites]
  H -- yes --> I{Approval required?}
  I -- yes --> P[PENDING + approval task] --> N
  I -- no --> J{Seat free?}
  J -- no --> W[WAITLISTED] --> N
  J -- yes --> K[ENROLLED] --> N[Notify learner]
```
- **DB:** SELECT…FOR UPDATE LMS_COURSES; INSERT LMS_ENROLLMENTS (unique index is backstop); LMS_NOTIFICATION_QUEUE; AUDIT.
- **Exceptions:** `ORA-00001` on `LMS_ENR_ACTIVE_UK` (should be unreachable due to lock) → treat as idempotent success.

## WF-04 Course completion
```mermaid
flowchart TD
  A[Open course] --> B[Study lesson] --> C[Player sends event]
  C --> D[Server validates event & dedupes] --> E[Update lesson progress and %]
  E --> F{All rules met? lessons, quiz pass, attendance, approval}
  F -- no --> B
  F -- yes --> G[Enrollment COMPLETED idempotent]
  G --> H{Certificate eligible?}
  H -- yes --> I[Issue certificate once] --> J[Notify]
  H -- no --> J
```
- **Alt:** instructor-approval rule keeps status IN_PROGRESS until approval. **DB:** LESSON_PROGRESS MERGE, ENROLLMENTS update (row_version), CERTIFICATES insert guarded by UK.

## WF-05 Assessment
```mermaid
flowchart TD
  A[Start quiz] --> B{Eligible? attempts < max, window open, enrolled}
  B -- no --> X[Reject]
  B -- yes --> C[Create attempt with server deadline]
  C --> D[Load questions - no correct flags]
  D --> E[Save answers incrementally]
  E --> F[Submit]
  F --> G{Before deadline + grace?}
  G -- no --> H[Auto-submit with saved answers / mark LATE per policy]
  G -- yes --> I[Grade objective items server-side]
  H --> I
  I --> J{Manual items?}
  J -- yes --> K[Status PENDING_GRADING] --> L[Instructor grades]
  J -- no --> M[Compute score]
  L --> M --> N{score ≥ pass?}
  N -- yes --> O[PASSED] --> P[Update progress]
  N -- no --> Q[FAILED, attempts left?] --> P
```
- **Rate limit:** QUIZ_SUBMIT 5/min, fail-closed. **Idempotency:** submit on an already-SUBMITTED attempt returns existing result.

## WF-06 Mandatory learning
```mermaid
flowchart TD
  A[Admin creates assignment: target + due date] --> B[Job expands targets to enrollments set-based]
  B --> C[Notify employees] --> D[Monitor]
  D --> E{T-7/T-1 days not complete?} -- yes --> F[Reminder]
  D --> G{Past due?} -- yes --> H[Escalate to manager, then dept head]
  D --> I[Compliance report]
```
- **DB:** LMS_LEARNING_ASSIGNMENTS, ENROLLMENTS (type MANDATORY), NOTIFICATION_QUEUE; scheduler `LMS_REMINDER_JOB` daily.

## WF-07 Instructor-led training
```mermaid
flowchart TD
  A[Create session] --> B[Publish] --> C[Enroll learners / waitlist] --> D[Conduct]
  D --> E[Record attendance] --> F{Attendance ≥ threshold?}
  F -- yes --> G[Mark course COMPLETED] --> H[Certificates]
  F -- no --> I[Not completed; may reschedule]
```
Cancel/reschedule → notify all participants and promote/reflow waitlist.

## WF-08 Certification renewal
```mermaid
flowchart TD
  A[Daily job: certificates expiring ≤ 90/30/7 days] --> B[Notify learner and manager]
  B --> C[Assign renewal course - new enrollment cycle]
  C --> D{Completed before expiry?}
  D -- yes --> E[Issue new certificate cycle_no+1] --> F[Old marked SUPERSEDED]
  D -- no --> G[Status EXPIRED, compliance flag]
```

## WF-09 Learning path completion
```mermaid
flowchart TD
  A[Enroll in path] --> B{Path prerequisites?}
  B -- no --> X[Reject]
  B -- yes --> C[Create path enrollment; unlock first course]
  C --> D[Complete course n] --> E[Recompute % = completed/total] --> F{More courses?}
  F -- yes --> G[Unlock next in sequence] --> D
  F -- no --> H[Path COMPLETED, issue path certificate]
```

## WF-10 Rate-limit enforcement
```mermaid
flowchart TD
  A[Request] --> B[WAF coarse limit] -->|over| R1[HTTP 429 + Retry-After]
  B -->|ok| C[ORDS / APEX]
  C --> D[Resolve identity server-side: user id or verified client key]
  D --> E[Load policy for operation]
  E --> F[Atomic increment in autonomous txn]
  F --> G{count > limit?}
  G -- yes --> H[Log RATE_LIMIT once per window] --> R2[ORA-20429 → APEX message / ORDS 429 + Retry-After]
  G -- no --> I[Proceed]
  F -.limiter error.-> J{fail_mode}
  J -- OPEN --> I
  J -- CLOSED --> R2
```

## WF-11 Approval and escalation
```mermaid
flowchart TD
  A[Submit request] --> B[Resolve approver: manager / admin by type] --> C[Notify approver]
  C --> D{Decision}
  D -- approve --> E[Apply: enrollment APPROVED→ENROLLED/ course PUBLISHED] --> F[Notify requester]
  D -- reject --> G[Record reason] --> F
  C -.overdue > N days.-> H[Escalate to approver's manager, notify] --> C
```
Approver cannot be the requester; delegate approver supported through `LMS_APPROVALS.delegate_user_id`.

### Common database operations summary
All state transitions: row lock → validate → DML → audit (autonomous) → enqueue notification (same transaction) → caller commits. Notification sending is asynchronous by `LMS_NOTIFICATION_PKG.PROCESS_QUEUE` (scheduler every minute, `FOR UPDATE SKIP LOCKED` batches, retry with backoff 1/5/30 min, give up after 5 attempts and log).
