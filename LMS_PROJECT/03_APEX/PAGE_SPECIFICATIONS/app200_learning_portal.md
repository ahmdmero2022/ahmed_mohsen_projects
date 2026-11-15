# App 200 — LMS Learning Portal: page specifications

Status: specification, not built. Conventions, schemes, LOVs, security attributes: `../SHARED_COMPONENTS/README.md`.
Data comes **only** from `V_LMS_*` views and `LMS_*_PKG` procedures (parsing schema `LMS_APP`). `:LMS_LANG` selects the
language: title expression `case when :LMS_LANG='ar' and title_ar is not null then title_ar else title_en end`
(written `title_l10n` below). "PAP" = Page Access Protection. All pages: authorization `LMS_AUTH_LEARNER` unless stated.

> **`*_l10n` notation.** Wherever a spec writes `X_l10n` (e.g. `title_l10n`, `module_title_l10n`, `full_name_l10n`) it stands for the language expression
> `case when :LMS_LANG = 'ar' and X_ar is not null then X_ar else X_en end` over the view's `X_en` / `X_ar` columns. Write it out in the region SQL
> (or as a Cards/IR *computed column*); there is deliberately no PL/SQL function for it, to avoid a context switch per row.

**Navigation menu (list `LMS_NAV_PORTAL`)**: Dashboard (1) · Catalog (10) · My Learning (30) · Learning Paths (50) ·
Sessions (55) · My skills (56) · Certificates (60) · Notifications (80, via navigation bar) · Preferences (70, via user menu).

| Pg | Name | Type | Pg | Name | Type |
|---|---|---|---|---|---|
| 0 | Global page | Global | 55 | Instructor-led sessions | Calendar + report |
| 1 | Learner dashboard | Home | 60 | My certificates | Cards |
| 10 | Course catalog | Cards + Faceted Search | 61 | Certificate print | Blank (print) |
| 11 | Course details | Blank | 70 | Preferences | Form |
| 12 | Enroll (confirm) | Modal dialog | 80 | Notifications | Interactive Report |
| 13 | Course feedback | Modal dialog | 56 | My skills | Blank |
| 20 | Learning player | Blank (Player template) | 90 | Verify a certificate | Public |
| 21 | Lesson file stream | Process-only page | | | |
| 30 | My learning | Cards + pill tabs | 9998 | Access error / session expired | Public |
| 40 | Assessment | Blank | 9999 | Login (local scheme only) | Login |
| 41 | Assessment result | Blank | | | |
| 50 / 51 | Learning paths / detail | Cards / Blank | | | |

---
## Page 0 — Global page
- **Computation** (Before Header, item `LMS_UNREAD`): `select count(*) from v_lms_my_notifications where read_flag = 'N'`.
  No polling timer (2,000 DAU × 1 request/min would be ~33 req/s of pure overhead); the badge refreshes on page load, and
  after `ajax_unread` when the user opens the notification menu (DA on click → Ajax callback `AJAX_UNREAD` → update badge).
- **Region** `R_LIVE` (Position: After Footer): `<div id="lms-live" class="u-VisuallyHidden" aria-live="polite" role="status"></div>`
  (screen-reader announcements for player/assessment scripts).
- **Page CSS file**: `#APP_FILES#app#MIN#.css`. No JS here.

## Page 1 — Learner dashboard
Purpose: FR-RPT-01 (learner KPIs), continue learning. PAP: Unrestricted-not-needed (home, no inputs). Template: Standard.

| Static ID | Type | Source | Notes |
|---|---|---|---|
| `R_WELCOME` | Static Content | `<h1>&P1_NAME.</h1>` | Item `P1_NAME` (Display Only, escape = yes), computation: `select case when :LMS_LANG='ar' and full_name_ar is not null then full_name_ar else full_name_en end from v_lms_my_profile` |
| `R_KPIS` | Classic Report, template *KPI Tile* | `select count(case when status in ('ENROLLED','IN_PROGRESS') then 1 end) in_progress, count(case when status='COMPLETED' then 1 end) completed, count(case when overdue_flag='Y' then 1 end) overdue from v_lms_my_enrollments` | 3 tiles; overdue tile gets `lms-kpi--bad` when > 0 (text + colour) |
| `R_CONTINUE` | Cards | `select enrollment_id, title_l10n title, progress_pct, last_activity_at, thumbnail_ref from v_lms_my_enrollments where status in ('ENROLLED','IN_PROGRESS') order by nvl(last_activity_at, enrolled_at) desc fetch first 3 rows only` | Card action *Resume* → page 20, `P20_ENROLLMENT_ID = enrollment_id` (checksum). Progress bar via card *Subtitle* HTML `<div class="lms-progress" role="progressbar" aria-valuenow="&PROGRESS_PCT." aria-valuemin="0" aria-valuemax="100"><span style="inline-size:&PROGRESS_PCT.%"></span></div>`. Empty state: link to page 10 |
| `R_MANDATORY` | Classic Report | `select title_l10n, due_date, status, overdue_flag, progress_pct, enrollment_id from v_lms_my_enrollments where mandatory_flag='Y' and status not in ('COMPLETED','CANCELLED','FAILED','EXPIRED') order by due_date nulls last` | Lazy Loading = Yes; overdue rows show the *Overdue* text badge |
| `R_SESSIONS` | Classic Report | `select title_l10n, start_ts, venue_en, status from v_lms_my_sessions where start_ts > systimestamp order by start_ts fetch first 5 rows only` | Lazy |
| `R_RECOMMENDED` | Cards | `select course_id, title_l10n title, duration_minutes, difficulty, thumbnail_ref from v_lms_my_recommended order by coverage desc fetch first 4 rows only` | Lazy; hidden when no rows (Server-side condition *Rows returned*) |
| `R_CERTS` | Cards | `select certificate_id, title_l10n title, issued_at, expires_at, status from v_lms_my_certs order by issued_at desc fetch first 3 rows only` | Lazy; link → 60 |
| `R_FEEDBACK_TODO` | Classic Report (condition: rows exist) | `select enrollment_id, title_l10n, completed_at, reviewed_flag, form_questions, answered from v_lms_my_feedback_todo order by completed_at desc fetch first 3 rows only` | Lazy; button *Give feedback* → page 13 (`P13_ENROLLMENT_ID`, checksum); appears only after completion |
| `R_ACHIEVEMENTS` | Classic Report | `select title_l10n, completed_at from v_lms_my_enrollments where status='COMPLETED' order by completed_at desc fetch first 5 rows only` | Lazy ("recent achievements") |

Performance: 8 small queries; the 5 lazy regions load after first paint. All hit `LMS_ENR_USER_STATUS_IX` (user + status). Expected 3–6 ms DB time each.
Mobile: regions stack; Cards 1 column; reports switch to *Column Toggle*. Arabic: RTL automatic; progress bars use `inline-size`.

## Page 10 — Course catalog
Purpose FR-CAT-01..03. Authorization `LMS_AUTH_CATALOG`. PAP: Unrestricted (read-only filters). Template: Standard + left column.

- **Before Header process** `PR_THROTTLE` (sequence 10): `:P10_THROTTLED := lms_apex_pkg.search_allowed;` (item `P10_THROTTLED`, hidden, not submitted).
  Note: a facet change refreshes the region by AJAX and does **not** re-run Before Header; the per-user `COURSE_SEARCH` quota
  therefore guards page loads, and the proxy/WAF rule guards the refresh traffic.
- `R_THROTTLE_MSG` (Alert region, condition `P10_THROTTLED = 'N'`): text message `LMS_THROTTLED`.
- `R_FACETS` — **Faceted Search** (Filtered Region `R_CATALOG`), condition `P10_THROTTLED = 'Y'`:
  `P10_SEARCH` (Search; columns `TITLE_EN, TITLE_AR, COURSE_CODE`), `P10_CATEGORY` (Checkbox Group, LOV `LOV_CATEGORIES`, show counts),
  `P10_DIFFICULTY` (Checkbox Group, `LOV_DIFFICULTY`), `P10_DURATION` (Checkbox Group on column `DURATION_BUCKET`: S ≤ 60, M ≤ 240, L > 240 min — labels from text messages),
  `P10_LANGUAGE` (Checkbox Group, column `LANGUAGE_CODE`), `P10_SORT` (Order-by facet: Recently added `PUBLISHED_AT desc`, Popularity `ENROLLED desc`, Rating `AVG_RATING desc`, Title).
- `R_CATALOG` — Cards, static id `lms-course-cards` (CSS class `lms-cards`), 12 per page, pagination "Page selector", condition `P10_THROTTLED = 'Y'`:
```sql
select c.course_id, c.course_code, c.title_en, c.title_ar,
       case when :LMS_LANG='ar' and c.title_ar is not null then c.title_ar else c.title_en end title,
       case when :LMS_LANG='ar' and c.category_ar is not null then c.category_ar else c.category_en end category,
       c.category_id, c.difficulty, c.duration_minutes, c.language_code, c.thumbnail_ref, c.published_at,
       case when c.duration_minutes <= 60 then 'S' when c.duration_minutes <= 240 then 'M' else 'L' end duration_bucket,
       c.avg_rating, c.rating_count, c.my_status, c.seats_left, nvl(s.enrolled,0) enrolled
  from v_lms_catalog c left join v_lms_course_popularity s on s.course_id = c.course_id
```
  (`V_LMS_COURSE_POPULARITY`, in `16_views_lov.sql`, reads the hourly summary table, so popularity is up to one hour old.)
  Card: title (link → page 11, `P11_COURSE_ID`), subtitle = category · duration · difficulty (text messages), media = thumbnail,
  badge = `my_status` label (`lms_apex_pkg.status_label(my_status)`), rating stars text "4.5 (12)". Actions: *View* → 11.
  **Enroll button on the card is intentionally not offered** (enrolment confirmation lives on 11/12 so prerequisites are visible).
- Empty state: text message `LMS_NO_COURSES` + *Clear filters* button (resets facets).
- Index/perf: `LMS_CRS_STATUS_PUB_IX`, `LMS_CRS_CAT_STATUS_IX`; 5,000 courses × 12 per page → < 100 ms. Facet counts computed by APEX with
  *Show Counts = Yes* only for Category and Difficulty (others off) to avoid extra aggregate queries. Search = `LIKE` on 5,000 rows is acceptable;
  add an Oracle Text index only if measured p95 > 1 s.
- Mobile: facets in a collapsible drawer (Facet region template *Collapsible*, initially collapsed ≤ 640 px).

## Page 11 — Course details
Authorization `LMS_AUTH_CATALOG`. PAP: *Arguments Must Have Checksum*. Item `P11_COURSE_ID` (hidden, Value Protected = Yes).
Page load: Before Header computation `P11_CAN_ENROLL`:
```sql
select case when c.my_status is not null then 'N'
            when exists (select 1 from v_lms_course_prereqs p where p.course_id = c.course_id and p.met_flag = 'N') then 'N'
            else 'Y' end
  from v_lms_catalog c where c.course_id = :P11_COURSE_ID
```
(UI hint only: the authoritative eligibility check is `lms_enrollment_pkg.enroll_self`.) If no row → raise not found (Before Header process
`PR_GUARD`: `select count(*) into l from v_lms_catalog where course_id=:P11_COURSE_ID; if l=0 then raise_application_error(-20404,'Course not found'); end if;`).

| Static ID | Type | Source |
|---|---|---|
| `R_BANNER` | Static Content (hero) | title, category, difficulty, duration, rating, my status badge, button `B_ENROLL` (condition `P11_CAN_ENROLL='Y'`, action Redirect → page 12 in modal) or `B_OPEN` (when enrolled: → page 20 with enrolment id via `select enrollment_id from v_lms_my_enrollments where course_id=:P11_COURSE_ID and status in (...)`) |
| `R_ABOUT` | Static Content | `description_l10n` (plain text; Escape = Yes; newline→`<br>` via `apex_escape.html` + `replace`) |
| `R_OBJECTIVES` | Static Content | `objectives_l10n` (one objective per line → list) |
| `R_CURRICULUM` | Classic Report with *Control Break* on module | `select module_order, module_title_l10n, lesson_order, lesson_title_l10n, lesson_type, duration_minutes from v_lms_course_outline where course_id=:P11_COURSE_ID order by module_order, lesson_order` (titles only; lesson content never exposed before enrolment) |
| `R_PREREQ` | Classic Report | `select title_l10n, met_flag from v_lms_course_prereqs where course_id=:P11_COURSE_ID` — met shows ✓ + "Completed", unmet shows ✗ + "Required"; text, not colour only |
| `R_REVIEWS` | Classic Report (lazy) | `select reviewer, course_rating, instructor_rating, review_text, review_date from v_lms_course_reviews_public where course_id=:P11_COURSE_ID order by review_date desc fetch first 10 rows only` — initials only; text escaped; hidden reviews never appear |
| `R_INSTRUCTORS` | Cards (small) | `select full_name_l10n, position_l10n, instructor_role from v_lms_course_instructors where course_id=:P11_COURSE_ID` |
| `R_REQUIREMENTS` | Static | completion rule text from `LMS_RULE_*` message + certificate flag |
Perf: 5 indexed queries by `course_id`. Cache: none (user-specific `met_flag`).

## Page 12 — Enroll (modal)
Template: Modal Dialog (Title: "Confirm enrolment"). Items: `P12_COURSE_ID` (hidden, protected), `P12_ENROLLMENT_ID`, `P12_STATUS` (hidden).
- `R_CONFIRM`: course title, duration, approval notice when the course needs approval (`approval_required` from `v_lms_catalog`), capacity note.
- Buttons: `B_CANCEL` (Cancel), `B_CONFIRM` (Create → submit).
- **Process** `PR_ENROLL` (Processing, on `B_CONFIRM`): `lms_enrollment_pkg.enroll_self(:P12_COURSE_ID, :P12_ENROLLMENT_ID, :P12_STATUS);`
  Success message (PL/SQL expression by status): `ENROLLED` → "You are enrolled", `PENDING` → "Sent for approval", `WAITLISTED` → "You are on the waiting list".
  Errors (prerequisites, deadline, rate limit) flow through the application error handler into an inline notification.
- **Dialog Closed** DA on page 11: refresh banner (`R_BANNER`) and redirect to 30 when status is ENROLLED.
- Validation: none client-side beyond the process (package is the authority). Idempotent: double-click returns the same enrolment.

## Page 13 — Course feedback (modal)
Template: Modal Dialog. Items: `P13_ENROLLMENT_ID` (hidden, Value Protected = Yes), `P13_REVIEW_ID` (hidden). Authorization `LMS_AUTH_LEARNER`; the packages re-check that the enrolment is the caller's and (policy `REVIEW_REQUIRES_COMPLETION`) completed.
- `R_REVIEW`: `P13_COURSE_RATING` (Star Rating 1–5, required), `P13_INSTRUCTOR_RATING` (Star Rating, optional), `P13_REVIEW_TEXT` (Textarea, 2,000, plain text). If a review exists (`select review_id, course_rating, instructor_rating, review_text, editable_flag from v_lms_my_reviews where enrollment_id = :P13_ENROLLMENT_ID`) fields load read-only unless `editable_flag = 'Y'` (policy `REVIEW_EDIT_DAYS`).
- `R_FORM` (only when the course has a questionnaire): Classic Report with `apex_item` inputs from `select question_id, text_l10n, answer_type, rating, comment_text from v_lms_my_feedback_form where enrollment_id = :P13_ENROLLMENT_ID order by sort_order` — RATING → `apex_item.radiogroup` 1–5, TEXT → `apex_item.textarea` (2,000). Rows already answered are read-only (answers are final).
- Processes (on `B_SUBMIT`, in this order): `PR_REVIEW`: `if :P13_REVIEW_ID is null then lms_feedback_pkg.submit_review(:P13_ENROLLMENT_ID, :P13_COURSE_RATING, :P13_INSTRUCTOR_RATING, :P13_REVIEW_TEXT); else lms_feedback_pkg.update_review(:P13_REVIEW_ID, :P13_COURSE_RATING, :P13_INSTRUCTOR_RATING, :P13_REVIEW_TEXT); end if;`
  `PR_ANSWERS`: loop over the unanswered rows (`apex_application.g_f01` = question ids, `g_f02` = ratings, `g_f03` = comments) → `lms_feedback_pkg.submit_answer(:P13_ENROLLMENT_ID, <question_id>, <rating>, <comment>);`
- Duplicate/unauthorised feedback is prevented in the database: one review per enrolment (unique key), one answer per question (unique key), ownership and completion checked in the package. A double submit cannot double count.

## Page 20 — Learning player
Template: **Player** (full width, no side nav). Authorization `LMS_AUTH_ENROLLED` (page) + `LMS_AUTH_LEARNER`. PAP: *Arguments Must Have Checksum*;
no deep-linking (clear session state on entry via the link's *Clear Cache* = 20).
Items: `P20_ENROLLMENT_ID` (hidden, protected), `P20_LESSON_ID` (hidden, protected), `P20_PROGRESS` (hidden), `P20_START_POS`, `P20_COMPLETED` (hidden).

Before Header:
1. `C_P20_LESSON` — if `:P20_LESSON_ID` is null: `select lesson_id from v_lms_resume_lesson where enrollment_id = :P20_ENROLLMENT_ID`.
2. `PR_GUARD_LESSON` — `lms_apex_pkg.authorize_lesson_access(:P20_ENROLLMENT_ID, :P20_LESSON_ID);` (locked lessons: also blocked in `record_event`).
3. `C_P20_STATE` — `select resume_position, case progress_status when 'COMPLETED' then 'Y' else 'N' end, (select progress_pct from v_lms_my_enrollments where enrollment_id=:P20_ENROLLMENT_ID) from v_lms_curriculum where enrollment_id=:P20_ENROLLMENT_ID and lesson_id=:P20_LESSON_ID` → `P20_START_POS`, `P20_COMPLETED`, `P20_PROGRESS`.

| Static ID | Type | Source |
|---|---|---|
| `R_TOP` | Static (header bar) | course title, progress bar (`#lms-progress`, role=progressbar), *Exit* button → page 30 |
| `R_NAV` | Classic Report (template: none, HTML Expression) | `select module_title_l10n, lesson_id, title_l10n, lesson_type, progress_status, locked_flag from v_lms_curriculum where enrollment_id=:P20_ENROLLMENT_ID order by module_order, lesson_order` with *control break* per module; each row: `<a class="lms-lesson" aria-current=...>` + state glyph (✓ done, ▶ current, 🔒 locked + visually hidden text); link to page 20 with new `P20_LESSON_ID` (checksum) unless locked |
| `R_VIEWER` | PL/SQL Dynamic Content | `apex_util.prn(lms_apex_pkg.lesson_html(:P20_ENROLLMENT_ID, :P20_LESSON_ID), false);` (escaping handled inside; viewer wrapper `<div class="lms-player__viewer">`) |
| `R_BAR` | Static | buttons `B_PREV`, `B_COMPLETE` (static id `lms-complete-btn`), `B_NEXT` |

- **Buttons:** `B_PREV`/`B_NEXT` link to the adjacent lesson from `v_lms_curriculum` (computed items `P20_PREV_LESSON`, `P20_NEXT_LESSON`); `B_NEXT` disabled until the current lesson is completed (or not required) — enforced by the server (`locked_flag`), the disabled state is UX.
- **Ajax Callback** `AJAX_PROGRESS` (Processing → Ajax Callback): `begin lms_apex_pkg.ajax_progress; end;`
- **JavaScript** (Page Load DA, Execute JavaScript): `lmsPlayer.init({enrollmentId:$v('P20_ENROLLMENT_ID'), lessonId:$v('P20_LESSON_ID'), startPosition:Number($v('P20_START_POS')), completed:$v('P20_COMPLETED')==='Y', media:'#lms-media'});`
  DA on custom event `lms-lesson-completed`: refresh `R_NAV`, enable `B_NEXT`.
- Files: `player.js`, `app.css` (page CSS: `.lms-player` layout). Text messages `LMS_JS_*` (Used in JavaScript).
- Security: lesson URLs are signed and expire in 5 min (`lms_apex_pkg.content_url`, rate limit `FILE_DOWNLOAD` 30/min); a stolen URL stops working; HTML lessons sanitised on save and on output; interactive content sandboxed.
- Perf: `v_lms_curriculum` for one enrolment ≈ 50–150 rows; heartbeat every 30 s while playing ⇒ 500 concurrent players ≈ 17 req/s of a single-row `MERGE`.
- Mobile: nav collapses above the viewer (CSS `max-width: 900px`); controls ≥ 44 px. Arabic: nav on the right (CSS grid + `border-inline-end`).
- Empty/locked state: if `locked_flag='Y'` the viewer shows the "complete the previous lesson first" message instead of content.

## Page 30 — My learning
Item `P30_TAB` (Radio Group, pill button template; values ALL, NOT_STARTED, IN_PROGRESS, COMPLETED, MANDATORY; labels from `LMS_STATUS_*`/`LMS_TAB_MANDATORY`); DA on change → refresh `R_MY`.
`R_MY` Cards (12 per page):
```sql
select enrollment_id, course_id, title_l10n title, status, progress_pct, due_date, overdue_flag, mandatory_flag, last_activity_at, thumbnail_ref, completed_at
  from v_lms_my_enrollments
 where status not in ('CANCELLED')
   and (:P30_TAB = 'ALL'
     or (:P30_TAB = 'NOT_STARTED' and status = 'ENROLLED')
     or (:P30_TAB = 'IN_PROGRESS' and status = 'IN_PROGRESS')
     or (:P30_TAB = 'COMPLETED' and status = 'COMPLETED')
     or (:P30_TAB = 'MANDATORY' and mandatory_flag = 'Y' and status not in ('COMPLETED','EXPIRED','FAILED')))
 order by case when status in ('ENROLLED','IN_PROGRESS') then 0 else 1 end, nvl(last_activity_at, enrolled_at) desc
```
Card: progress bar, last activity (relative date), status text badge, button *Resume* (active) / *Review* (completed) → page 20; for PENDING/WAITLISTED rows (shown in ALL) the button is *Cancel request* → confirm → process `PR_CANCEL`: `lms_enrollment_pkg.cancel(:P30_ENROLLMENT_ID);` (checks ownership/scope in the package). Empty: `LMS_NO_LEARNING` + link to 10.
Authorization `LMS_AUTH_LEARNER`. Perf: `LMS_ENR_USER_STATUS_IX`.

## Page 21 — Lesson file stream (database-stored documents)
Blank page (no template output), Authorization `LMS_AUTH_ENROLLED` is **not** used (it reads `P20_*`); the process authorises itself.
PAP: *Arguments Must Have Checksum*; items `P21_ENROLLMENT_ID`, `P21_LESSON_ID` (hidden, Value Protected = Yes).
Before Header process `PR_STREAM` (the only process): `lms_apex_pkg.stream_lesson_file(:P21_ENROLLMENT_ID, :P21_LESSON_ID);` —
authorises (owner, active enrolment, lesson in course, available), applies `FILE_DOWNLOAD` 30/min, audits, sends the file with
`Content-Disposition: inline`, `X-Content-Type-Options: nosniff`, `Cache-Control: private, no-store`, then stops the APEX engine.
Used as the `src` of the viewer iframe built by `lms_apex_pkg.lesson_html` when `content_ref` starts with `blob:`.

## Pages 40/41 — Assessment and result
**Page 40** — PAP: *Arguments Must Have Checksum*, Deep Linking disabled. Items: `P40_QUIZ_ID` (hidden, protected), `P40_ATTEMPT_ID` (hidden, protected),
`P40_Q_INDEX` (hidden, default 1), `P40_QUESTION_ID`, `P40_QTYPE`, `P40_ANSWER` (radio/checkbox/text depending on type), `P40_DEADLINE_MS`, `P40_SERVER_NOW_MS`, `P40_TOTAL`, `P40_ANSWERED`.
- Landing (request null and no attempt): `R_INTRO` shows title, pass mark, time limit, attempts used (`v_lms_my_quizzes`), button `B_START` → process `PR_START`: `:P40_ATTEMPT_ID := lms_assessment_pkg.start_attempt(:P40_QUIZ_ID);` then branch to page 40 (same page, with `P40_ATTEMPT_ID`). Resumes an open attempt automatically.
- Before Header (attempt present): `select question_id, question_type from v_lms_attempt_questions where attempt_id=:P40_ATTEMPT_ID and sort_order=:P40_Q_INDEX` → `P40_QUESTION_ID`, `P40_QTYPE`; `select to_char(round((cast(sys_extract_utc(deadline_at) as date)-date '1970-01-01')*86400000)), to_char(round((cast(sys_extract_utc(systimestamp) as date)-date '1970-01-01')*86400000)) from v_lms_my_attempts where attempt_id=:P40_ATTEMPT_ID` → deadline/now items; `P40_TOTAL`/`P40_ANSWERED` from `v_lms_attempt_questions`.
- `R_QUESTION` (static id wrapper `<div id="lms-question" data-type="&P40_QTYPE." data-question="&P40_QUESTION_ID.">`):
  question text (`v_lms_attempt_questions`, escaped) and, by type:
  MCQ/TF → Radio Group item `P40_ANSWER`, LOV `select option_text_l10n d, option_id r from v_lms_attempt_options where attempt_id=:P40_ATTEMPT_ID and question_id=:P40_QUESTION_ID order by display_order`;
  MULTI → Checkbox Group same LOV; MATCH → report of left options with `apex_item.select_list_from_query(1, null, 'select choice_text d, choice_text r from v_lms_attempt_match_choices where attempt_id='||:P40_ATTEMPT_ID||' and question_id='||:P40_QUESTION_ID||' order by display_order', 'data-option="'||option_id||'"')` — **the query text built with numeric item values; both are protected, server-set items, never browser input**; SHORT → Text item; ESSAY → Textarea (max 3,500 chars).
  Saved answer re-populated from `answer_json` on load (JSON_VALUE/JSON_TABLE into the item).
- `R_PROGRESS`: "Question &P40_Q_INDEX. of &P40_TOTAL." + progress bar; `#lms-timer` (role="timer", `aria-live="off"`; announcements go to `#lms-live`), `#lms-saved`.
- Buttons: `B_PREV`, `B_NEXT` → DA *Execute JavaScript* `lmsAssessment.go('PREV'|'NEXT')`; request handlers (process on request) update `P40_Q_INDEX` (±1, bounded). `B_SUBMIT` → DA: *Confirm* (text `LMS_CONFIRM_SUBMIT`) → JS `lmsAssessment.save().always(function(){ lmsAssessment.markSubmitting(); apex.page.submit('SUBMIT_ATTEMPT'); });`
- **Ajax callback** `AJAX_SAVE_ANSWER`: `begin lms_apex_pkg.ajax_save_answer; end;`
- **Process** `PR_SUBMIT` (request `SUBMIT_ATTEMPT`): `lms_assessment_pkg.submit_attempt(:P40_ATTEMPT_ID, :P40_STATUS, :P40_SCORE, :P40_PASSED);` → branch to page 41 (`P41_ATTEMPT_ID`).
- Page load JS: `lmsAssessment.init({attemptId:$v('P40_ATTEMPT_ID'), deadlineMs:Number($v('P40_DEADLINE_MS'))||null, serverNowMs:Number($v('P40_SERVER_NOW_MS'))});`
- Integrity: server owns the deadline; answers after `deadline_at` are rejected (`-20417`); reload resumes with the same attempt; correct answers are never in the page, the Ajax responses or the views (test S-14/F-23). Time-up auto-submit grades the answers saved before the deadline.
- Rate limit: `QUIZ_SUBMIT` 5/min fail-closed inside `submit_attempt`.
**Page 41** — Authorization `LMS_AUTH_LEARNER`; item `P41_ATTEMPT_ID` (hidden, protected). `R_RESULT`: `select title_l10n, status, score_pct, passed_flag, attempt_no, pass_score from v_lms_my_attempts where attempt_id=:P41_ATTEMPT_ID` — if `PENDING_GRADING`: message "Awaiting instructor grading". `R_REVIEW` (condition: attempt GRADED and `show_review='Y'`): `select question_l10n, option_text_en, is_correct, answer_json, points_awarded, max_points, feedback from v_lms_attempt_review where attempt_id=:P41_ATTEMPT_ID order by sort_order` (the view enforces the quiz's review policy). Buttons: *Retake* (visible when attempts remain → page 40), *Back to course* (→ 20).

## Pages 50/51 — Learning paths
**50** (`LMS_AUTH_LEARNER`): `R_MY_PATHS` Cards from `v_lms_my_paths` (progress bar, status); `R_ALL_PATHS` Cards from `v_lms_path_catalog` (button *View*; badge `my_status`). **51** (`P51_PATH_ID`, `P51_PATH_ENROLLMENT_ID` hidden, protected):
`R_SEQUENCE` report `select sequence_no, title_l10n, course_status, required_flag from v_lms_path_courses where path_enrollment_id=:P51_PATH_ENROLLMENT_ID order by sequence_no` (✓ completed / ▶ next / ○ later, as text);
`B_ENROLL_PATH` (when not enrolled) → `:P51_PATH_ENROLLMENT_ID := lms_learning_path_pkg.enroll_path(:P51_PATH_ID);`;
`B_NEXT_COURSE` → `lms_learning_path_pkg.start_next_course(:P51_PATH_ENROLLMENT_ID, :P51_COURSE_ID, :P51_ENROLLMENT_ID, :P51_STATUS);` then redirect to 20 (or 11 if the status is PENDING/WAITLISTED).
Path certificate shown in `R_CERT` when `status='COMPLETED'` (link to 60). "Recommended next course" = the next incomplete sequence entry.

## Page 55 — Instructor-led sessions
`R_CAL` Calendar (Display Column `start_ts`, End `end_ts`, title `title_l10n`; Source `v_lms_session_catalog`); `R_UPCOMING` Classic Report same source with `seats_left`, `my_status`, button *Register* (when `my_status is null and seats_left > 0`), *Join waiting list* (when no seats), *Unregister* (when registered). Processes: `PR_REGISTER` → `lms_session_pkg.register(:P55_SESSION_ID, :P55_STATUS);` `PR_UNREGISTER` → `lms_session_pkg.cancel_registration(:P55_SESSION_ENROLLMENT_ID);` (ownership checked inside). `R_MINE` report from `v_lms_my_sessions` (meeting link only when REGISTERED). Registered learners receive an e-mail/in-app reminder 24 h and 1 h before the start (policy `SESSION_REMINDER_*_HOURS`), and a notice if the venue, link, trainer or time changes. Calendar timezone: display in the user's browser zone; stored `TIMESTAMP WITH TIME ZONE`.

## Page 56 — My skills
Authorization `LMS_AUTH_LEARNER`. `R_SKILLS` Classic Report on `v_lms_my_skills` (skill, current level, level required by my position, gap; text such as "2 of 4" plus a level bar). `R_NEXT` Cards on `v_lms_my_recommended` ("Courses that close your gaps") → page 11. Levels rise automatically when a course tagged with the skill is completed (`lms_progress_pkg`) and when a manager/HR records an assessment (app 230 page 41). Empty state: "No skills are defined for your position yet."

## Pages 60/61 — Certificates
**60**: `R_CERTS` Cards from `v_lms_my_certs` (title, issued, expires, verification code, status text); buttons *Download* → page 61 (`P61_CERTIFICATE_ID`, checksum), *Copy verification link* (JS, builds `…/90?P90_CODE=`). Empty state `LMS_NO_CERTS`.
**61** (Blank, print layout): Authorization `LMS_AUTH_CERT_OWNER`; Before Header `PR_AUTH`: `lms_certification_pkg.authorize_download(:P61_CERTIFICATE_ID);` (ownership + `CERT_GENERATE` 5/hour fail-closed + audit). Content: `v_lms_certificate_print` rendered in an HTML layout (`@media print` in `app.css`), bilingual per `:LMS_LANG`.
*PDF alternative:* APEX Report Query + layout needs a print server; **Arabic shaping/RTL in PDF must be proven with your print server and fonts before relying on it** — use browser "Print to PDF" of this HTML page until then.

## Page 70 — Preferences
Form on `v_lms_my_profile` (Display Only for name/email/dept/position/manager; **no direct DML on the table**). Item `P70_LANG` (Select List en/ar). Process `PR_SAVE` (on Save): `lms_user_pkg.set_language(:P70_LANG); apex_util.set_session_lang(:P70_LANG); :LMS_LANG := :P70_LANG;` then redirect to same page (so labels change). Mandatory notification channel selection is not implemented (no column).

## Page 80 — Notifications
`R_NOTIF` Interactive Report on `v_lms_my_notifications` (columns: unread dot (text "New"), title, message (escaped), created_at, link). Row link → process `PR_OPEN` (`lms_notification_pkg.mark_read(:P80_ID)`) then redirect to `link_url` **only if it starts with `f?p=` or is relative (validated in the process; absolute external links are ignored)**. Button `B_READ_ALL` → `lms_notification_pkg.mark_all_read;`. Saved report default sort: created_at desc; downloads disabled (no need).

## Page 90 — Verify a certificate (public)
Authorization: none (*Public page*), template Minimal, PAP: Unrestricted. Item `P90_CODE` (Text, max 20, `a-z0-9` pattern validation, escape output). Process `PR_VERIFY` (on `B_VERIFY`):
```sql
declare
  l_cur sys_refcursor; l_en varchar2(250); l_ar varchar2(250); l_st varchar2(10);
  l_iss date; l_exp date; l_holder varchar2(200);
begin
  l_cur := lms_certification_pkg.verify(:P90_CODE, owa_util.get_cgi_env('HTTP_X_LMS_CLIENT_IP'));  -- header set by the proxy
  fetch l_cur into l_en, l_ar, l_st, l_iss, l_exp, l_holder; 
  if l_cur%found then :P90_RESULT := l_st; :P90_TITLE := case when :LMS_LANG='ar' and l_ar is not null then l_ar else l_en end;
                      :P90_ISSUED := to_char(l_iss,'YYYY-MM-DD'); :P90_EXPIRES := to_char(l_exp,'YYYY-MM-DD'); :P90_HOLDER := l_holder;
  else :P90_RESULT := 'NOT_FOUND'; end if;
  close l_cur;
end;
```
`-20429` surfaces as the friendly rate-limit message through the error handler. Result region shows status as text + icon, never the holder's full details beyond policy. No session-state ID is exposed; the code is the only input. A CAPTCHA at the WAF for this path is recommended.

## Pages 9998 / 9999
**9998** Public, Minimal; item `P9998_REASON` (EXPIRED | DENIED | other) — rendered through a CASE to fixed text messages (the value is never printed), button *Sign in* → `apex_page.get_url(p_page=>1)`. Generic wording for DENIED ("You do not have access to LMS. Contact your administrator.") — same for unmapped and inactive accounts (no account-state disclosure).
**9999** only for the DEV local scheme: Username/Password items, Login button → `apex_authentication.login`; single generic failure message; no "forgot password" (handled by the IdP in PROD).
