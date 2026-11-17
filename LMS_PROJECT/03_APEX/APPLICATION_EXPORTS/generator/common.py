"""Shared building blocks for the five LMS applications."""
from engine import App, Page, l10n

import os
STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'STATIC_FILES') + os.sep

# Authorization schemes (03_APEX/SHARED_COMPONENTS/README.md section 3)
SCHEMES = {
    'LMS_AUTH_ACTIVE': 'return lms_apex_pkg.is_active_user;',
    'LMS_AUTH_CATALOG': "return lms_apex_pkg.has_perm('CATALOG_VIEW');",
    'LMS_AUTH_LEARNER': "return lms_apex_pkg.has_perm('ENROLL_SELF');",
    'LMS_AUTH_INSTRUCTOR': "return lms_apex_pkg.has_perm('COURSE_AUTHOR') or lms_apex_pkg.has_perm('GRADE') or lms_apex_pkg.has_perm('SESSION_MANAGE');",
    'LMS_AUTH_COURSE_AUTHOR': "return lms_apex_pkg.has_perm('COURSE_AUTHOR');",
    'LMS_AUTH_QUIZ_AUTHOR': "return lms_apex_pkg.has_perm('QUIZ_AUTHOR');",
    'LMS_AUTH_GRADE': "return lms_apex_pkg.has_perm('GRADE');",
    'LMS_AUTH_SESSION_MANAGE': "return lms_apex_pkg.has_perm('SESSION_MANAGE');",
    'LMS_AUTH_MANAGER': 'return lms_apex_pkg.is_manager;',
    'LMS_AUTH_ENROLL_ASSIGN': "return lms_apex_pkg.has_perm('ENROLL_ASSIGN');",
    'LMS_AUTH_APPROVER': "return lms_apex_pkg.has_perm('ENROLL_APPROVE') or lms_apex_pkg.has_perm('COURSE_PUBLISH');",
    'LMS_AUTH_TRAINING_ADMIN': "return lms_apex_pkg.has_perm('COURSE_PUBLISH');",
    'LMS_AUTH_CERT_POLICY': "return lms_apex_pkg.has_perm('CERT_POLICY');",
    'LMS_AUTH_HR': "return lms_apex_pkg.has_perm('SKILL_MANAGE');",
    'LMS_AUTH_REPORT_TEAM': "return lms_apex_pkg.has_perm('REPORT_TEAM');",
    'LMS_AUTH_REPORT_ORG': "return lms_apex_pkg.has_scope('REPORT_ORG','ALL');",
    'LMS_AUTH_SYSADMIN': "return lms_apex_pkg.has_perm('USER_ADMIN');",
    'LMS_AUTH_ROLE_ADMIN': "return lms_apex_pkg.has_perm('ROLE_ADMIN');",
    'LMS_AUTH_SETTINGS': "return lms_apex_pkg.has_perm('SETTINGS_ADMIN');",
    'LMS_AUTH_AUDIT': "return lms_apex_pkg.has_perm('AUDIT_VIEW');",
    'LMS_AUTH_RATELIMIT': "return lms_apex_pkg.has_perm('RATELIMIT_ADMIN');",
    'LMS_AUTH_TEMPLATES': "return lms_apex_pkg.has_perm('NOTIF_TEMPLATE_ADMIN');",
}


def link(page, items, label, request=None, cls=None):
    """SQL expression for an HTML link with a checksummed URL. items: list of (ITEM_NAME, sql_expr)."""
    names = ','.join(n for n, _ in items)
    vals = "||','||".join(f'to_char({e})' for _, e in items) if items else "null"
    req = f", p_request => '{request}'" if request else ''
    c = f' class="{cls}"' if cls else ''
    return (f"'<a{c} href=\"' || apex_page.get_url(p_page => {page}, p_items => '{names}', p_values => {vals}{req})"
            f" || '\">' || apex_escape.html({label}) || '</a>'")


def new_app(app_id, alias, name, base, home=1, schemes=(), static=('app.css', 'app-pages.css')):
    a = App(app_id, alias, name, base, home)
    for s in ('LMS_AUTH_ACTIVE',) + tuple(schemes):
        a.scheme(s, SCHEMES[s])
    a.items = ['LMS_USER_ID', 'LMS_LANG', 'LMS_UNREAD']
    a.app_processes.append(('SET_LANGUAGE',
        "declare\n  l_lang varchar2(2) := case :REQUEST when 'LANG_AR' then 'ar' else 'en' end;\nbegin\n"
        "  lms_user_pkg.set_language(l_lang);\n  apex_util.set_session_lang(l_lang);\n  :LMS_LANG := l_lang;\nend;",
        'LANG_AR,LANG_EN'))
    a.app_processes.append(('UNREAD_COUNT',
        "begin\n  if :APP_USER is not null and :APP_USER <> 'nobody' and lms_apex_pkg.is_active_user then\n"
        "    :LMS_UNREAD := nullif(lms_notification_pkg.unread_count, 0);\n  end if;\n"
        "exception when others then :LMS_UNREAD := null;\nend;", None))
    for f in static:
        mime = 'text/css' if f.endswith('.css') else 'application/javascript'
        a.files.append((f, mime, open(STATIC_DIR + f, 'rb').read()))
    # navigation bar (all apps)
    a.navbar = [
        ('Notifications', 'f?p=200:80:&SESSION.::&DEBUG.:::', 'fa-bell', None, None),
        ('العربية', 'f?p=&APP_ID.:&APP_PAGE_ID.:&SESSION.:LANG_AR:&DEBUG.:::', 'fa-language', None, None),
        ('English', 'f?p=&APP_ID.:&APP_PAGE_ID.:&SESSION.:LANG_EN:&DEBUG.:::', 'fa-language', None, None),
        ('&APP_USER.', None, 'fa-user-circle', None, None),
        ('Preferences', 'f?p=200:70:&SESSION.::&DEBUG.:::', 'fa-user', None, None, '&APP_USER.'),
        ('Sign out', '&LOGOUT_URL.', 'fa-sign-out', None, None, '&APP_USER.'),
    ]
    common_pages(a)
    return a


def common_pages(a):
    # global page: screen-reader live region used by the static scripts
    p = Page(a, 0, 'Global Page', protection='D')
    p.static('Live region', '<div id="lms-live" class="u-VisuallyHidden" aria-live="polite" role="status"></div>',
             template='reg_blank', point='REGION_POSITION_05')
    # 9998 access problem / session expired (public, never redirects)
    p = Page(a, 9998, 'Access', alias='ACCESS', template='minimal', public=True, protection='D')
    p.static('Access', '<p>You do not have access to LMS, or your session has ended.</p>'
             '<p>If you think you should have access, contact your administrator.</p>'
             '<p><a class="t-Button t-Button--hot" href="f?p=&APP_ID.:1:0">Sign in</a></p>'
             '<p dir="rtl" lang="ar">ليس لديك صلاحية الوصول إلى النظام أو انتهت جلستك. تواصل مع مسؤول النظام إن كنت تعتقد أنه يجب أن يكون لك وصول.</p>')
    # 9999 login (APEX accounts in DEV; replace the scheme for SSO in production)
    p = Page(a, 9999, 'Sign In', alias='LOGIN', template='login', public=True, title=a.name + ' - Sign In')
    r = p.form(a.name, template='reg_login', icon='fa fa-graduation-cap')
    p.item(r, 'P9999_USERNAME', 'text', 'Username', required=True, placeholder='Username', protected=False)
    p.item(r, 'P9999_PASSWORD', 'password', 'Password', required=True, placeholder='Password', protected=False)
    b = p.button(r, 'LOGIN', 'Sign In', hot=True)
    p.process('Login', "apex_authentication.send_login_username_cookie(p_username => lower(:P9999_USERNAME));\n"
              "apex_authentication.login(p_username => :P9999_USERNAME, p_password => :P9999_PASSWORD);",
              when_button=b)
    p.process('Clear page cache', "apex_util.clear_page_cache(9999);", seq=20)
