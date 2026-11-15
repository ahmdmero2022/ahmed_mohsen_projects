# 02 — System Architecture (Step 3)

All diagrams are Mermaid. Not rendered/validated in this session; paste into a Mermaid live editor to check.

## 1. High-level solution architecture

```mermaid
flowchart LR
  U[Learners / Instructors / Managers / Admins] -->|HTTPS| WAF[WAF + Reverse Proxy / Load Balancer]
  WAF --> ORDS1[ORDS node 1]
  WAF --> ORDS2[ORDS node 2]
  ORDS1 --> DB[(Oracle DB 19c<br/>LMS schema)]
  ORDS2 --> DB
  subgraph APEX[APEX 24.1 workspace LMS]
    A1[200 Learning Portal]
    A2[210 Instructor]
    A3[220 Administration]
    A4[230 Management]
    A5[240 Analytics]
  end
  ORDS1 --- APEX
  DB --- APEX
  IDP[Corporate IdP OIDC/SAML] -.SSO.-> WAF
  HR[HR system] -->|REST/CSV| ORDS1
  DB -->|APEX_MAIL| SMTP[SMTP relay]
  A1 -->|signed URLs| OBJ[(Object storage / CDN<br/>video, large files)]
  DB --> BK[(RMAN backups)]
```

## 2. Component responsibilities

| Component | Responsibility | Interacts with |
|---|---|---|
| WAF / reverse proxy | TLS termination, coarse rate limits, bot rules, header sanitising (sets trusted `X-Forwarded-For`) | ORDS |
| ORDS (≥ 2 nodes) | Serve APEX and REST modules; JDBC pool per node | DB |
| APEX apps | UI, validation UX, calling packages | Packages |
| `LMS_SECURITY_PKG` | Current user resolution, permission checks, row visibility | all packages |
| `LMS_COURSE_PKG` | Course lifecycle, approvals | security, audit |
| `LMS_ENROLLMENT_PKG` | Eligibility, capacity, waitlist, approval | rate limit, notification |
| `LMS_PROGRESS_PKG` | Event ingest, dedupe, % and completion | enrollment, certification |
| `LMS_ASSESSMENT_PKG` | Attempts, grading, answer protection | progress |
| `LMS_CERTIFICATION_PKG` | Issue/verify/revoke/renew | notification |
| `LMS_NOTIFICATION_PKG` | Queue, render templates, send, retry | `APEX_MAIL` |
| `LMS_RATE_LIMIT_PKG` | Atomic quota decisions | security events |
| `LMS_AUDIT_PKG` | Append-only audit and security events (autonomous) | all |
| `LMS_REPORTING_PKG` + MVs/summary tables | Dashboard data | scheduler |
| DBMS_SCHEDULER jobs | Notifications, reminders, summary refresh, cleanup, expiry | packages |

## 3. Logical application architecture

```mermaid
flowchart TB
  subgraph P[Presentation: APEX pages]
    Pg[Pages, Cards, IR/IG, Charts, Dialogs]
  end
  subgraph S[Application services: PL/SQL packages]
    Sec[SECURITY] --- Crs[COURSE] --- Enr[ENROLLMENT] --- Prg[PROGRESS] --- Asm[ASSESSMENT] --- Crt[CERTIFICATION]
    Ntf[NOTIFICATION] --- Rpt[REPORTING] --- Rl[RATE_LIMIT] --- Aud[AUDIT]
  end
  subgraph D[Data: tables, constraints, views, MVs]
    T[(LMS_* tables)]
  end
  subgraph I[Integration: ORDS REST modules]
    R[hr/employees, content/webhooks, verify/certificate, notifications]
  end
  Pg --> S
  R --> S
  S --> D
```

Rules: pages never write to tables directly except trivial maintenance forms on lookup tables; every other DML goes through a package. Packages never `COMMIT` (exception: autonomous audit/rate-limit/queue procedures). The APEX page process owns the transaction.

## 4. Deployment architecture

```mermaid
flowchart TB
  subgraph DMZ
    LB[Load balancer + WAF]
  end
  subgraph AppTier
    O1[ORDS + Jetty/Tomcat 1]
    O2[ORDS 2]
  end
  subgraph DataTier
    DBP[(Primary 19c)]
    DBS[(Standby - Data Guard, if licensed)]
  end
  LB --> O1 & O2
  O1 & O2 --> DBP
  DBP -.redo.-> DBS
  DBP --> RM[(RMAN backup target)]
  O1 & O2 --> ST[(Static files / CDN)]
```

Environments: DEV → TEST → UAT → PROD, each with its own schema, ORDS and workspace; same scripts, different `LMS_SYSTEM_SETTINGS` and credentials (never in source).

## 5. Data-flow diagram (level 1)

```mermaid
flowchart LR
  L((Learner)) -->|enroll request| E[Enrollment]
  E -->|enrollment| DB1[(Enrollments)]
  L -->|progress event| PG[Progress]
  PG -->|validated events| DB2[(Lesson progress)]
  PG -->|completion| C[Certification]
  C --> DB3[(Certificates)]
  L -->|answers| AS[Assessment]
  AS --> DB4[(Attempts/Responses)]
  AS --> PG
  E & PG & C --> N[Notification queue]
  N --> M((Email/In-app))
  DB1 & DB2 & DB3 & DB4 --> RP[Summary jobs] --> DASH[Dashboards]
  HRS((HR)) -->|employee feed| U[User sync] --> DB0[(Users)]
```

## 6. Authentication sequence

```mermaid
sequenceDiagram
  actor U as User
  participant W as WAF
  participant A as APEX app
  participant I as IdP (OIDC)
  participant S as LMS_SECURITY_PKG
  participant L as LMS_AUDIT_PKG
  U->>W: GET app URL
  W->>W: Rate check (login path)
  W->>A: forward
  A->>I: redirect (auth request)
  I->>U: credentials / MFA
  I->>A: code → ID token (validated by APEX Social Sign-In scheme)
  A->>S: post_auth (map IdP subject → LMS_USERS)
  alt not mapped or INACTIVE
    S->>L: log LOGIN_DENIED
    A-->>U: access error page (generic)
  else ok
    S->>S: load roles, set app items
    S->>L: log LOGIN_SUCCESS
    A-->>U: dashboard by highest-priority role
  end
```

Fallback (dev/local or house scheme): `AUTH.Pkg_Security.Authenticate_User_` verifies the user and `AUTH.AUTHS` grant, then the LMS post-auth procedure above maps the username to `LMS_USERS`. Doc 06 §6 lists required hardening before reuse.

## 7. Course-enrollment sequence

```mermaid
sequenceDiagram
  actor L as Learner
  participant P as APEX page 200:12
  participant E as LMS_ENROLLMENT_PKG
  participant R as LMS_RATE_LIMIT_PKG
  participant DB as Tables
  participant N as Notification queue
  L->>P: click Enroll (+CSRF-protected submit)
  P->>E: enroll(course_id)
  E->>R: enforce_limit('COURSE_ENROLL')
  alt over limit
    R-->>P: ORA-20429 → friendly error
  end
  E->>DB: SELECT course FOR UPDATE
  E->>DB: check published/dates, existing, prerequisites
  E->>DB: count seats
  alt seat free & no approval
    E->>DB: INSERT ENROLLED
  else approval needed
    E->>DB: INSERT PENDING + approval task
  else full
    E->>DB: INSERT WAITLISTED
  end
  E->>N: queue ENROLL_CONFIRM
  E-->>P: enrollment_id, status
  P-->>L: message, redirect My Learning
```

## 8. Learning-progress update sequence

```mermaid
sequenceDiagram
  participant C as Player (browser)
  participant AJ as APEX AJAX callback
  participant G as LMS_PROGRESS_PKG
  participant DB as Tables
  C->>AJ: lesson_complete(lesson_id, event_uuid, position)
  AJ->>G: record_event(...)
  G->>DB: verify enrollment belongs to current user, active, lesson available, prereq lessons done
  G->>DB: MERGE lesson_progress (dedupe on enrollment+lesson / event_uuid unique)
  G->>G: recompute progress % (set-based)
  alt all completion rules met
    G->>DB: UPDATE enrollment COMPLETED (idempotent)
    G->>DB: issue certificate if eligible
  end
  G-->>AJ: JSON {percent,status,next_lesson}
  AJ-->>C: update UI
```

## 9. Rate-limiting architecture
See doc 06 §3 (diagram and policy table).
