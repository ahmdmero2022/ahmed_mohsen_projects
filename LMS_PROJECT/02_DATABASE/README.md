# 02_DATABASE — status: written, NOT executed against Oracle 19c

| File | Contents |
|---|---|
| `01_core_schema.sql` | 21 tables: org, RBAC, categories, courses, prerequisites, modules, lessons, enrollments, lesson progress, settings, audit, security events, rate-limit policies/counters |
| `02_packages_security_ratelimit_enrollment.sql` | `LMS_SECURITY_PKG`, `LMS_AUDIT_PKG`, `LMS_RATE_LIMIT_PKG`, `LMS_ENROLLMENT_PKG`, seed rate-limit policies, purge job |

Run order: 01 then 02 as the schema owner (needs `GRANT EXECUTE ON SYS.DBMS_CRYPTO`). Within 02, specs compile before bodies. The remaining ~45 tables and packages are listed in `01_DOCUMENTATION/08_Readiness_Report.md` §4.
