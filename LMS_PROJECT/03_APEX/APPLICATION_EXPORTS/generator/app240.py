"""App 240 - LMS Analytics (03_APEX/PAGE_SPECIFICATIONS/app230_240_management_analytics.md)."""
from engine import Page, l10n
from common import new_app


def build(base):
    a = new_app(240, 'lms-analytics', 'LMS Analytics', base, schemes=('LMS_AUTH_REPORT_ORG', 'LMS_AUTH_LEARNER'))
    a.nav = [
        ('Executive dashboard', 1, 'fa-dashboard', 'LMS_AUTH_REPORT_ORG', '1'),
        ('Reports', 10, 'fa-table', 'LMS_AUTH_REPORT_ORG', '10'),
        ('Drill-down', 20, 'fa-search-plus', 'LMS_AUTH_REPORT_ORG', '20'),
        ('Learning portal', 'f?p=200:1:&SESSION.', 'fa-graduation-cap', 'LMS_AUTH_LEARNER', None),
    ]

    p = Page(a, 1, 'Executive dashboard', alias='HOME', auth='LMS_AUTH_REPORT_ORG')
    p.plsql('Key indicators', """for k in (select * from v_lms_org_kpis) loop
  htp.p('<p class="lms-fresh">Data refreshed ' || to_char(k.summaries_refreshed_at, 'DD-MON-YYYY HH24:MI') || '</p><div class="lms-kpis">');
  for t in (select 'Learners' lbl, to_char(k.total_learners) val, null warn from dual union all
            select 'Active learners', to_char(k.active_learners), null from dual union all
            select 'Published courses', to_char(k.published_courses) || ' of ' || k.total_courses, null from dual union all
            select 'Enrollments', to_char(k.total_enrollments), null from dual union all
            select 'Completion rate', to_char(k.completion_rate_pct) || '%', null from dual union all
            select 'Average score', to_char(k.avg_assessment_score) || '%', null from dual union all
            select 'Mandatory compliance', to_char(k.mandatory_compliance_pct) || '%',
                   case when k.mandatory_compliance_pct < 90 then 'Below 90%' end from dual union all
            select 'Certificates issued', to_char(k.certificates_issued), null from dual union all
            select 'Certificates expired', to_char(k.certificates_expired), null from dual union all
            select 'Learning hours', to_char(round(k.learning_hours)), null from dual union all
            select 'Average rating', to_char(k.avg_course_rating, 'fm0.0'), null from dual) loop
    htp.p('<div class="lms-kpi' || case when t.warn is not null then ' lms-kpi--warn' end || '"><span class="lms-kpi__value">'
       || apex_escape.html(t.val) || '</span><span class="lms-kpi__label">' || apex_escape.html(t.lbl)
       || case when t.warn is not null then ' (' || t.warn || ')' end || '</span></div>');
  end loop;
  htp.p('</div>');
end loop;""", template='reg_blank')
    p.ir('Department trend (last 90 days)', """select department_en, sum(enrollments) enrollments, sum(completions) completions,
       round(sum(learning_hours)) learning_hours
  from v_lms_exec_dept_trend where summary_day >= trunc(sysdate) - 90
 group by department_en""",
         [('department_en', 'Department'), ('enrollments', 'Enrollments', 'NUMBER'), ('completions', 'Completions', 'NUMBER'),
          ('learning_hours', 'Learning hours', 'NUMBER')], sort='completions', desc=True, icon='fa-line-chart')
    p.ir('Courses', """select course_code, title_en, status, enrolled, completed, completion_pct, avg_score, avg_rating, rating_count
  from v_lms_exec_courses""",
         [('course_code', 'Code'), ('title_en', 'Course'), ('status', 'Status'), ('enrolled', 'Enrolled', 'NUMBER'),
          ('completed', 'Completed', 'NUMBER'), ('completion_pct', 'Completion %', 'NUMBER'), ('avg_score', 'Avg score', 'NUMBER'),
          ('avg_rating', 'Rating', 'NUMBER', '0.0'), ('rating_count', 'Ratings', 'NUMBER')], sort='enrolled', desc=True,
         icon='fa-book')

    p = Page(a, 10, 'Reports', alias='REPORTS', auth='LMS_AUTH_REPORT_ORG')
    p.ir('All enrollments', """select full_name_en, department_en, course_code, course_title_en, status, enrollment_type, due_date,
       progress_pct, case overdue_flag when 'Y' then 'Overdue' end overdue, completed_at
  from v_lms_team_enrollments""",
         [('full_name_en', 'Employee'), ('department_en', 'Department'), ('course_code', 'Code'), ('course_title_en', 'Course'),
          ('status', 'Status'), ('enrollment_type', 'Type'), ('due_date', 'Due', 'DATE', 'DD-MON-YYYY'),
          ('progress_pct', 'Progress %', 'NUMBER'), ('overdue', 'Overdue'), ('completed_at', 'Completed', 'DATE', 'DD-MON-YYYY')],
         icon='fa-table')
    p.ir('Mandatory compliance', 'select department_en, assigned, completed, overdue, compliance_pct from v_lms_mandatory_compliance',
         [('department_en', 'Department'), ('assigned', 'Assigned', 'NUMBER'), ('completed', 'Completed', 'NUMBER'),
          ('overdue', 'Overdue', 'NUMBER'), ('compliance_pct', 'Compliance %', 'NUMBER')], sort='compliance_pct', icon='fa-shield')
    p.ir('Certificates expiring', 'select full_name_en, title_en, expires_at, days_left from v_lms_cert_expiring',
         [('full_name_en', 'Employee'), ('title_en', 'Certificate'), ('expires_at', 'Expires', 'DATE', 'DD-MON-YYYY'),
          ('days_left', 'Days left', 'NUMBER')], sort='days_left', icon='fa-certificate')

    p = Page(a, 20, 'Drill-down', alias='DRILL', auth='LMS_AUTH_REPORT_ORG')
    p.ir('Participation by department', 'select department_en, employees, active_90d, with_completion from v_lms_dept_participation',
         [('department_en', 'Department'), ('employees', 'Employees', 'NUMBER'), ('active_90d', 'Active in 90 days', 'NUMBER'),
          ('with_completion', 'With a completion', 'NUMBER')], icon='fa-sitemap')
    p.ir('Daily trend', """select summary_day, department_en, enrollments, completions, learning_hours from v_lms_exec_dept_trend""",
         [('summary_day', 'Day', 'DATE', 'DD-MON-YYYY'), ('department_en', 'Department'), ('enrollments', 'Enrollments', 'NUMBER'),
          ('completions', 'Completions', 'NUMBER'), ('learning_hours', 'Hours', 'NUMBER', '999G990D0')],
         sort='summary_day', desc=True, icon='fa-calendar')
    p.ir('Assessment results', """select full_name_en, course_en, quiz_en, attempt_no, score_pct,
       case passed_flag when 'Y' then 'Passed' else 'Not passed' end passed, submitted_at
  from v_lms_team_results""",
         [('full_name_en', 'Employee'), ('course_en', 'Course'), ('quiz_en', 'Quiz'), ('attempt_no', 'Attempt', 'NUMBER'),
          ('score_pct', 'Score %', 'NUMBER'), ('passed', 'Result'), ('submitted_at', 'Submitted', 'DATE', 'DD-MON-YYYY')],
         sort='submitted_at', desc=True, icon='fa-check-square-o')
    return a
