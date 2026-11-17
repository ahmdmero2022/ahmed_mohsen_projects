"""Rebuild views.json (view -> columns) and sigs.json (package -> members) from 02_DATABASE."""
import re, json, glob, os
import sqlglot
from sqlglot import exp

DB = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '02_DATABASE')
views, sigs = {}, {}
for f in sorted(glob.glob(os.path.join(DB, '*.sql'))):
    s = open(f, encoding='utf8').read()
    for m in re.finditer(r'CREATE OR REPLACE (?:FORCE )?VIEW\s+(\w+)\s*(\(([^)]*)\))?\s+AS\s+(.*?)(?=\n/\s*\n|;\s*\n(?:--|CREATE|COMMENT|GRANT|\s*$|PROMPT|BEGIN|\n))', s, re.S | re.I):
        if m.group(3):
            cols = [c.strip().lower() for c in m.group(3).split(',')]
        else:
            t = sqlglot.parse_one(m.group(4).strip().rstrip(';'), read='oracle')
            sel = t.find(exp.Select) if not isinstance(t, exp.Select) else t
            while isinstance(t, exp.Union):
                t = t.left
                sel = t
            cols = [e.alias_or_name.lower() for e in sel.expressions]
        views[m.group(1).lower()] = cols
    for pm in re.finditer(r'CREATE OR REPLACE PACKAGE\s+(\w+)\s+(?:AUTHID\s+\w+\s+)?(?:IS|AS)\b(.*?)\bEND\s+\1\s*;', s, re.S | re.I):
        body = re.sub(r'--[^\n]*', '', re.sub(r'/\*.*?\*/', '', pm.group(2), flags=re.S))
        for m in re.finditer(r'\b(PROCEDURE|FUNCTION)\s+(\w+)\s*(\((.*?)\))?\s*(RETURN\s+([\w.%]+))?\s*(ACCESSIBLE BY\s*\([^)]*\))?\s*;', body, re.S | re.I):
            params = []
            for p in (m.group(4) or '').split(','):
                p = ' '.join(p.split())
                if p:
                    params.append({'n': p.split()[0].lower(), 'mode': 'OUT' if re.search(r'\bOUT\b', p, re.I) else 'IN',
                                   'def': bool(re.search(r'DEFAULT|:=', p, re.I)), 't': p})
            sigs.setdefault(pm.group(1).lower(), {}).setdefault(m.group(2).lower(), []).append(
                {'kind': m.group(1).upper(), 'ret': m.group(6), 'params': params, 'acc': bool(m.group(7))})
json.dump(views, open('views.json', 'w'), indent=0)
json.dump(sigs, open('sigs.json', 'w'), indent=0)
print(len(views), 'views,', sum(len(v) for v in sigs.values()), 'package members')
