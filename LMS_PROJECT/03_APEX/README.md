# 03_APEX — page specifications, shared components, static files

Status: **specification + static assets, not an APEX export.** Nothing was imported into an APEX 24.1 workspace, so page
definitions, regions, dynamic actions and processes are *build instructions*, not verified components.

| Path | Contents |
|---|---|
| `SHARED_COMPONENTS/README.md` | Application settings, authentication, security headers, 25 authorization schemes (exact PL/SQL), items, LOVs, navigation, theme, conventions |
| `SHARED_COMPONENTS/text_messages.csv` | 72 text messages (EN + draft AR) for errors, JavaScript, statuses, lookups |
| `PAGE_SPECIFICATIONS/app200_learning_portal.md` | 26 pages: dashboard, catalog, course details, enrol, player, my learning, assessment, paths, sessions, certificates, preferences, notifications, public verification |
| `PAGE_SPECIFICATIONS/app210_instructor_portal.md` | Dashboard, my courses, 6-step course builder (incl. course skills and feedback form), course feedback analytics, lesson content/upload, question bank, grading, sessions/attendance, learner progress |
| `PAGE_SPECIFICATIONS/app220_administration.md` | Courses, approvals, enrolments, mandatory assignments, schedule, certificates, categories, settings, templates, users, roles matrix, audit/security/integration logs, rate limits, monitoring |
| `PAGE_SPECIFICATIONS/app230_240_management_analytics.md` | Manager dashboard/team/approvals/assign/skill gaps, HR skills framework (42–44); executive dashboard, reports, drill-down |
| `STATIC_FILES/app.css` | Tokens, cards, KPI tiles, badges, player/assessment layout, RTL-safe logical properties, print, reduced motion |
| `STATIC_FILES/player.js` | Progress reporting (heartbeat, de-duplicated retries, completion); syntax-checked with `node --check`, not run in a browser |
| `STATIC_FILES/assessment.js` | Server-clock-based timer, autosave, time-up submit; syntax-checked only |

## How the pages stay thin and safe
- Pages read **only** `V_LMS_*` views (92 views; each view that exposes more than the caller's own data checks the permission itself).
- Pages write **only** by calling `LMS_*_PKG` procedures (one-line processes). No page DML on tables, no business rules in pages.
- Database objects that back the pages: `02_DATABASE/13_apex_glue.sql` (authorization functions, post-auth, error handler, Ajax callbacks,
  signed content URLs, lesson renderer, file streaming, audited admin writes), `15_views_apex.sql`, `16_views_lov.sql`.
- Build order suggestion: shared components → app 200 pages 9998, 1, 10, 11, 12, 30, 20 (vertical slice, test with `10_test_data.sql` users) →
  40/41 → 60/61/90 → app 220 (users, approvals, rate limits) → app 210 builder → 230/240.

## Not covered (needs a real APEX workspace)
Page Designer definitions and exports (`f200.sql` …), theme roller output, translated XLIFF, actual region templates (Cards/KPI), print-server
configuration for PDF (Arabic shaping), accessibility and RTL verification in a browser, performance measurement.
