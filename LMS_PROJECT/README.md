# Enterprise LMS — Oracle APEX 24.1 + Oracle Database 19c

Design package and implementation blueprint. Document version 0.1 (draft for review).

## Honest status (read first)

| Item | Status |
|---|---|
| Design documents (requirements, architecture, ERD, flows, UI, security, testing, deployment) | **Written** — see index below |
| SQL/PL/SQL in `02_DATABASE/` | **Written, NOT compiled or executed.** No Oracle 19c instance was available. Treat as reviewed code that must be installed (`00_install.sql`) and tested in a dev schema |
| APEX application export (`f*.sql`) | **Not produced.** Page specifications only; cannot be validated without an APEX 24.1 workspace |
| Test results | **None.** Test cases are defined; all "Actual result" fields are blank |
| Database scripts (56 tables, 91 views, 22 packages, seeds, jobs, validation, rollback) | **Written, not executed.** Static consistency checks run; see `02_DATABASE/README.md` |
| APEX page specifications (5 apps, ~75 pages), shared components, CSS/JS | **Written as build specs**; no APEX export; JS syntax-checked only; see `03_APEX/README.md` |
| ORDS modules, OpenAPI contract, smoke test | **Written, not executed**; see `05_INTEGRATIONS/README.md` |

## Index

| # | Document | Covers prompt steps |
|---|---|---|
| 01 | [Overview & Requirements](01_DOCUMENTATION/01_Overview_and_Requirements.md) | 1, 2 |
| 02 | [Architecture](01_DOCUMENTATION/02_Architecture.md) | 3 |
| 03 | [Database Design (ERD + dictionary)](01_DOCUMENTATION/03_Database_Design.md) | 4, 5 |
| 04 | [Business Process Flows](01_DOCUMENTATION/04_Process_Flows.md) | 6 |
| 05 | [UI/UX and APEX Page Specs](01_DOCUMENTATION/05_UIUX_and_APEX_Pages.md) | 7, 9 |
| 06 | [Security, Rate Limiting, Performance](01_DOCUMENTATION/06_Security_RateLimit_Performance.md) | 10, 11 |
| 07 | [Testing, Deployment, Operations](01_DOCUMENTATION/07_Testing_Deployment_Operations.md) | 12, 13 |
| 08 | [Readiness Report](01_DOCUMENTATION/08_Readiness_Report.md) | 14 |
| DB | [`02_DATABASE/`](02_DATABASE/) scripts | 8 |
| APEX | [`03_APEX/`](03_APEX/) page specs, shared components, static files | 9 |
| REST | [`05_INTEGRATIONS/`](05_INTEGRATIONS/) ORDS modules, OpenAPI | 9, 10 |

## Key decisions (summary)

1. **Five APEX applications, one schema** (Portal, Instructor, Admin, Management, Analytics), shared packages, shared authentication.
2. **Authentication:** SSO/OIDC preferred in production. Where the organisation's existing `AUTH.Pkg_Security` scheme is used, it is a bridge only; it has known weaknesses (recoverable passwords, user enumeration, no lockout) listed in doc 06 §6.
3. **Rate limiting is layered:** WAF/reverse proxy for volume, ORDS/PL/SQL for business operations. Database counters are used only for sensitive operations, never every page view.
4. **Videos are stored outside the database** (object storage/CDN or streaming service); the database stores metadata and signed-URL references. Documents ≤ 25 MB may use BLOB.
5. **Capacity controlled by row-level locking on the course row**, with a partial unique index as the last defence against duplicate enrollment.
6. **No features newer than APEX 24.1 / DB 19c** (no 23ai syntax, no `IF NOT EXISTS`, no JSON Relational Duality).

## Assumptions needing confirmation

See doc 01 §1.6. Most impactful: user count (10k assumed), SSO provider, video hosting, Arabic as co-primary language, Partitioning option licensed or not.
