"""App 200 - LMS Learning Portal (03_APEX/PAGE_SPECIFICATIONS/app200_learning_portal.md)."""
from engine import Page, l10n
from common import new_app, link

TITLE = l10n('title', 'title')


def build(base):
    a = new_app(200, 'lms', 'LMS Learning Portal', base,
                schemes=('LMS_AUTH_CATALOG', 'LMS_AUTH_LEARNER', 'LMS_AUTH_INSTRUCTOR', 'LMS_AUTH_TRAINING_ADMIN',
                         'LMS_AUTH_MANAGER', 'LMS_AUTH_REPORT_ORG'),
                static=('app.css', 'app-pages.css'))
    a.nav = [
        ('Dashboard', 1, 'fa-home', None, '1'),
        ('Catalog', 10, 'fa-search', 'LMS_AUTH_CATALOG', '10,11'),
        ('My learning', 30, 'fa-book', 'LMS_AUTH_LEARNER', '30,20,40,41,13'),
        ('Learning paths', 50, 'fa-road', 'LMS_AUTH_LEARNER', '50,51'),
        ('Sessions', 55, 'fa-calendar', 'LMS_AUTH_LEARNER', '55'),
        ('My skills', 56, 'fa-line-chart', 'LMS_AUTH_LEARNER', '56'),
        ('Certificates', 60, 'fa-certificate', 'LMS_AUTH_LEARNER', '60'),
        ('Notifications', 80, 'fa-bell', None, '80'),
        ('Instructor portal', 'f?p=210:1:&SESSION.', 'fa-pencil', 'LMS_AUTH_INSTRUCTOR', None),
        ('Administration', 'f?p=220:1:&SESSION.', 'fa-cogs', 'LMS_AUTH_TRAINING_ADMIN', None),
        ('Management', 'f?p=230:1:&SESSION.', 'fa-users', 'LMS_AUTH_MANAGER', None),
        ('Analytics', 'f?p=240:1:&SESSION.', 'fa-bar-chart', 'LMS_AUTH_REPORT_ORG', None),
    ]

    # ---------------------------------------------------------------- 1 Dashboard
    p = Page(a, 1, 'Dashboard', alias='HOME', auth='LMS_AUTH_ACTIVE')
    p.plsql('Welcome', """declare
  l_name varchar2(400); l_prog number; l_done number; l_over number;
begin
  select case when :LMS_LANG = 'ar' and full_name_ar is not null then full_name_ar else full_name_en end
    into l_name from v_lms_my_profile;
  select count(case when status in ('ENROLLED','IN_PROGRESS') then 1 end),
         count(case when status = 'COMPLETED' then 1 end),
         count(case when overdue_flag = 'Y' then 1 end)
    into l_prog, l_done, l_over from v_lms_my_enrollments;
  htp.p('<h1 class="lms-welcome">' || apex_escape.html(l_name) || '</h1><div class="lms-kpis">'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || l_prog || '</span><span class="lms-kpi__label">In progress</span></div>'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || l_done || '</span><span class="lms-kpi__label">Completed</span></div>'
     || '<div class="lms-kpi' || case when l_over > 0 then ' lms-kpi--bad' end || '"><span class="lms-kpi__value">'
     || l_over || '</span><span class="lms-kpi__label">Overdue</span></div></div>');
exception when no_data_found then
  htp.p('<p>Your account is not linked to an active LMS user. Contact your administrator.</p>');
end;""", template='reg_blank')
    p.ir('Continue learning',
         f"""select enrollment_id, {l10n('title', 'title')}, status, progress_pct, last_activity_at, due_date,
       {link(20, [('P20_ENROLLMENT_ID', 'enrollment_id')], "'Resume'", cls='t-Button t-Button--small t-Button--hot')} action
  from v_lms_my_enrollments
 where status in ('ENROLLED','IN_PROGRESS')""",
         [('enrollment_id', '-', 'NUMBER'), ('title', 'Course'), ('status', 'Status'), ('progress_pct', 'Progress %', 'NUMBER'),
          ('last_activity_at', 'Last activity', 'DATE', 'DD-MON-YYYY HH24:MI'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'),
          ('action', ' ', 'STRING', None, True)], sort='last_activity_at', desc=True, icon='fa-play')
    p.ir('Mandatory training',
         f"""select {l10n('title', 'title')}, due_date, status, progress_pct,
       case overdue_flag when 'Y' then 'Overdue' end overdue
  from v_lms_my_enrollments
 where mandatory_flag = 'Y' and status not in ('COMPLETED','CANCELLED','FAILED','EXPIRED')""",
         [('title', 'Course'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'), ('status', 'Status'),
          ('progress_pct', 'Progress %', 'NUMBER'), ('overdue', 'Overdue')], sort='due_date', icon='fa-exclamation-circle')
    p.ir('Upcoming sessions',
         f"""select {l10n('title', 'title')}, start_ts, end_ts, {l10n('venue', 'venue')}, status
  from v_lms_my_sessions where start_ts > systimestamp""",
         [('title', 'Session'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('end_ts', 'Ends', 'DATE', 'HH24:MI'),
          ('venue', 'Venue'), ('status', 'Status')], sort='start_ts', icon='fa-calendar')
    p.ir('Feedback waiting for you',
         f"""select {l10n('title', 'title')}, completed_at,
       {link(13, [('P13_ENROLLMENT_ID', 'enrollment_id')], "'Give feedback'", cls='t-Button t-Button--small')} action
  from v_lms_my_feedback_todo""",
         [('title', 'Course'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY'), ('action', ' ', 'STRING', None, True)],
         sort='completed_at', desc=True, icon='fa-comment')
    p.ir('Recommended for you',
         f"""select {l10n('title', 'title')}, duration_minutes, difficulty, coverage,
       {link(11, [('P11_COURSE_ID', 'course_id')], "'View'", cls='t-Button t-Button--small')} action
  from v_lms_my_recommended""",
         [('title', 'Course'), ('duration_minutes', 'Minutes', 'NUMBER'), ('difficulty', 'Difficulty'),
          ('coverage', 'Gaps covered', 'NUMBER'), ('action', ' ', 'STRING', None, True)], sort='coverage', desc=True,
         icon='fa-lightbulb-o')

    # ---------------------------------------------------------------- 10 Catalog
    p = Page(a, 10, 'Course catalog', alias='CATALOG', auth='LMS_AUTH_CATALOG', protection='D')
    h = p.form('Throttle', template='reg_blank')
    p.item(h, 'P10_THROTTLED', 'hidden', protected=False)
    p.process('Check search quota', ":P10_THROTTLED := lms_apex_pkg.search_allowed;", point='BEFORE_HEADER')
    p.plsql('Notice', """if :P10_THROTTLED = 'N' then
  htp.p('<div class="t-Alert t-Alert--warning t-Alert--wizard"><p>Too many searches in a short time. Please wait a minute and try again.</p></div>');
end if;""", template='reg_blank')
    p.ir('Courses',
         f"""select c.course_id, {link(11, [('P11_COURSE_ID', 'c.course_id')], l10n('c.title'))} title,
       c.course_code, {l10n('c.category', 'category')}, c.difficulty, c.duration_minutes, c.language_code,
       c.delivery_method, c.avg_rating, c.rating_count, c.seats_left,
       lms_apex_pkg.status_label(c.my_status) my_status, c.published_at
  from v_lms_catalog c
 where :P10_THROTTLED = 'Y'""",
         [('course_id', '-', 'NUMBER'), ('title', 'Course', 'STRING', None, True), ('course_code', 'Code'),
          ('category', 'Category'), ('difficulty', 'Difficulty'), ('duration_minutes', 'Minutes', 'NUMBER'),
          ('language_code', 'Language'), ('delivery_method', 'Delivery'), ('avg_rating', 'Rating', 'NUMBER', '0.0'),
          ('rating_count', 'Ratings', 'NUMBER'), ('seats_left', 'Seats left', 'NUMBER'), ('my_status', 'My status'),
          ('published_at', 'Published', 'DATE', 'DD-MON-YYYY')], sort='published_at', desc=True, icon='fa-search')

    # ---------------------------------------------------------------- 11 Course details
    p = Page(a, 11, 'Course details', alias='COURSE', auth='LMS_AUTH_CATALOG')
    h = p.form('Course', template='reg_blank')
    for n in ('P11_COURSE_ID', 'P11_ENROLLMENT_ID', 'P11_STATUS'):
        p.item(h, n, 'hidden')
    p.process('Load', """declare l number;
begin
  select count(*) into l from v_lms_catalog where course_id = :P11_COURSE_ID;
  if l = 0 then raise_application_error(-20404, 'Course not found'); end if;
  begin
    select enrollment_id into :P11_ENROLLMENT_ID from v_lms_my_enrollments
     where course_id = :P11_COURSE_ID and status not in ('CANCELLED','FAILED','EXPIRED','COMPLETED')
       and rownum = 1;
  exception when no_data_found then :P11_ENROLLMENT_ID := null;
  end;
end;""", point='BEFORE_HEADER')
    p.plsql('About', """for c in (select * from v_lms_catalog where course_id = :P11_COURSE_ID) loop
  htp.p('<div class="lms-hero"><h1>' || apex_escape.html(case when :LMS_LANG = 'ar' and c.title_ar is not null then c.title_ar else c.title_en end) || '</h1>'
     || '<p class="lms-hero__meta">' || apex_escape.html(case when :LMS_LANG = 'ar' and c.category_ar is not null then c.category_ar else c.category_en end)
     || ' &middot; ' || apex_escape.html(c.difficulty) || ' &middot; ' || c.duration_minutes || ' min'
     || case when c.rating_count > 0 then ' &middot; ' || to_char(c.avg_rating, 'fm0.0') || ' (' || c.rating_count || ')' end
     || case when c.my_status is not null then ' &middot; <strong>' || apex_escape.html(lms_apex_pkg.status_label(c.my_status)) || '</strong>' end
     || '</p></div>');
  htp.p('<h2>About</h2><p>' || replace(apex_escape.html(case when :LMS_LANG = 'ar' and c.description_ar is not null then c.description_ar else c.description_en end), chr(10), '<br>') || '</p>');
  htp.p('<h2>Objectives</h2><p>' || replace(apex_escape.html(case when :LMS_LANG = 'ar' and c.objectives_ar is not null then c.objectives_ar else c.objectives_en end), chr(10), '<br>') || '</p>');
  htp.p('<p>Completion: ' || apex_escape.html(c.completion_rule) || case c.certificate_eligible when 'Y' then ' &middot; Certificate on completion' end
     || case c.approval_required when 'Y' then ' &middot; Needs manager approval' end || '</p>');
end loop;""")
    r = p.buttons()
    b_enroll = p.button(r, 'ENROLL', 'Enroll', hot=True, cond_exists=
        "select 1 from v_lms_catalog c where c.course_id = :P11_COURSE_ID and c.my_status is null "
        "and not exists (select 1 from v_lms_course_prereqs p where p.course_id = c.course_id and p.met_flag = 'N')")
    p.button(r, 'OPEN', 'Open course', action='URL', hot=True,
             url='f?p=&APP_ID.:20:&SESSION.::&DEBUG.::P20_ENROLLMENT_ID:&P11_ENROLLMENT_ID.',
             cond_exists="select 1 from v_lms_my_enrollments where enrollment_id = :P11_ENROLLMENT_ID and status in ('ENROLLED','IN_PROGRESS')")
    p.button(r, 'BACK', 'Back to catalog', action='URL', url='f?p=&APP_ID.:10:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Enroll', """lms_enrollment_pkg.enroll_self(:P11_COURSE_ID, :P11_ENROLLMENT_ID, :P11_STATUS);
apex_application.g_print_success_message := case :P11_STATUS
  when 'PENDING' then 'Sent for approval.'
  when 'WAITLISTED' then 'You are on the waiting list.'
  else 'You are enrolled.' end;""", when_button=b_enroll)
    p.branch(11, items=[('P11_COURSE_ID', '&P11_COURSE_ID.')])
    p.ir('Curriculum',
         f"""select module_order, {l10n('module_title', 'module_title')}, lesson_order, {l10n('lesson_title', 'lesson_title')},
       lesson_type, duration_minutes, required_flag
  from v_lms_course_outline where course_id = :P11_COURSE_ID""",
         [('module_order', '#', 'NUMBER'), ('module_title', 'Module'), ('lesson_order', 'Lesson #', 'NUMBER'),
          ('lesson_title', 'Lesson'), ('lesson_type', 'Type'), ('duration_minutes', 'Minutes', 'NUMBER'),
          ('required_flag', 'Required')], sort='module_order', icon='fa-list')
    p.ir('Prerequisites',
         f"""select course_code, {l10n('title', 'title')}, case met_flag when 'Y' then 'Completed' else 'Required' end state
  from v_lms_course_prereqs where course_id = :P11_COURSE_ID""",
         [('course_code', 'Code'), ('title', 'Course'), ('state', 'State')], icon='fa-check-square-o')
    p.ir('Instructors',
         f"""select {l10n('full_name', 'name')}, {l10n('position', 'position')}, instructor_role
  from v_lms_course_instructors where course_id = :P11_COURSE_ID""",
         [('name', 'Instructor'), ('position', 'Position'), ('instructor_role', 'Role')], icon='fa-user')
    p.ir('Reviews',
         """select reviewer, course_rating, instructor_rating, review_text, review_date
  from v_lms_course_reviews_public where course_id = :P11_COURSE_ID""",
         [('reviewer', 'Reviewer'), ('course_rating', 'Course', 'NUMBER'), ('instructor_rating', 'Instructor', 'NUMBER'),
          ('review_text', 'Review'), ('review_date', 'Date', 'DATE', 'DD-MON-YYYY')], sort='review_date', desc=True,
         icon='fa-star')

    # ---------------------------------------------------------------- 13 Feedback
    p = Page(a, 13, 'Course feedback', alias='FEEDBACK', auth='LMS_AUTH_LEARNER')
    r = p.form('Your review')
    p.item(r, 'P13_ENROLLMENT_ID', 'hidden')
    p.item(r, 'P13_REVIEW_ID', 'hidden')
    p.item(r, 'P13_COURSE', 'display', 'Course')
    p.item(r, 'P13_COURSE_RATING', 'rating', 'Course rating', required=True)
    p.item(r, 'P13_INSTRUCTOR_RATING', 'rating', 'Instructor rating')
    p.item(r, 'P13_REVIEW_TEXT', 'textarea', 'Comments', maxlen=2000)
    p.process('Load', """select case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end
  into :P13_COURSE from v_lms_my_feedback_todo where enrollment_id = :P13_ENROLLMENT_ID
 union all
select case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end
  from v_lms_my_reviews where enrollment_id = :P13_ENROLLMENT_ID and not exists
       (select 1 from v_lms_my_feedback_todo t where t.enrollment_id = :P13_ENROLLMENT_ID)
 fetch first 1 rows only;
for r in (select review_id, course_rating, instructor_rating, review_text from v_lms_my_reviews where enrollment_id = :P13_ENROLLMENT_ID) loop
  :P13_REVIEW_ID := r.review_id; :P13_COURSE_RATING := r.course_rating;
  :P13_INSTRUCTOR_RATING := r.instructor_rating; :P13_REVIEW_TEXT := r.review_text;
end loop;""".replace("select case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end\n  into :P13_COURSE from v_lms_my_feedback_todo where enrollment_id = :P13_ENROLLMENT_ID\n union all\nselect case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end\n  from v_lms_my_reviews where enrollment_id = :P13_ENROLLMENT_ID and not exists\n       (select 1 from v_lms_my_feedback_todo t where t.enrollment_id = :P13_ENROLLMENT_ID)\n fetch first 1 rows only;",
    """for c in (select case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end t
            from v_lms_my_enrollments where enrollment_id = :P13_ENROLLMENT_ID) loop
  :P13_COURSE := c.t;
end loop;"""), point='BEFORE_HEADER')
    p.plsql('Questionnaire', """for q in (select question_id, case when :LMS_LANG = 'ar' and text_ar is not null then text_ar else text_en end txt,
                 answer_type, rating, comment_text
            from v_lms_my_feedback_form where enrollment_id = :P13_ENROLLMENT_ID order by sort_order) loop
  htp.p('<div class="lms-fq"><p><strong>' || apex_escape.html(q.txt) || '</strong></p>'
     || apex_item.hidden(1, q.question_id));
  if q.answer_type = 'RATING' then
    htp.p(apex_item.select_list(2, q.rating, '1;1,2;2,3;3,4;4,5;5', null, 'YES', null, '-',
          p_item_label => apex_escape.html(q.txt)) || apex_item.hidden(3, null));
  else
    htp.p(apex_item.hidden(2, null) || apex_item.textarea(3, q.comment_text, 3, 60, p_item_label => apex_escape.html(q.txt)));
  end if;
  htp.p('</div>');
end loop;""")
    r = p.buttons()
    b = p.button(r, 'SUBMIT', 'Submit', hot=True)
    p.button(r, 'CANCEL', 'Cancel', action='URL', url='f?p=&APP_ID.:1:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save review and answers', """if :P13_REVIEW_ID is null then
  lms_feedback_pkg.submit_review(:P13_ENROLLMENT_ID, :P13_COURSE_RATING, :P13_INSTRUCTOR_RATING, :P13_REVIEW_TEXT);
else
  lms_feedback_pkg.update_review(:P13_REVIEW_ID, :P13_COURSE_RATING, :P13_INSTRUCTOR_RATING, :P13_REVIEW_TEXT);
end if;
for i in 1 .. apex_application.g_f01.count loop
  if apex_application.g_f02(i) is not null or apex_application.g_f03(i) is not null then
    lms_feedback_pkg.submit_answer(:P13_ENROLLMENT_ID, to_number(apex_application.g_f01(i)),
                                   to_number(apex_application.g_f02(i)), apex_application.g_f03(i));
  end if;
end loop;""", when_button=b, success='Thank you for your feedback.')
    p.branch(1)

    # ---------------------------------------------------------------- 20 Player
    p = Page(a, 20, 'Learning player', alias='PLAYER', auth='LMS_AUTH_LEARNER')
    h = p.form('State', template='reg_blank')
    for n in ('P20_ENROLLMENT_ID', 'P20_LESSON_ID', 'P20_PREV_LESSON', 'P20_NEXT_LESSON', 'P20_LESSON_TYPE', 'P20_PROGRESS', 'P20_STATUS'):
        p.item(h, n, 'hidden')
    p.process('Resolve lesson and record start', """if :P20_LESSON_ID is null then
  select max(lesson_id) into :P20_LESSON_ID from v_lms_resume_lesson where enrollment_id = :P20_ENROLLMENT_ID;
end if;
if :P20_LESSON_ID is null then
  select min(lesson_id) keep (dense_rank first order by module_order, lesson_order)
    into :P20_LESSON_ID from v_lms_curriculum where enrollment_id = :P20_ENROLLMENT_ID;
end if;
lms_apex_pkg.authorize_lesson_access(:P20_ENROLLMENT_ID, :P20_LESSON_ID);
select lesson_type into :P20_LESSON_TYPE from v_lms_curriculum
 where enrollment_id = :P20_ENROLLMENT_ID and lesson_id = :P20_LESSON_ID;
select max(prev_id), max(next_id) into :P20_PREV_LESSON, :P20_NEXT_LESSON
  from (select lesson_id,
               lag(lesson_id)  over (order by module_order, lesson_order) prev_id,
               lead(lesson_id) over (order by module_order, lesson_order) next_id
          from v_lms_curriculum where enrollment_id = :P20_ENROLLMENT_ID)
 where lesson_id = :P20_LESSON_ID;
if :REQUEST is null or :REQUEST <> 'COMPLETE' then
  lms_progress_pkg.record_event(:P20_ENROLLMENT_ID, :P20_LESSON_ID, 'START', lower(rawtohex(sys_guid())),
                                null, null, :P20_PROGRESS, :P20_STATUS);
end if;""", point='BEFORE_HEADER')
    p.plsql('Curriculum', """for l in (select lesson_id, module_order, lesson_order,
                 case when :LMS_LANG = 'ar' and module_title_ar is not null then module_title_ar else module_title_en end module_title,
                 case when :LMS_LANG = 'ar' and title_ar is not null then title_ar else title_en end title,
                 progress_status, locked_flag,
                 lag(module_id) over (order by module_order, lesson_order) prev_module, module_id
            from v_lms_curriculum where enrollment_id = :P20_ENROLLMENT_ID
           order by module_order, lesson_order) loop
  if l.prev_module is null or l.prev_module <> l.module_id then
    htp.p('<h3 class="lms-module">' || apex_escape.html(l.module_title) || '</h3>');
  end if;
  if l.locked_flag = 'Y' then
    htp.p('<div class="lms-lesson lms-lesson--locked"><span class="fa fa-lock" aria-hidden="true"></span> ' || apex_escape.html(l.title) || ' <span class="u-VisuallyHidden">(locked)</span></div>');
  else
    htp.p('<a class="lms-lesson" ' || case when l.lesson_id = :P20_LESSON_ID then 'aria-current="true" ' end || 'href="'
       || apex_page.get_url(p_page => 20, p_items => 'P20_ENROLLMENT_ID,P20_LESSON_ID', p_values => :P20_ENROLLMENT_ID || ',' || l.lesson_id)
       || '">' || case when l.progress_status = 'COMPLETED' then '<span class="fa fa-check" aria-hidden="true"></span> ' end
       || apex_escape.html(l.title) || case when l.progress_status = 'COMPLETED' then ' <span class="u-VisuallyHidden">(completed)</span>' end || '</a>');
  end if;
end loop;""", template='reg_std', icon='fa-list')
    p.plsql('Lesson', """declare
  l_html clob := lms_apex_pkg.lesson_html(:P20_ENROLLMENT_ID, :P20_LESSON_ID);
  l_pos  pls_integer := 1;
begin
  htp.p('<div id="lms-progress" class="lms-progress" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="'
     || nvl(:P20_PROGRESS, 0) || '"><span style="inline-size:' || nvl(:P20_PROGRESS, 0) || '%"></span></div>');
  while l_pos <= dbms_lob.getlength(l_html) loop
    htp.prn(dbms_lob.substr(l_html, 8000, l_pos));
    l_pos := l_pos + 8000;
  end loop;
end;""", template='reg_std', icon='fa-play')
    p.ir('Quizzes in this course', f"""select q.quiz_id, {l10n('q.title', 'title')}, q.pass_score, q.time_limit_min, q.max_attempts,
       q.attempts_used, q.best_score,
       {link(40, [('P40_QUIZ_ID', 'q.quiz_id')], "case when q.open_attempt_id is not null then 'Resume' else 'Take quiz' end", cls='t-Button t-Button--small t-Button--hot')} action
  from v_lms_my_quizzes q where q.enrollment_id = :P20_ENROLLMENT_ID""",
         [('quiz_id', '-', 'NUMBER'), ('title', 'Quiz'), ('pass_score', 'Pass %', 'NUMBER'), ('time_limit_min', 'Minutes', 'NUMBER'),
          ('max_attempts', 'Attempts allowed', 'NUMBER'), ('attempts_used', 'Used', 'NUMBER'), ('best_score', 'Best %', 'NUMBER'),
          ('action', ' ', 'STRING', None, True)], icon='fa-question-circle')
    r = p.buttons()
    p.button(r, 'PREV', 'Previous', action='URL', position='PREVIOUS', icon='fa-chevron-left',
             url='f?p=&APP_ID.:20:&SESSION.::&DEBUG.::P20_ENROLLMENT_ID,P20_LESSON_ID:&P20_ENROLLMENT_ID.,&P20_PREV_LESSON.',
             cond_exists="select 1 from dual where :P20_PREV_LESSON is not null")
    b = p.button(r, 'COMPLETE', 'Mark complete', hot=True, icon='fa-check',
                 cond_exists="select 1 from v_lms_curriculum where enrollment_id = :P20_ENROLLMENT_ID and lesson_id = :P20_LESSON_ID "
                             "and nvl(progress_status, 'X') <> 'COMPLETED' and lesson_type not in ('ASSESSMENT','LIVE_SESSION')")
    p.button(r, 'NEXT', 'Next', action='URL', icon='fa-chevron-right',
             url='f?p=&APP_ID.:20:&SESSION.::&DEBUG.::P20_ENROLLMENT_ID,P20_LESSON_ID:&P20_ENROLLMENT_ID.,&P20_NEXT_LESSON.',
             cond_exists="select 1 from v_lms_curriculum where enrollment_id = :P20_ENROLLMENT_ID and lesson_id = :P20_NEXT_LESSON and locked_flag = 'N'")
    p.button(r, 'EXIT', 'Exit', action='URL', url='f?p=&APP_ID.:30:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Complete lesson', """lms_progress_pkg.record_event(:P20_ENROLLMENT_ID, :P20_LESSON_ID, 'COMPLETE', lower(rawtohex(sys_guid())),
                              null, null, :P20_PROGRESS, :P20_STATUS);""",
              when_button=b, success='Lesson completed.')
    p.branch(20, items=[('P20_ENROLLMENT_ID', '&P20_ENROLLMENT_ID.'), ('P20_LESSON_ID', '&P20_LESSON_ID.')])

    # ---------------------------------------------------------------- 21 Lesson file stream
    p = Page(a, 21, 'Lesson file', alias='LESSON-FILE', auth='LMS_AUTH_LEARNER', template='minimal')
    h = p.form('File', template='reg_blank')
    p.item(h, 'P21_ENROLLMENT_ID', 'hidden')
    p.item(h, 'P21_LESSON_ID', 'hidden')
    p.process('Stream', 'lms_apex_pkg.stream_lesson_file(:P21_ENROLLMENT_ID, :P21_LESSON_ID);', point='BEFORE_HEADER')

    # ---------------------------------------------------------------- 30 My learning
    p = Page(a, 30, 'My learning', alias='MY-LEARNING', auth='LMS_AUTH_LEARNER')
    r = p.form('Show', template='reg_blank')
    p.item(r, 'P30_TAB', 'radio', 'Show', default='ALL', protected=False,
           lov='STATIC:All;ALL,Not started;NOT_STARTED,In progress;IN_PROGRESS,Completed;COMPLETED,Mandatory;MANDATORY')
    p.item(r, 'P30_ENROLLMENT_ID', 'hidden')
    p.process('Cancel request', 'lms_enrollment_pkg.cancel(:P30_ENROLLMENT_ID);', point='BEFORE_HEADER',
              when_request='CANCEL', success='Request cancelled.')
    p.ir('My courses', f"""select e.enrollment_id, {l10n('e.title', 'title')}, lms_apex_pkg.status_label(e.status) status, e.progress_pct,
       e.due_date, case e.overdue_flag when 'Y' then 'Overdue' end overdue,
       case e.mandatory_flag when 'Y' then 'Mandatory' end mandatory, e.last_activity_at,
       case when e.status in ('ENROLLED','IN_PROGRESS','COMPLETED')
              then {link(20, [('P20_ENROLLMENT_ID', 'e.enrollment_id')], "case when e.status = 'COMPLETED' then 'Review' else 'Resume' end", cls='t-Button t-Button--small t-Button--hot')}
            when e.status in ('PENDING','WAITLISTED')
              then {link(30, [('P30_ENROLLMENT_ID', 'e.enrollment_id')], "'Cancel request'", request='CANCEL', cls='t-Button t-Button--small')}
       end action
  from v_lms_my_enrollments e
 where e.status <> 'CANCELLED'
   and (nvl(:P30_TAB, 'ALL') = 'ALL'
     or (:P30_TAB = 'NOT_STARTED' and e.status = 'ENROLLED')
     or (:P30_TAB = 'IN_PROGRESS' and e.status = 'IN_PROGRESS')
     or (:P30_TAB = 'COMPLETED' and e.status = 'COMPLETED')
     or (:P30_TAB = 'MANDATORY' and e.mandatory_flag = 'Y' and e.status not in ('COMPLETED','EXPIRED','FAILED')))""",
         [('enrollment_id', '-', 'NUMBER'), ('title', 'Course'), ('status', 'Status'), ('progress_pct', 'Progress %', 'NUMBER'),
          ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'), ('overdue', 'Overdue'), ('mandatory', 'Mandatory'),
          ('last_activity_at', 'Last activity', 'DATE', 'DD-MON-YYYY HH24:MI'), ('action', ' ', 'STRING', None, True)],
         sort='last_activity_at', desc=True, icon='fa-book')

    # ---------------------------------------------------------------- 40 Assessment
    p = Page(a, 40, 'Assessment', alias='ASSESSMENT', auth='LMS_AUTH_LEARNER')
    h = p.form('State', template='reg_blank')
    for n in ('P40_QUIZ_ID', 'P40_ATTEMPT_ID', 'P40_Q_INDEX', 'P40_TOTAL', 'P40_QUESTION_ID', 'P40_QTYPE', 'P40_GOTO',
              'P40_STATUS', 'P40_SCORE', 'P40_PASSED'):
        p.item(h, n, 'hidden')
    p.process('Load question', """if :P40_ATTEMPT_ID is null then
  select max(open_attempt_id) into :P40_ATTEMPT_ID from v_lms_my_quizzes where quiz_id = :P40_QUIZ_ID;
end if;
if :P40_ATTEMPT_ID is not null then
  select count(*) into :P40_TOTAL from v_lms_attempt_questions where attempt_id = :P40_ATTEMPT_ID;
  :P40_Q_INDEX := least(greatest(nvl(to_number(:P40_Q_INDEX), 1), 1), greatest(to_number(:P40_TOTAL), 1));
  select max(question_id), max(question_type) into :P40_QUESTION_ID, :P40_QTYPE
    from v_lms_attempt_questions where attempt_id = :P40_ATTEMPT_ID and sort_order = :P40_Q_INDEX;
end if;""", point='BEFORE_HEADER')
    p.plsql('Quiz', """if :P40_ATTEMPT_ID is null then
  for q in (select * from v_lms_my_quizzes where quiz_id = :P40_QUIZ_ID) loop
    htp.p('<h1>' || apex_escape.html(case when :LMS_LANG = 'ar' and q.title_ar is not null then q.title_ar else q.title_en end) || '</h1>'
       || '<ul><li>Pass mark: ' || q.pass_score || '%</li>'
       || case when q.time_limit_min is not null then '<li>Time limit: ' || q.time_limit_min || ' minutes</li>' end
       || '<li>Attempts used: ' || q.attempts_used || ' of ' || nvl(to_char(q.max_attempts), 'unlimited') || '</li></ul>');
  end loop;
else
  for a in (select * from v_lms_my_attempts where attempt_id = :P40_ATTEMPT_ID) loop
    htp.p('<p class="lms-quiz-status">Question ' || :P40_Q_INDEX || ' of ' || :P40_TOTAL
       || case when a.deadline_at is not null then ' &middot; Submit before <strong>' || to_char(a.deadline_at, 'DD-MON-YYYY HH24:MI') || '</strong> (server time)' end
       || '</p>');
  end loop;
  for q in (select * from v_lms_attempt_questions where attempt_id = :P40_ATTEMPT_ID and question_id = :P40_QUESTION_ID) loop
    htp.p('<fieldset class="lms-question"><legend>' || apex_escape.html(case when :LMS_LANG = 'ar' and q.text_ar is not null then q.text_ar else q.text_en end)
       || ' <span class="lms-points">(' || q.points || ')</span></legend>');
    if q.question_type in ('MCQ', 'TF', 'MULTI') then
      for o in (select o.option_id, case when :LMS_LANG = 'ar' and o.option_text_ar is not null then o.option_text_ar else o.option_text_en end txt,
                       case when exists (select 1 from json_table(q.answer_json, '$.selected[*]' columns (id number path '$')) j
                                          where j.id = o.option_id) then 'Y' end chosen
                  from v_lms_attempt_options o
                 where o.attempt_id = :P40_ATTEMPT_ID and o.question_id = q.question_id order by o.display_order) loop
        htp.p('<label class="lms-option">'
           || case when q.question_type = 'MULTI'
                   then apex_item.checkbox2(1, o.option_id, case when o.chosen = 'Y' then 'CHECKED' end)
                   else '<input type="radio" name="f01" value="' || o.option_id || '"' || case when o.chosen = 'Y' then ' checked' end || '>' end
           || ' ' || apex_escape.html(o.txt) || '</label>');
      end loop;
    elsif q.question_type = 'MATCH' then
      for o in (select o.option_id, case when :LMS_LANG = 'ar' and o.option_text_ar is not null then o.option_text_ar else o.option_text_en end txt,
                       (select max(j.choice) from json_table(q.answer_json, '$.pairs[*]'
                                 columns (opt number path '$.option', choice varchar2(500) path '$.choice')) j
                         where j.opt = o.option_id) chosen
                  from v_lms_attempt_options o
                 where o.attempt_id = :P40_ATTEMPT_ID and o.question_id = q.question_id order by o.display_order) loop
        htp.p('<div class="lms-match">' || apex_escape.html(o.txt) || ' ' || apex_item.hidden(1, o.option_id)
           || apex_item.select_list_from_query(2, o.chosen,
                'select choice_text d, choice_text r from v_lms_attempt_match_choices where attempt_id = ' || to_number(:P40_ATTEMPT_ID)
                  || ' and question_id = ' || to_number(q.question_id) || ' order by display_order',
                null, 'YES', null, '-', p_item_label => apex_escape.html(o.txt)) || '</div>');
      end loop;
    else
      htp.p(apex_item.textarea(3, json_value(q.answer_json, '$.text'), case q.question_type when 'ESSAY' then 10 else 2 end, 70,
            p_item_label => 'Answer'));
    end if;
    htp.p('</fieldset>');
  end loop;
end if;""")
    r = p.buttons()
    b_start = p.button(r, 'START', 'Start', hot=True, cond_exists="select 1 from dual where :P40_ATTEMPT_ID is null")
    p.button(r, 'PREV', 'Previous', position='PREVIOUS', icon='fa-chevron-left',
             cond_exists="select 1 from dual where :P40_ATTEMPT_ID is not null and to_number(:P40_Q_INDEX) > 1")
    p.button(r, 'NEXT', 'Save and next', icon='fa-chevron-right',
             cond_exists="select 1 from dual where :P40_ATTEMPT_ID is not null and to_number(:P40_Q_INDEX) < to_number(:P40_TOTAL)")
    p.button(r, 'SUBMIT_ATTEMPT', 'Submit answers', hot=True, confirm='Submit your answers? You cannot change them afterwards.',
             cond_exists="select 1 from dual where :P40_ATTEMPT_ID is not null")
    p.process('Start attempt', ":P40_ATTEMPT_ID := lms_assessment_pkg.start_attempt(:P40_QUIZ_ID);\n:P40_Q_INDEX := 1;\n:P40_GOTO := 40;",
              when_button=b_start)
    p.process('Save answer and move', """declare
  l_json varchar2(4000);
  l_arr  json_array_t := json_array_t();
  l_obj  json_object_t := json_object_t();
begin
  if :P40_QTYPE in ('MCQ','TF','MULTI') then
    for i in 1 .. apex_application.g_f01.count loop l_arr.append(to_number(apex_application.g_f01(i))); end loop;
    l_obj.put('selected', l_arr);
  elsif :P40_QTYPE = 'MATCH' then
    for i in 1 .. apex_application.g_f01.count loop
      if apex_application.g_f02(i) is not null then
        declare p json_object_t := json_object_t();
        begin p.put('option', to_number(apex_application.g_f01(i))); p.put('choice', apex_application.g_f02(i)); l_arr.append(p); end;
      end if;
    end loop;
    l_obj.put('pairs', l_arr);
  else
    l_obj.put('text', case when apex_application.g_f03.count > 0 then apex_application.g_f03(1) end);
  end if;
  l_json := l_obj.to_string;
  begin
    lms_assessment_pkg.save_answer(:P40_ATTEMPT_ID, :P40_QUESTION_ID, l_json);
  exception when others then
    -- after the deadline the answer is refused (-20417) but the attempt can still be submitted
    if sqlcode <> -20417 or :REQUEST <> 'SUBMIT_ATTEMPT' then raise; end if;
  end;
  :P40_Q_INDEX := to_number(:P40_Q_INDEX) + case :REQUEST when 'NEXT' then 1 when 'PREV' then -1 else 0 end;
  :P40_GOTO := 40;
  if :REQUEST = 'SUBMIT_ATTEMPT' then
    lms_assessment_pkg.submit_attempt(:P40_ATTEMPT_ID, :P40_STATUS, :P40_SCORE, :P40_PASSED);
    :P40_GOTO := 41;
  end if;
end;""", when_request='NEXT,PREV,SUBMIT_ATTEMPT')
    p.branch(url='f?p=&APP_ID.:&P40_GOTO.:&SESSION.::&DEBUG.::P40_QUIZ_ID,P40_ATTEMPT_ID,P40_Q_INDEX,P41_ATTEMPT_ID:'
                 '&P40_QUIZ_ID.,&P40_ATTEMPT_ID.,&P40_Q_INDEX.,&P40_ATTEMPT_ID.')

    # ---------------------------------------------------------------- 41 Result
    p = Page(a, 41, 'Assessment result', alias='RESULT', auth='LMS_AUTH_LEARNER')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P41_ATTEMPT_ID', 'hidden')
    p.plsql('Result', """for a in (select * from v_lms_my_attempts where attempt_id = :P41_ATTEMPT_ID) loop
  htp.p('<h1>' || apex_escape.html(case when :LMS_LANG = 'ar' and a.title_ar is not null then a.title_ar else a.title_en end) || '</h1>');
  if a.status = 'PENDING_GRADING' then
    htp.p('<p>Awaiting instructor grading.</p>');
  else
    htp.p('<p class="lms-result ' || case a.passed_flag when 'Y' then 'is-pass' else 'is-fail' end || '">'
       || case a.passed_flag when 'Y' then 'Passed' else 'Not passed' end || ': ' || nvl(to_char(a.score_pct), '-')
       || '% (pass mark ' || a.pass_score || '%), attempt ' || a.attempt_no || '</p>');
  end if;
end loop;""")
    p.ir('Answer review', f"""select sort_order, {l10n('text', 'question')}, option_text_en answer_option,
       case is_correct when 'Y' then 'Correct' when 'N' then 'Incorrect' end correct, points_awarded, max_points, feedback
  from v_lms_attempt_review where attempt_id = :P41_ATTEMPT_ID""",
         [('sort_order', '#', 'NUMBER'), ('question', 'Question'), ('answer_option', 'Option'), ('correct', 'Correct'),
          ('points_awarded', 'Points', 'NUMBER'), ('max_points', 'Max', 'NUMBER'), ('feedback', 'Feedback')], sort='sort_order')
    r = p.buttons()
    p.button(r, 'BACK', 'My learning', action='URL', url='f?p=&APP_ID.:30:&SESSION.::&DEBUG.:::')

    # ---------------------------------------------------------------- 50/51 Learning paths
    p = Page(a, 50, 'Learning paths', alias='PATHS', auth='LMS_AUTH_LEARNER')
    p.ir('My paths', f"""select {link(51, [('P51_PATH_ID', 'path_id'), ('P51_PATH_ENROLLMENT_ID', 'path_enrollment_id')], l10n('title'))} title,
       status, progress_pct, course_count, enrolled_at, completed_at
  from v_lms_my_paths""",
         [('title', 'Path', 'STRING', None, True), ('status', 'Status'), ('progress_pct', 'Progress %', 'NUMBER'),
          ('course_count', 'Courses', 'NUMBER'), ('enrolled_at', 'Enrolled', 'DATE', 'DD-MON-YYYY'),
          ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY')], icon='fa-road')
    p.ir('All paths', f"""select {link(51, [('P51_PATH_ID', 'path_id')], l10n('title'))} title,
       course_count, case certificate_eligible when 'Y' then 'Yes' else 'No' end certificate,
       lms_apex_pkg.status_label(my_status) my_status
  from v_lms_path_catalog""",
         [('title', 'Path', 'STRING', None, True), ('course_count', 'Courses', 'NUMBER'), ('certificate', 'Certificate'),
          ('my_status', 'My status')], icon='fa-map-signs')

    p = Page(a, 51, 'Learning path', alias='PATH', auth='LMS_AUTH_LEARNER')
    h = p.form('State', template='reg_blank')
    for n in ('P51_PATH_ID', 'P51_PATH_ENROLLMENT_ID', 'P51_COURSE_ID', 'P51_ENROLLMENT_ID', 'P51_STATUS', 'P51_GOTO'):
        p.item(h, n, 'hidden')
    p.process('Load', """if :P51_PATH_ENROLLMENT_ID is null then
  select max(path_enrollment_id) into :P51_PATH_ENROLLMENT_ID from v_lms_my_paths where path_id = :P51_PATH_ID;
end if;""", point='BEFORE_HEADER')
    p.plsql('Path', """for x in (select * from v_lms_path_catalog where path_id = :P51_PATH_ID) loop
  htp.p('<h1>' || apex_escape.html(case when :LMS_LANG = 'ar' and x.title_ar is not null then x.title_ar else x.title_en end) || '</h1><p>'
     || apex_escape.html(case when :LMS_LANG = 'ar' and x.description_ar is not null then x.description_ar else x.description_en end) || '</p>');
end loop;""")
    p.ir('Courses in this path', f"""select sequence_no, {l10n('title', 'title')},
       case when course_status = 'COMPLETED' then 'Completed' when course_status is not null then lms_apex_pkg.status_label(course_status) else 'Not started' end state,
       case required_flag when 'Y' then 'Required' else 'Optional' end required
  from v_lms_path_courses where path_enrollment_id = :P51_PATH_ENROLLMENT_ID""",
         [('sequence_no', '#', 'NUMBER'), ('title', 'Course'), ('state', 'State'), ('required', 'Required')], sort='sequence_no')
    r = p.buttons()
    b1 = p.button(r, 'ENROLL_PATH', 'Enroll in path', hot=True, cond_exists="select 1 from dual where :P51_PATH_ENROLLMENT_ID is null")
    b2 = p.button(r, 'NEXT_COURSE', 'Start next course', hot=True,
                  cond_exists="select 1 from v_lms_my_paths where path_enrollment_id = :P51_PATH_ENROLLMENT_ID and status <> 'COMPLETED'")
    p.process('Enroll in path', ":P51_PATH_ENROLLMENT_ID := lms_learning_path_pkg.enroll_path(:P51_PATH_ID);\n:P51_GOTO := 51;",
              when_button=b1, success='You are enrolled in the path.')
    p.process('Start next course', """lms_learning_path_pkg.start_next_course(:P51_PATH_ENROLLMENT_ID, :P51_COURSE_ID, :P51_ENROLLMENT_ID, :P51_STATUS);
:P51_GOTO := case when :P51_STATUS in ('ENROLLED','IN_PROGRESS') then 20 else 51 end;
apex_application.g_print_success_message := case :P51_STATUS when 'PENDING' then 'Sent for approval.'
  when 'WAITLISTED' then 'You are on the waiting list.' end;""", when_button=b2)
    p.branch(url='f?p=&APP_ID.:&P51_GOTO.:&SESSION.::&DEBUG.::P51_PATH_ID,P51_PATH_ENROLLMENT_ID,P20_ENROLLMENT_ID:'
                 '&P51_PATH_ID.,&P51_PATH_ENROLLMENT_ID.,&P51_ENROLLMENT_ID.')

    # ---------------------------------------------------------------- 55 Sessions
    p = Page(a, 55, 'Sessions', alias='SESSIONS', auth='LMS_AUTH_LEARNER')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P55_SESSION_ID', 'hidden')
    p.item(h, 'P55_SESSION_ENROLLMENT_ID', 'hidden')
    p.item(h, 'P55_STATUS', 'hidden')
    p.process('Register', """lms_session_pkg.register(:P55_SESSION_ID, :P55_STATUS);
apex_application.g_print_success_message := case :P55_STATUS when 'WAITLISTED' then 'You are on the waiting list.' else 'You are registered.' end;""",
              point='BEFORE_HEADER', when_request='REGISTER')
    p.process('Unregister', 'lms_session_pkg.cancel_registration(:P55_SESSION_ENROLLMENT_ID);', point='BEFORE_HEADER',
              when_request='UNREGISTER', success='Registration cancelled.')
    p.ir('My sessions', f"""select {l10n('title', 'title')}, start_ts, end_ts, {l10n('venue', 'venue')}, status,
       meeting_url,
       {link(57, [('P57_SESSION_ID', 'session_id')], "'Add to calendar'", cls='t-Button t-Button--small')}
       || ' ' || {link(55, [('P55_SESSION_ENROLLMENT_ID', 'session_enrollment_id')], "'Unregister'", request='UNREGISTER', cls='t-Button t-Button--small')} action
  from v_lms_my_sessions where end_ts > systimestamp""",
         [('title', 'Session'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('end_ts', 'Ends', 'DATE', 'HH24:MI'),
          ('venue', 'Venue'), ('status', 'Status'), ('meeting_url', 'Join link'), ('action', ' ', 'STRING', None, True)],
         sort='start_ts', icon='fa-calendar-check-o')
    p.ir('Upcoming sessions', f"""select {l10n('title', 'title')}, start_ts, end_ts, {l10n('venue', 'venue')}, seats, seats_left,
       lms_apex_pkg.status_label(my_status) my_status,
       case when my_status is null then
         {link(55, [('P55_SESSION_ID', 'session_id')], "case when seats_left > 0 then 'Register' else 'Join waiting list' end", request='REGISTER', cls='t-Button t-Button--small t-Button--hot')}
       end action
  from v_lms_session_catalog where start_ts > systimestamp""",
         [('title', 'Session'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('end_ts', 'Ends', 'DATE', 'HH24:MI'),
          ('venue', 'Venue'), ('seats', 'Seats', 'NUMBER'), ('seats_left', 'Seats left', 'NUMBER'), ('my_status', 'My status'),
          ('action', ' ', 'STRING', None, True)], sort='start_ts', icon='fa-calendar')

    # ---------------------------------------------------------------- 56 Skills
    p = Page(a, 56, 'My skills', alias='SKILLS', auth='LMS_AUTH_LEARNER')
    p.ir('My skills', f"""select {l10n('name', 'skill')}, current_level, required_level, gap,
       nvl(current_level, 0) || ' of ' || nvl(required_level, 0) level_text
  from v_lms_my_skills""",
         [('skill', 'Skill'), ('current_level', 'Current', 'NUMBER'), ('required_level', 'Required', 'NUMBER'),
          ('gap', 'Gap', 'NUMBER'), ('level_text', 'Level')], sort='gap', desc=True, icon='fa-line-chart')
    p.ir('Courses that close your gaps', f"""select {link(11, [('P11_COURSE_ID', 'course_id')], l10n('title'))} title,
       duration_minutes, difficulty, coverage
  from v_lms_my_recommended""",
         [('title', 'Course', 'STRING', None, True), ('duration_minutes', 'Minutes', 'NUMBER'), ('difficulty', 'Difficulty'),
          ('coverage', 'Gaps covered', 'NUMBER')], sort='coverage', desc=True, icon='fa-lightbulb-o')

    # ---------------------------------------------------------------- 57 Calendar file
    p = Page(a, 57, 'Calendar file', alias='ICS', auth='LMS_AUTH_LEARNER', template='minimal')
    h = p.form('File', template='reg_blank')
    p.item(h, 'P57_SESSION_ID', 'hidden')
    p.process('Stream', 'lms_calendar_pkg.stream_my_ics(:P57_SESSION_ID);', point='BEFORE_HEADER')

    # ---------------------------------------------------------------- 60/61 Certificates
    p = Page(a, 60, 'My certificates', alias='CERTIFICATES', auth='LMS_AUTH_LEARNER')
    p.ir('Certificates', f"""select certificate_no, {l10n('title', 'title')}, issued_at, expires_at, status, verification_code,
       {link(61, [('P61_CERTIFICATE_ID', 'certificate_id')], "'Download'", cls='t-Button t-Button--small t-Button--hot')} action
  from v_lms_my_certs""",
         [('certificate_no', 'Number'), ('title', 'Title'), ('issued_at', 'Issued', 'DATE', 'DD-MON-YYYY'),
          ('expires_at', 'Expires', 'DATE', 'DD-MON-YYYY'), ('status', 'Status'), ('verification_code', 'Verification code'),
          ('action', ' ', 'STRING', None, True)], sort='issued_at', desc=True, icon='fa-certificate')

    p = Page(a, 61, 'Certificate', alias='CERTIFICATE', auth='LMS_AUTH_LEARNER', template='minimal')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P61_CERTIFICATE_ID', 'hidden')
    p.process('Authorise download', 'lms_certification_pkg.authorize_download(:P61_CERTIFICATE_ID);', point='BEFORE_HEADER')
    p.plsql('Certificate', """for c in (select * from v_lms_certificate_print where certificate_id = :P61_CERTIFICATE_ID) loop
  htp.p('<div class="lms-cert"' || case when :LMS_LANG = 'ar' then ' dir="rtl" lang="ar"' end || '>'
     || '<p class="lms-cert__kicker">Certificate of completion</p>'
     || '<h1>' || apex_escape.html(case when :LMS_LANG = 'ar' and c.full_name_ar is not null then c.full_name_ar else c.full_name_en end) || '</h1>'
     || '<h2>' || apex_escape.html(case when :LMS_LANG = 'ar' and c.title_ar is not null then c.title_ar else c.title_en end) || '</h2>'
     || '<p>Issued ' || to_char(c.issued_at, 'DD-MON-YYYY') || case when c.expires_at is not null then ' &middot; Valid until ' || to_char(c.expires_at, 'DD-MON-YYYY') end || '</p>'
     || '<p>Certificate ' || apex_escape.html(c.certificate_no) || ' &middot; Verification code ' || apex_escape.html(c.verification_code) || '</p>'
     || '</div><p class="u-hidden-print"><button type="button" class="t-Button t-Button--hot" onclick="window.print()">Print or save as PDF</button></p>');
end loop;""", template='reg_blank')

    # ---------------------------------------------------------------- 70 Preferences
    p = Page(a, 70, 'Preferences', alias='PREFERENCES', auth='LMS_AUTH_ACTIVE')
    r = p.form('My profile')
    for n, lbl in (('P70_NAME', 'Name'), ('P70_EMAIL', 'E-mail'), ('P70_DEPARTMENT', 'Department'),
                   ('P70_POSITION', 'Position'), ('P70_MANAGER', 'Manager'), ('P70_ROLES', 'Roles')):
        p.item(r, n, 'display', lbl)
    p.item(r, 'P70_LANG', 'select', 'Language', lov='STATIC:English;en,العربية;ar', required=True, protected=False)
    p.process('Load', """select full_name_en, email, department_en, position_en, manager_en, roles, preferred_lang
  into :P70_NAME, :P70_EMAIL, :P70_DEPARTMENT, :P70_POSITION, :P70_MANAGER, :P70_ROLES, :P70_LANG
  from v_lms_my_profile;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save', hot=True)
    p.process('Save language', "lms_user_pkg.set_language(:P70_LANG);\napex_util.set_session_lang(:P70_LANG);\n:LMS_LANG := :P70_LANG;",
              when_button=b, success='Preferences saved.')
    p.branch(70)

    # ---------------------------------------------------------------- 80 Notifications
    p = Page(a, 80, 'Notifications', alias='NOTIFICATIONS', auth='LMS_AUTH_ACTIVE')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P80_ID', 'hidden')
    p.process('Mark read', 'lms_notification_pkg.mark_read(:P80_ID);', point='BEFORE_HEADER', when_request='READ')
    p.ir('Notifications', f"""select case read_flag when 'N' then 'New' end unread, title, message, created_at,
       case when read_flag = 'N' then {link(80, [('P80_ID', 'notification_id')], "'Mark read'", request='READ', cls='t-Button t-Button--small')} end
       || case when link_url like 'f?p=%' then ' <a class="t-Button t-Button--small" href="' || apex_escape.html_attribute(link_url) || '">Open</a>' end action
  from v_lms_my_notifications""",
         [('unread', ' '), ('title', 'Title'), ('message', 'Message'), ('created_at', 'Received', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('action', ' ', 'STRING', None, True)], sort='created_at', desc=True, icon='fa-bell')
    r = p.buttons()
    b = p.button(r, 'MARK_ALL', 'Mark all as read')
    p.process('Mark all read', 'lms_notification_pkg.mark_all_read;', when_button=b, success='All notifications marked as read.')
    p.branch(80)

    # ---------------------------------------------------------------- 90 Verify (public)
    p = Page(a, 90, 'Verify a certificate', alias='VERIFY', public=True, template='minimal', protection='D')
    r = p.form('Verify a certificate')
    p.item(r, 'P90_CODE', 'text', 'Verification code', required=True, maxlen=20, protected=False)
    for n, lbl in (('P90_RESULT', 'Result'), ('P90_TITLE', 'Title'), ('P90_HOLDER', 'Holder'),
                   ('P90_ISSUED', 'Issued'), ('P90_EXPIRES', 'Expires')):
        p.item(r, n, 'display', lbl)
    b = p.button(r, 'VERIFY', 'Verify', hot=True)
    p.process('Verify', """declare
  l_cur sys_refcursor; l_en varchar2(250); l_ar varchar2(250); l_st varchar2(10);
  l_iss date; l_exp date; l_holder varchar2(200);
begin
  if not regexp_like(:P90_CODE, '^[A-Za-z0-9-]{4,20}$') then
    :P90_RESULT := 'NOT FOUND'; return;
  end if;
  l_cur := lms_certification_pkg.verify(:P90_CODE, owa_util.get_cgi_env('HTTP_X_LMS_CLIENT_IP'));
  fetch l_cur into l_en, l_ar, l_st, l_iss, l_exp, l_holder;
  if l_cur%found then
    :P90_RESULT := l_st;
    :P90_TITLE := case when :LMS_LANG = 'ar' and l_ar is not null then l_ar else l_en end;
    :P90_ISSUED := to_char(l_iss, 'YYYY-MM-DD'); :P90_EXPIRES := to_char(l_exp, 'YYYY-MM-DD'); :P90_HOLDER := l_holder;
  else
    :P90_RESULT := 'NOT FOUND';
  end if;
  close l_cur;
end;""", when_button=b)
    return a
