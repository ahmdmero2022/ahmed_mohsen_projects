"""App 230 - LMS Management (03_APEX/PAGE_SPECIFICATIONS/app230_240_management_analytics.md)."""
from engine import Page, l10n
from common import new_app, link
from app220 import decide_page, assign_form

BTN = 't-Button t-Button--small'


def build(base):
    a = new_app(230, 'lms-manager', 'LMS Management', base,
                schemes=('LMS_AUTH_MANAGER', 'LMS_AUTH_REPORT_TEAM', 'LMS_AUTH_APPROVER', 'LMS_AUTH_ENROLL_ASSIGN',
                         'LMS_AUTH_HR', 'LMS_AUTH_LEARNER'))
    a.nav = [
        ('Dashboard', 1, 'fa-home', None, '1'),
        ('Team learning', 10, 'fa-users', 'LMS_AUTH_REPORT_TEAM', '10'),
        ('Approvals', 20, 'fa-check', 'LMS_AUTH_APPROVER', '20,21'),
        ('Assign training', 30, 'fa-plus', 'LMS_AUTH_ENROLL_ASSIGN', '30'),
        ('Skill gaps', 40, 'fa-line-chart', 'LMS_AUTH_REPORT_TEAM', '40'),
        ('Skills catalogue', 42, 'fa-tags', 'LMS_AUTH_HR', '42'),
        ('Position requirements', 43, 'fa-id-badge', 'LMS_AUTH_HR', '43'),
        ('Course skills', 44, 'fa-book', 'LMS_AUTH_HR', '44'),
        ('Learning portal', 'f?p=200:1:&SESSION.', 'fa-graduation-cap', 'LMS_AUTH_LEARNER', None),
    ]

    # ---------------------------------------------------------------- 1 Dashboard
    p = Page(a, 1, 'Manager dashboard', alias='HOME', auth='LMS_AUTH_ACTIVE')
    p.plsql('Team summary', """for k in (select count(distinct user_id) people, count(*) enrollments,
                 count(case when status = 'COMPLETED' then 1 end) completed,
                 count(case when overdue_flag = 'Y' then 1 end) overdue
            from v_lms_team_enrollments) loop
  htp.p('<div class="lms-kpis">'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || k.people || '</span><span class="lms-kpi__label">People learning</span></div>'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || k.completed || '</span><span class="lms-kpi__label">Completions</span></div>'
     || '<div class="lms-kpi"><span class="lms-kpi__value">' || case when k.enrollments > 0 then round(100 * k.completed / k.enrollments) else 0 end
     || '%</span><span class="lms-kpi__label">Completion rate</span></div>'
     || '<div class="lms-kpi' || case when k.overdue > 0 then ' lms-kpi--bad' end || '"><span class="lms-kpi__value">' || k.overdue
     || '</span><span class="lms-kpi__label">Overdue</span></div></div>');
end loop;""", template='reg_blank')
    p.ir('Mandatory training compliance', 'select department_en, assigned, completed, overdue, compliance_pct from v_lms_mandatory_compliance',
         [('department_en', 'Department'), ('assigned', 'Assigned', 'NUMBER'), ('completed', 'Completed', 'NUMBER'),
          ('overdue', 'Overdue', 'NUMBER'), ('compliance_pct', 'Compliance %', 'NUMBER')], sort='compliance_pct', icon='fa-shield')
    p.ir('Waiting for my approval', f"""select item_en, requester_en, due_at, case overdue_flag when 'Y' then 'Overdue' end overdue,
       {link(21, [('P21_APPROVAL_ID', 'approval_id')], "'Decide'", cls=BTN + ' t-Button--hot')} action
  from v_lms_approvals_inbox""",
         [('item_en', 'Request'), ('requester_en', 'Requested by'), ('due_at', 'Due', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('overdue', 'Overdue'), ('action', ' ', 'STRING', None, True)], sort='due_at', icon='fa-check')
    p.ir('Participation', 'select department_en, employees, active_90d, with_completion from v_lms_dept_participation',
         [('department_en', 'Department'), ('employees', 'Employees', 'NUMBER'), ('active_90d', 'Active in 90 days', 'NUMBER'),
          ('with_completion', 'With a completion', 'NUMBER')], icon='fa-bar-chart')

    # ---------------------------------------------------------------- 10 Team learning
    p = Page(a, 10, 'Team learning', alias='TEAM', auth='LMS_AUTH_REPORT_TEAM')
    p.ir('Team enrollments', """select full_name_en, department_en, course_code, course_title_en, status, enrollment_type, due_date,
       progress_pct, case overdue_flag when 'Y' then 'Overdue' end overdue, completed_at
  from v_lms_team_enrollments""",
         [('full_name_en', 'Employee'), ('department_en', 'Department'), ('course_code', 'Code'), ('course_title_en', 'Course'),
          ('status', 'Status'), ('enrollment_type', 'Type'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'),
          ('progress_pct', 'Progress %', 'NUMBER'), ('overdue', 'Overdue'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY')],
         icon='fa-users')
    p.ir('Quiz results', """select full_name_en, course_en, quiz_en, attempt_no, score_pct, case passed_flag when 'Y' then 'Passed' else 'Not passed' end passed,
       submitted_at
  from v_lms_team_results""",
         [('full_name_en', 'Employee'), ('course_en', 'Course'), ('quiz_en', 'Quiz'), ('attempt_no', 'Attempt', 'NUMBER'),
          ('score_pct', 'Score %', 'NUMBER'), ('passed', 'Result'), ('submitted_at', 'Submitted', 'DATE', 'DD-MON-YYYY')],
         sort='submitted_at', desc=True, icon='fa-check-square-o')
    p.ir('Certificates expiring', 'select full_name_en, title_en, expires_at, days_left from v_lms_cert_expiring',
         [('full_name_en', 'Employee'), ('title_en', 'Certificate'), ('expires_at', 'Expires', 'DATE', 'DD-MON-YYYY'),
          ('days_left', 'Days left', 'NUMBER')], sort='days_left', icon='fa-certificate')

    # ---------------------------------------------------------------- 20/21 Approvals
    p = Page(a, 20, 'Approvals', alias='APPROVALS', auth='LMS_AUTH_APPROVER')
    p.ir('Waiting for my decision', f"""select request_type, item_en, requester_en, requested_at, due_at,
       case overdue_flag when 'Y' then 'Overdue' end overdue,
       {link(21, [('P21_APPROVAL_ID', 'approval_id')], "'Decide'", cls=BTN + ' t-Button--hot')} action
  from v_lms_approvals_inbox""",
         [('request_type', 'Type'), ('item_en', 'Request'), ('requester_en', 'Requested by'),
          ('requested_at', 'Requested', 'DATE', 'DD-MON-YYYY HH24:MI'), ('due_at', 'Due', 'DATE', 'DD-MON-YYYY HH24:MI'),
          ('overdue', 'Overdue'), ('action', ' ', 'STRING', None, True)], sort='due_at', icon='fa-check')
    decide_page(a, 21, 20, 'LMS_AUTH_APPROVER')

    # ---------------------------------------------------------------- 30 Assign training
    p = Page(a, 30, 'Assign training', alias='ASSIGN', auth='LMS_AUTH_ENROLL_ASSIGN')
    assign_form(p, 30, back=10, mandatory_switch=True)

    # ---------------------------------------------------------------- 40 Skill gaps
    p = Page(a, 40, 'Skill gaps', alias='GAPS', auth='LMS_AUTH_REPORT_TEAM')
    h = p.form('Employee', template='reg_blank')
    p.item(h, 'P40_USER_ID', 'select', 'Show recommended courses for',
           lov='select distinct full_name_en d, user_id r from v_lms_skill_gaps order by 1')
    b = p.button(h, 'SHOW', 'Show')
    p.branch(40, items=[('P40_USER_ID', '&P40_USER_ID.')])
    p.ir('Gaps', 'select full_name_en, skill_en, required_level, current_level, gap from v_lms_skill_gaps where gap > 0',
         [('full_name_en', 'Employee'), ('skill_en', 'Skill'), ('required_level', 'Required', 'NUMBER'),
          ('current_level', 'Current', 'NUMBER'), ('gap', 'Gap', 'NUMBER')], sort='gap', desc=True, icon='fa-line-chart')
    p.ir('Recommended courses', f"""select {l10n('title', 'title')}, coverage from v_lms_team_recommended where user_id = :P40_USER_ID""",
         [('title', 'Course'), ('coverage', 'Gaps covered', 'NUMBER')], sort='coverage', desc=True, icon='fa-lightbulb-o')
    p.ir('Gaps by department', 'select department_en, employees_with_gaps, gap_index from v_lms_skill_gap_by_dept',
         [('department_en', 'Department'), ('employees_with_gaps', 'People with gaps', 'NUMBER'), ('gap_index', 'Gap index', 'NUMBER')],
         icon='fa-sitemap')

    # ---------------------------------------------------------------- 42/43/44 Skills framework (HR)
    p = Page(a, 42, 'Skills catalogue', alias='SKILLS', auth='LMS_AUTH_HR')
    r = p.form('Skill')
    p.item(r, 'P42_SKILL_ID', 'hidden')
    p.item(r, 'P42_CODE', 'text', 'Code', required=True, maxlen=30)
    p.item(r, 'P42_NAME_EN', 'text', 'Name (English)', required=True, maxlen=200)
    p.item(r, 'P42_NAME_AR', 'text', 'Name (Arabic)', maxlen=200)
    p.item(r, 'P42_GROUP', 'text', 'Group', maxlen=100)
    p.item(r, 'P42_ACTIVE', 'select', 'Active', lov='STATIC:Yes;Y,No;N', default='Y')
    p.process('Load', """if :P42_SKILL_ID is not null and :REQUEST = 'EDIT' then
  select skill_code, name_en, name_ar, skill_group, active_flag into :P42_CODE, :P42_NAME_EN, :P42_NAME_AR, :P42_GROUP, :P42_ACTIVE
    from v_lms_skills_admin where skill_id = :P42_SKILL_ID;
end if;""", point='BEFORE_HEADER')
    p.process('Remove', 'lms_skill_pkg.remove_skill(:P42_SKILL_ID);\n:P42_SKILL_ID := null;', point='BEFORE_HEADER',
              when_request='REMOVE', success='Skill removed.')
    b = p.button(r, 'SAVE', 'Save skill', hot=True)
    p.process('Save skill', ":P42_SKILL_ID := lms_skill_pkg.save_skill(:P42_SKILL_ID, :P42_CODE, :P42_NAME_EN, :P42_NAME_AR, :P42_GROUP, nvl(:P42_ACTIVE, 'Y'));",
              when_button=b, success='Skill saved.')
    p.branch(42)
    p.ir('Skills', f"""select skill_code, name_en, name_ar, skill_group, active_flag, positions_using, courses_using, people_assessed,
       {link(42, [('P42_SKILL_ID', 'skill_id')], "'Edit'", request='EDIT', cls=BTN)}
       || case when positions_using = 0 and courses_using = 0 and people_assessed = 0
               then ' ' || {link(42, [('P42_SKILL_ID', 'skill_id')], "'Remove'", request='REMOVE', cls=BTN)} end action
  from v_lms_skills_admin""",
         [('skill_code', 'Code'), ('name_en', 'Skill'), ('name_ar', 'Arabic name'), ('skill_group', 'Group'), ('active_flag', 'Active'),
          ('positions_using', 'Positions', 'NUMBER'), ('courses_using', 'Courses', 'NUMBER'), ('people_assessed', 'People', 'NUMBER'),
          ('action', ' ', 'STRING', None, True)], sort='skill_code', icon='fa-tags')

    p = Page(a, 43, 'Position requirements', alias='POSITION-SKILLS', auth='LMS_AUTH_HR')
    r = p.form('Requirement')
    p.item(r, 'P43_POSITION_ID', 'select', 'Position', required=True,
           lov='select job_title_en d, position_id r from v_lms_lov_positions order by job_title_en')
    p.item(r, 'P43_SKILL_ID', 'select', 'Skill', lov='select name_en d, skill_id r from v_lms_lov_skills order by name_en')
    p.item(r, 'P43_LEVEL', 'select', 'Required level (empty = remove)', lov='STATIC:1;1,2;2,3;3,4;4,5;5')
    b = p.button(r, 'SAVE', 'Save requirement', hot=True)
    p.process('Save requirement', 'lms_skill_pkg.set_position_skill(:P43_POSITION_ID, :P43_SKILL_ID, :P43_LEVEL);',
              when_button=b, success='Requirement saved.')
    p.branch(43, items=[('P43_POSITION_ID', '&P43_POSITION_ID.')])
    p.ir('Requirements', """select job_title_en, skill_code, skill_en, required_level from v_lms_position_skills_admin
 where position_id = :P43_POSITION_ID or :P43_POSITION_ID is null""",
         [('job_title_en', 'Position'), ('skill_code', 'Code'), ('skill_en', 'Skill'), ('required_level', 'Required level', 'NUMBER')],
         sort='job_title_en', icon='fa-id-badge')

    p = Page(a, 44, 'Course skills', alias='COURSE-SKILLS', auth='LMS_AUTH_HR')
    r = p.form('Course skill')
    p.item(r, 'P44_COURSE_ID', 'select', 'Course', required=True, lov='select title_en d, course_id r from v_lms_catalog order by title_en')
    p.item(r, 'P44_SKILL_ID', 'select', 'Skill', lov='select name_en d, skill_id r from v_lms_lov_skills order by name_en')
    p.item(r, 'P44_LEVEL', 'select', 'Level gained (empty = remove)', lov='STATIC:1;1,2;2,3;3,4;4,5;5')
    b = p.button(r, 'SAVE', 'Save', hot=True)
    p.process('Save course skill', 'lms_skill_pkg.set_course_skill(:P44_COURSE_ID, :P44_SKILL_ID, :P44_LEVEL);',
              when_button=b, success='Saved.')
    p.branch(44, items=[('P44_COURSE_ID', '&P44_COURSE_ID.')])
    p.ir('Skills of the course', 'select skill_code, skill_en, level_gained from v_lms_course_skills_edit where course_id = :P44_COURSE_ID',
         [('skill_code', 'Code'), ('skill_en', 'Skill'), ('level_gained', 'Level gained', 'NUMBER')], icon='fa-book')
    return a
