"""App 210 - LMS Instructor Portal (03_APEX/PAGE_SPECIFICATIONS/app210_instructor_portal.md)."""
from engine import Page, l10n
from common import new_app, link

STEPS = [(11, 'Basic information'), (12, 'Modules'), (13, 'Lessons'), (14, 'Assessments'), (15, 'Completion rules'),
         (16, 'Review and publish')]


def wizard_nav(p, item):
    """Step links for the course builder; the course id travels as a checksummed URL argument."""
    links = " || ' &rsaquo; ' || ".join(
        f"case when {pid} = {p.id} then '<strong>{n}. {label}</strong>' else "
        f"'<a href=\"' || apex_page.get_url(p_page => {pid}, p_items => 'P{pid}_COURSE_ID', p_values => :{item}) || '\">{n}. {label}</a>' end"
        for n, (pid, label) in enumerate(STEPS, 1))
    p.plsql('Course builder', f"""if :{item} is not null then
  for c in (select course_code, title_en, status from v_lms_my_courses where course_id = :{item}) loop
    htp.p('<p class="lms-builder-title"><strong>' || apex_escape.html(c.course_code || ' - ' || c.title_en) || '</strong> ('
       || apex_escape.html(c.status) || ')</p>');
  end loop;
  htp.p('<nav class="lms-steps" aria-label="Course builder steps">' || {links} || '</nav>');
end if;""", template='reg_blank')


def build(base):
    a = new_app(210, 'lms-instructor', 'LMS Instructor Portal', base,
                schemes=('LMS_AUTH_INSTRUCTOR', 'LMS_AUTH_COURSE_AUTHOR', 'LMS_AUTH_QUIZ_AUTHOR', 'LMS_AUTH_GRADE',
                         'LMS_AUTH_SESSION_MANAGE', 'LMS_AUTH_LEARNER'))
    a.nav = [
        ('Dashboard', 1, 'fa-home', None, '1'),
        ('My courses', 10, 'fa-book', 'LMS_AUTH_INSTRUCTOR', '10,11,12,13,14,15,16,17'),
        ('Question bank', 20, 'fa-question-circle', 'LMS_AUTH_QUIZ_AUTHOR', '20,21'),
        ('Grading', 30, 'fa-check-square-o', 'LMS_AUTH_GRADE', '30,31'),
        ('Sessions', 40, 'fa-calendar', 'LMS_AUTH_SESSION_MANAGE', '40,41,42'),
        ('Learner progress', 50, 'fa-users', 'LMS_AUTH_INSTRUCTOR', '50'),
        ('Course feedback', 51, 'fa-comments', 'LMS_AUTH_INSTRUCTOR', '51'),
        ('Learning portal', 'f?p=200:1:&SESSION.', 'fa-graduation-cap', 'LMS_AUTH_LEARNER', None),
    ]

    # ---------------------------------------------------------------- 1 Dashboard
    p = Page(a, 1, 'Instructor dashboard', alias='HOME', auth='LMS_AUTH_INSTRUCTOR')
    p.plsql('Summary', """for k in (select count(*) courses, nvl(sum(active_learners), 0) learners, nvl(sum(pending_grading), 0) grading
            from v_lms_my_courses where status = 'PUBLISHED') loop
  htp.p('<div class="lms-kpis"><div class="lms-kpi"><span class="lms-kpi__value">' || k.courses || '</span><span class="lms-kpi__label">Published courses</span></div>'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || k.learners || '</span><span class="lms-kpi__label">Active learners</span></div>'
     || '<div class="lms-kpi' || case when k.grading > 0 then ' lms-kpi--warn' end || '"><span class="lms-kpi__value">' || k.grading
     || '</span><span class="lms-kpi__label">Awaiting grading</span></div></div>');
end loop;""", template='reg_blank')
    p.ir('Grading queue', f"""select quiz_title, learner, submitted_at,
       {link(31, [('P31_ATTEMPT_ID', 'attempt_id')], "'Grade'", cls='t-Button t-Button--small t-Button--hot')} action
  from v_lms_grading_queue""",
         [('quiz_title', 'Quiz'), ('learner', 'Learner'), ('submitted_at', 'Submitted', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('action', ' ', 'STRING', None, True)], sort='submitted_at', icon='fa-check-square-o')
    p.ir('Upcoming sessions', f"""select {l10n('title', 'title')}, start_ts, registered, seats, waitlisted, status
  from v_lms_sessions_manage where start_ts > systimestamp and status in ('SCHEDULED','PUBLISHED')""",
         [('title', 'Session'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('registered', 'Registered', 'NUMBER'),
          ('seats', 'Seats', 'NUMBER'), ('waitlisted', 'Waiting', 'NUMBER'), ('status', 'Status')], sort='start_ts',
         icon='fa-calendar')

    # ---------------------------------------------------------------- 10 My courses
    p = Page(a, 10, 'My courses', alias='COURSES', auth='LMS_AUTH_INSTRUCTOR')
    p.ir('Courses', f"""select course_code, {link(11, [('P11_COURSE_ID', 'course_id')], l10n('title'))} title,
       status, delivery_method, category_en, active_learners, pending_grading, updated_at
  from v_lms_my_courses""",
         [('course_code', 'Code'), ('title', 'Course', 'STRING', None, True), ('status', 'Status'), ('delivery_method', 'Delivery'),
          ('category_en', 'Category'), ('active_learners', 'Active learners', 'NUMBER'), ('pending_grading', 'Grading', 'NUMBER'),
          ('updated_at', 'Updated', 'DATE', 'DD-MON-YYYY HH24:MI')], sort='updated_at', desc=True, icon='fa-book')
    r = p.buttons()
    p.button(r, 'NEW', 'New course', action='URL', hot=True, icon='fa-plus', url='f?p=&APP_ID.:11:&SESSION.::&DEBUG.:11::')

    # ---------------------------------------------------------------- 11 Basic information
    p = Page(a, 11, 'Course: basic information', alias='COURSE', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P11_COURSE_ID')
    r = p.form('Basic information')
    p.item(r, 'P11_COURSE_ID', 'hidden')
    p.item(r, 'P11_ROW_VERSION', 'hidden')
    p.item(r, 'P11_STATUS', 'display', 'Status')
    p.item(r, 'P11_COURSE_CODE', 'text', 'Course code', required=True, maxlen=30, placeholder='e.g. SEC-101')
    p.item(r, 'P11_TITLE_EN', 'text', 'Title (English)', required=True, maxlen=250)
    p.item(r, 'P11_TITLE_AR', 'text', 'Title (Arabic)', maxlen=250)
    p.item(r, 'P11_CATEGORY_ID', 'select', 'Category', required=True,
           lov="select case when :LMS_LANG = 'ar' and name_ar is not null then name_ar else name_en end d, category_id r from v_lms_categories order by sort_order")
    p.item(r, 'P11_DELIVERY_METHOD', 'select', 'Delivery', required=True,
           lov='STATIC:Self-paced;SELF_PACED,Classroom;CLASSROOM,Virtual;VIRTUAL,Blended;BLENDED')
    p.item(r, 'P11_DIFFICULTY', 'select', 'Difficulty', lov='STATIC:Beginner;BEGINNER,Intermediate;INTERMEDIATE,Advanced;ADVANCED')
    p.item(r, 'P11_DURATION_MINUTES', 'number', 'Duration (minutes)')
    p.item(r, 'P11_LANGUAGE_CODE', 'select', 'Language', lov='STATIC:English;en,Arabic;ar,Bilingual;bi')
    p.item(r, 'P11_CAPACITY', 'number', 'Capacity (empty = unlimited)')
    p.item(r, 'P11_APPROVAL_REQUIRED', 'select', 'Manager approval required', lov='STATIC:No;N,Yes;Y', default='N')
    p.item(r, 'P11_AVAILABLE_FROM', 'date', 'Available from')
    p.item(r, 'P11_AVAILABLE_TO', 'date', 'Available to')
    p.item(r, 'P11_ENROLL_DEADLINE', 'date', 'Enrollment deadline')
    p.item(r, 'P11_DESCRIPTION_EN', 'textarea', 'Description (English)')
    p.item(r, 'P11_DESCRIPTION_AR', 'textarea', 'Description (Arabic)')
    p.item(r, 'P11_OBJECTIVES_EN', 'textarea', 'Objectives (English), one per line')
    p.item(r, 'P11_OBJECTIVES_AR', 'textarea', 'Objectives (Arabic), one per line')
    p.item(r, 'P11_THUMBNAIL_REF', 'text', 'Thumbnail object key', maxlen=500)
    p.item(r, 'P11_COMPLETION_RULE', 'hidden')
    p.item(r, 'P11_CERT_ELIGIBLE', 'hidden')
    p.process('Load', """if :P11_COURSE_ID is not null then
  select course_code, title_en, title_ar, category_id, delivery_method, difficulty, duration_minutes, language_code, capacity,
         approval_required, available_from, available_to, enroll_deadline, description_en, description_ar, objectives_en,
         objectives_ar, thumbnail_ref, completion_rule, certificate_eligible, status, row_version
    into :P11_COURSE_CODE, :P11_TITLE_EN, :P11_TITLE_AR, :P11_CATEGORY_ID, :P11_DELIVERY_METHOD, :P11_DIFFICULTY,
         :P11_DURATION_MINUTES, :P11_LANGUAGE_CODE, :P11_CAPACITY, :P11_APPROVAL_REQUIRED, :P11_AVAILABLE_FROM,
         :P11_AVAILABLE_TO, :P11_ENROLL_DEADLINE, :P11_DESCRIPTION_EN, :P11_DESCRIPTION_AR, :P11_OBJECTIVES_EN,
         :P11_OBJECTIVES_AR, :P11_THUMBNAIL_REF, :P11_COMPLETION_RULE, :P11_CERT_ELIGIBLE, :P11_STATUS, :P11_ROW_VERSION
    from v_lms_course_edit where course_id = :P11_COURSE_ID;
end if;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save and continue', hot=True)
    p.button(r2, 'BACK', 'My courses', action='URL', url='f?p=&APP_ID.:10:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save', """if :P11_COURSE_ID is null then
  :P11_COURSE_ID := lms_course_pkg.create_course(upper(:P11_COURSE_CODE), :P11_TITLE_EN, :P11_TITLE_AR, :P11_CATEGORY_ID,
                     :P11_DELIVERY_METHOD, :P11_DIFFICULTY, :P11_DURATION_MINUTES, :P11_LANGUAGE_CODE, :P11_CAPACITY,
                     :P11_APPROVAL_REQUIRED, 'LESSONS', 'N');
  select row_version into :P11_ROW_VERSION from v_lms_course_edit where course_id = :P11_COURSE_ID;
  :P11_COMPLETION_RULE := 'LESSONS'; :P11_CERT_ELIGIBLE := 'N';
end if;
lms_course_pkg.update_course(:P11_COURSE_ID, :P11_ROW_VERSION, :P11_TITLE_EN, :P11_TITLE_AR, :P11_CATEGORY_ID, :P11_DIFFICULTY,
                             :P11_DURATION_MINUTES, :P11_CAPACITY, :P11_APPROVAL_REQUIRED, nvl(:P11_COMPLETION_RULE, 'LESSONS'),
                             nvl(:P11_CERT_ELIGIBLE, 'N'), :P11_AVAILABLE_FROM, :P11_AVAILABLE_TO, :P11_ENROLL_DEADLINE);
select row_version into :P11_ROW_VERSION from v_lms_course_edit where course_id = :P11_COURSE_ID;
lms_course_pkg.set_course_text(:P11_COURSE_ID, :P11_ROW_VERSION, :P11_DESCRIPTION_EN, :P11_DESCRIPTION_AR,
                               :P11_OBJECTIVES_EN, :P11_OBJECTIVES_AR, :P11_THUMBNAIL_REF);""",
              when_button=b, success='Course saved.')
    p.branch(12, items=[('P12_COURSE_ID', '&P11_COURSE_ID.')])

    # ---------------------------------------------------------------- 12 Modules
    p = Page(a, 12, 'Course: modules', alias='MODULES', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P12_COURSE_ID')
    h = p.form('Module')
    p.item(h, 'P12_COURSE_ID', 'hidden')
    p.item(h, 'P12_MODULE_ID', 'hidden')
    p.item(h, 'P12_TITLE_EN', 'text', 'Module title (English)', required=True, maxlen=250)
    p.item(h, 'P12_TITLE_AR', 'text', 'Module title (Arabic)', maxlen=250)
    p.process('Load', """if :P12_MODULE_ID is not null and :REQUEST is null then
  select title_en, title_ar into :P12_TITLE_EN, :P12_TITLE_AR from v_lms_modules_edit where module_id = :P12_MODULE_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Move up', "lms_course_pkg.move_module(:P12_MODULE_ID, 'UP');\n:P12_MODULE_ID := null;", point='BEFORE_HEADER', when_request='UP')
    p.process('Move down', "lms_course_pkg.move_module(:P12_MODULE_ID, 'DOWN');\n:P12_MODULE_ID := null;", point='BEFORE_HEADER', when_request='DOWN')
    p.process('Remove', "lms_course_pkg.remove_module(:P12_MODULE_ID);\n:P12_MODULE_ID := null;", point='BEFORE_HEADER',
              when_request='REMOVE', success='Module removed.')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save module', hot=True)
    p.button(r2, 'NEXT_STEP', 'Next: lessons', action='URL', url='f?p=&APP_ID.:13:&SESSION.::&DEBUG.::P13_COURSE_ID:&P12_COURSE_ID.')
    p.process('Save module', """if :P12_MODULE_ID is null then
  :P12_MODULE_ID := lms_course_pkg.add_module(:P12_COURSE_ID, :P12_TITLE_EN, :P12_TITLE_AR);
else
  lms_course_pkg.update_module(:P12_MODULE_ID, :P12_TITLE_EN, :P12_TITLE_AR);
end if;""", when_button=b, success='Module saved.')
    p.branch(12, items=[('P12_COURSE_ID', '&P12_COURSE_ID.')])
    row = lambda req, txt: link(12, [('P12_COURSE_ID', 'course_id'), ('P12_MODULE_ID', 'module_id')], f"'{txt}'", request=req, cls='t-Button t-Button--small')
    p.ir('Modules', f"""select sort_order, title_en, title_ar,
       {link(12, [('P12_COURSE_ID', 'course_id'), ('P12_MODULE_ID', 'module_id')], "'Edit'", cls='t-Button t-Button--small')} || ' '
       || {row('UP', 'Up')} || ' ' || {row('DOWN', 'Down')} || ' ' || {row('REMOVE', 'Remove')} action
  from v_lms_modules_edit where course_id = :P12_COURSE_ID""",
         [('sort_order', '#', 'NUMBER'), ('title_en', 'Title'), ('title_ar', 'Arabic title'), ('action', ' ', 'STRING', None, True)],
         sort='sort_order', icon='fa-th-list')

    # ---------------------------------------------------------------- 13 Lessons
    p = Page(a, 13, 'Course: lessons', alias='LESSONS', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P13_COURSE_ID')
    h = p.form('Lesson')
    p.item(h, 'P13_COURSE_ID', 'hidden')
    p.item(h, 'P13_LESSON_ID', 'hidden')
    p.item(h, 'P13_MODULE_ID', 'select', 'Module', required=True,
           lov='select title_en d, module_id r from v_lms_modules_edit where course_id = :P13_COURSE_ID order by sort_order')
    p.item(h, 'P13_TITLE_EN', 'text', 'Lesson title (English)', required=True, maxlen=250)
    p.item(h, 'P13_TITLE_AR', 'text', 'Lesson title (Arabic)', maxlen=250)
    p.item(h, 'P13_LESSON_TYPE', 'select', 'Type', required=True,
           lov='STATIC:Video;VIDEO,PDF;PDF,Presentation;PRESENTATION,Text;TEXT,HTML;HTML,Web link;URL,Download;DOWNLOAD,Interactive;INTERACTIVE,Assessment;ASSESSMENT,Assignment;ASSIGNMENT,Live session;LIVE_SESSION')
    p.item(h, 'P13_DURATION_MINUTES', 'number', 'Duration (minutes)')
    p.item(h, 'P13_REQUIRED_FLAG', 'select', 'Required', lov='STATIC:Yes;Y,No;N', default='Y')
    p.item(h, 'P13_PREREQ_LESSON_ID', 'select', 'Must complete first',
           lov='select title_en d, lesson_id r from v_lms_lessons_edit where course_id = :P13_COURSE_ID order by module_order, sort_order')
    p.item(h, 'P13_AVAILABLE_FROM', 'date', 'Available from')
    p.process('Load', """if :P13_LESSON_ID is not null and :REQUEST is null then
  select module_id, title_en, title_ar, lesson_type, duration_minutes, required_flag, prereq_lesson_id, available_from
    into :P13_MODULE_ID, :P13_TITLE_EN, :P13_TITLE_AR, :P13_LESSON_TYPE, :P13_DURATION_MINUTES, :P13_REQUIRED_FLAG,
         :P13_PREREQ_LESSON_ID, :P13_AVAILABLE_FROM
    from v_lms_lessons_edit where lesson_id = :P13_LESSON_ID;
end if;""", point='BEFORE_HEADER')
    for req, code in (('UP', "lms_course_pkg.move_lesson(:P13_LESSON_ID, 'UP');"),
                      ('DOWN', "lms_course_pkg.move_lesson(:P13_LESSON_ID, 'DOWN');"),
                      ('REMOVE', 'lms_course_pkg.remove_lesson(:P13_LESSON_ID);')):
        p.process(f'Lesson {req.lower()}', code + '\n:P13_LESSON_ID := null;', point='BEFORE_HEADER', when_request=req)
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save lesson', hot=True)
    p.button(r2, 'NEXT_STEP', 'Next: assessments', action='URL', url='f?p=&APP_ID.:14:&SESSION.::&DEBUG.::P14_COURSE_ID:&P13_COURSE_ID.')
    p.process('Save lesson', """if :P13_LESSON_ID is null then
  :P13_LESSON_ID := lms_course_pkg.add_lesson(:P13_MODULE_ID, :P13_TITLE_EN, :P13_LESSON_TYPE, :P13_TITLE_AR, null,
                     :P13_DURATION_MINUTES, nvl(:P13_REQUIRED_FLAG, 'Y'), :P13_PREREQ_LESSON_ID);
else
  lms_course_pkg.update_lesson(:P13_LESSON_ID, :P13_TITLE_EN, :P13_TITLE_AR, :P13_LESSON_TYPE, :P13_DURATION_MINUTES,
                               nvl(:P13_REQUIRED_FLAG, 'Y'), :P13_PREREQ_LESSON_ID, :P13_AVAILABLE_FROM);
end if;""", when_button=b, success='Lesson saved.')
    p.branch(13, items=[('P13_COURSE_ID', '&P13_COURSE_ID.')])
    row = lambda req, txt: link(13, [('P13_COURSE_ID', 'course_id'), ('P13_LESSON_ID', 'lesson_id')], f"'{txt}'", request=req, cls='t-Button t-Button--small')
    p.ir('Lessons', f"""select module_order, module_title_en, sort_order, title_en, lesson_type, duration_minutes, required_flag,
       case has_content when 'Y' then 'Yes' else 'No' end has_content,
       {link(13, [('P13_COURSE_ID', 'course_id'), ('P13_LESSON_ID', 'lesson_id')], "'Edit'", cls='t-Button t-Button--small')} || ' '
       || {link(17, [('P17_COURSE_ID', 'course_id'), ('P17_LESSON_ID', 'lesson_id')], "'Content'", cls='t-Button t-Button--small')} || ' '
       || {row('UP', 'Up')} || ' ' || {row('DOWN', 'Down')} || ' ' || {row('REMOVE', 'Remove')} action
  from v_lms_lessons_edit where course_id = :P13_COURSE_ID""",
         [('module_order', 'Module #', 'NUMBER'), ('module_title_en', 'Module'), ('sort_order', 'Lesson #', 'NUMBER'),
          ('title_en', 'Lesson'), ('lesson_type', 'Type'), ('duration_minutes', 'Minutes', 'NUMBER'),
          ('required_flag', 'Required'), ('has_content', 'Content'), ('action', ' ', 'STRING', None, True)],
         sort='module_order', icon='fa-file-text-o')

    # ---------------------------------------------------------------- 17 Lesson content
    p = Page(a, 17, 'Lesson content', alias='LESSON-CONTENT', auth='LMS_AUTH_COURSE_AUTHOR')
    r = p.form('Lesson content')
    p.item(r, 'P17_COURSE_ID', 'hidden')
    p.item(r, 'P17_LESSON_ID', 'hidden')
    p.item(r, 'P17_LESSON', 'display', 'Lesson')
    p.item(r, 'P17_CONTENT_REF', 'text', 'Object-store key or https:// link', maxlen=1000)
    p.item(r, 'P17_CONTENT_TEXT', 'textarea', 'Text or HTML (basic formatting tags only)', height=12, maxlen=32000)
    p.process('Load', """select title_en || ' (' || lesson_type || ')', content_ref into :P17_LESSON, :P17_CONTENT_REF
  from v_lms_lessons_edit where lesson_id = :P17_LESSON_ID;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save content', hot=True)
    p.button(r2, 'BACK', 'Back to lessons', action='URL', position='PREVIOUS',
             url='f?p=&APP_ID.:13:&SESSION.::&DEBUG.::P13_COURSE_ID:&P17_COURSE_ID.')
    p.process('Save content', 'lms_course_pkg.set_lesson_content(:P17_LESSON_ID, :P17_CONTENT_REF, :P17_CONTENT_TEXT);',
              when_button=b, success='Content saved.')
    p.branch(13, items=[('P13_COURSE_ID', '&P17_COURSE_ID.')])

    # ---------------------------------------------------------------- 14 Assessments
    p = Page(a, 14, 'Course: assessments', alias='QUIZZES', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P14_COURSE_ID')
    h = p.form('Quiz')
    p.item(h, 'P14_COURSE_ID', 'hidden')
    p.item(h, 'P14_QUIZ_ID', 'hidden')
    p.item(h, 'P14_TITLE_EN', 'text', 'Title (English)', required=True, maxlen=250)
    p.item(h, 'P14_TITLE_AR', 'text', 'Title (Arabic)', maxlen=250)
    p.item(h, 'P14_LESSON_ID', 'select', 'Linked assessment lesson',
           lov="select title_en d, lesson_id r from v_lms_lessons_edit where course_id = :P14_COURSE_ID and lesson_type = 'ASSESSMENT' order by module_order, sort_order")
    p.item(h, 'P14_PASS_SCORE', 'number', 'Pass mark (%)', default='70')
    p.item(h, 'P14_TIME_LIMIT_MIN', 'number', 'Time limit (minutes, empty = none)')
    p.item(h, 'P14_MAX_ATTEMPTS', 'number', 'Attempts allowed (empty = unlimited)', default='3')
    p.item(h, 'P14_QUESTION_COUNT', 'number', 'Questions per attempt (empty = all linked)')
    p.item(h, 'P14_RANDOMIZE_Q', 'select', 'Shuffle questions', lov='STATIC:Yes;Y,No;N', default='Y')
    p.item(h, 'P14_RANDOMIZE_A', 'select', 'Shuffle options', lov='STATIC:Yes;Y,No;N', default='Y')
    p.item(h, 'P14_SHOW_REVIEW', 'select', 'Show review after submit', lov='STATIC:Yes;Y,No;N', default='N')
    p.item(h, 'P14_REQUIRED_FLAG', 'select', 'Required for completion', lov='STATIC:Yes;Y,No;N', default='Y')
    p.item(h, 'P14_AVAILABLE_FROM', 'date', 'Available from')
    p.item(h, 'P14_AVAILABLE_TO', 'date', 'Available to')
    p.item(h, 'P14_ACTIVE_FLAG', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.item(h, 'P14_ADD_QUESTION', 'select', 'Add question from my banks',
           lov="select bank_en || ': ' || substr(text_en, 1, 80) d, question_id r from v_lms_question_authoring where active_flag = 'Y' order by bank_en, question_id")
    p.process('Load', """if :P14_QUIZ_ID is not null and :REQUEST is null then
  select title_en, title_ar, lesson_id, pass_score, time_limit_min, max_attempts, question_count, randomize_q, randomize_a,
         show_review, required_flag, available_from, available_to, active_flag
    into :P14_TITLE_EN, :P14_TITLE_AR, :P14_LESSON_ID, :P14_PASS_SCORE, :P14_TIME_LIMIT_MIN, :P14_MAX_ATTEMPTS,
         :P14_QUESTION_COUNT, :P14_RANDOMIZE_Q, :P14_RANDOMIZE_A, :P14_SHOW_REVIEW, :P14_REQUIRED_FLAG,
         :P14_AVAILABLE_FROM, :P14_AVAILABLE_TO, :P14_ACTIVE_FLAG
    from v_lms_quizzes_edit where quiz_id = :P14_QUIZ_ID;
end if;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save quiz', hot=True)
    b2 = p.button(r2, 'LINK', 'Add question', cond_exists='select 1 from dual where :P14_QUIZ_ID is not null')
    p.button(r2, 'NEXT_STEP', 'Next: completion rules', action='URL', url='f?p=&APP_ID.:15:&SESSION.::&DEBUG.::P15_COURSE_ID:&P14_COURSE_ID.')
    p.process('Save quiz', """if :P14_QUIZ_ID is null then
  :P14_QUIZ_ID := lms_assessment_pkg.create_quiz(:P14_COURSE_ID, :P14_TITLE_EN, :P14_PASS_SCORE, :P14_TIME_LIMIT_MIN,
                                                 :P14_MAX_ATTEMPTS, :P14_LESSON_ID);
end if;
lms_assessment_pkg.update_quiz(:P14_QUIZ_ID, :P14_TITLE_EN, :P14_TITLE_AR, :P14_PASS_SCORE, :P14_TIME_LIMIT_MIN, :P14_MAX_ATTEMPTS,
                               :P14_QUESTION_COUNT, nvl(:P14_RANDOMIZE_Q, 'Y'), nvl(:P14_RANDOMIZE_A, 'Y'), nvl(:P14_SHOW_REVIEW, 'N'),
                               nvl(:P14_REQUIRED_FLAG, 'Y'), :P14_AVAILABLE_FROM, :P14_AVAILABLE_TO, nvl(:P14_ACTIVE_FLAG, 'Y'),
                               :P14_LESSON_ID);""", when_button=b, success='Quiz saved.')
    p.process('Link question', 'lms_assessment_pkg.link_question(:P14_QUIZ_ID, :P14_ADD_QUESTION);', when_button=b2,
              success='Question added.')
    p.branch(14, items=[('P14_COURSE_ID', '&P14_COURSE_ID.'), ('P14_QUIZ_ID', '&P14_QUIZ_ID.')])
    p.ir('Quizzes', f"""select title_en, pass_score, time_limit_min, max_attempts, linked_questions, attempts, active_flag,
       {link(14, [('P14_COURSE_ID', 'course_id'), ('P14_QUIZ_ID', 'quiz_id')], "'Edit'", cls='t-Button t-Button--small')} action
  from v_lms_quizzes_edit where course_id = :P14_COURSE_ID""",
         [('title_en', 'Quiz'), ('pass_score', 'Pass %', 'NUMBER'), ('time_limit_min', 'Minutes', 'NUMBER'),
          ('max_attempts', 'Attempts', 'NUMBER'), ('linked_questions', 'Questions', 'NUMBER'), ('attempts', 'Taken', 'NUMBER'),
          ('active_flag', 'Active'), ('action', ' ', 'STRING', None, True)], icon='fa-question-circle')

    # ---------------------------------------------------------------- 15 Completion rules
    p = Page(a, 15, 'Course: completion rules', alias='RULES', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P15_COURSE_ID')
    r = p.form('Completion and certificate')
    p.item(r, 'P15_COURSE_ID', 'hidden')
    p.item(r, 'P15_ROW_VERSION', 'hidden')
    p.item(r, 'P15_COMPLETION_RULE', 'radiolist', 'The course is complete when the learner has', required=True,
           lov='STATIC:Completed the required lessons;LESSONS,Completed the lessons and passed the assessment;LESSONS_ASSESSMENT,'
               'Attended the session;ATTENDANCE,Completed the lessons and attended;LESSONS_ATTENDANCE,'
               'Been approved by the instructor;INSTRUCTOR_APPROVAL')
    p.item(r, 'P15_CERT_ELIGIBLE', 'select', 'Issue a certificate', lov='STATIC:No;N,Yes;Y', default='N')
    p.item(r, 'P15_CERT_TEMPLATE', 'select', 'Certificate template', lov='select name_en d, template_id r from v_lms_lov_templates order by name_en')
    p.item(r, 'P15_FEEDBACK_FORM', 'select', 'Feedback questionnaire', lov='select name_en d, form_id r from v_lms_lov_feedback_forms order by name_en')
    p.process('Load', """select completion_rule, certificate_eligible, certificate_template_id, row_version
  into :P15_COMPLETION_RULE, :P15_CERT_ELIGIBLE, :P15_CERT_TEMPLATE, :P15_ROW_VERSION
  from v_lms_course_edit where course_id = :P15_COURSE_ID;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save and continue', hot=True)
    p.process('Save rules', """for c in (select * from v_lms_course_edit where course_id = :P15_COURSE_ID) loop
  lms_course_pkg.update_course(c.course_id, :P15_ROW_VERSION, c.title_en, c.title_ar, c.category_id, c.difficulty,
                               c.duration_minutes, c.capacity, c.approval_required, :P15_COMPLETION_RULE, :P15_CERT_ELIGIBLE,
                               c.available_from, c.available_to, c.enroll_deadline);
end loop;
if :P15_CERT_TEMPLATE is not null then
  lms_course_pkg.set_certificate_template(:P15_COURSE_ID, :P15_CERT_TEMPLATE);
end if;
lms_feedback_pkg.assign_form(:P15_COURSE_ID, :P15_FEEDBACK_FORM);""", when_button=b, success='Rules saved.')
    p.branch(16, items=[('P16_COURSE_ID', '&P15_COURSE_ID.')])
    r3 = p.form('Skills this course builds')
    p.item(r3, 'P15_SKILL_ID', 'select', 'Skill', lov='select name_en d, skill_id r from v_lms_lov_skills order by name_en')
    p.item(r3, 'P15_LEVEL_GAINED', 'select', 'Level gained', lov='STATIC:1;1,2;2,3;3,4;4,5;5')
    b3 = p.button(r3, 'SET_SKILL', 'Save skill')
    p.process('Save skill', 'lms_skill_pkg.set_course_skill(:P15_COURSE_ID, :P15_SKILL_ID, :P15_LEVEL_GAINED);',
              when_button=b3, success='Skill saved.')
    p.ir('Course skills', """select skill_code, skill_en, level_gained
  from v_lms_course_skills_edit where course_id = :P15_COURSE_ID""",
         [('skill_code', 'Code'), ('skill_en', 'Skill'), ('level_gained', 'Level gained', 'NUMBER')], icon='fa-line-chart')

    # ---------------------------------------------------------------- 16 Review and publish
    p = Page(a, 16, 'Course: review and publish', alias='PUBLISH', auth='LMS_AUTH_COURSE_AUTHOR')
    wizard_nav(p, 'P16_COURSE_ID')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P16_COURSE_ID', 'hidden')
    p.item(h, 'P16_PROBLEMS', 'hidden')
    p.process('Validate', ':P16_PROBLEMS := lms_course_pkg.validate_publishable(:P16_COURSE_ID);', point='BEFORE_HEADER')
    p.plsql('Readiness', """for c in (select * from v_lms_course_edit where course_id = :P16_COURSE_ID) loop
  htp.p('<p>Status: <strong>' || apex_escape.html(c.status) || '</strong> &middot; Completion rule: '
     || apex_escape.html(c.completion_rule) || ' &middot; Certificate: ' || c.certificate_eligible || '</p>');
end loop;
for k in (select count(distinct module_id) modules, count(*) lessons, count(case when required_flag = 'Y' then 1 end) required_lessons
            from v_lms_lessons_edit where course_id = :P16_COURSE_ID) loop
  htp.p('<p>' || k.modules || ' modules, ' || k.lessons || ' lessons (' || k.required_lessons || ' required)</p>');
end loop;
if :P16_PROBLEMS is null then
  htp.p('<div class="t-Alert t-Alert--success"><p>The course is ready to submit for review.</p></div>');
else
  htp.p('<div class="t-Alert t-Alert--warning"><p>Fix before publishing:</p><p>' || replace(apex_escape.html(:P16_PROBLEMS), chr(10), '<br>') || '</p></div>');
end if;""")
    r2 = p.buttons()
    b = p.button(r2, 'SUBMIT_REVIEW', 'Submit for review', hot=True,
                 cond_exists="select 1 from v_lms_course_edit where course_id = :P16_COURSE_ID and status = 'DRAFT' and :P16_PROBLEMS is null")
    p.process('Submit for review', 'lms_course_pkg.submit_for_review(:P16_COURSE_ID);', when_button=b,
              success='Submitted for review. An approver has been notified.')
    p.branch(10)

    # ---------------------------------------------------------------- 20/21 Question bank
    p = Page(a, 20, 'Question bank', alias='QUESTIONS', auth='LMS_AUTH_QUIZ_AUTHOR')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P20_QUESTION_ID', 'hidden')
    p.process('Clone', 'declare l number; begin l := lms_assessment_pkg.clone_question(:P20_QUESTION_ID); end;',
              point='BEFORE_HEADER', when_request='CLONE', success='Question cloned.')
    p.ir('Questions', f"""select bank_en, question_type, substr(text_en, 1, 200) text_en, points, active_flag,
       {link(21, [('P21_QUESTION_ID', 'question_id')], "'Edit'", cls='t-Button t-Button--small')} || ' '
       || {link(20, [('P20_QUESTION_ID', 'question_id')], "'Clone'", request='CLONE', cls='t-Button t-Button--small')} action
  from v_lms_question_authoring""",
         [('bank_en', 'Bank'), ('question_type', 'Type'), ('text_en', 'Question'), ('points', 'Points', 'NUMBER'),
          ('active_flag', 'Active'), ('action', ' ', 'STRING', None, True)], icon='fa-question-circle')
    r = p.buttons()
    p.button(r, 'NEW', 'New question', action='URL', hot=True, icon='fa-plus', url='f?p=&APP_ID.:21:&SESSION.::&DEBUG.:21::')

    p = Page(a, 21, 'Question', alias='QUESTION', auth='LMS_AUTH_QUIZ_AUTHOR')
    r = p.form('Question')
    p.item(r, 'P21_QUESTION_ID', 'hidden')
    p.item(r, 'P21_BANK_ID', 'select', 'Bank',
           lov='select distinct bank_en d, bank_id r from v_lms_question_authoring order by 1')
    p.item(r, 'P21_NEW_BANK_EN', 'text', 'Or create a new bank (English name)', maxlen=200)
    p.item(r, 'P21_NEW_BANK_AR', 'text', 'New bank (Arabic name)', maxlen=200)
    p.item(r, 'P21_TYPE', 'select', 'Type', required=True,
           lov='STATIC:Single choice;MCQ,Multiple choice;MULTI,True or false;TF,Matching;MATCH,Short answer;SHORT,Essay;ESSAY')
    p.item(r, 'P21_TEXT_EN', 'textarea', 'Question (English)', required=True)
    p.item(r, 'P21_TEXT_AR', 'textarea', 'Question (Arabic)')
    p.item(r, 'P21_POINTS', 'number', 'Points', required=True, default='1')
    p.item(r, 'P21_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P21_QUESTION_ID is not null and :REQUEST is null then
  select bank_id, question_type, text_en, text_ar, points, active_flag
    into :P21_BANK_ID, :P21_TYPE, :P21_TEXT_EN, :P21_TEXT_AR, :P21_POINTS, :P21_ACTIVE
    from v_lms_question_authoring where question_id = :P21_QUESTION_ID;
end if;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save question', hot=True)
    p.button(r2, 'BACK', 'Question bank', action='URL', url='f?p=&APP_ID.:20:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save question', """if :P21_BANK_ID is null and :P21_NEW_BANK_EN is not null then
  :P21_BANK_ID := lms_assessment_pkg.create_bank(:P21_NEW_BANK_EN, :P21_NEW_BANK_AR);
end if;
if :P21_BANK_ID is null then
  raise_application_error(-20400, 'Choose a bank or enter a new bank name');
end if;
:P21_QUESTION_ID := lms_assessment_pkg.save_question(:P21_QUESTION_ID, :P21_BANK_ID, :P21_TYPE, :P21_TEXT_EN, :P21_TEXT_AR,
                                                     :P21_POINTS, nvl(:P21_ACTIVE, 'Y'));""", when_button=b, success='Question saved.')
    o = p.form('Answer option')
    p.item(o, 'P21_OPTION_ID', 'hidden')
    p.item(o, 'P21_OPT_EN', 'text', 'Option (English)', maxlen=1000)
    p.item(o, 'P21_OPT_AR', 'text', 'Option (Arabic)', maxlen=1000)
    p.item(o, 'P21_IS_CORRECT', 'select', 'Correct', lov='STATIC:No;N,Yes;Y', default='N')
    p.item(o, 'P21_MATCH_KEY', 'text', 'Match key (matching questions)', maxlen=500)
    p.process('Load option', """if :P21_OPTION_ID is not null and :REQUEST = 'EDIT_OPTION' then
  select option_text_en, option_text_ar, is_correct, match_key into :P21_OPT_EN, :P21_OPT_AR, :P21_IS_CORRECT, :P21_MATCH_KEY
    from v_lms_question_options_edit where option_id = :P21_OPTION_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Remove option', 'lms_assessment_pkg.remove_option(:P21_OPTION_ID);\n:P21_OPTION_ID := null;',
              point='BEFORE_HEADER', when_request='REMOVE_OPTION')
    b2 = p.button(o, 'SAVE_OPTION', 'Save option', cond_exists='select 1 from dual where :P21_QUESTION_ID is not null')
    p.process('Save option', """declare l number;
begin
  l := lms_assessment_pkg.save_option(:P21_OPTION_ID, :P21_QUESTION_ID, :P21_OPT_EN, :P21_OPT_AR, nvl(:P21_IS_CORRECT, 'N'), :P21_MATCH_KEY);
  :P21_OPTION_ID := null; :P21_OPT_EN := null; :P21_OPT_AR := null; :P21_MATCH_KEY := null;
end;""", when_button=b2, success='Option saved.')
    p.branch(21, items=[('P21_QUESTION_ID', '&P21_QUESTION_ID.')])
    p.ir('Options', f"""select sort_order, option_text_en, option_text_ar, case is_correct when 'Y' then 'Correct' end is_correct, match_key,
       {link(21, [('P21_QUESTION_ID', 'question_id'), ('P21_OPTION_ID', 'option_id')], "'Edit'", request='EDIT_OPTION', cls='t-Button t-Button--small')} || ' '
       || {link(21, [('P21_QUESTION_ID', 'question_id'), ('P21_OPTION_ID', 'option_id')], "'Remove'", request='REMOVE_OPTION', cls='t-Button t-Button--small')} action
  from v_lms_question_options_edit where question_id = :P21_QUESTION_ID""",
         [('sort_order', '#', 'NUMBER'), ('option_text_en', 'Option'), ('option_text_ar', 'Arabic'), ('is_correct', 'Correct'),
          ('match_key', 'Match key'), ('action', ' ', 'STRING', None, True)], sort='sort_order', icon='fa-list-ol')

    # ---------------------------------------------------------------- 30/31 Grading
    p = Page(a, 30, 'Grading queue', alias='GRADING', auth='LMS_AUTH_GRADE')
    p.ir('Attempts awaiting grading', f"""select quiz_title, learner, submitted_at,
       {link(31, [('P31_ATTEMPT_ID', 'attempt_id')], "'Grade'", cls='t-Button t-Button--small t-Button--hot')} action
  from v_lms_grading_queue""",
         [('quiz_title', 'Quiz'), ('learner', 'Learner'), ('submitted_at', 'Submitted', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('action', ' ', 'STRING', None, True)], sort='submitted_at', icon='fa-check-square-o')

    p = Page(a, 31, 'Grade attempt', alias='GRADE', auth='LMS_AUTH_GRADE')
    r = p.form('Grade an answer')
    p.item(r, 'P31_ATTEMPT_ID', 'hidden')
    p.item(r, 'P31_QUESTION_ID', 'select', 'Question', required=True,
           lov="select sort_order || '. ' || substr(text_en, 1, 80) d, question_id r from v_lms_grading_detail where attempt_id = :P31_ATTEMPT_ID order by sort_order")
    p.item(r, 'P31_POINTS', 'number', 'Points awarded', required=True)
    p.item(r, 'P31_FEEDBACK', 'textarea', 'Feedback to the learner', maxlen=2000)
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save grade', hot=True)
    p.button(r2, 'BACK', 'Grading queue', action='URL', url='f?p=&APP_ID.:30:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save grade', 'lms_assessment_pkg.grade_response(:P31_ATTEMPT_ID, :P31_QUESTION_ID, :P31_POINTS, :P31_FEEDBACK);',
              when_button=b, success='Grade saved.')
    p.branch(31, items=[('P31_ATTEMPT_ID', '&P31_ATTEMPT_ID.')])
    p.ir('Answers', """select sort_order, question_type, text_en, json_value(answer_json, '$.text') answer_text, answer_json,
       max_points, points_awarded, feedback
  from v_lms_grading_detail where attempt_id = :P31_ATTEMPT_ID""",
         [('sort_order', '#', 'NUMBER'), ('question_type', 'Type'), ('text_en', 'Question'), ('answer_text', 'Answer'),
          ('answer_json', 'Raw answer'), ('max_points', 'Max', 'NUMBER'), ('points_awarded', 'Awarded', 'NUMBER'),
          ('feedback', 'Feedback')], sort='sort_order', icon='fa-pencil')

    # ---------------------------------------------------------------- 40/41/42 Sessions
    p = Page(a, 40, 'Sessions', alias='SESSIONS', auth='LMS_AUTH_SESSION_MANAGE')
    p.ir('Sessions', f"""select {l10n('title', 'title')}, start_ts, end_ts, venue_en, instructor_en, seats, registered, waitlisted, status,
       {link(41, [('P41_SESSION_ID', 'session_id')], "'Open'", cls='t-Button t-Button--small')} || ' '
       || {link(42, [('P42_SESSION_ID', 'session_id')], "'Attendance'", cls='t-Button t-Button--small')} action
  from v_lms_sessions_manage""",
         [('title', 'Course'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('end_ts', 'Ends', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('venue_en', 'Venue'), ('instructor_en', 'Trainer'), ('seats', 'Seats', 'NUMBER'), ('registered', 'Registered', 'NUMBER'),
          ('waitlisted', 'Waiting', 'NUMBER'), ('status', 'Status'), ('action', ' ', 'STRING', None, True)],
         sort='start_ts', desc=True, icon='fa-calendar')
    r = p.buttons()
    p.button(r, 'NEW', 'New session', action='URL', hot=True, icon='fa-plus', url='f?p=&APP_ID.:41:&SESSION.::&DEBUG.:41::')

    p = Page(a, 41, 'Session', alias='SESSION', auth='LMS_AUTH_SESSION_MANAGE')
    r = p.form('Session')
    p.item(r, 'P41_SESSION_ID', 'hidden')
    p.item(r, 'P41_STATUS', 'display', 'Status')
    p.item(r, 'P41_COURSE_ID', 'select', 'Course', required=True,
           lov="select title_en d, course_id r from v_lms_my_courses where delivery_method <> 'SELF_PACED' order by title_en")
    p.item(r, 'P41_VENUE_ID', 'select', 'Venue', lov="select name_en || ' (' || capacity || ')' d, venue_id r from v_lms_lov_venues order by name_en")
    p.item(r, 'P41_MEETING_URL', 'text', 'Meeting link (virtual sessions)', maxlen=1000)
    p.item(r, 'P41_INSTRUCTOR_ID', 'select', 'Trainer', required=True,
           lov='select full_name_en d, user_id r from v_lms_lov_instructors order by full_name_en')
    p.item(r, 'P41_START_TS', 'datetime', 'Starts', required=True)
    p.item(r, 'P41_END_TS', 'datetime', 'Ends', required=True)
    p.item(r, 'P41_SEATS', 'number', 'Seats', required=True)
    p.item(r, 'P41_MIN_ATTENDANCE_PCT', 'number', 'Minimum attendance (%)', default='80')
    p.item(r, 'P41_REASON', 'text', 'Reason (when cancelling)', maxlen=500)
    p.process('Load', """if :P41_SESSION_ID is not null and :REQUEST is null then
  select course_id, meeting_url, instructor_id, to_char(start_ts, 'DD-MON-YYYY HH24:MI'), to_char(end_ts, 'DD-MON-YYYY HH24:MI'),
         seats, min_attendance_pct, status
    into :P41_COURSE_ID, :P41_MEETING_URL, :P41_INSTRUCTOR_ID, :P41_START_TS, :P41_END_TS, :P41_SEATS,
         :P41_MIN_ATTENDANCE_PCT, :P41_STATUS
    from v_lms_sessions_manage where session_id = :P41_SESSION_ID;
end if;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b_save = p.button(r2, 'SAVE', 'Save', hot=True)
    exists = lambda st: f"select 1 from v_lms_sessions_manage where session_id = :P41_SESSION_ID and status in ({st})"
    b_pub = p.button(r2, 'PUBLISH', 'Publish', cond_exists=exists("'SCHEDULED'"))
    b_res = p.button(r2, 'RESCHEDULE', 'Reschedule to the times above', cond_exists=exists("'SCHEDULED','PUBLISHED'"))
    b_can = p.button(r2, 'CANCEL_SESSION', 'Cancel session', cond_exists=exists("'SCHEDULED','PUBLISHED'"),
                     confirm='Cancel this session? Registered learners and the trainer are notified.')
    b_cmp = p.button(r2, 'COMPLETE', 'Complete session',
                     cond_exists="select 1 from v_lms_sessions_manage where session_id = :P41_SESSION_ID and status = 'PUBLISHED' and end_ts < systimestamp")
    p.button(r2, 'BACK', 'Sessions', action='URL', url='f?p=&APP_ID.:40:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save', """if :P41_SESSION_ID is null then
  :P41_SESSION_ID := lms_session_pkg.create_session(:P41_COURSE_ID, :P41_VENUE_ID, :P41_INSTRUCTOR_ID,
      to_timestamp_tz(:P41_START_TS || ' ' || sessiontimezone, 'DD-MON-YYYY HH24:MI TZR'),
      to_timestamp_tz(:P41_END_TS || ' ' || sessiontimezone, 'DD-MON-YYYY HH24:MI TZR'),
      :P41_SEATS, :P41_MEETING_URL, :P41_MIN_ATTENDANCE_PCT);
else
  lms_session_pkg.update_session(:P41_SESSION_ID, :P41_VENUE_ID, :P41_INSTRUCTOR_ID, :P41_SEATS, :P41_MEETING_URL, :P41_MIN_ATTENDANCE_PCT);
end if;""", when_button=b_save, success='Session saved.')
    p.process('Publish', 'lms_session_pkg.publish_session(:P41_SESSION_ID);', when_button=b_pub, success='Session published.')
    p.process('Reschedule', """lms_session_pkg.reschedule(:P41_SESSION_ID,
  to_timestamp_tz(:P41_START_TS || ' ' || sessiontimezone, 'DD-MON-YYYY HH24:MI TZR'),
  to_timestamp_tz(:P41_END_TS || ' ' || sessiontimezone, 'DD-MON-YYYY HH24:MI TZR'));""", when_button=b_res,
              success='Session rescheduled.')
    p.process('Cancel session', 'lms_session_pkg.cancel_session(:P41_SESSION_ID, :P41_REASON);', when_button=b_can,
              success='Session cancelled.')
    p.process('Complete session', 'lms_session_pkg.complete_session(:P41_SESSION_ID);', when_button=b_cmp,
              success='Session completed.')
    p.branch(41, items=[('P41_SESSION_ID', '&P41_SESSION_ID.')])

    p = Page(a, 42, 'Attendance', alias='ATTENDANCE', auth='LMS_AUTH_SESSION_MANAGE')
    r = p.form('Record attendance')
    p.item(r, 'P42_SESSION_ID', 'hidden')
    p.item(r, 'P42_SESSION_ENROLLMENT_ID', 'select', 'Learner', required=True,
           lov="select full_name_en d, session_enrollment_id r from v_lms_session_roster where session_id = :P42_SESSION_ID and status = 'REGISTERED' order by full_name_en")
    p.item(r, 'P42_DAY', 'date', 'Day', required=True)
    p.item(r, 'P42_STATUS', 'select', 'Attendance', required=True, lov='STATIC:Present;PRESENT,Absent;ABSENT,Late;LATE,Excused;EXCUSED')
    r2 = p.buttons()
    b = p.button(r2, 'SAVE', 'Save attendance', hot=True)
    p.button(r2, 'BACK', 'Sessions', action='URL', url='f?p=&APP_ID.:40:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save attendance', "lms_session_pkg.record_attendance(:P42_SESSION_ENROLLMENT_ID, to_date(:P42_DAY, 'DD-MON-YYYY'), :P42_STATUS);",
              when_button=b, success='Attendance saved.')
    p.branch(42, items=[('P42_SESSION_ID', '&P42_SESSION_ID.')])
    p.ir('Roster', """select full_name_en, status, registered_at from v_lms_session_roster where session_id = :P42_SESSION_ID""",
         [('full_name_en', 'Learner'), ('status', 'Registration'), ('registered_at', 'Registered', 'DATE', 'DD-MON-YYYY HH24:MI')],
         icon='fa-users')

    # ---------------------------------------------------------------- 50 Learner progress
    p = Page(a, 50, 'Learner progress', alias='PROGRESS', auth='LMS_AUTH_INSTRUCTOR')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P50_ENROLLMENT_ID', 'hidden')
    p.process('Approve completion', 'lms_progress_pkg.approve_completion(:P50_ENROLLMENT_ID);', point='BEFORE_HEADER',
              when_request='APPROVE', success='Completion approved.')
    p.ir('Learners in my courses', f"""select l.full_name_en, l.department_en, c.title_en course, l.status, l.progress_pct, l.best_score,
       round(l.time_spent_sec / 60) minutes, l.last_activity_at, l.completed_at,
       case when c.completion_rule = 'INSTRUCTOR_APPROVAL' and l.status = 'IN_PROGRESS' and l.instructor_approved_flag = 'N'
            then {link(50, [('P50_ENROLLMENT_ID', 'l.enrollment_id')], "'Approve completion'", request='APPROVE', cls='t-Button t-Button--small')} end action
  from v_lms_course_learners l join v_lms_my_courses c on c.course_id = l.course_id""",
         [('full_name_en', 'Learner'), ('department_en', 'Department'), ('course', 'Course'), ('status', 'Status'),
          ('progress_pct', 'Progress %', 'NUMBER'), ('best_score', 'Best score', 'NUMBER'), ('minutes', 'Minutes', 'NUMBER'),
          ('last_activity_at', 'Last activity', 'DATE', 'DD-MON-YYYY HH24:MI'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY'),
          ('action', ' ', 'STRING', None, True)], sort='last_activity_at', desc=True, icon='fa-users')

    # ---------------------------------------------------------------- 51 Course feedback
    p = Page(a, 51, 'Course feedback', alias='FEEDBACK', auth='LMS_AUTH_INSTRUCTOR')
    p.ir('Ratings', """select course_en, reviews, avg_course_rating, avg_instructor_rating from v_lms_course_review_summary""",
         [('course_en', 'Course'), ('reviews', 'Reviews', 'NUMBER'), ('avg_course_rating', 'Course rating', 'NUMBER', '0.0'),
          ('avg_instructor_rating', 'Instructor rating', 'NUMBER', '0.0')], icon='fa-star')
    p.ir('Questionnaire results', """select course_en, sort_order, question_en, responses, avg_rating, favourable, unfavourable
  from v_lms_course_feedback_summary""",
         [('course_en', 'Course'), ('sort_order', '#', 'NUMBER'), ('question_en', 'Question'), ('responses', 'Responses', 'NUMBER'),
          ('avg_rating', 'Average', 'NUMBER', '0.0'), ('favourable', 'Favourable', 'NUMBER'), ('unfavourable', 'Unfavourable', 'NUMBER')],
         icon='fa-bar-chart')
    p.ir('Comments', """select course_id, source, comment_month, comment_text from v_lms_course_feedback_comments""",
         [('course_id', 'Course id', 'NUMBER'), ('source', 'Source'), ('comment_month', 'Month'), ('comment_text', 'Comment')],
         icon='fa-comments')
    return a
