# Shared Components specification (all five LMS apps)

Status: **specification, not an APEX export.** Nothing here was imported into an APEX 24.1 workspace. Menu paths follow the
APEX 24.1 Builder as documented; confirm labels in your instance. Build once in **app 200 (master)**, then in apps 210–240
use *Shared Components → Subscriptions* (authorization schemes, LOVs, lists, text messages, static files, theme) so there is
one definition. A subscribed component refreshes only when you press **Refresh** on the subscriber.

## 1. Applications
| ID | Alias | Name | Home page | Audience |
|---|---|---|---|---|
| 200 | `lms` | LMS Learning Portal | 1 | learners (everyone) |
| 210 | `lms-instructor` | LMS Instructor Portal | 1 | instructors, training admins |
| 220 | `lms-admin` | LMS Administration | 1 | training admins, system admins |
| 230 | `lms-manager` | LMS Management | 1 | department managers, HR |
| 240 | `lms-analytics` | LMS Analytics | 1 | executives, HR, training admins |

Common settings (**Shared Components → Application Definition / Security Attributes**):
| Setting | Value | Why |
|---|---|---|
| Parsing schema | `LMS_APP` (not the owner) | has `EXECUTE` on `LMS_*_PKG` and `SELECT` on `V_LMS_*` views only |
| Application Primary Language | English; add **Arabic (ar)** (Globalization → Application Language Map) | RTL is automatic for `ar` |
| Authorization Scheme (application level) | `LMS_AUTH_ACTIVE` | a signed-in identity that is not an active `LMS_USERS` row sees nothing |
| Session Timeout | idle 1800 s, max length 28800 s, with *"Redirect to page"* 9998 | doc 06 |
| Session State Protection | **Enabled**; every page ≥ "Arguments Must Have Checksum"; items that carry IDs = "Checksum Required – Session Level" | IDOR defence |
| Deep Linking | Disabled for 40 (assessment), 20 (player) | must pass through start/resume logic |
| Browser Cache | Disabled on all authenticated pages | no stale authorised data |
| Cookie attributes | Secure, HttpOnly, SameSite=Lax; cookie name unique per app | |
| HTTP Response Headers | see §2 | CSP, nosniff, referrer policy |
| Error Handling Function | `lms_apex_pkg.error_handler` | friendly business errors, generic internals |
| Substitution strings | `APP_NAME_LMS` = "LMS" | |
| Logging / Debug | Debug = "Yes" only in DEV; in PROD "No" (Debug level cannot be forced by URL: *Allow debugging by developers only*) | |
| Build Option | `LMS_DEV_ONLY` excluded in PROD (hides test pages) | |

### 1.1 Authentication scheme (all apps)
1. **PROD:** *Social Sign-In* (OpenID Connect) against the corporate IdP, or SAML/reverse-proxy scheme as your IdP team
   prescribes. Username claim = `preferred_username`/UPN, matched **upper-case** against `LMS_USERS.USERNAME`.
2. **Post-Authentication Procedure Name:** `lms_apex_pkg.post_auth` (maps identity → `LMS_USERS`, sets protected items
   `LMS_USER_ID`, `LMS_LANG`, session language, logs `LOGIN_SUCCESS` / `LOGIN_DENIED`).
3. **DEV/bridge only:** *Custom* scheme whose function is the organisation's `AUTH.Pkg_Security` flow
   (`Authenticate_User_` + `Process_Login_`), with the hardening listed in doc 06 §2. Never combine DEV and PROD schemes
   in the same exported application.
4. Logout URL → IdP single logout; **Session Not Valid** page = 9998; **Login** page = 9999 (only when using a local scheme).

## 2. Security headers (Security Attributes → HTTP Response Header)
```
Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline';
                         img-src 'self' data: https://<cdn-host>; media-src 'self' https://<cdn-host>;
                         frame-src https://<cdn-host>; frame-ancestors 'self'; base-uri 'self'; form-action 'self'
X-Content-Type-Options: nosniff
Referrer-Policy: same-origin
Permissions-Policy: camera=(), microphone=(), geolocation=()
```
APEX itself needs `'unsafe-inline'`/`'unsafe-eval'` for several native features; tighten with nonces only if your APEX
release supports it, and test the Builder pages separately (the Builder is a different application). Add `<cdn-host>`
for video/PDF viewers. `frame-ancestors 'self'` also blocks clickjacking of the player.

## 3. Authorization schemes
Type **PL/SQL Function Returning Boolean**. "Once per session" is safe where roles rarely change mid-session; use "Once per
page view" for anything data-dependent. Error message key = text message `LMS_ERR_FORBIDDEN`.

| Scheme | Function body | Evaluate |
|---|---|---|
| `LMS_AUTH_ACTIVE` (app level) | `return lms_apex_pkg.is_active_user;` | session |
| `LMS_AUTH_CATALOG` | `return lms_apex_pkg.has_perm('CATALOG_VIEW');` | session |
| `LMS_AUTH_LEARNER` | `return lms_apex_pkg.has_perm('ENROLL_SELF');` | session |
| `LMS_AUTH_INSTRUCTOR` | `return lms_apex_pkg.has_perm('COURSE_AUTHOR') or lms_apex_pkg.has_perm('GRADE') or lms_apex_pkg.has_perm('SESSION_MANAGE');` | session |
| `LMS_AUTH_COURSE_AUTHOR` | `return lms_apex_pkg.has_perm('COURSE_AUTHOR');` | session |
| `LMS_AUTH_QUIZ_AUTHOR` | `return lms_apex_pkg.has_perm('QUIZ_AUTHOR');` | session |
| `LMS_AUTH_GRADE` | `return lms_apex_pkg.has_perm('GRADE');` | session |
| `LMS_AUTH_SESSION_MANAGE` | `return lms_apex_pkg.has_perm('SESSION_MANAGE');` | session |
| `LMS_AUTH_MANAGER` | `return lms_apex_pkg.is_manager;` | session |
| `LMS_AUTH_ENROLL_ASSIGN` | `return lms_apex_pkg.has_perm('ENROLL_ASSIGN');` | session |
| `LMS_AUTH_APPROVER` | `return lms_apex_pkg.has_perm('ENROLL_APPROVE') or lms_apex_pkg.has_perm('COURSE_PUBLISH');` | session |
| `LMS_AUTH_TRAINING_ADMIN` | `return lms_apex_pkg.has_perm('COURSE_PUBLISH');` | session |
| `LMS_AUTH_CERT_POLICY` | `return lms_apex_pkg.has_perm('CERT_POLICY');` | session |
| `LMS_AUTH_HR` | `return lms_apex_pkg.has_perm('SKILL_MANAGE');` | session |
| `LMS_AUTH_REPORT_TEAM` | `return lms_apex_pkg.has_perm('REPORT_TEAM');` | session |
| `LMS_AUTH_REPORT_ORG` | `return lms_apex_pkg.has_scope('REPORT_ORG','ALL');` | session |
| `LMS_AUTH_SYSADMIN` | `return lms_apex_pkg.has_perm('USER_ADMIN');` | session |
| `LMS_AUTH_ROLE_ADMIN` | `return lms_apex_pkg.has_perm('ROLE_ADMIN');` | session |
| `LMS_AUTH_SETTINGS` | `return lms_apex_pkg.has_perm('SETTINGS_ADMIN');` | session |
| `LMS_AUTH_AUDIT` | `return lms_apex_pkg.has_perm('AUDIT_VIEW');` | session |
| `LMS_AUTH_RATELIMIT` | `return lms_apex_pkg.has_perm('RATELIMIT_ADMIN');` | session |
| `LMS_AUTH_TEMPLATES` | `return lms_apex_pkg.has_perm('NOTIF_TEMPLATE_ADMIN');` | session |
| `LMS_AUTH_ENROLLED` | `return lms_apex_pkg.is_enrolled(:P20_ENROLLMENT_ID);` | page view |
| `LMS_AUTH_COURSE_MANAGE` | `return lms_apex_pkg.can_manage_course(:P_COURSE_ID_ITEM);` — create one scheme per page item name that carries a course id (e.g. `…_P11`) because the bind differs | page view |
| `LMS_AUTH_CERT_OWNER` | `return lms_apex_pkg.owns_certificate(:P61_CERTIFICATE_ID);` | page view |

Rule (doc 01 NFR-SEC-01): **a scheme only decides visibility/reachability.** Every write also re-checks the permission inside
the package, so a mis-assigned scheme cannot grant a write.

## 4. Application items and computations
| Item | Scope | Protection | Set by |
|---|---|---|---|
| `LMS_USER_ID` | Application | **Restricted – May not be set from browser** | `post_auth` |
| `LMS_LANG` | Application | Restricted | `post_auth`; Preferences page via `lms_user_pkg.set_language` + `apex_util.set_session_lang` |
| `LMS_UNREAD` | Application | Restricted | computation *Before Header* on page 0: `select count(*) from v_lms_my_notifications where read_flag='N'` |

Never read `:LMS_USER_ID` for authorization; packages derive identity themselves (`LMS_SECURITY_PKG.CURRENT_USER_ID`). The
items are for display/convenience only.

## 5. Lists of values (cached "Application" LOVs, subscribed)
| LOV | SQL |
|---|---|
| `LOV_CATEGORIES` | `select case when :LMS_LANG='ar' and name_ar is not null then name_ar else name_en end d, category_id r from v_lms_categories order by sort_order` |
| `LOV_DIFFICULTY` | Static: BEGINNER / INTERMEDIATE / ADVANCED (display = text messages `LMS_DIFF_*`) |
| `LOV_DELIVERY` | Static: SELF_PACED / CLASSROOM / VIRTUAL / BLENDED |
| `LOV_COMPLETION_RULE` | Static: LESSONS, LESSONS_ASSESSMENT, ATTENDANCE, LESSONS_ATTENDANCE, INSTRUCTOR_APPROVAL |
| `LOV_LESSON_TYPE` | Static: VIDEO, PDF, PRESENTATION, TEXT, HTML, URL, DOWNLOAD, INTERACTIVE, ASSESSMENT, ASSIGNMENT, LIVE_SESSION |
| `LOV_QUESTION_TYPE` | Static: MCQ, MULTI, TF, MATCH, SHORT, ESSAY |
| `LOV_DEPARTMENTS`, `LOV_POSITIONS`, `LOV_USERS_ACTIVE` (admin/manager apps), `LOV_ROLES` | from the `V_LMS_LOV_*` views (§6) |

Static display values are Text Messages (not literals) so they translate.

## 6. Lookup views used by LOVs
Pages must not select from base tables. The lookup views are in `02_DATABASE/16_views_lov.sql`:
`V_LMS_CATEGORIES`, `V_LMS_LOV_DEPARTMENTS`, `V_LMS_LOV_POSITIONS`, `V_LMS_LOV_USERS` (visible users only),
`V_LMS_LOV_INSTRUCTORS`, `V_LMS_LOV_VENUES`, `V_LMS_LOV_SKILLS`, `V_LMS_LOV_TEMPLATES`, `V_LMS_LOV_ROLES`.
Use them in the LOV SQL, e.g. `LOV_CATEGORIES`: `select case when :LMS_LANG='ar' and name_ar is not null then name_ar else name_en end d, category_id r from v_lms_categories order by sort_order`.

## 7. Navigation
One **List** per app (type *Navigation Menu*), each entry with a **Condition Type = Authorization Scheme** so users only
see what they may open. Hiding is cosmetic; every target page has its own authorization. Entries per app are listed in the
page specification of that app. **Navigation Bar** list (all apps): notifications (badge `&LMS_UNREAD.`, target 200:80),
cross-app switcher ("Instructor", "Administration", "Management", "Analytics" — each conditioned on its scheme, link
built with `apex_page.get_url(p_application => 210, p_page => 1)`), language toggle (calls `lms_user_pkg.set_language`
through a process then reloads), user menu (profile 200:70, logout).

## 8. Static files, theme, templates
| Asset | Location | Notes |
|---|---|---|
| `app.css`, `player.js`, `assessment.js` | `03_APEX/STATIC_FILES/` → *Static Application Files* of app 200 (subscribed by 210–240 for `app.css`) | reference as `#APP_FILES#app#MIN#.css`; minify in the release pipeline |
| Theme | Universal Theme (Vita), Theme Style "LMS" via Theme Roller using the tokens in `app.css` | keep one Theme Style, no per-page colour overrides |
| Page templates | *Standard* (with left side column, breadcrumb), *Minimal (No Navigation)* for 9998/9999/90, *Modal Dialog* for dialogs, a cloned *Standard* named **Player** for 200:20 (no side navigation, full width body) | |
| Region templates | *Cards*, *Standard*, *Alert*, *Inline Dialog*; custom **KPI Tile** (template options: ok/warn/bad) | |
| Icons | Font APEX (built in) only; no external icon CDNs | CSP |
| Fonts | Latin: system stack; Arabic: *Noto Sans Arabic* or *Tajawal* self-hosted as static files (woff2) | no third-party font calls (CSP, privacy) |

## 9. Text Messages and translation
`text_messages.csv` (this folder) is the source of truth for dynamic/JS/error text (keys, EN, AR). Create them in
*Shared Components → Text Messages* (set **Used in JavaScript = Yes** for `LMS_JS_*`). For page-level static text use
*Translate Application → Seed → Export XLIFF → translate → Apply → Publish*. Arabic copy in the CSV is a **draft for
native-speaker review**.

## 10. Build conventions (apply to every page)
- Static IDs: regions `R_<PURPOSE>` (e.g. `R_CATALOG`), buttons `B_<ACTION>`, items `P<page>_<NAME>`, processes `PR_<VERB>_<NOUN>`,
  dynamic actions `DA_<WHAT>`, validations `V_<RULE>`, computations `C_<ITEM>`.
- **IDs in URLs:** link builder always `apex_page.get_url(...)` / declarative links so the checksum is added; items that accept IDs have
  *Value Protected = Yes*.
- **No business logic in pages:** processes are one-liners calling a package procedure; validations are UX helpers only
  (the package/constraint is the authority).
- **Escaping:** report/card columns "Escape special characters = Yes" (the default); the only exceptions are columns that
  build trusted markup from `apex_escape.html(...)` inside the SQL, flagged in the spec.
- **Transactions:** a page submit = one transaction; do not call `COMMIT` in page code; error → APEX rolls back.
- **Lazy loading** on every dashboard region below the fold; cards/IR pagination ≤ 50 rows; no region without a row limit.
- **Accessibility:** every interactive region has a title (hidden if not visually needed); icon-only buttons have *Label*
  (hidden text) set; status columns show text, not colour only.
- **Empty states:** each report region has *No Data Found* message = text message + call-to-action link (see page specs).
