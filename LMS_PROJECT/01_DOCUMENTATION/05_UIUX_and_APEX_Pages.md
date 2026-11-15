# 05 — UI/UX Design and APEX Page Specifications (Steps 7 & 9)

Status: specification only. No APEX export was generated or validated. Page numbers are proposals.

## 1. Design system

| Token | Value | Use |
|---|---|---|
| Primary | `#2563EB` | actions, links, focus ring base |
| Secondary | `#0F172A` | sidebar, headings on light |
| Background / Card | `#F8FAFC` / `#FFFFFF` | page / cards |
| Success / Warning / Error | `#16A34A` / `#F59E0B` / `#DC2626` | status |
| Text primary / secondary | `#1E293B` / `#64748B` | body / meta |

- Contrast: `#64748B` on `#FFFFFF` ≈ 4.8:1 (passes AA for normal text); `#F59E0B` on white fails AA for text — use it only as a fill with dark text (`#1E293B`) or an icon with a text label. White on `#2563EB` ≈ 5.2:1 passes. Verify with a contrast tool before sign-off.
- Typography: system UI stack for Latin; **Noto Sans Arabic / Tajawal** for Arabic; base 16px, scale 14/16/20/24/32.
- Radius 12px cards, 8px inputs; shadow `0 1px 3px rgba(15,23,42,.08)`; spacing 4px grid; transitions ≤150 ms; `prefers-reduced-motion` respected.
- Implementation in APEX 24.1: create a **Theme Style** based on Universal Theme (Theme Roller: set CSS variables `--ut-palette-primary`, etc.), plus one `app.css` static file using CSS custom properties; colours only via variables so a dark theme style can be added later.
- Components: KPI card, course card (APEX Cards region template **Cards: Standard** with custom CSS), progress bar, status badge (`u-success/u-warning/u-danger` colour classes), empty-state region, stepper (Wizard Progress list).

### Navigation
Left sidebar (Universal Theme "Left Side Column" template, collapsible), top bar (search item, notifications badge via navigation-bar list entry with `&LMS_UNREAD_COUNT.`, user menu), breadcrumbs region on every non-home page. Mobile: sidebar collapses to modal drawer; cards stack to 1 column; tables switch to column-toggle reports.

### Arabic / RTL
- Set application **Primary Language** en; add **Arabic (ar)** via Shared Components → Globalization → Application Language Map; session language from `LMS_USERS.PREFERRED_LANG` set in post-auth (`APEX_UTIL.SET_SESSION_LANG` equivalent via `APEX_UTIL.SET_PREFERENCE('FSP_LANGUAGE_PREFERENCE', 'ar')`; verify in your 24.1 instance).
- Universal Theme switches to RTL automatically for RTL languages (ar). Use logical CSS properties (`margin-inline-start`, `padding-inline-end`) in `app.css`; avoid `left/right`.
- All UI text through **Shared Components → Text Messages** (`APEX_LANG.MESSAGE('KEY')`); region titles/labels through translation seeding (**Translate Application** → Seed → Export XLIFF → Translate → Publish).
- Mirror directional icons (chevrons, back arrows); keep numerals Western or Arabic-Indic per setting `LMS_NUMERALS`; dates via `TO_CHAR(..., 'DD Month YYYY', 'NLS_DATE_LANGUAGE=ARABIC')`.
- Chart.js-free: use native APEX Charts (JET); ensure axis/legend flip in RTL; test.

### Accessibility checklist
Visible focus (2px `#2563EB` + 2px offset), skip-to-content link, one `h1` per page, labelled form items, error text associated via `aria-describedby` (APEX default), status not by colour alone, minimum 44px touch targets, keyboard-operable cards and player controls, captions for video, `lang`/`dir` attributes set, test with NVDA/VoiceOver, axe.

## 2. Screen inventory and APEX page map

Roles: L Learner · I Instructor · M Manager · TA Training Admin · HR · SA System Admin. Authorization scheme names in `LMS_AUTH_*` map to `LMS_SECURITY_PKG.HAS_PERMISSION('CODE')` (type *PL/SQL Function Returning Boolean*, evaluated once per page view or per session where permissions are static).

### App 200 — Learning Portal
| Pg | Name | Type | Auth | Key regions / components | Source (summary) |
|---|---|---|---|---|---|
| 9999 | Login | Login | Public | Auth scheme (OIDC/Social Sign-In or custom) | — |
| 9998 | Access error / Session expired | Blank | Public | Static content, link to login | — |
| 1 | Learner Dashboard | Home | L | Welcome (static), **Continue learning** (Cards, top 3 IN_PROGRESS), **Progress KPI** (3 Badge-list tiles), **Assigned/mandatory** (Classic report), **Upcoming sessions** (List), **Recommended** (Cards), **Certificates** (Cards), recent achievements | `v_lms_my_enrollments`, `v_lms_my_certs`, recommendation view |
| 10 | Course Catalog | Cards + **Faceted Search** | L (all authenticated) | Facets: Category (checkbox group with counts), Difficulty, Duration bucket, Language; Search box (`LOWER` LIKE bind, Oracle Text optional); Sort select; Cards pagination 12/page | `v_lms_catalog` (published only, with rating, my status) |
| 11 | Course Details | Blank | L | Banner, description, objectives, instructor card, **Curriculum** (tree/collapsible report), prerequisites with met/unmet icons, rating, **Enroll** button (conditional on server-computed `P11_CAN_ENROLL`) | `lms_course_pkg.get_summary` view |
| 12 | Enroll (modal confirm) | Modal dialog | L | Confirmation, process calling `lms_enrollment_pkg.enroll_self` | — |
| 20 | Learning Player | Blank (full-width, no side nav) | L + enrolled (page-level authorization `LMS_AUTH_ENROLLED(P20_COURSE_ID)`) | Left curriculum (Tree/List with completion icons), center content region (video via signed URL, PDF iframe, HTML sanitized), bottom bar (Prev / Mark complete / Next), top progress bar | AJAX callbacks → `lms_progress_pkg.record_event` |
| 30 | My Learning | Report page | L | Tabs (All / Not started / In progress / Completed / Mandatory) implemented as Facets or Static-ID filtered regions; **Resume** button | `v_lms_my_enrollments` |
| 40 | Assessment | Blank | L | Question region (one per page via partial refresh), timer (server deadline `P40_DEADLINE_EPOCH`, client shows countdown only), Save/Next/Prev, Submit with confirm dialog | `lms_assessment_pkg.*` (never selects correct flags) |
| 41 | Assessment result | Blank | L | Score, pass/fail, review (if policy permits) | |
| 50 | Learning Paths | Cards + detail region | L | Path overview, course sequence with lock icons, progress | |
| 60 | Certificates | Cards/IR | L | Title, issue/expiry, code, Download (PDF process after ownership check + `CERT_GENERATE` limit) | `v_lms_my_certs` |
| 70 | Preferences | Form | L | Language, notification channel | `LMS_USERS` via package |
| 90 | Public certificate verification | Blank, public | Public + rate-limited | Input code; shows status, title, issue/expiry, holder name per policy | `lms_certification_pkg.verify` |

### App 210 — Instructor Portal
| Pg | Name | Auth | Notes |
|---|---|---|---|
| 1 | Instructor Dashboard | I | Assigned courses (cards), active learners, **pending grading** (count + IR), upcoming sessions (Calendar), completion stats (bar chart), performance |
| 10–15 | **Course Builder wizard** | I (assigned) / TA | Steps via Wizard Progress: 1 Basic info (form) · 2 Modules (Interactive Grid with sortable rows) · 3 Content (IG of lessons + file upload via native File Upload item to external store/BLOB) · 4 Assessments · 5 Completion rules · 6 Review & publish (validations list, submit for review) |
| 20 | Question Bank | I | IG for questions; modal for options |
| 30 | Grading Queue | I | IR of attempts `PENDING_GRADING`; modal grading page |
| 40 | Sessions | I | Calendar region (Start/End columns), attendance modal (IG) |
| 50 | Learner Progress | I | IR limited to own courses (row filter in view) |

### App 220 — Administration
Pages: 1 Admin dashboard · 10 Course management (IR + form) · 11 Course approvals · 20 Enrollment management (IR, bulk assign via IG selection + `ASSIGN`) · 25 Assignments (mandatory) · 30 Training schedule/sessions · 40 Certificates & templates · 50 Categories (IG) · 60 Learning policies/settings (form on `LMS_SYSTEM_SETTINGS`) · 70 Users (IR + form, role assignment with shuttle) · 71 Roles & permissions (IG matrix) · 80 Audit log (IR, filters, export restricted) · 81 Security events · 82 Integration logs · 90 **Rate-limit policies** (IG on `LMS_RATE_LIMIT_POLICIES`, validation limit>0, change audited) · 95 Monitoring dashboard (see doc 07). Auth: TA for 10–50, SA for 60–95.

### App 230 — Management
Pages: 1 Manager dashboard (department status, participation, mandatory, pending approvals, effectiveness, skill gaps) · 10 Team learning (IR on `v_lms_team_enrollments` — view joins `lms_security_pkg` subtree) · 20 Approvals (IR + approve/reject dialog) · 30 Assign training (dialog) · 40 Skill gaps (chart + IR).

### App 240 — Analytics
Pages: 1 Executive dashboard (KPI cards, department comparison bar, completion trend line, utilisation, compliance gauge-style cards, skills trend) · 10 Reports (IR set: enrollments, completions, assessments, certificates expiring, mandatory compliance) with CSV/Excel download · 20 Drill-down page (department → course → learner, with authorization at each level).

## 3. Detailed specification — representative screens

### 3.1 Page 200:10 Course Catalog
- **Purpose:** discover and filter courses (FR-CAT-01..03). **Roles:** all authenticated.
- **Layout:** left Faceted Search column; right Cards region (4 col desktop / 2 tablet / 1 mobile).
- **Region SQL (Cards):**
```sql
select c.course_id,
       case when v('APP_LANGUAGE')='ar' and c.title_ar is not null then c.title_ar else c.title_en end title,
       cat.name_en category,
       c.duration_minutes, c.difficulty, c.thumbnail_ref,
       r.avg_rating, r.rating_count,
       e.status my_status,
       case when e.status is null then 'Enroll' else 'Open' end action_label
  from lms_courses c
  join lms_categories cat on cat.category_id = c.category_id
  left join lms_course_rating_v r on r.course_id = c.course_id          -- summary view
  left join lms_enrollments e on e.course_id = c.course_id
        and e.user_id = lms_security_pkg.current_user_id
        and e.status not in ('CANCELLED','FAILED','EXPIRED')
 where c.status = 'PUBLISHED'
   and (c.available_to is null or c.available_to >= trunc(sysdate))
```
(Facets and search apply additional predicates automatically; `v('APP_LANGUAGE')` is acceptable here but prefer a page-item bind `:APP_LANGUAGE` — verify in 24.1.)
- **Interactions:** facet change = partial refresh; the search item triggers `COURSE_SEARCH` rate limit through a before-region process (soft-fail to message).
- **Validation:** none (read-only). **Empty state:** "No courses match" + Clear filters button. **Loading:** APEX spinner. **Error:** inline alert region.
- **Performance:** index `LMS_CRS_CAT_STATUS_IX`; cap pagination 12; cache category facet LOV (Shared Component LOV with application cache). Expected: 5,000 rows, 100+ concurrent searches → p95 target < 3 s; rating from summary view/table refreshed on review change (avoid per-card aggregate).
- **Mobile:** single column cards, facets in collapsible drawer. **Arabic:** RTL mirrored; title column switches via the CASE above.

### 3.2 Page 200:20 Learning Player
- **Authorization:** page scheme `LMS_AUTH_ENROLLED` → function checks `lms_enrollments` for `current_user_id` and `:P20_ENROLLMENT_ID`; **never trust the item alone**: Session State Protection set to *Checksum Required – Session Level* on the page's URL, plus the function re-validates.
- **Progress persistence:** Dynamic Action "Mark complete" → *Execute Server-side Code* (Ajax callback) `lms_progress_pkg.record_event(:P20_ENROLLMENT_ID,:P20_LESSON_ID,sys_guid())` with item submit list restricted; position heartbeat every 30 s limited by `PROGRESS_UPDATE` policy (30/min).
- **Resume:** on load, `P20_START_POS` from `lms_lesson_progress.resume_position`.
- **Content security:** video/PDF URLs are short-lived signed URLs produced server-side after the authorization check; HTML lessons are sanitised on save (`APEX_ESCAPE.HTML_WHITELIST` for allowed tags) and rendered in a sandboxed iframe.
- **JS/CSS:** `player.js` (≈ 3 KB: sends heartbeat, handles keyboard shortcuts); `player.css`.

### 3.3 Page 200:40 Assessment (integrity rules)
1. Start process `lms_assessment_pkg.start_attempt` validates eligibility + creates attempt row with `deadline_at = SYSTIMESTAMP + time_limit`.
2. Question text/options are fetched through a pipelined/ref-cursor view that **excludes** `is_correct`.
3. Answer save = Ajax callback; server rejects after `deadline_at + grace`.
4. Submit = confirmation dialog (modal) → process; grading in package; `QUIZ_SUBMIT` limit fail-closed.
5. Timer is cosmetic; page reload shows remaining time from server.

### 3.4 Page 240:1 Executive dashboard
KPIs (source: `LMS_SUM_*` tables refreshed hourly; freshness label "Updated hh:mm" shown on page): total/active learners, total/published courses, enrollments, completion rate, avg assessment score, mandatory compliance %, certificates issued/expired, learning hours, department participation, top 10 courses, training effectiveness (post-course rating + pass rate), skill-gap index. Charts: line (completion trend), bar (department comparison), donut (status mix). Filters: date range, department. Row-level: executives see org-wide through `REPORT_ORG`.

## 4. APEX shared components (build once in app 200, subscribe elsewhere)
- Authentication scheme(s); Authorization schemes `LMS_AUTH_LEARNER`, `_INSTRUCTOR`, `_MANAGER`, `_TRAINING_ADMIN`, `_HR`, `_SYSADMIN`, `_ENROLLED`, `_COURSE_AUTHOR`.
- Application items: `LMS_USER_ID` (protected, *Restricted — May not be set from browser*), `LMS_UNREAD_COUNT`, `LMS_LANG`.
- LOVs (cached): categories, difficulty, status, departments. Lists: nav menu (entries conditioned by authorization), user menu. Templates: Cards (custom), KPI tile. Static files: `app.css`, `player.js`.
- Application-level **Error Handling Function** (`lms_security_pkg` companion) mapping `ORA-20xxx` to Text Messages and hiding internal ORA text.
- **Session**: Session Timeout 30 min idle (with warning), max 8 h; Session State Protection enabled at application level; Browser Security: HTTP header `Content-Security-Policy` (via Shared Components → Security Attributes → *HTTP Response Headers*), `X-Content-Type-Options: nosniff`, cookies `Secure; HttpOnly; SameSite=Lax`; Deep Linking enabled only where required.

## 5. Page-level performance notes (all major pages)
| Page | Workload | Index / strategy | Risk | Optimisation |
|---|---|---|---|---|
| 1 Dashboard | ~2k DAU, 6 regions | user_status index; **lazy-load** recommendation and certificate regions (Lazy Loading = Yes) | 6 queries per hit | Single view for KPIs; cache recommendations (collection or per-user 15 min table) |
| 10 Catalog | 100–200 searches/min | cat/status index; Oracle Text index on title/description if LIKE is slow | `LIKE '%x%'` scan on 5k rows (acceptable) | Pagination, facet counts only for top facets |
| 20 Player | Heartbeats 500 × 2/min | unique `(enrollment_id, lesson_id)` | Hot rows | Heartbeat updates only every 30 s, `MERGE` single row; no commit-per-event overhead beyond APEX's request commit |
| 40 Assessment | burst at deadlines | attempt keyed by `(quiz,user)` | Burst submissions | Short transactions, no per-question commit |
| 240 Dashboards | Aggregates over 1M rows | `LMS_SUM_*` | Live aggregation | Scheduled refresh; show freshness |

Diagnostics: APEX Debug (level 4–9 for one session) → *View Debug*; **Monitor Activity** reports; `APEX_WORKSPACE_ACTIVITY_LOG`/`APEX_DEBUG_MESSAGES` views; SQL Developer tuning with `GATHER_PLAN_STATISTICS` hint on the offending region SQL.
