# 08 — Final Quality Review and Implementation Readiness (Step 14)

## 1. Verified vs proposed

| Area | Status | Evidence |
|---|---|---|
| Documents 01–07 | Written | Files in this repo |
| Mermaid diagrams | **Unverified** | Not rendered; syntax reviewed by eye only |
| `01_core_schema.sql` | **Unverified** | Not run on Oracle 19c. Reviewed for 19c-valid syntax (identity, function-based unique index, `IS JSON` check) |
| `02_packages_*.sql` | **Unverified** | Not compiled. Compile order fixed to specs-then-bodies (security/audit are mutually dependent) |
| APEX export | **Not produced** | Page specs only |
| Test execution | **None** | All tests unexecuted |
| Performance figures | **Estimates** | Order-of-magnitude, not measured |

## 2. Review checks

| Check | Result |
|---|---|
| Architectural consistency | Layers/packages/pages consistent. Five-app split requires a shared-components subscription strategy (doc 01 §1.2) |
| Referential integrity | DDL FKs match ERD for implemented tables. Intentional no-FK audit/security columns documented |
| DDL validity | Not executed. Risks to check on first run: inline `PRIMARY KEY` after identity clause, function-based unique index with `CASE`, `CHECK … IS JSON` on `VARCHAR2` |
| Package dependencies | `LMS_AUDIT_PKG` ↔ `LMS_SECURITY_PKG` circular spec dependency (resolved by order); `LMS_RATE_LIMIT_PKG` needs `DBMS_CRYPTO` grant; enrollment needs all three |
| APEX 24.1 compatibility | Features used (Cards, Faceted Search, IG/IR, Charts, Automations, Social Sign-In) exist in 24.1 per my knowledge; items flagged "verify" in docs (language preference API, ORDS 429 header mechanics, Approvals/Workflow component as engine) must be confirmed in a real instance |
| Oracle 19c compatibility | No 21c/23ai-only syntax used |
| Access-control enforcement | Server-side via packages; one known shortcut (see below) |
| Rate-limit correctness | Atomic increment + autonomous txn + unique key race handling; fixed-window boundary burst (≤2×) accepted |
| Testing completeness | 102 cases defined (32 F, 20 S, 15 P, 15 R, 20 I); none executed |
| Deployment readiness | Checklist defined; scripts 14–21 not yet written |

## 3. Known defects / shortcuts in delivered code (found on self-review)

1. **`LMS_ENROLLMENT_PKG.ASSIGN`** uses `HAS_PERMISSION('REPORT_ORG')` as a stand-in for "unrestricted scope". Replace by scope lookup (`LMS_ROLE_PERMISSIONS.SCOPE`).
2. **`LMS_ENROLLMENT_PKG.CANCEL`** allows any `ENROLL_ASSIGN` holder to cancel anyone's enrollment without subtree/scope check.
3. **`LMS_ENROLLMENT_PKG.DO_ENROLL`** rate-limit and audit calls happen before commit; audit rows (autonomous) can exist for a rolled-back enrollment. Acceptable for audit semantic ("attempted"), but the metadata should say so.
4. **Waitlist promotion** does not enqueue notifications yet; approval (`PENDING`→`APPROVED`) transition procedure is not implemented.
5. **`LMS_SECURITY_PKG.CURRENT_USER_ID_SAFE`** uses `SYS_CONTEXT('APEX$SESSION','APP_USER')`; confirm the namespace/attribute in 24.1, otherwise use `V('APP_USER')` or `APEX_APPLICATION.G_USER`.
6. **Rate-limit `HIT`**: exception handler references `l_pol.fail_mode`, which is unset if the policy lookup itself failed; defaults then to fail-open. Decide whether a lookup failure for sensitive ops should fail closed.
7. **Seed policies** MERGE is idempotent; running the scheduler job creation twice raises ORA-27477 (job exists) — wrap in existence check.
8. `LMS_ENR_DONE_CK` check is redundant-looking; simplify to `status <> 'COMPLETED' OR completed_at IS NOT NULL`.

## 4. Outstanding work (explicitly incomplete deliverables)

| # | Work item | Prompt reference |
|---|---|---|
| 1 | DDL for all [SPEC] tables (~45), plus constraints/indexes (scripts 04, 06–11 of the suggested structure) | §8 |
| 2 | Seed data (roles, permissions, matrix, categories, templates), test data scripts | §8 |
| 3 | Packages: USER, COURSE, PROGRESS, ASSESSMENT, LEARNING_PATH, CERTIFICATION, NOTIFICATION, REPORTING + full unit tests | §9 |
| 4 | Reporting views and summary tables, scheduler jobs | §5 M14, §16 |
| 5 | Full per-page APEX definitions (items, DAs, validations, SQL) for every page in doc 05; APEX exports | §13 |
| 6 | ORDS modules and templates; WAF config for chosen product | §15 |
| 7 | Low-fidelity wireframes and high-fidelity mock-ups (not drawn); full screen-state tables for every screen | §11 |
| 8 | JMeter/k6 scripts; utPLSQL decision | §19 |
| 9 | Rollback scripts, validation script, installation guide per environment | §22 |
| 10 | Arabic translation of UI strings and notification templates | §2 |

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
**Not implementation-complete.** The blueprint (requirements, architecture, data model, flows, UI/APEX map, security, rate limiting, test plan, deployment) is ready for review. Code is an unexecuted starting point covering the enrollment/security/rate-limit vertical slice. Recommended next step (matches your note): finalise DDL for all modules in a dev 19c schema and compile/test the packages first, then build APEX pages on top of the proven data model.
