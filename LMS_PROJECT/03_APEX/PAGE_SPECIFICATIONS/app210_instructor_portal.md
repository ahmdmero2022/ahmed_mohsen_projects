# App 210 — LMS Instructor Portal: page specifications

Status: specification, not built. Shared conventions: `../SHARED_COMPONENTS/README.md`. Application-level scheme `LMS_AUTH_ACTIVE`;
default page scheme `LMS_AUTH_INSTRUCTOR`. Course-scoped pages additionally use a `LMS_AUTH_COURSE_MANAGE_Pnn` scheme
(`return lms_apex_pkg.can_manage_course(:Pnn_COURSE_ID, 'COURSE_AUTHOR');`, one per page item name). Every write is again
authorised in `LMS_COURSE_PKG` / `LMS_ASSESSMENT_PKG` / `LMS_SESSION_PKG` (instructors are scoped to courses they created or teach; training admins have scope ALL).

> **`*_l10n` notation.** Wherever a spec writes `X_l10n` (e.g. `title_l10n`, `module_title_l10n`, `full_name_l10n`) it stands for the language expression
> `case when :LMS_LANG = 'ar' and X_ar is not null then X_ar else X_en end` over the view's `X_en` / `X_ar` columns. Write it out in the region SQL
> (or as a Cards/IR *computed column*); there is deliberately no PL/SQL function for it, to avoid a context switch per row.

**Navigation**: Dashboard (1) · My courses (10) · Question bank (20) · Grading (30) · Sessions (40) · Learner progress (50) · Feedback (51).

| Pg | Name | Type |
|---|---|---|
| 1 | Instructor dashboard | Home |
| 10 | My courses | Cards |
| 11–16 | **Course builder wizard** (11 Basic, 12 Modules, 13 Lessons, 14 Assessments, 15 Completion rules, 16 Review & publish) | Form / IG pages sharing `P_COURSE_ID` |
| 17 | Lesson content (modal) | Modal form |
| 20 / 21 | Question bank / Question editor (modal) | IG / Modal form |
| 30 / 31 | Grading queue / Grade attempt (modal) | IR / Modal |
| 40 / 41 / 42 | Sessions calendar / Session form (modal) / Attendance (modal) | Calendar / Form / IG |
| 50 | Learner progress | IR |
| 51 | Course feedback | Report + charts |

## Page 1 — Instructor dashboard
| Static ID | Source |
|---|---|
| `R_KPIS` (KPI tiles) | `select count(*) courses, nvl(sum(active_learners),0) active_learners, nvl(sum(pending_grading),0) pending_grading from v_lms_my_courses where status = 'PUBLISHED'` |
| `R_MYCOURSES` Cards (top 6) | `select course_id, title_l10n, status, active_learners, pending_grading from v_lms_my_courses order by updated_at desc fetch first 6 rows only` → page 11/50 |
| `R_GRADING` Classic report | `select attempt_id, quiz_title, learner, submitted_at from v_lms_grading_queue order by submitted_at fetch first 10 rows only` → page 31 |
| `R_SESSIONS` Classic report | `select title_l10n, start_ts, registered, seats from v_lms_sessions_manage where start_ts > systimestamp and status in ('SCHEDULED','PUBLISHED') order by start_ts fetch first 5 rows only` |
| `R_COMPLETION` Chart (bar) | `select title_en label, nvl(completed,0) completed, nvl(enrolled,0) - nvl(completed,0) in_progress from v_lms_my_courses c join v_lms_course_popularity p on p.course_id = c.course_id where c.status='PUBLISHED' order by enrolled desc fetch first 8 rows only` (summary table, hourly) |
| `R_PERFORMANCE` Chart | `select to_char(trunc(submitted_at,'IW'),'YYYY-"W"IW') wk, round(avg(score_pct),1) avg_score from v_lms_my_attempts…` **instructor scope: attempts in own courses only** → use `v_lms_course_learners` aggregate `avg(best_score)` per course instead (view already course-scoped) |
Lazy loading on all but `R_KPIS`.

## Page 10 — My courses
Cards on `v_lms_my_courses` (status badge, active learners, pending grading, updated). Facets: status, delivery method, search by title/code. Button `B_NEW` (condition scheme `LMS_AUTH_COURSE_AUTHOR`) → page 11 with `P11_COURSE_ID` null. Card actions: *Edit* (→ 11, only if status DRAFT/SUSPENDED, else *View*), *Learners* (→ 50), *Submit for review* (confirm → `lms_course_pkg.submit_for_review`).
Empty: "You have no courses yet" + *New course*.

## Course builder wizard (pages 11–16)
List `LMS_WIZARD` (Wizard Progress template) with 6 steps; each page has *Previous*/*Next*; *Next* is available once the step saved. Shared hidden item
`P_COURSE_ID` is a **page-specific item per page** (`P11_COURSE_ID`, `P12_COURSE_ID`, …), Value Protected = Yes, passed on links (checksum).
Wizard pages authorise with `LMS_AUTH_COURSE_MANAGE_Pnn` (except page 11 when creating).
A course not in DRAFT/SUSPENDED shows all wizard pages **read-only** (all edit buttons conditioned on `status in ('DRAFT','SUSPENDED')`; the package refuses edits anyway).

### Page 11 — Step 1: Basic information
Items: `P11_COURSE_ID`, `P11_ROW_VERSION` (hidden, protected), `P11_COURSE_CODE`, `P11_TITLE_EN` (required), `P11_TITLE_AR`, `P11_CATEGORY_ID` (Select List `LOV_CATEGORIES`), `P11_DELIVERY_METHOD`, `P11_DIFFICULTY`, `P11_DURATION_MINUTES` (Number ≥ 0), `P11_LANGUAGE_CODE`, `P11_CAPACITY` (Number > 0, optional), `P11_APPROVAL_REQUIRED` (Switch Y/N), `P11_DESCRIPTION_EN/AR` (Textarea, plain text, 4,000), `P11_OBJECTIVES_EN/AR` (Textarea, one per line), `P11_THUMBNAIL_REF` (Text, object-store key; the upload to the object store is done by the content platform, see gaps), availability `P11_AVAILABLE_FROM/TO`, `P11_ENROLL_DEADLINE`.
Load (existing course): *Form* region on `V_LMS_COURSE_EDIT` (only courses the caller manages; includes the text columns and `row_version`). Saving never uses the Form's automatic DML: the processes below call the package.
Validations (UX): code pattern `^[A-Z0-9-]{3,30}$`; deadline ≥ available_from. Real rules: package + table checks.
Processes (on `B_SAVE`, condition `P11_COURSE_ID is null` / not null):
```plsql
-- PR_CREATE
:P11_COURSE_ID := lms_course_pkg.create_course(:P11_COURSE_CODE, :P11_TITLE_EN, :P11_TITLE_AR, :P11_CATEGORY_ID, :P11_DELIVERY_METHOD,
                  :P11_DIFFICULTY, :P11_DURATION_MINUTES, :P11_LANGUAGE_CODE, :P11_CAPACITY, :P11_APPROVAL_REQUIRED, 'LESSONS', 'N');
-- PR_UPDATE (also sets rule and certificate flag later on step 5)
lms_course_pkg.update_course(:P11_COURSE_ID, :P11_ROW_VERSION, :P11_TITLE_EN, :P11_TITLE_AR, :P11_CATEGORY_ID, :P11_DIFFICULTY,
                  :P11_DURATION_MINUTES, :P11_CAPACITY, :P11_APPROVAL_REQUIRED, :P11_COMPLETION_RULE, :P11_CERT_ELIGIBLE,
                  :P11_AVAILABLE_FROM, :P11_AVAILABLE_TO, :P11_ENROLL_DEADLINE);
lms_course_pkg.set_course_text(:P11_COURSE_ID, :P11_ROW_VERSION + 1, :P11_DESCRIPTION_EN, :P11_DESCRIPTION_AR, :P11_OBJECTIVES_EN, :P11_OBJECTIVES_AR, :P11_THUMBNAIL_REF);
```
A stale `row_version` yields "changed by another user" (optimistic locking). Branch → page 12 with the new id.

### Page 12 — Step 2: Modules
`R_MODULES` **Interactive Grid** (editing enabled, row actions up/down/delete) on `V_LMS_MODULES_EDIT`, columns `module_id, title_en, title_ar, sort_order (display only)`; the IG's *Automatic Row Processing* is **disabled**, the custom process below replaces it.
IG **Save** process `PR_SAVE_MODULES` (type PL/SQL code, runs per changed row):
```plsql
case :APEX$ROW_STATUS
  when 'C' then l_id := lms_course_pkg.add_module(:P12_COURSE_ID, :TITLE_EN, :TITLE_AR);
  when 'U' then lms_course_pkg.update_module(:MODULE_ID, :TITLE_EN, :TITLE_AR);
  when 'D' then lms_course_pkg.remove_module(:MODULE_ID);      -- refuses when lessons exist
end case;
```
Buttons *Move up/down* (toolbar) → DA → Ajax → `lms_course_pkg.move_module(:MODULE_ID, 'UP'|'DOWN')` then refresh the grid. The grid's own order column is **not** editable (prevents unique-key collisions).

### Page 13 — Step 3: Lessons and content
`R_LESSONS` IG grouped by module on `V_LMS_LESSONS_EDIT` (automatic row processing disabled): `lesson_id, module_id (select list), title_en, title_ar, lesson_type, duration_minutes, required_flag, prereq_lesson_id (select list limited to same course), available_from`. Save process:
```plsql
case :APEX$ROW_STATUS
  when 'C' then l_id := lms_course_pkg.add_lesson(:MODULE_ID, :TITLE_EN, :LESSON_TYPE, :TITLE_AR, null, :DURATION_MINUTES, :REQUIRED_FLAG, :PREREQ_LESSON_ID);
  when 'U' then lms_course_pkg.update_lesson(:LESSON_ID, :TITLE_EN, :TITLE_AR, :LESSON_TYPE, :DURATION_MINUTES, :REQUIRED_FLAG, :PREREQ_LESSON_ID, :AVAILABLE_FROM);
  when 'D' then lms_course_pkg.remove_lesson(:LESSON_ID);
end case;
```
Row buttons: *Move up/down* (`move_lesson`), *Content…* → page 17 (modal) for that lesson.

### Page 17 — Lesson content (modal)
Items `P17_LESSON_ID` (protected), `P17_LESSON_TYPE` (display), `P17_CONTENT_REF` (Text: object-store key or `https://` link; condition by type), `P17_CONTENT_TEXT` (Textarea; TEXT = plain text, HTML = restricted tags only (p, br, b, strong, i, em, u, ul, ol, li, h2–h4, table parts) — help text lists them), `P17_FILE` (File Upload, *Table: APEX_APPLICATION_TEMP_FILES*, max 25 MB, accepted `.pdf,.pptx,.docx,.png,.jpg`).
Processes: `PR_SAVE_TEXT_REF`: `lms_course_pkg.set_lesson_content(:P17_LESSON_ID, :P17_CONTENT_REF, :P17_CONTENT_TEXT);`
`PR_UPLOAD` (when a file is present):
```plsql
for f in (select filename, mime_type, blob_content from apex_application_temp_files where name = :P17_FILE) loop
  lms_course_pkg.add_lesson_file(:P17_LESSON_ID, f.filename, f.mime_type, f.blob_content);
end loop;
```
Validation `V_FILE_SCAN` runs **before** the process: call the organisation's malware-scan service (REST via `apex_web_service` to an approved scanner) — **not implemented here; mandatory before go-live if policy requires**. Large video: not uploaded through APEX; the content platform produces the object key which the author pastes in `P17_CONTENT_REF`.

### Page 14 — Step 4: Assessments
`R_QUIZZES` IG on `V_LMS_QUIZZES_EDIT` (title, pass score, time limit, max attempts, question count, randomise flags, show-review, required, availability, lesson link; read-only columns `linked_questions`, `attempts`). Save process: `C` → `lms_assessment_pkg.create_quiz(:P14_COURSE_ID, :TITLE_EN, :PASS_SCORE, :TIME_LIMIT_MIN, :MAX_ATTEMPTS, :LESSON_ID)`; `U` → `lms_assessment_pkg.update_quiz(:QUIZ_ID, :TITLE_EN, :TITLE_AR, :PASS_SCORE, :TIME_LIMIT_MIN, :MAX_ATTEMPTS, :QUESTION_COUNT, :RANDOMIZE_Q, :RANDOMIZE_A, :SHOW_REVIEW, :REQUIRED_FLAG, :AVAILABLE_FROM, :AVAILABLE_TO, :ACTIVE_FLAG, :LESSON_ID)` (the package refuses to change pass mark or question count once anyone has attempted the quiz). `R_QUIZ_QUESTIONS`: Shuttle/IG of `v_lms_question_authoring` for the selected quiz; add → `lms_assessment_pkg.link_question(:QUIZ_ID, :QUESTION_ID, :SORT_ORDER)`, remove → `unlink_question` (refused after attempts). Inline check: `lms_assessment_pkg.validate_quiz(:QUIZ_ID)` shown beside each quiz.

### Page 15 — Step 5: Completion rules
Form: `P15_COMPLETION_RULE` (Radio Group `LOV_COMPLETION_RULE` with help text), `P15_CERT_ELIGIBLE` (Switch), `P15_CERT_TEMPLATE` (Select List `v_lms_lov_templates`; process `lms_course_pkg.set_certificate_template(:P15_COURSE_ID, :P15_CERT_TEMPLATE)`), `P15_PASS_REQUIRED`. Live **validation panel** (`R_CHECKS`, Classic Report) showing `lms_course_pkg.validate_publishable(:P15_COURSE_ID)` result; disabled *Next* while it returns text.
Process: `lms_course_pkg.update_course(...)` as on page 11 with the new rule.
Two more regions on this step:
- `R_SKILLS` — *Skills this course builds*: IG on `v_lms_course_skills_edit` (skill select from `v_lms_lov_skills`, level gained 1–5). Save per row: `C/U` → `lms_skill_pkg.set_course_skill(:P15_COURSE_ID, :SKILL_ID, :LEVEL_GAINED);` `D` → same call with `null`. Course authors may tag their own courses; HR may tag any. Completing the course raises each learner's level for these skills (never lowers it).
- `R_FEEDBACK_FORM` — `P15_FEEDBACK_FORM` Select List (`v_lms_lov_feedback_forms`; empty = no questionnaire); process `lms_feedback_pkg.assign_form(:P15_COURSE_ID, :P15_FEEDBACK_FORM);` (refused once feedback was collected with a different form).

### Page 16 — Step 6: Review and publish
Read-only summary (counts: modules, lessons, required lessons, quizzes, duration; `validate_publishable` result), button `B_SUBMIT` (condition: status = DRAFT and no validation message) → confirm → `lms_course_pkg.submit_for_review(:P16_COURSE_ID);`. After submit, the course shows *Under review*; the author **cannot approve** (SoD in `lms_approval_pkg.decide`). A rejection returns it to DRAFT with the reviewer note by notification.

## Pages 20/21 — Question bank
**20**: IG (read-only) on `v_lms_question_authoring` (bank, type, text, points, active); facets: bank, type, active; *Edit* → 21; *Clone* → `lms_assessment_pkg.clone_question(:QUESTION_ID)` (shown when the question was already answered); `B_NEW_BANK` (dialog, `lms_assessment_pkg.create_bank`). Authorization `LMS_AUTH_QUIZ_AUTHOR`.
**21** (modal; `P21_QUESTION_ID` hidden protected): items `P21_BANK_ID` (select, own banks), `P21_TYPE` (`LOV_QUESTION_TYPE`), `P21_TEXT_EN`, `P21_TEXT_AR`, `P21_POINTS`, `P21_ACTIVE`; sub-region **options IG** on `V_LMS_QUESTION_OPTIONS_EDIT` (text EN/AR, `is_correct` switch, `match_key` — column shown only for MATCH, for SHORT the options are the *accepted answers*; MCQ/TF/MULTI use `is_correct`).
Processes: `PR_SAVE_Q`: `:P21_QUESTION_ID := lms_assessment_pkg.save_question(:P21_QUESTION_ID, :P21_BANK_ID, :P21_TYPE, :P21_TEXT_EN, :P21_TEXT_AR, :P21_POINTS, :P21_ACTIVE);` then options IG save: `C/U` → `l_id := lms_assessment_pkg.save_option(:OPTION_ID, :P21_QUESTION_ID, :OPTION_TEXT_EN, :OPTION_TEXT_AR, :IS_CORRECT, :MATCH_KEY, :SORT_ORDER)`, `D` → `lms_assessment_pkg.remove_option(:OPTION_ID)`.
Immutability: once any learner has answered the question, all edits raise "Clone it instead" (so graded history stays correct). **This is the only place correct answers are readable**, behind `QUIZ_AUTHOR` and bank ownership (`v_lms_question_options_edit` is filtered by `v_lms_question_authoring`).

## Pages 30/31 — Grading
**30**: IR on `v_lms_grading_queue` (quiz, learner, submitted); row → 31. **31** (modal, `P31_ATTEMPT_ID` protected): the learner's essay/short answers from `V_LMS_GRADING_DETAIL` (only attempts in the caller's grading queue), IG with `points_awarded` (0…max), `feedback`. Process: per row `lms_assessment_pkg.grade_response(:P31_ATTEMPT_ID, :QUESTION_ID, :POINTS, :FEEDBACK);` — when the last item is graded the package computes the score, pass/fail, completes the lesson and notifies the learner.
Learner answers are rendered escaped (stored as typed).

## Pages 40/41/42 — Sessions
**40**: Calendar on `v_lms_sessions_manage` (start/end, title, colour by status) + IR beneath; `B_NEW` → 41. **41** (modal) has two modes. *Create* (no `P41_SESSION_ID`): items below, process `create_session`. *Edit* (`P41_SESSION_ID` hidden, protected; opened from the calendar or IR for sessions that are SCHEDULED/PUBLISHED **and not started**; any other session opens read-only):
`P41_VENUE_ID`, `P41_INSTRUCTOR_ID`, `P41_SEATS`, `P41_MEETING_URL`, `P41_MIN_ATTENDANCE_PCT` are editable; the course and the time are read-only (time changes go through *Reschedule*). Process `PR_UPDATE`: `lms_session_pkg.update_session(:P41_SESSION_ID, :P41_VENUE_ID, :P41_INSTRUCTOR_ID, :P41_SEATS, :P41_MEETING_URL, :P41_MIN_ATTENDANCE_PCT);` — seats below the registered count, an inactive/too-small venue, a double-booked venue or trainer, and a threshold change after attendance was recorded are refused with an explanation. Help text on the page states what happens: more seats promote the waiting list; a changed place, link or trainer notifies registered and waiting learners (and the new trainer).
Buttons in edit mode: *Publish* (SCHEDULED only), *Cancel session*, *Reschedule*, and **`B_COMPLETE`** *Complete session* (visible when PUBLISHED and ended; `lms_session_pkg.complete_session(:P41_SESSION_ID)` — re-evaluates the attendance rule for every registered learner). Sessions that ended more than `SESSION_AUTOCLOSE_DAYS` (7) ago are completed automatically by the nightly job, so recording attendance within that week matters.
Create-mode items: `P41_COURSE_ID` (select from `v_lms_my_courses` where delivery ≠ SELF_PACED), `P41_VENUE_ID` (`v_lms_lov_venues`, label shows the capacity; validation `P41_SEATS <= capacity` is a UX hint, the package decides), `P41_INSTRUCTOR_ID` (`v_lms_lov_instructors`), `P41_START_TS`, `P41_END_TS` (Date Pickers with time, stored with the session time zone), `P41_SEATS`, `P41_MEETING_URL` (https only), `P41_MIN_ATTENDANCE_PCT`; processes `lms_session_pkg.create_session(...)`, *Publish* → `publish_session`, *Cancel* (confirm + reason) → `cancel_session`, *Reschedule* → `reschedule`. Venue/instructor double-booking is rejected by the package.
**42** (attendance, `P42_SESSION_ID` protected): IG on `v_lms_session_roster` × day selector (`P42_DAY` among the session's dates) with status (PRESENT, ABSENT, LATE, EXCUSED); save → `lms_session_pkg.record_attendance(:SESSION_ENROLLMENT_ID, :P42_DAY, :STATUS)`; completion is re-evaluated automatically.

## Page 50 — Learner progress
IR on `v_lms_course_learners` (course selector `P50_COURSE_ID` from `v_lms_my_courses`): learner, department, status, progress %, last activity, best score, time spent. Download CSV allowed (row scope already enforced by the view; downloads audited via a *Before Download* process `lms_audit_pkg.log_event('EXPORT','REPORT',null,'SUCCESS',lms_util_pkg.js('report','course_learners'))`). Button *Approve completion* (only for courses with rule `INSTRUCTOR_APPROVAL`, row status IN_PROGRESS and all lessons done) → `lms_progress_pkg.approve_completion(:ENROLLMENT_ID)`.

## Page 51 — Course feedback (anonymous aggregates)
Authorization `LMS_AUTH_INSTRUCTOR`; item `P51_COURSE_ID` (select from `v_lms_my_courses`). **Nothing is shown until the number of responses reaches `FEEDBACK_MIN_RESPONSES` (default 5)**, so individuals cannot be identified; below the threshold the page says "Not enough responses yet".
- `R_RATINGS` Chart (bar): `select question_en, avg_rating, responses from v_lms_course_feedback_summary where course_id=:P51_COURSE_ID order by sort_order` (with data-table alternative).
- `R_REVIEWS_SUM` KPI tiles: `select reviews, avg_course_rating, avg_instructor_rating from v_lms_course_review_summary where course_id=:P51_COURSE_ID`.
- `R_COMMENTS` Classic Report: `select comment_month, source, comment_text from v_lms_course_feedback_comments where course_id=:P51_COURSE_ID order by comment_month desc` — no names, no enrolment ids, month granularity only; text escaped; downloads disabled.
- Moderation of abusive reviews is a training-admin action (app 220 page 14).

---
## Remaining items for this app
1. **Malware scan** of uploaded files is a hook only (`V_FILE_SCAN` validation on page 17): integrate the organisation's scanner before go-live if policy requires it.
2. **Object-store upload** for large media/thumbnails happens outside APEX (content platform/pre-signed upload); authors paste the resulting object key. A pre-signed-upload helper is not written.
3. The IG-based save processes above are specified, not built; the IG column/ID names (`:TITLE_EN`, `:MODULE_ID`, …) must match the grid column static IDs when built.
