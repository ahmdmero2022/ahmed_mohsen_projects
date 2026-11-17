"""Static checks of the generated applications against the database scripts."""
import json, re
import sqlglot
from sqlglot import exp

VIEWS = json.load(open('views.json'))
SIGS = json.load(open('sigs.json'))
APEX_PKGS = ('apex_', 'htp', 'owa_util', 'dbms_lob', 'json_')


def strip_strings(code):
    return re.sub(r"'(?:[^']|'')*'", "''", code)


def split_args(s):
    depth, cur, out = 0, '', []
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur); cur = ''
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def check_calls(code, where, errs):
    c = strip_strings(code)
    for m in re.finditer(r'\b(lms_\w+_pkg)\.(\w+)\b(\s*\()?', c, re.I):
        pkg, mem = m.group(1).lower(), m.group(2).lower()
        if pkg not in SIGS:
            errs.append(f'{where}: unknown package {pkg}'); continue
        if mem not in SIGS[pkg]:
            errs.append(f'{where}: unknown member {pkg}.{mem}'); continue
        overloads = SIGS[pkg][mem]
        if m.group(3):
            i, depth = m.end(), 1
            while depth and i < len(c):
                depth += {'(': 1, ')': -1}.get(c[i], 0); i += 1
            args = split_args(c[m.end():i - 1])
            named = [a for a in args if '=>' in a]
            n = len(args)
            ok = False
            for o in overloads:
                req = sum(1 for p in o['params'] if not p['def'])
                if req <= n <= len(o['params']) or named:
                    ok = True
            if not ok:
                errs.append(f'{where}: {pkg}.{mem} called with {n} args, expects '
                            + '/'.join(f"{sum(1 for p in o['params'] if not p['def'])}-{len(o['params'])}" for o in overloads))
        else:
            if all(o['params'] and any(not p['def'] for p in o['params']) for o in overloads):
                errs.append(f'{where}: {pkg}.{mem} used without arguments')


def check_views(code, where, errs):
    for v in re.findall(r'\bfrom\s+(v_lms_\w+|lms_\w+)|\bjoin\s+(v_lms_\w+|lms_\w+)', code, re.I):
        name = (v[0] or v[1]).lower()
        if name.startswith('v_lms_') and name not in VIEWS:
            errs.append(f'{where}: unknown view {name}')
        elif name.startswith('lms_') and not name.endswith('_pkg') and name not in VIEWS:
            errs.append(f'{where}: page reads base table {name}')


def check_sql_columns(sql, where, errs, ir_cols=None):
    parts = re.split(r"('(?:[^']|'')*')", sql)
    s = ''.join(pt if pt.startswith("'") else re.sub(r':(\w+)', "'BIND'", pt) for pt in parts)
    try:
        tree = sqlglot.parse_one(s, read='oracle')
    except Exception as e:
        errs.append(f'{where}: SQL parse error {str(e)[:120]}'); return
    for sel in tree.find_all(exp.Select):
        aliases = {}
        for t in sel.find_all(exp.Table):
            if t.find_ancestor(exp.Select) is not sel:
                continue
            aliases[(t.alias or t.name).lower()] = t.name.lower()
        selaliases = {e.alias_or_name.lower() for e in sel.expressions}
        for col in sel.find_all(exp.Column):
            if col.find_ancestor(exp.Select) is not sel:
                continue
            name, tq = col.name.lower(), (col.table or '').lower()
            if name in ('rownum', 'sysdate', 'systimestamp', 'level', 'user'):
                continue
            if tq:
                v = aliases.get(tq)
                if v and v in VIEWS and name not in VIEWS[v]:
                    errs.append(f'{where}: {v}.{name} does not exist')
            else:
                srcs = [v for v in aliases.values() if v in VIEWS]
                if srcs and not any(name in VIEWS[v] for v in srcs) and name not in selaliases and name != 'dual':
                    if not any(v == 'dual' for v in aliases.values()):
                        errs.append(f'{where}: column {name} not in {srcs}')
    if ir_cols is not None:
        top = tree if isinstance(tree, exp.Select) else tree.find(exp.Select)
        names = [e.alias_or_name.lower() for e in top.expressions]
        for c in ir_cols:
            if c.lower() not in names:
                errs.append(f'{where}: IR column {c} not in select list {names}')


def check_page(page, records, errs):
    items = page.items | set()
    for kind, where, code, extra in records:
        check_calls(code, where, errs)
        check_views(code, where, errs)
        if kind == 'ir':
            check_sql_columns(code, where, errs, extra)
        elif kind == 'cond':
            check_sql_columns(code, where, errs)
        for it in set(re.findall(r':(P\d+_\w+)', strip_strings(code))):
            if not it.startswith(f'P{page.id}_'):
                errs.append(f'{where}: references item {it} of another page')
            elif it not in items:
                errs.append(f'{where}: unknown item {it}')
        for it in set(re.findall(r'&(P\d+_\w+)\.', code)):
            if it.startswith(f'P{page.id}_') and it not in items:
                errs.append(f'{where}: unknown substitution &{it}.')
