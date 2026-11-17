"""App 220 - LMS Administration (03_APEX/PAGE_SPECIFICATIONS/app220_administration.md)."""
from engine import Page, l10n
from common import new_app, link

BTN = 't-Button t-Button--small'


def build(base):
    a = new_app(220, 'lms-admin', 'LMS Administration', base,
                schemes=('LMS_AUTH_TRAINING_ADMIN', 'LMS_AUTH_APPROVER', 'LMS_AUTH_ENROLL_ASSIGN', 'LMS_AUTH_SESSION_MANAGE',
                         'LMS_AUTH_CERT_POLICY', 'LMS_AUTH_SYSADMIN', 'LMS_AUTH_ROLE_ADMIN', 'LMS_AUTH_SETTINGS',
                         'LMS_AUTH_AUDIT', 'LMS_AUTH_RATELIMIT', 'LMS_AUTH_TEMPLATES', 'LMS_AUTH_LEARNER'))
    a.nav = [
        ('Dashboard', 1, 'fa-home', None, '1'),
        ('Courses', 10, 'fa-book', 'LMS_AUTH_TRAINING_ADMIN', '10,11'),
        ('Approvals', 12, 'fa-check', 'LMS_AUTH_APPROVER', '12,13'),
        ('Reviews', 14, 'fa-star', 'LMS_AUTH_TRAINING_ADMIN', '14'),
        ('Feedback forms', 15, 'fa-comments', 'LMS_AUTH_TRAINING_ADMIN', '15'),
        ('Enrollments', 20, 'fa-users', 'LMS_AUTH_ENROLL_ASSIGN', '20,21'),
        ('Mandatory assignments', 25, 'fa-tasks', 'LMS_AUTH_ENROLL_ASSIGN', '25,26'),
        ('Training schedule', 30, 'fa-calendar', 'LMS_AUTH_SESSION_MANAGE', '30'),
        ('Venues', 31, 'fa-building', 'LMS_AUTH_SESSION_MANAGE', '31'),
        ('Certificates', 40, 'fa-certificate', 'LMS_AUTH_CERT_POLICY', '40,41,42'),
        ('Categories', 50, 'fa-folder', 'LMS_AUTH_TRAINING_ADMIN', '50'),
        ('System settings', 60, 'fa-sliders', 'LMS_AUTH_SETTINGS', '60'),
        ('Notification templates', 61, 'fa-envelope', 'LMS_AUTH_TEMPLATES', '61'),
        ('Users', 70, 'fa-user', 'LMS_AUTH_SYSADMIN', '70,71'),
        ('Roles and permissions', 73, 'fa-key', 'LMS_AUTH_ROLE_ADMIN', '73'),
        ('Audit log', 80, 'fa-history', 'LMS_AUTH_AUDIT', '80'),
        ('Security events', 81, 'fa-shield', 'LMS_AUTH_AUDIT', '81'),
        ('Integration log', 82, 'fa-exchange', 'LMS_AUTH_AUDIT', '82'),
        ('Rate limits', 90, 'fa-tachometer', 'LMS_AUTH_RATELIMIT', '90'),
        ('Monitoring', 95, 'fa-heartbeat', 'LMS_AUTH_AUDIT', '95'),
        ('Learning portal', 'f?p=200:1:&SESSION.', 'fa-graduation-cap', 'LMS_AUTH_LEARNER', None),
    ]

    # ---------------------------------------------------------------- 1 Dashboard
    p = Page(a, 1, 'Administration', alias='HOME', auth='LMS_AUTH_ACTIVE')
    p.ir('Courses', """select course_code, title_en, status, enrolled, completed, completion_pct, avg_score, avg_rating, refreshed_at
  from v_lms_exec_courses""",
         [('course_code', 'Code'), ('title_en', 'Course'), ('status', 'Status'), ('enrolled', 'Enrolled', 'NUMBER'),
          ('completed', 'Completed', 'NUMBER'), ('completion_pct', 'Completion %', 'NUMBER'), ('avg_score', 'Avg score', 'NUMBER'),
          ('avg_rating', 'Rating', 'NUMBER', '0.0'), ('refreshed_at', 'Refreshed', 'DATE', 'DD-MON-YYYY HH24:MI')],
         sort='enrolled', desc=True, icon='fa-book')
    p.ir('Notification queue', 'select status, cnt, oldest_due, max_attempts from v_lms_queue_status',
         [('status', 'Status'), ('cnt', 'Count', 'NUMBER'), ('oldest_due', 'Oldest due', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('max_attempts', 'Max attempts', 'NUMBER')], icon='fa-envelope')
    p.ir('Scheduled jobs', 'select job_name, enabled, state, last_status, last_start_date, next_run_date from v_lms_job_status',
         [('job_name', 'Job'), ('enabled', 'Enabled'), ('state', 'State'), ('last_status', 'Last result'),
          ('last_start_date', 'Last run', 'DATE', 'DD-MON-YYYY HH24:MI'), ('next_run_date', 'Next run', 'DATE', 'DD-MON-YYYY HH24:MI')],
         icon='fa-clock-o')

    # ---------------------------------------------------------------- 10/11 Courses
    p = Page(a, 10, 'Courses', alias='COURSES', auth='LMS_AUTH_TRAINING_ADMIN')
    p.ir('All courses', f"""select course_code, {link(11, [('P11_COURSE_ID', 'course_id')], 'title_en')} title, category_en, status,
       delivery_method, active_learners, pending_grading, updated_at
  from v_lms_my_courses""",
         [('course_code', 'Code'), ('title', 'Course', 'STRING', None, True), ('category_en', 'Category'), ('status', 'Status'),
          ('delivery_method', 'Delivery'), ('active_learners', 'Active learners', 'NUMBER'), ('pending_grading', 'Grading', 'NUMBER'),
          ('updated_at', 'Updated', 'DATE', 'DD-MON-YYYY HH24:MI')], sort='updated_at', desc=True, icon='fa-book')

    p = Page(a, 11, 'Course administration', alias='COURSE', auth='LMS_AUTH_TRAINING_ADMIN')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P11_COURSE_ID', 'hidden')
    p.plsql('Course', """for c in (select * from v_lms_my_courses where course_id = :P11_COURSE_ID) loop
  htp.p('<h1>' || apex_escape.html(c.course_code || ' - ' || c.title_en) || '</h1><p>Status: <strong>' || apex_escape.html(c.status)
     || '</strong> &middot; Active learners: ' || nvl(c.active_learners, 0) || '</p>'
     || '<p>To change the content, open the course in the Instructor portal (My courses).</p>');
end loop;""")
    r = p.buttons()
    st = lambda s: f"select 1 from v_lms_my_courses where course_id = :P11_COURSE_ID and status in ({s})"
    b1 = p.button(r, 'SUSPEND', 'Suspend', cond_exists=st("'PUBLISHED'"), confirm='Suspend this course? Learners cannot open it while suspended.')
    b2 = p.button(r, 'REINSTATE', 'Reinstate', cond_exists=st("'SUSPENDED'"))
    b3 = p.button(r, 'ARCHIVE', 'Archive', cond_exists=st("'DRAFT','SUSPENDED','PUBLISHED'"), confirm='Archive this course? History is kept.')
    p.button(r, 'BACK', 'Courses', action='URL', url='f?p=&APP_ID.:10:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Suspend', 'lms_course_pkg.suspend(:P11_COURSE_ID);', when_button=b1, success='Course suspended.')
    p.process('Reinstate', 'lms_course_pkg.reinstate(:P11_COURSE_ID);', when_button=b2, success='Course reinstated.')
    p.process('Archive', 'lms_course_pkg.archive(:P11_COURSE_ID);', when_button=b3, success='Course archived.')
    p.branch(11, items=[('P11_COURSE_ID', '&P11_COURSE_ID.')])
    p.ir('Learners', """select full_name_en, department_en, status, progress_pct, last_activity_at, completed_at
  from v_lms_course_learners where course_id = :P11_COURSE_ID""",
         [('full_name_en', 'Learner'), ('department_en', 'Department'), ('status', 'Status'), ('progress_pct', 'Progress %', 'NUMBER'),
          ('last_activity_at', 'Last activity', 'DATE', 'DD-MON-YYYY HH24:MI'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY')],
         icon='fa-users')

    # ---------------------------------------------------------------- 12/13 Approvals
    p = Page(a, 12, 'Approvals', alias='APPROVALS', auth='LMS_AUTH_APPROVER')
    p.ir('Waiting for my decision', f"""select request_type, item_en, requester_en, requested_at, due_at,
       case overdue_flag when 'Y' then 'Overdue' end overdue, escalation_count,
       {link(13, [('P13_APPROVAL_ID', 'approval_id')], "'Decide'", cls=BTN + ' t-Button--hot')} action
  from v_lms_approvals_inbox""",
         [('request_type', 'Type'), ('item_en', 'Item'), ('requester_en', 'Requested by'),
          ('requested_at', 'Requested', 'DATE', 'DD-MON-YYYY HH24:MI'), ('due_at', 'Due', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('overdue', 'Overdue'), ('escalation_count', 'Escalations', 'NUMBER'), ('action', ' ', 'STRING', None, True)],
         sort='due_at', icon='fa-check')
    decide_page(a, 13, 12, 'LMS_AUTH_APPROVER')

    # ---------------------------------------------------------------- 14 Reviews moderation
    p = Page(a, 14, 'Reviews', alias='REVIEWS', auth='LMS_AUTH_TRAINING_ADMIN')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P14_REVIEW_ID', 'hidden')
    p.process('Hide', 'lms_feedback_pkg.set_review_visibility(:P14_REVIEW_ID, false);', point='BEFORE_HEADER',
              when_request='HIDE', success='Review hidden.')
    p.process('Show', 'lms_feedback_pkg.set_review_visibility(:P14_REVIEW_ID, true);', point='BEFORE_HEADER',
              when_request='SHOW', success='Review visible.')
    p.ir('Reviews', f"""select course_en, course_rating, instructor_rating, review_text, status, created_at,
       case when status = 'HIDDEN'
            then {link(14, [('P14_REVIEW_ID', 'review_id')], "'Show'", request='SHOW', cls=BTN)}
            else {link(14, [('P14_REVIEW_ID', 'review_id')], "'Hide'", request='HIDE', cls=BTN)} end action
  from v_lms_reviews_moderation""",
         [('course_en', 'Course'), ('course_rating', 'Course', 'NUMBER'), ('instructor_rating', 'Instructor', 'NUMBER'),
          ('review_text', 'Review'), ('status', 'Status'), ('created_at', 'Date', 'DATE', 'DD-MON-YYYY'),
          ('action', ' ', 'STRING', None, True)], sort='created_at', desc=True, icon='fa-star')

    # ---------------------------------------------------------------- 15 Feedback forms
    p = Page(a, 15, 'Feedback forms', alias='FORMS', auth='LMS_AUTH_TRAINING_ADMIN')
    r = p.form('Form')
    p.item(r, 'P15_FORM_ID', 'hidden')
    p.item(r, 'P15_NAME_EN', 'text', 'Name (English)', maxlen=200)
    p.item(r, 'P15_NAME_AR', 'text', 'Name (Arabic)', maxlen=200)
    p.item(r, 'P15_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load form', """if :P15_FORM_ID is not null and :REQUEST = 'EDIT_FORM' then
  select name_en, name_ar, active_flag into :P15_NAME_EN, :P15_NAME_AR, :P15_ACTIVE from v_lms_feedback_forms_admin where form_id = :P15_FORM_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Clone form', ':P15_FORM_ID := lms_feedback_pkg.clone_form(:P15_FORM_ID);', point='BEFORE_HEADER',
              when_request='CLONE', success='Form copied.')
    bf = p.button(r, 'SAVE_FORM', 'Save form', hot=True)
    p.process('Save form', ":P15_FORM_ID := lms_feedback_pkg.save_form(:P15_FORM_ID, :P15_NAME_EN, :P15_NAME_AR, nvl(:P15_ACTIVE, 'Y'));",
              when_button=bf, success='Form saved.')
    q = p.form('Question of the selected form')
    p.item(q, 'P15_QUESTION_ID', 'hidden')
    p.item(q, 'P15_Q_TEXT_EN', 'text', 'Question (English)', maxlen=1000)
    p.item(q, 'P15_Q_TEXT_AR', 'text', 'Question (Arabic)', maxlen=1000)
    p.item(q, 'P15_Q_TYPE', 'select', 'Answer type', lov='STATIC:Rating 1-5;RATING,Text;TEXT', default='RATING')
    p.item(q, 'P15_Q_SORT', 'number', 'Order', default='10')
    p.process('Load question', """if :P15_QUESTION_ID is not null and :REQUEST = 'EDIT_Q' then
  select text_en, text_ar, answer_type, sort_order into :P15_Q_TEXT_EN, :P15_Q_TEXT_AR, :P15_Q_TYPE, :P15_Q_SORT
    from v_lms_feedback_questions_admin where question_id = :P15_QUESTION_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Remove question', 'lms_feedback_pkg.remove_form_question(:P15_QUESTION_ID);\n:P15_QUESTION_ID := null;',
              point='BEFORE_HEADER', when_request='REMOVE_Q', success='Question removed.')
    bq = p.button(q, 'SAVE_Q', 'Save question', cond_exists='select 1 from dual where :P15_FORM_ID is not null')
    p.process('Save question', """:P15_QUESTION_ID := lms_feedback_pkg.save_form_question(:P15_QUESTION_ID, :P15_FORM_ID, :P15_Q_TEXT_EN,
                                                       :P15_Q_TEXT_AR, :P15_Q_TYPE, :P15_Q_SORT);
:P15_QUESTION_ID := null;""", when_button=bq, success='Question saved.')
    p.branch(15, items=[('P15_FORM_ID', '&P15_FORM_ID.')])
    p.ir('Forms', f"""select name_en, name_ar, active_flag, questions, courses_using, responses,
       {link(15, [('P15_FORM_ID', 'form_id')], "'Edit'", request='EDIT_FORM', cls=BTN)} || ' '
       || {link(15, [('P15_FORM_ID', 'form_id')], "'Copy'", request='CLONE', cls=BTN)} action
  from v_lms_feedback_forms_admin""",
         [('name_en', 'Form'), ('name_ar', 'Arabic name'), ('active_flag', 'Active'), ('questions', 'Questions', 'NUMBER'),
          ('courses_using', 'Courses', 'NUMBER'), ('responses', 'Responses', 'NUMBER'), ('action', ' ', 'STRING', None, True)],
         icon='fa-comments')
    p.ir('Questions', f"""select sort_order, text_en, text_ar, answer_type, responses,
       {link(15, [('P15_FORM_ID', 'form_id'), ('P15_QUESTION_ID', 'question_id')], "'Edit'", request='EDIT_Q', cls=BTN)} || ' '
       || {link(15, [('P15_FORM_ID', 'form_id'), ('P15_QUESTION_ID', 'question_id')], "'Remove'", request='REMOVE_Q', cls=BTN)} action
  from v_lms_feedback_questions_admin where form_id = :P15_FORM_ID""",
         [('sort_order', '#', 'NUMBER'), ('text_en', 'Question'), ('text_ar', 'Arabic'), ('answer_type', 'Type'),
          ('responses', 'Responses', 'NUMBER'), ('action', ' ', 'STRING', None, True)], sort='sort_order', icon='fa-list')

    # ---------------------------------------------------------------- 20/21 Enrollments
    p = Page(a, 20, 'Enrollments', alias='ENROLLMENTS', auth='LMS_AUTH_ENROLL_ASSIGN')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P20_ENROLLMENT_ID', 'hidden')
    p.process('Cancel enrollment', 'lms_enrollment_pkg.cancel(:P20_ENROLLMENT_ID);', point='BEFORE_HEADER',
              when_request='CANCEL', success='Enrollment cancelled.')
    p.ir('Enrollments', f"""select full_name_en, department_en, course_code, course_title_en, status, enrollment_type, due_date,
       progress_pct, case overdue_flag when 'Y' then 'Overdue' end overdue, completed_at,
       case when status in ('PENDING','WAITLISTED','APPROVED','ENROLLED','IN_PROGRESS')
            then {link(20, [('P20_ENROLLMENT_ID', 'enrollment_id')], "'Cancel'", request='CANCEL', cls=BTN)} end action
  from v_lms_team_enrollments""",
         [('full_name_en', 'Learner'), ('department_en', 'Department'), ('course_code', 'Code'), ('course_title_en', 'Course'),
          ('status', 'Status'), ('enrollment_type', 'Type'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'),
          ('progress_pct', 'Progress %', 'NUMBER'), ('overdue', 'Overdue'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY'),
          ('action', ' ', 'STRING', None, True)], icon='fa-users')
    r = p.buttons()
    p.button(r, 'ASSIGN', 'Assign a course', action='URL', hot=True, icon='fa-plus', url='f?p=&APP_ID.:21:&SESSION.::&DEBUG.:21::')

    p = Page(a, 21, 'Assign a course', alias='ASSIGN', auth='LMS_AUTH_ENROLL_ASSIGN')
    assign_form(p, 21, back=20)

    # ---------------------------------------------------------------- 25/26 Mandatory assignments
    p = Page(a, 25, 'Mandatory assignments', alias='ASSIGNMENTS', auth='LMS_AUTH_ENROLL_ASSIGN')
    h = p.form('State', template='reg_blank')
    p.item(h, 'P25_ASSIGNMENT_ID', 'hidden')
    p.process('Close assignment', 'lms_enrollment_pkg.close_assignment(:P25_ASSIGNMENT_ID);', point='BEFORE_HEADER',
              when_request='CLOSE', success='Assignment closed. Existing enrollments are kept.')
    p.ir('Assignments', f"""select course_en, target_type, target_en, due_date, status, enrolled, completed,
       case when enrolled > 0 then round(100 * completed / enrolled) end pct_complete, created_at,
       case when status = 'ACTIVE' then {link(25, [('P25_ASSIGNMENT_ID', 'assignment_id')], "'Close'", request='CLOSE', cls=BTN)} end action
  from v_lms_assignments_admin""",
         [('course_en', 'Course'), ('target_type', 'Target'), ('target_en', 'Who'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'),
          ('status', 'Status'), ('enrolled', 'Enrolled', 'NUMBER'), ('completed', 'Completed', 'NUMBER'),
          ('pct_complete', '% complete', 'NUMBER'), ('created_at', 'Created', 'DATE', 'DD-MON-YYYY'),
          ('action', ' ', 'STRING', None, True)], sort='created_at', desc=True, icon='fa-tasks')
    r = p.buttons()
    p.button(r, 'NEW', 'New assignment', action='URL', hot=True, icon='fa-plus', url='f?p=&APP_ID.:26:&SESSION.::&DEBUG.:26::')

    p = Page(a, 26, 'New mandatory assignment', alias='NEW-ASSIGNMENT', auth='LMS_AUTH_ENROLL_ASSIGN')
    r = p.form('Assignment')
    p.item(r, 'P26_COURSE_ID', 'select', 'Course', required=True,
           lov="select title_en d, course_id r from v_lms_catalog order by title_en")
    p.item(r, 'P26_TARGET_TYPE', 'select', 'Assign to', required=True, lov='STATIC:Department;DEPARTMENT,Position;POSITION')
    p.item(r, 'P26_DEPARTMENT_ID', 'select', 'Department', lov='select name_en d, department_id r from v_lms_lov_departments order by name_en')
    p.item(r, 'P26_POSITION_ID', 'select', 'Position', lov='select job_title_en d, position_id r from v_lms_lov_positions order by job_title_en')
    p.item(r, 'P26_DUE_DATE', 'date', 'Due date', required=True)
    r2 = p.buttons()
    b = p.button(r2, 'CREATE', 'Create assignment', hot=True)
    p.button(r2, 'BACK', 'Cancel', action='URL', url='f?p=&APP_ID.:25:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Create assignment', """declare l number;
begin
  l := lms_enrollment_pkg.create_assignment(:P26_COURSE_ID, :P26_TARGET_TYPE,
         case :P26_TARGET_TYPE when 'DEPARTMENT' then :P26_DEPARTMENT_ID else :P26_POSITION_ID end,
         to_date(:P26_DUE_DATE, 'DD-MON-YYYY'));
end;""", when_button=b, success='Assignment created. People in the group are enrolled now and as they join.')
    p.branch(25)

    # ---------------------------------------------------------------- 30 Schedule, 31 Venues
    p = Page(a, 30, 'Training schedule', alias='SCHEDULE', auth='LMS_AUTH_SESSION_MANAGE')
    p.ir('Sessions', f"""select {l10n('title', 'title')}, start_ts, end_ts, venue_en, instructor_en, seats, registered, waitlisted, status,
       session_id
  from v_lms_sessions_manage""",
         [('title', 'Course'), ('start_ts', 'Starts', 'DATE', 'DD-MON-YYYY HH24:MI'), ('end_ts', 'Ends', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('venue_en', 'Venue'), ('instructor_en', 'Trainer'), ('seats', 'Seats', 'NUMBER'), ('registered', 'Registered', 'NUMBER'),
          ('waitlisted', 'Waiting', 'NUMBER'), ('status', 'Status'), ('session_id', 'Session id', 'NUMBER')],
         sort='start_ts', desc=True, icon='fa-calendar')
    p.static('Manage sessions', '<p>Create, publish, edit, cancel and record attendance in the Instructor portal: '
             '<a href="f?p=210:40:&SESSION.">Sessions</a>.</p>')

    p = Page(a, 31, 'Venues', alias='VENUES', auth='LMS_AUTH_SESSION_MANAGE')
    r = p.form('Venue')
    p.item(r, 'P31_VENUE_ID', 'hidden')
    p.item(r, 'P31_NAME_EN', 'text', 'Name (English)', required=True, maxlen=200)
    p.item(r, 'P31_NAME_AR', 'text', 'Name (Arabic)', maxlen=200)
    p.item(r, 'P31_ADDRESS', 'text', 'Address', maxlen=500)
    p.item(r, 'P31_CAPACITY', 'number', 'Capacity', required=True)
    p.item(r, 'P31_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P31_VENUE_ID is not null and :REQUEST = 'EDIT' then
  select name_en, name_ar, address, capacity, active_flag into :P31_NAME_EN, :P31_NAME_AR, :P31_ADDRESS, :P31_CAPACITY, :P31_ACTIVE
    from v_lms_venues_admin where venue_id = :P31_VENUE_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Remove', 'lms_session_pkg.remove_venue(:P31_VENUE_ID);\n:P31_VENUE_ID := null;', point='BEFORE_HEADER',
              when_request='REMOVE', success='Venue removed.')
    b = p.button(r, 'SAVE', 'Save venue', hot=True)
    p.process('Save venue', """:P31_VENUE_ID := lms_session_pkg.save_venue(:P31_VENUE_ID, :P31_NAME_EN, :P31_NAME_AR, :P31_ADDRESS,
                                           :P31_CAPACITY, nvl(:P31_ACTIVE, 'Y'));""", when_button=b, success='Venue saved.')
    p.branch(31)
    p.ir('Venues', f"""select name_en, name_ar, address, capacity, active_flag, sessions_upcoming, max_upcoming_seats, sessions_total,
       {link(31, [('P31_VENUE_ID', 'venue_id')], "'Edit'", request='EDIT', cls=BTN)}
       || case when sessions_total = 0 then ' ' || {link(31, [('P31_VENUE_ID', 'venue_id')], "'Remove'", request='REMOVE', cls=BTN)} end action
  from v_lms_venues_admin""",
         [('name_en', 'Venue'), ('name_ar', 'Arabic name'), ('address', 'Address'), ('capacity', 'Capacity', 'NUMBER'),
          ('active_flag', 'Active'), ('sessions_upcoming', 'Upcoming sessions', 'NUMBER'),
          ('max_upcoming_seats', 'Largest upcoming', 'NUMBER'), ('sessions_total', 'All sessions', 'NUMBER'),
          ('action', ' ', 'STRING', None, True)], icon='fa-building')

    # ---------------------------------------------------------------- 40/41/42 Certificates
    p = Page(a, 40, 'Certificates', alias='CERTIFICATES', auth='LMS_AUTH_CERT_POLICY')
    p.ir('Issued certificates', f"""select certificate_no, full_name_en, title_en, issued_at, expires_at, status, revoked_reason,
       case when status = 'VALID' then {link(41, [('P41_CERTIFICATE_ID', 'certificate_id')], "'Revoke'", cls=BTN)} end action
  from v_lms_certificates_admin""",
         [('certificate_no', 'Number'), ('full_name_en', 'Holder'), ('title_en', 'Title'), ('issued_at', 'Issued', 'DATE', 'DD-MON-YYYY'),
          ('expires_at', 'Expires', 'DATE', 'DD-MON-YYYY'), ('status', 'Status'), ('revoked_reason', 'Revocation reason'),
          ('action', ' ', 'STRING', None, True)], sort='issued_at', desc=True, icon='fa-certificate')
    r = p.buttons()
    p.button(r, 'TEMPLATES', 'Certificate templates', action='URL', url='f?p=&APP_ID.:42:&SESSION.::&DEBUG.:::')

    p = Page(a, 41, 'Revoke certificate', alias='REVOKE', auth='LMS_AUTH_CERT_POLICY')
    r = p.form('Revoke')
    p.item(r, 'P41_CERTIFICATE_ID', 'hidden')
    p.item(r, 'P41_CERT', 'display', 'Certificate')
    p.item(r, 'P41_REASON', 'textarea', 'Reason (at least 5 characters)', required=True, maxlen=500)
    p.process('Load', """select certificate_no || ' - ' || full_name_en || ' - ' || title_en into :P41_CERT
  from v_lms_certificates_admin where certificate_id = :P41_CERTIFICATE_ID;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b = p.button(r2, 'REVOKE', 'Revoke', hot=True, confirm='Revoke this certificate? It will no longer verify as valid.')
    p.button(r2, 'BACK', 'Cancel', action='URL', url='f?p=&APP_ID.:40:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Revoke', 'lms_certification_pkg.revoke(:P41_CERTIFICATE_ID, :P41_REASON);', when_button=b,
              success='Certificate revoked.')
    p.branch(40)

    p = Page(a, 42, 'Certificate templates', alias='CERT-TEMPLATES', auth='LMS_AUTH_CERT_POLICY')
    r = p.form('Template')
    p.item(r, 'P42_TEMPLATE_ID', 'hidden')
    p.item(r, 'P42_CODE', 'text', 'Code', required=True, maxlen=30)
    p.item(r, 'P42_NAME_EN', 'text', 'Name (English)', required=True, maxlen=200)
    p.item(r, 'P42_NAME_AR', 'text', 'Name (Arabic)', maxlen=200)
    p.item(r, 'P42_VALIDITY', 'number', 'Validity (months, empty = no expiry)')
    p.item(r, 'P42_BODY', 'textarea', 'Certificate text', maxlen=4000)
    p.item(r, 'P42_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P42_TEMPLATE_ID is not null and :REQUEST = 'EDIT' then
  select template_code, name_en, name_ar, validity_months, body_text, active_flag
    into :P42_CODE, :P42_NAME_EN, :P42_NAME_AR, :P42_VALIDITY, :P42_BODY, :P42_ACTIVE
    from v_lms_templates_cert where template_id = :P42_TEMPLATE_ID;
end if;""", point='BEFORE_HEADER')
    b = p.button(r, 'SAVE', 'Save template', hot=True)
    p.process('Save template', """:P42_TEMPLATE_ID := lms_admin_pkg.save_certificate_template(:P42_TEMPLATE_ID, :P42_CODE, :P42_NAME_EN,
                         :P42_NAME_AR, :P42_VALIDITY, :P42_BODY, nvl(:P42_ACTIVE, 'Y'));""", when_button=b, success='Template saved.')
    p.branch(42)
    p.ir('Templates', f"""select template_code, name_en, name_ar, validity_months, active_flag,
       {link(42, [('P42_TEMPLATE_ID', 'template_id')], "'Edit'", request='EDIT', cls=BTN)} action
  from v_lms_templates_cert""",
         [('template_code', 'Code'), ('name_en', 'Name'), ('name_ar', 'Arabic name'), ('validity_months', 'Validity (months)', 'NUMBER'),
          ('active_flag', 'Active'), ('action', ' ', 'STRING', None, True)], icon='fa-file-o')

    # ---------------------------------------------------------------- 50 Categories
    p = Page(a, 50, 'Categories', alias='CATEGORIES', auth='LMS_AUTH_TRAINING_ADMIN')
    r = p.form('Category')
    p.item(r, 'P50_CATEGORY_ID', 'hidden')
    p.item(r, 'P50_PARENT_ID', 'select', 'Parent category', lov='select name_en d, category_id r from v_lms_categories_admin order by name_en')
    p.item(r, 'P50_NAME_EN', 'text', 'Name (English)', required=True, maxlen=200)
    p.item(r, 'P50_NAME_AR', 'text', 'Name (Arabic)', maxlen=200)
    p.item(r, 'P50_SORT', 'number', 'Sort order', default='100')
    p.item(r, 'P50_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P50_CATEGORY_ID is not null and :REQUEST = 'EDIT' then
  select parent_category_id, name_en, name_ar, sort_order, active_flag
    into :P50_PARENT_ID, :P50_NAME_EN, :P50_NAME_AR, :P50_SORT, :P50_ACTIVE
    from v_lms_categories_admin where category_id = :P50_CATEGORY_ID;
end if;""", point='BEFORE_HEADER')
    b = p.button(r, 'SAVE', 'Save category', hot=True)
    p.process('Save category', """:P50_CATEGORY_ID := lms_admin_pkg.save_category(:P50_CATEGORY_ID, :P50_PARENT_ID, :P50_NAME_EN, :P50_NAME_AR,
                                                  :P50_SORT, nvl(:P50_ACTIVE, 'Y'));""", when_button=b, success='Category saved.')
    p.branch(50)
    p.ir('Categories', f"""select c.name_en, c.name_ar, p.name_en parent_en, c.sort_order, c.active_flag,
       {link(50, [('P50_CATEGORY_ID', 'c.category_id')], "'Edit'", request='EDIT', cls=BTN)} action
  from v_lms_categories_admin c left join v_lms_categories_admin p on p.category_id = c.parent_category_id""",
         [('name_en', 'Category'), ('name_ar', 'Arabic name'), ('parent_en', 'Parent'), ('sort_order', 'Order', 'NUMBER'),
          ('active_flag', 'Active'), ('action', ' ', 'STRING', None, True)], sort='sort_order', icon='fa-folder')

    # ---------------------------------------------------------------- 60 Settings, 61 Templates
    p = Page(a, 60, 'System settings', alias='SETTINGS', auth='LMS_AUTH_SETTINGS')
    r = p.form('Change a setting')
    p.item(r, 'P60_KEY', 'select', 'Setting', required=True, lov='select setting_key d, setting_key r from v_lms_settings order by 1')
    p.item(r, 'P60_VALUE', 'text', 'New value', required=True, maxlen=4000,
           placeholder='Never enter passwords, keys or tokens here')
    p.process('Load', """if :P60_KEY is not null and :REQUEST = 'EDIT' then
  select setting_value into :P60_VALUE from v_lms_settings where setting_key = :P60_KEY;
end if;""", point='BEFORE_HEADER')
    b = p.button(r, 'SAVE', 'Save setting', hot=True)
    p.process('Save setting', 'lms_admin_pkg.set_setting(:P60_KEY, :P60_VALUE);', when_button=b, success='Setting saved.')
    p.branch(60)
    p.ir('Settings', f"""select setting_key, setting_value, description, updated_at,
       {link(60, [('P60_KEY', 'setting_key')], "'Edit'", request='EDIT', cls=BTN)} action
  from v_lms_settings""",
         [('setting_key', 'Key'), ('setting_value', 'Value'), ('description', 'Meaning'),
          ('updated_at', 'Changed', 'DATE', 'DD-MON-YYYY HH24:MI'), ('action', ' ', 'STRING', None, True)],
         sort='setting_key', icon='fa-sliders')

    p = Page(a, 61, 'Notification templates', alias='TEMPLATES', auth='LMS_AUTH_TEMPLATES')
    r = p.form('Template')
    p.item(r, 'P61_TEMPLATE_ID', 'hidden')
    p.item(r, 'P61_CODE', 'text', 'Code', required=True, maxlen=50)
    p.item(r, 'P61_LANG', 'select', 'Language', required=True, lov='STATIC:English;en,Arabic;ar')
    p.item(r, 'P61_SUBJECT', 'text', 'Subject', required=True, maxlen=250)
    p.item(r, 'P61_BODY', 'textarea', 'Body (keep {{placeholders}} exactly)', required=True, height=10, maxlen=4000)
    p.item(r, 'P61_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P61_TEMPLATE_ID is not null and :REQUEST = 'EDIT' then
  select template_code, lang, subject, body, active_flag into :P61_CODE, :P61_LANG, :P61_SUBJECT, :P61_BODY, :P61_ACTIVE
    from v_lms_templates_admin where template_id = :P61_TEMPLATE_ID;
end if;""", point='BEFORE_HEADER')
    b = p.button(r, 'SAVE', 'Save template', hot=True)
    p.process('Save template', "lms_admin_pkg.save_template(:P61_CODE, :P61_LANG, :P61_SUBJECT, :P61_BODY, nvl(:P61_ACTIVE, 'Y'));",
              when_button=b, success='Template saved.')
    p.branch(61)
    p.ir('Templates', f"""select template_code, lang, subject, active_flag,
       {link(61, [('P61_TEMPLATE_ID', 'template_id')], "'Edit'", request='EDIT', cls=BTN)} action
  from v_lms_templates_admin""",
         [('template_code', 'Code'), ('lang', 'Language'), ('subject', 'Subject'), ('active_flag', 'Active'),
          ('action', ' ', 'STRING', None, True)], sort='template_code', icon='fa-envelope')

    # ---------------------------------------------------------------- 70/71 Users
    p = Page(a, 70, 'Users', alias='USERS', auth='LMS_AUTH_SYSADMIN')
    p.ir('Users', f"""select {link(71, [('P71_USER_ID', 'user_id')], 'full_name_en')} full_name_en, username, employee_no, email,
       department_en, position_en, manager_en, status, roles
  from v_lms_users_admin""",
         [('full_name_en', 'Name', 'STRING', None, True), ('username', 'Username'), ('employee_no', 'Employee no.'), ('email', 'E-mail'),
          ('department_en', 'Department'), ('position_en', 'Position'), ('manager_en', 'Manager'), ('status', 'Status'),
          ('roles', 'Roles')], sort='full_name_en', icon='fa-user')

    p = Page(a, 71, 'User', alias='USER', auth='LMS_AUTH_SYSADMIN')
    r = p.form('User')
    p.item(r, 'P71_USER_ID', 'hidden')
    for n, lbl in (('P71_NAME', 'Name'), ('P71_USERNAME', 'Username'), ('P71_EMAIL', 'E-mail'), ('P71_DEPARTMENT', 'Department'),
                   ('P71_ROLES', 'Roles')):
        p.item(r, n, 'display', lbl)
    p.item(r, 'P71_STATUS', 'select', 'Status', required=True, lov='STATIC:Active;ACTIVE,Inactive;INACTIVE,Locked;LOCKED')
    p.item(r, 'P71_MANAGER_ID', 'select', 'Manager', lov='select full_name_en d, user_id r from v_lms_lov_users order by full_name_en')
    p.item(r, 'P71_ROLE', 'select', 'Role to grant or revoke', lov='select name_en d, role_code r from v_lms_lov_roles order by name_en')
    p.process('Load', """select full_name_en, username, email, department_en, roles, status, manager_user_id
  into :P71_NAME, :P71_USERNAME, :P71_EMAIL, :P71_DEPARTMENT, :P71_ROLES, :P71_STATUS, :P71_MANAGER_ID
  from v_lms_users_admin where user_id = :P71_USER_ID;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b1 = p.button(r2, 'SAVE', 'Save status and manager', hot=True)
    b2 = p.button(r2, 'GRANT', 'Grant role')
    b3 = p.button(r2, 'REVOKE', 'Revoke role', confirm='Revoke this role from the user?')
    p.button(r2, 'BACK', 'Users', action='URL', url='f?p=&APP_ID.:70:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Save', """lms_user_pkg.set_status(:P71_USER_ID, :P71_STATUS);
lms_user_pkg.set_manager(:P71_USER_ID, :P71_MANAGER_ID);""", when_button=b1, success='User saved.')
    p.process('Grant role', 'lms_user_pkg.grant_role(:P71_USER_ID, :P71_ROLE);', when_button=b2, success='Role granted.')
    p.process('Revoke role', 'lms_user_pkg.revoke_role(:P71_USER_ID, :P71_ROLE);', when_button=b3, success='Role revoked.')
    p.branch(71, items=[('P71_USER_ID', '&P71_USER_ID.')])
    p.ir('Effective permissions', """select permission_code, scope, role_code from v_lms_effective_permissions where user_id = :P71_USER_ID""",
         [('permission_code', 'Permission'), ('scope', 'Scope'), ('role_code', 'From role')], sort='permission_code', icon='fa-key')

    # ---------------------------------------------------------------- 73 Roles and permissions
    p = Page(a, 73, 'Roles and permissions', alias='ROLES', auth='LMS_AUTH_ROLE_ADMIN')
    r = p.form('Change a permission')
    p.item(r, 'P73_ROLE', 'select', 'Role', required=True, lov='select name_en d, role_code r from v_lms_lov_roles order by name_en')
    p.item(r, 'P73_PERMISSION', 'select', 'Permission', required=True,
           lov='select distinct permission_code d, permission_code r from v_lms_role_matrix order by 1')
    p.item(r, 'P73_SCOPE', 'select', 'Scope (empty = remove)', lov='STATIC:All;ALL,Team;TEAM,Own;OWN,Assigned;ASSIGNED')
    b = p.button(r, 'SAVE', 'Save', hot=True)
    p.process('Save', 'lms_admin_pkg.set_role_permission(:P73_ROLE, :P73_PERMISSION, :P73_SCOPE);', when_button=b,
              success='Permission saved.')
    p.branch(73)
    p.ir('Matrix', 'select permission_code, role_code, scope from v_lms_role_matrix',
         [('permission_code', 'Permission'), ('role_code', 'Role'), ('scope', 'Scope')], sort='permission_code', icon='fa-key')

    # ---------------------------------------------------------------- 80/81/82 Logs
    p = Page(a, 80, 'Audit log', alias='AUDIT', auth='LMS_AUTH_AUDIT')
    p.ir('Audit log (last 30 days)', """select event_time, actor, operation, entity_name, entity_id, result, correlation_id, metadata
  from v_lms_audit where event_time > systimestamp - interval '30' day""",
         [('event_time', 'Time', 'DATE', 'DD-MON-YYYY HH24:MI:SS'), ('actor', 'Actor'), ('operation', 'Operation'),
          ('entity_name', 'Entity'), ('entity_id', 'Id', 'NUMBER'), ('result', 'Result'), ('correlation_id', 'Correlation'),
          ('metadata', 'Details')], sort='event_time', desc=True, icon='fa-history')
    p = Page(a, 81, 'Security events', alias='SECURITY', auth='LMS_AUTH_AUDIT')
    p.ir('Security events (last 30 days)', """select event_time, event_type, severity, app_user, operation, subject_key, detail
  from v_lms_security_events_admin where event_time > systimestamp - interval '30' day""",
         [('event_time', 'Time', 'DATE', 'DD-MON-YYYY HH24:MI:SS'), ('event_type', 'Event'), ('severity', 'Severity'),
          ('app_user', 'User'), ('operation', 'Operation'), ('subject_key', 'Subject'), ('detail', 'Detail')],
         sort='event_time', desc=True, icon='fa-shield')
    p = Page(a, 82, 'Integration log', alias='API-LOG', auth='LMS_AUTH_AUDIT')
    p.ir('REST calls (last 7 days)', """select log_time, http_method, route, http_status, duration_ms, subject_key
  from v_lms_api_log_admin where log_time > systimestamp - interval '7' day""",
         [('log_time', 'Time', 'DATE', 'DD-MON-YYYY HH24:MI:SS'), ('http_method', 'Method'), ('route', 'Route'),
          ('http_status', 'Status', 'NUMBER'), ('duration_ms', 'ms', 'NUMBER'), ('subject_key', 'Client')],
         sort='log_time', desc=True, icon='fa-exchange')

    # ---------------------------------------------------------------- 90 Rate limits, 95 Monitoring
    p = Page(a, 90, 'Rate limits', alias='RATE-LIMITS', auth='LMS_AUTH_RATELIMIT')
    r = p.form('Policy')
    p.item(r, 'P90_POLICY_ID', 'select', 'Operation', required=True,
           lov='select operation_name d, policy_id r from v_lms_rate_policies order by 1')
    p.item(r, 'P90_LIMIT', 'number', 'Requests allowed', required=True)
    p.item(r, 'P90_WINDOW', 'number', 'Window (seconds)', required=True)
    p.item(r, 'P90_BURST', 'number', 'Burst limit')
    p.item(r, 'P90_FAIL_MODE', 'select', 'If the limiter fails', required=True, lov='STATIC:Allow;OPEN,Reject;CLOSED')
    p.item(r, 'P90_ENABLED', 'select', 'Enabled', required=True, lov='STATIC:Yes;Y,No;N')
    p.process('Load', """if :P90_POLICY_ID is not null and :REQUEST = 'EDIT' then
  select limit_count, window_seconds, burst_limit, fail_mode, enabled_flag
    into :P90_LIMIT, :P90_WINDOW, :P90_BURST, :P90_FAIL_MODE, :P90_ENABLED
    from v_lms_rate_policies where policy_id = :P90_POLICY_ID;
end if;""", point='BEFORE_HEADER')
    b = p.button(r, 'SAVE', 'Save policy', hot=True)
    p.process('Save policy', 'lms_admin_pkg.set_rate_limit_policy(:P90_POLICY_ID, :P90_LIMIT, :P90_WINDOW, :P90_BURST, :P90_FAIL_MODE, :P90_ENABLED);',
              when_button=b, success='Policy saved.')
    p.branch(90)
    p.ir('Policies', f"""select operation_name, limit_count, window_seconds, burst_limit, fail_mode, enabled_flag, updated_at,
       {link(90, [('P90_POLICY_ID', 'policy_id')], "'Edit'", request='EDIT', cls=BTN)} action
  from v_lms_rate_policies""",
         [('operation_name', 'Operation'), ('limit_count', 'Limit', 'NUMBER'), ('window_seconds', 'Window (s)', 'NUMBER'),
          ('burst_limit', 'Burst', 'NUMBER'), ('fail_mode', 'On failure'), ('enabled_flag', 'Enabled'),
          ('updated_at', 'Changed', 'DATE', 'DD-MON-YYYY HH24:MI'), ('action', ' ', 'STRING', None, True)], icon='fa-tachometer')
    p.ir('Rejected requests (by hour)', 'select hour_start, operation, violations, subjects from v_lms_rate_violations',
         [('hour_start', 'Hour', 'DATE', 'DD-MON-YYYY HH24:MI'), ('operation', 'Operation'), ('violations', 'Rejected', 'NUMBER'),
          ('subjects', 'Distinct clients', 'NUMBER')], sort='hour_start', desc=True, icon='fa-ban')

    p = Page(a, 95, 'Monitoring', alias='MONITORING', auth='LMS_AUTH_AUDIT')
    p.ir('Notification queue', 'select status, cnt, oldest_due, max_attempts from v_lms_queue_status',
         [('status', 'Status'), ('cnt', 'Count', 'NUMBER'), ('oldest_due', 'Oldest due', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('max_attempts', 'Max attempts', 'NUMBER')], icon='fa-envelope')
    p.ir('Failed notifications', 'select queue_id, template_code, recipient, attempts, last_error, created_at from v_lms_queue_failures',
         [('queue_id', 'Id', 'NUMBER'), ('template_code', 'Template'), ('recipient', 'Recipient'), ('attempts', 'Attempts', 'NUMBER'),
          ('last_error', 'Last error'), ('created_at', 'Created', 'DATE', 'DD-MON-YYYY HH24:MI')], sort='created_at', desc=True,
         icon='fa-exclamation-triangle')
    p.ir('Scheduled jobs', 'select job_name, enabled, repeat_interval, state, last_status, last_start_date, next_run_date from v_lms_job_status',
         [('job_name', 'Job'), ('enabled', 'Enabled'), ('repeat_interval', 'Schedule'), ('state', 'State'), ('last_status', 'Last result'),
          ('last_start_date', 'Last run', 'DATE', 'DD-MON-YYYY HH24:MI'), ('next_run_date', 'Next run', 'DATE', 'DD-MON-YYYY HH24:MI')],
         icon='fa-clock-o')
    return a


def decide_page(a, pid, back, auth):
    """Approval decision page (shared by apps 220 and 230)."""
    p = Page(a, pid, 'Decide', alias='DECIDE', auth=auth)
    r = p.form('Request')
    p.item(r, f'P{pid}_APPROVAL_ID', 'hidden')
    p.item(r, f'P{pid}_ITEM', 'display', 'Request')
    p.item(r, f'P{pid}_REQUESTER', 'display', 'Requested by')
    p.item(r, f'P{pid}_NOTE', 'textarea', 'Note (optional)', maxlen=1000)
    p.process('Load', f"""select request_type || ': ' || item_en, requester_en into :P{pid}_ITEM, :P{pid}_REQUESTER
  from v_lms_approvals_inbox where approval_id = :P{pid}_APPROVAL_ID;""", point='BEFORE_HEADER')
    r2 = p.buttons()
    b1 = p.button(r2, 'APPROVE', 'Approve', hot=True)
    b2 = p.button(r2, 'REJECT', 'Reject')
    p.button(r2, 'BACK', 'Back', action='URL', url=f'f?p=&APP_ID.:{back}:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Approve', f"lms_approval_pkg.decide(:P{pid}_APPROVAL_ID, 'APPROVE', :P{pid}_NOTE);", when_button=b1, success='Approved.')
    p.process('Reject', f"lms_approval_pkg.decide(:P{pid}_APPROVAL_ID, 'REJECT', :P{pid}_NOTE);", when_button=b2, success='Rejected.')
    p.branch(back)


def assign_form(p, pid, back, mandatory_switch=False):
    """Assign one person to a course (apps 220 and 230)."""
    r = p.form('Assignment')
    p.item(r, f'P{pid}_USER_ID', 'select', 'Person', required=True,
           lov='select full_name_en || nvl2(employee_no, \' (\' || employee_no || \')\', null) d, user_id r from v_lms_lov_users order by full_name_en')
    p.item(r, f'P{pid}_COURSE_ID', 'select', 'Course', required=True, lov='select title_en d, course_id r from v_lms_catalog order by title_en')
    p.item(r, f'P{pid}_DUE_DATE', 'date', 'Due date')
    if mandatory_switch:
        p.item(r, f'P{pid}_TYPE', 'select', 'Type', required=True, lov='STATIC:Recommended;MANAGER,Mandatory;MANDATORY', default='MANAGER')
    else:
        p.item(r, f'P{pid}_TYPE', 'select', 'Type', required=True, lov='STATIC:Administrative;ADMIN,Mandatory;MANDATORY', default='ADMIN')
    p.item(r, f'P{pid}_ENROLLMENT_ID', 'hidden')
    p.item(r, f'P{pid}_STATUS', 'hidden')
    r2 = p.buttons()
    b = p.button(r2, 'ASSIGN', 'Assign', hot=True)
    p.button(r2, 'BACK', 'Cancel', action='URL', url=f'f?p=&APP_ID.:{back}:&SESSION.::&DEBUG.:::', position='PREVIOUS')
    p.process('Assign', f"""lms_enrollment_pkg.assign(:P{pid}_USER_ID, :P{pid}_COURSE_ID, to_date(:P{pid}_DUE_DATE, 'DD-MON-YYYY'),
                          :P{pid}_TYPE, :P{pid}_ENROLLMENT_ID, :P{pid}_STATUS);""", when_button=b,
              success='Course assigned. The person has been notified.')
    p.branch(back)
