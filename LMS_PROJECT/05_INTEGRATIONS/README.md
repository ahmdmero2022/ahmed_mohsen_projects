# 05_INTEGRATIONS — ORDS modules and REST contract

Status: **written, not executed.** No ORDS instance was available. API signatures (`ORDS.*`, `OAUTH.*`) and the
`:status_code` / HEADER-OUT mechanics must be confirmed against the ORDS release certified for your APEX 24.1 install.

| File | Purpose |
|---|---|
| `ORDS/01_enable_roles_clients.sql` | Enable schema (base path `lms`), roles, privileges, three OAuth2 client-credentials clients |
| `ORDS/02_modules.sql` | Modules `lms.public`, `lms.catalog`, `lms.hr`, `lms.ops` (re-runnable) |
| `REST_APIS/lms-openapi.yaml` | OpenAPI 3.0.3 contract (YAML parses; not validated against a live service) |
| `../06_TESTING/INTEGRATION_TESTS/ords_smoke_test.sh` | curl-based smoke/abuse test (I-06..I-10, R-14, R-15) |
| `../02_DATABASE/14_ords_pkg.sql` | All handler logic (`LMS_ORDS_PKG`) |

## Endpoints
| Method / path | Auth | Rate-limit policy | Purpose |
|---|---|---|---|
| `GET /ords/lms/public/certificates/{code}` | none | `CERT_VERIFY` 30/min per client key | Verification, minimal disclosure |
| `GET /ords/lms/catalog/courses` | OAuth2 `lms.catalog_read` | `COURSE_SEARCH` 60/min | Search published courses |
| `GET /ords/lms/catalog/courses/{id}` | OAuth2 `lms.catalog_read` | `COURSE_SEARCH` | Course details |
| `POST /ords/lms/hr/employees` | OAuth2 `lms.hr_sync` | `HR_SYNC` 6/min, fail closed | Batch upsert (≤ 500) |
| `GET /ords/lms/ops/health` | OAuth2 `lms.ops` | none | Monitoring |

## Design decisions
1. **All handler logic lives in a package**, not in handler source. Handlers are 6 lines that call the package and copy
   status/`Retry-After`. Logic is therefore versioned, reviewable and testable without ORDS.
2. **Identity of anonymous callers = proxy-verified client address**, passed in the header `X-LMS-Client-IP`.
   The reverse proxy must **overwrite** this header on every request (never append/forward the client's value) and
   ORDS must be reachable only from the proxy (network ACL / firewall). The limiter hashes the value (SHA-256) before
   storing it. A direct call to ORDS from outside the proxy could forge the header; that is why network isolation is a
   hard requirement, not an option.
3. **OAuth2 clients are machine identities**, so no endpoint returns data about a specific learner. Learner-specific
   data stays inside APEX (session + authorization schemes).
4. **Least privilege:** deploy the REST modules in a separate schema `LMS_REST` that has only
   `GRANT EXECUTE ON lms_owner.lms_ords_pkg TO lms_rest` (no table/view grants). `LMS_ORDS_PKG` runs with definer rights.
   `LMS_HR_SYNC_PKG` is reachable only through `LMS_ORDS_PKG` (grant it to the owner only). Using the owner schema for
   REST works but widens the blast radius of an ORDS compromise.
5. **No personal data in errors**: unknown/malformed certificate codes both return 404; 500 returns a fixed text and the
   detail goes to `LMS_SECURITY_EVENTS` (`API_ERROR`).
6. **HR batch semantics**: per-employee savepoints; 200 all ok, 207 partial (failed items listed), 400 malformed. ORDS
   commits the successful rows when the handler completes. Re-sending a batch is safe (upsert).

## Reverse-proxy requirements (nginx shown; translate for your product)
```nginx
# overwrite, never forward, the client-supplied value
proxy_set_header X-LMS-Client-IP $remote_addr;          # $remote_addr must be the real client (set_real_ip_from <LB CIDR>)
proxy_set_header X-Forwarded-For $remote_addr;
limit_req_zone $binary_remote_addr zone=lms_public:10m rate=30r/m;
location /ords/lms/public/ { limit_req zone=lms_public burst=10 nodelay; limit_req_status 429;
                             add_header Retry-After 60 always; proxy_pass http://ords_upstream; }
location /ords/lms/hr/     { allow <HR system CIDR>; deny all; proxy_pass http://ords_upstream; }   # network allow-list on top of OAuth2
location /ords/lms/ops/    { allow <monitoring CIDR>; deny all; proxy_pass http://ords_upstream; }
```
Also: TLS 1.2+, request body limit (`client_max_body_size 2m` for `/hr/`), no CORS at the proxy (CORS for `/public` is set
in ORDS via `SET_MODULE_ORIGINS_ALLOWED`).

## Deployment order
1. DB scripts `00_install.sql` (includes `13_apex_glue.sql`, `14_ords_pkg.sql`).
2. As the owner: `GRANT EXECUTE ON lms_ords_pkg TO lms_rest;` (if a separate REST schema is used).
3. As `lms_rest`: `@01_enable_roles_clients.sql` (prompts: `schema`, `support_email`) then `@02_modules.sql`
   (`owner`, `allowed_origin`).
4. Read client credentials once, store in the secret manager; configure the HR job and monitoring with them.
5. Run `ords_smoke_test.sh`; review `LMS_API_REQUEST_LOG`.

## Known gaps
- No endpoint yet for content-platform webhooks or virtual-classroom callbacks (listed in the prompt as possible
  integrations); add as separate modules with their own client and HMAC signature check.
- No SSO group-to-role sync endpoint; roles are managed in LMS (`LMS_USER_PKG`).
- ORDS metadata export (`ORDS.EXPORT_MODULE`) should be committed after the first successful deployment so that the
  environment definitions are reproducible byte-for-byte.
