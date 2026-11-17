import sys, importlib
sys.path.insert(0, '.')
import verify
BASE = open('theme_ut42_base.sql', encoding='ascii').read()
OUT = sys.argv[1]
mods = sys.argv[2:] or ['app200', 'app210', 'app220', 'app230', 'app240']
total = 0
for m in mods:
    app = importlib.import_module(m).build(BASE)
    errs = []
    for pg in app.pages:
        verify.check_page(pg, pg.records, errs)
    for name, code, req in app.app_processes:
        verify.check_calls(code, f'{app.id} app process {name}', errs)
    for name, (sid, body, pp) in app.schemes.items():
        verify.check_calls(body, f'{app.id} scheme {name}', errs)
    text = app.render()
    open(f'{OUT}/f{app.id}.sql', 'w', encoding='ascii').write(text)
    print(f'f{app.id}.sql: {len(app.pages)} pages, {len(text):,} bytes, {len(errs)} issues')
    for e in errs:
        print('   ', e)
    total += len(errs)
print('TOTAL ISSUES', total)
