"""One application containing all five LMS modules.

Page ranges: Learning portal 1-99 (unchanged), Instructor 101-151, Administration 201-295, Management 301-344,
Analytics 401-420. Pages, items, links, branches and navigation of each module are renumbered here, so the module
definitions (app200.py ... app240.py) stay the single source.
"""
import re
from common import new_app, SCHEMES
import app200, app210, app220, app230, app240

APP_ID, ALIAS, NAME = 500, 'lms-portal', 'Enterprise LMS'
MODULES = [  # (module, original app id, page offset, section label, section icon, section scheme, alias prefix)
    (app200, 200, 0, 'Learning', 'fa-graduation-cap', None, ''),
    (app210, 210, 100, 'Teaching', 'fa-pencil', 'LMS_AUTH_INSTRUCTOR', 'INSTRUCTOR-'),
    (app220, 220, 200, 'Administration', 'fa-cogs', 'LMS_AUTH_ANY_ADMIN', 'ADMIN-'),
    (app230, 230, 300, 'Management', 'fa-users', 'LMS_AUTH_ANY_MANAGEMENT', 'MGR-'),
    (app240, 240, 400, 'Analytics', 'fa-bar-chart', 'LMS_AUTH_REPORT_ORG', 'ANALYTICS-'),
]
OFFSET = {m[1]: m[2] for m in MODULES}
SHARED_PAGES = {0, 9998, 9999}

SCHEMES['LMS_AUTH_ANY_ADMIN'] = (
    "return lms_apex_pkg.has_perm('COURSE_PUBLISH') or lms_apex_pkg.has_perm('ENROLL_APPROVE') "
    "or lms_apex_pkg.has_perm('ENROLL_ASSIGN') or lms_apex_pkg.has_perm('SESSION_MANAGE') "
    "or lms_apex_pkg.has_perm('CERT_POLICY') or lms_apex_pkg.has_perm('USER_ADMIN') or lms_apex_pkg.has_perm('ROLE_ADMIN') "
    "or lms_apex_pkg.has_perm('SETTINGS_ADMIN') or lms_apex_pkg.has_perm('AUDIT_VIEW') "
    "or lms_apex_pkg.has_perm('RATELIMIT_ADMIN') or lms_apex_pkg.has_perm('NOTIF_TEMPLATE_ADMIN');")
SCHEMES['LMS_AUTH_ANY_MANAGEMENT'] = (
    "return lms_apex_pkg.is_manager or lms_apex_pkg.has_perm('REPORT_TEAM') or lms_apex_pkg.has_perm('ENROLL_APPROVE') "
    "or lms_apex_pkg.has_perm('ENROLL_ASSIGN') or lms_apex_pkg.has_perm('SKILL_MANAGE');")


def make_mapper(app_id, pages):
    off = OFFSET[app_id]

    def pg(n):
        n = int(n)
        return n + off if n in pages and n not in SHARED_PAGES else n

    def remap(s):
        if s is None or off == 0:
            s2 = s
        else:
            s2 = re.sub(r'\bP(\d+)_', lambda m: f'P{pg(m.group(1))}_', s)
            s2 = re.sub(r'(f\?p=&APP_ID\.:)(\d+)(:)', lambda m: f'{m.group(1)}{pg(m.group(2))}{m.group(3)}', s2)
            s2 = re.sub(r'(&DEBUG\.:)(\d+)(::)', lambda m: f'{m.group(1)}{pg(m.group(2))}{m.group(3)}', s2)
            s2 = re.sub(r'(p_page => )(\d+)', lambda m: f'{m.group(1)}{pg(m.group(2))}', s2)
            s2 = re.sub(r'(case when )(\d+)( = )(\d+)', lambda m: f'{m.group(1)}{pg(m.group(2))}{m.group(3)}{pg(m.group(4))}', s2)
            s2 = re.sub(r"(apex_util\.clear_page_cache\()(\d+)", lambda m: f'{m.group(1)}{pg(m.group(2))}', s2)
        # links that pointed at another of the five applications now stay inside this one
        return re.sub(r'f\?p=(2[0-4]0):(\d+):', lambda m: f'f?p=&APP_ID.:{int(m.group(2)) + OFFSET[int(m.group(1))]}:', s2)
    return pg, remap


def build(base):
    used = set()
    built = []
    for mod, app_id, off, *_ in MODULES:
        sub = mod.build(base)
        built.append(sub)
        used |= set(sub.schemes)
    used |= {'LMS_AUTH_ANY_ADMIN', 'LMS_AUTH_ANY_MANAGEMENT'}
    master = new_app(APP_ID, ALIAS, NAME, base, schemes=tuple(sorted(used - {'LMS_AUTH_ACTIVE'})))
    master.pages = [p for p in master.pages if p.id not in SHARED_PAGES]   # taken from the portal module below
    for sub, (mod, app_id, off, label, icon, scheme, prefix) in zip(built, MODULES):
        for name, (sid, body, per_page) in sub.schemes.items():
            if name not in master.schemes:
                master.scheme(name, body, per_page)
        page_ids = {p.id for p in sub.pages}
        pg, remap = make_mapper(app_id, page_ids)
        for p in sub.pages:
            if p.id in SHARED_PAGES and app_id != 200:
                continue
            p.app = master
            p.id = pg(p.id)
            if p.alias and p.id not in SHARED_PAGES:
                p.alias = (prefix + p.alias) if not (app_id == 200) else p.alias
            p.out = [remap(o) for o in p.out]
            p.items = {remap(i) for i in p.items}
            p.records = [(k, w, remap(c), [remap(x) for x in e] if isinstance(e, list) else e) for k, w, c, e in p.records]
            master.pages.append(p)
        # navigation: one section per module
        master.nav.append((label, None, icon, scheme, None))
        for e in sub.nav:
            lbl, target, ic, sch, cur = (list(e) + [None] * 5)[:5]
            if isinstance(target, str) and re.match(r'f\?p=2[0-4]0:', target):
                continue          # the old "switch application" links
            if isinstance(target, int):
                target = pg(target)
            if cur:
                cur = ','.join(str(pg(x)) for x in cur.split(','))
            master.nav.append((lbl, target, ic, sch, cur, label))
    master.navbar = [tuple(re.sub(r'f\?p=200:', 'f?p=&APP_ID.:', x) if isinstance(x, str) else x for x in e)
                     for e in master.navbar]
    ids = [p.id for p in master.pages]
    assert len(ids) == len(set(ids)), sorted(i for i in ids if ids.count(i) > 1)
    aliases = [p.alias for p in master.pages if p.alias]
    assert len(aliases) == len(set(aliases)), sorted(a for a in aliases if aliases.count(a) > 1)
    return master
