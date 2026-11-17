import re, sys, collections
for f in sys.argv[1:]:
    s = open(f, encoding='ascii').read()   # raises if non-ASCII
    errs = []
    blocks = s.split('\n/\n')
    for bi, b in enumerate(blocks):
        # strip string literals (Oracle '' escaping)
        nostr, i, n, inq = [], 0, len(b), False
        while i < n:
            c = b[i]
            if inq:
                if c == "'":
                    if i + 1 < n and b[i + 1] == "'": i += 2; continue
                    inq = False
                i += 1; continue
            if c == "'": inq = True; i += 1; continue
            nostr.append(c); i += 1
        if inq: errs.append(f'block {bi}: unterminated string'); continue
        t = ''.join(nostr)
        if t.count('(') != t.count(')'): errs.append(f'block {bi}: parens {t.count("(")} vs {t.count(")")}: {b[:80]!r}')
        if 'begin' in t and not re.search(r'end;\s*$', t.strip() + '\n') and 'end;' not in t:
            errs.append(f'block {bi}: begin without end')
    ids = re.findall(r'\bp_id=>wwv_flow_imp\.id\((\d+)\)', s)
    dup = [k for k, v in collections.Counter(ids).items() if v > 1]
    if dup: errs.append(f'duplicate ids: {dup[:5]}')
    defined = set(ids)
    refs = set(re.findall(r'p_(?!id=>)\w+=>wwv_flow_imp\.id\((\d+)\)', s))
    missing = refs - defined
    if missing: errs.append(f'{len(missing)} references to undefined ids: {sorted(missing)[:8]}')
    pages = re.findall(r'create_page\(\n p_id=>(\d+)', s)
    print(f'{f}: {len(blocks)} blocks, {len(defined)} ids, {len(refs)} refs, pages {len(pages)}, errors {len(errs)}')
    for e in errs[:15]: print('   ', e)
