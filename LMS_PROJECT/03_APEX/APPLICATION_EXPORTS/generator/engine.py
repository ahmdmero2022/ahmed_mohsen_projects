"""Generate Oracle APEX 24.1 application import files.

The theme (Universal Theme 42 templates, template options, template components) is copied verbatim from an
existing APEX 24.1 export, so every template id referenced here exists in the file. Everything else is generated.
Only import-API parameters that appear in that reference export are used, plus a small, documented set of
standard ones (see README).
"""
import re, secrets

# ---- template ids from the reference export (Universal Theme 42) -------------------------------------
T = dict(
    page_std=237380489078697915, page_modal=237385280085697938, page_login=237382911860697916,
    page_minimal=237391308166697942,
    reg_std=237431389965697982, reg_blank=237400365074697960, reg_ir=237429413056697980,
    reg_buttons=237401367838697961, reg_login=237430074332697981, reg_hero=237421592641697977,
    reg_alert=237396681264697949, reg_cards=237403534606697962,
    fld_opt_above=237493879064698023, fld_req_above=237494781466698024, fld_hidden=237493687164698022,
    btn_text=237496403622698026, btn_icon_text=237496564509698026,
    list_side=237484294166698018, list_navbar=237483816620698018,
)
THEME_PREFIXES = (
    'application/plugin_settings',
    'application/shared_components/logic/application_settings',
    'application/shared_components/navigation/tabs/',
    'application/pages/page_groups',
    'application/comments',
    'application/shared_components/navigation/breadcrumbentry',
    'application/shared_components/user_interface/',
    'application/shared_components/globalization/',
    'application/shared_components/logic/build_options',
    'application/shared_components/plugins/',
    'application/user_interfaces/combined_files',
)


def split_blocks(text):
    parts = re.split(r'(?m)^(?=prompt --)', text)
    out = []
    for p in parts:
        m = re.match(r'prompt --(\S+)', p)
        if m:
            out.append((m.group(1), p))
    return out


# ---- literal helpers -------------------------------------------------------------------------------------
def _lit(line):
    """One Oracle string literal; non-ASCII text becomes unistr() so the file stays ASCII (as APEX does)."""
    if all(ord(c) < 128 for c in line):
        return "'" + line.replace("'", "''") + "'"
    out = []
    for c in line:
        if c == '\\':
            out.append('\\005C')
        elif ord(c) < 128:
            out.append("''" if c == "'" else c)
        else:
            out.append('\\%04X' % ord(c))
    return "unistr('" + ''.join(out) + "')"


def q(s):
    """Literal for a parameter value; multi-line or long text becomes wwv_flow_string.join(...)."""
    if s is None:
        return 'null'
    s = str(s)
    lines = s.split('\n')
    if len(lines) == 1 and len(s) < 900:
        return _lit(s)
    chunks = []
    for i, ln in enumerate(lines):
        while len(ln) > 900:
            chunks.append((ln[:900], False))
            ln = ln[900:]
        chunks.append((ln, True))
    # join(...) inserts a newline between elements; long-line splits must not get one, so glue them with ||
    elems, cur = [], None
    for text, ends in chunks:
        cur = _lit(text) if cur is None else cur + '||' + _lit(text)
        if ends:
            elems.append(cur)
            cur = None
    return 'wwv_flow_string.join(wwv_flow_t_varchar2(\n' + ',\n'.join(elems) + '))'


def call(api, params):
    rows = []
    for k, v in params:
        if v is None:
            continue
        rows.append(f'p_{k}=>{v}')
    return f'{api}(\n ' + '\n,'.join(rows) + '\n);'


def ident(n):
    return f'wwv_flow_imp.id({n})'


def l10n(col_base, alias=None):
    e = f"case when :LMS_LANG = 'ar' and {col_base}_ar is not null then {col_base}_ar else {col_base}_en end"
    return f'{e} {alias}' if alias else e


# ---- model -----------------------------------------------------------------------------------------------
class Ids:
    def __init__(self, base):
        self.n = base

    def __call__(self):
        self.n += 1
        return self.n


class Page:
    def __init__(self, app, pid, name, alias=None, mode='NORMAL', template=None, auth=None, public=False,
                 protection='C', title=None, help_text=None, inline_css=None):
        self.app, self.id, self.name, self.alias = app, pid, name, alias
        self.mode, self.template, self.auth, self.public = mode, template, auth, public
        self.protection, self.title, self.inline_css = protection, title or name, inline_css
        self.out = []          # generated API calls (strings)
        self.items = set()
        self.has_ir = False
        self.reg_seq = 0
        self.btn_seq = 0
        self.records = []      # (kind, where, code, extra) for static verification
        app.pages.append(self)

    # regions -------------------------------------------------------------------------------------------
    def _plug(self, name, template, source=None, source_type=None, point=None, seq=None, css=None, opts='#DEFAULT#',
              icon=None, parent=None, extra=()):
        rid = self.app.ids()
        self.reg_seq += 10
        params = [('id', ident(rid)), ('plug_name', q(name)), ('parent_plug_id', ident(parent) if parent else None),
                  ('icon_css_classes', q(icon) if icon else None),
                  ('region_css_classes', q(css) if css else None),
                  ('region_template_options', q(opts)), ('plug_template', ident(template)),
                  ('plug_display_sequence', seq or self.reg_seq),
                  ('plug_display_point', q(point) if point else None)]
        params += list(extra)
        if source_type is None:
            params += [('plug_source', q(source) if source else None),
                       ('attributes', "wwv_flow_t_plugin_attributes(wwv_flow_t_varchar2(\n  'expand_shortcuts', 'N',\n  'output_as', 'HTML')).to_clob")]
        else:
            params += [('plug_source', q(source)), ('plug_source_type', q(source_type))]
            if source_type == 'NATIVE_PLSQL':
                params += [('plug_query_num_rows', 15)]
        self.out.append(call('wwv_flow_imp_page.create_page_plug', params))
        return rid

    def static(self, name, html=None, template='reg_std', **kw):
        return self._plug(name, T[template], source=html, **kw)

    def form(self, name, template='reg_std', **kw):
        return self._plug(name, T[template], **kw)

    def plsql(self, name, code, template='reg_std', **kw):
        self.records.append(('plsql', f'{self.app.id}:{self.id} region "{name}"', code, None))
        return self._plug(name, T[template], source=code, source_type='NATIVE_PLSQL', **kw)

    def buttons(self):
        return self._plug('Buttons', T['reg_buttons'], point='REGION_POSITION_03' if self.mode == 'MODAL' else None)

    def ir(self, name, sql, cols, sort=None, desc=False, icon=None, rows=None):
        """cols: list of (column, label, type, format_mask, raw)."""
        self.records.append(('ir', f'{self.app.id}:{self.id} IR "{name}"', sql, [c[0] for c in cols]))
        self.has_ir = True
        rid = self._plug(name, T['reg_ir'], source=sql, source_type='NATIVE_IR', icon=icon,
                         extra=[('query_type', q('SQL')), ('prn_page_header', q(name))])
        wid = self.app.ids()
        self.out.append(call('wwv_flow_imp_page.create_worksheet', [
            ('id', ident(wid)), ('name', q(name)), ('max_row_count', q('100000')),
            ('max_row_count_message', q('The maximum row count for this report is #MAX_ROW_COUNT# rows. Please apply a filter.')),
            ('no_data_found_message', q('No records found.')), ('allow_save_rpt_public', q('Y')),
            ('pagination_type', q('ROWS_X_TO_Y')), ('pagination_display_pos', q('BOTTOM_RIGHT')),
            ('report_list_mode', q('TABS')), ('lazy_loading', 'false'), ('show_detail_link', q('N')),
            ('show_notify', q('Y')), ('download_formats', q('CSV:HTML:XLSX:PDF')), ('enable_mail_download', q('N')),
            ('owner', q('LMS')), ('internal_uid', wid)]))
        shown = []
        for i, c in enumerate(cols):
            col, label, typ, fmt, raw = (list(c) + [None, None, None, None])[:5]
            typ = typ or 'STRING'
            letter = ''.join(chr(65 + x) for x in ([i] if i < 26 else [i // 26 - 1, i % 26]))
            p = [('id', ident(self.app.ids())), ('db_column_name', q(col.upper())), ('display_order', (i + 1) * 10),
                 ('column_identifier', q(letter)), ('column_label', q(label)), ('column_type', q(typ))]
            if fmt:
                p.append(('format_mask', q(fmt)))
            if typ == 'DATE':
                p.append(('tz_dependent', q('N')))
            if raw:
                p += [('display_text_as', q('WITHOUT_MODIFICATION')), ('rpt_show_filter_lov', q('N'))]
            if label == '-':   # hidden column
                p += [('display_text_as', q('HIDDEN'))]
            p.append(('use_as_row_header', q('N')))
            self.out.append(call('wwv_flow_imp_page.create_worksheet_column', p))
            if label != '-':
                shown.append(col.upper())
        rpt = [('id', ident(self.app.ids())), ('application_user', q('APXWS_DEFAULT')), ('report_seq', 10),
               ('report_alias', q(str(self.app.ids())[-7:])), ('status', q('PUBLIC')), ('is_default', q('Y')),
               ('report_columns', q(':'.join(shown)))]
        if rows:
            rpt.append(('rows_per_page', rows))
        if sort:
            rpt += [('sort_column_1', q(sort.upper())), ('sort_direction_1', q('DESC' if desc else 'ASC'))]
        self.out.append(call('wwv_flow_imp_page.create_worksheet_rpt', rpt))
        return rid

    # items ---------------------------------------------------------------------------------------------
    def item(self, region, name, kind, label=None, required=False, lov=None, default=None, placeholder=None,
             size=None, maxlen=None, height=None, protected=True, fmt=None, colspan=None, newline=True, help=None):
        assert name.startswith(f'P{self.id}_'), name
        assert name not in self.items, name
        self.items.add(name)
        if lov and not lov.startswith('STATIC'):
            self.records.append(('cond', f'{self.app.id}:{self.id} LOV {name}', lov, None))
        seq = 10 * (len(self.items))
        p = [('id', ident(self.app.ids())), ('name', q(name)), ('is_required', 'true' if required else None),
             ('item_sequence', seq), ('item_plug_id', ident(region)),
             ('item_default', q(default) if default is not None else None),
             ('prompt', q(label) if label and kind != 'hidden' else None),
             ('placeholder', q(placeholder) if placeholder else None),
             ('format_mask', q(fmt) if fmt else None)]
        fld = T['fld_req_above'] if required else T['fld_opt_above']
        if kind == 'hidden':
            p += [('display_as', q('NATIVE_HIDDEN')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('Y' if protected else 'N'))]
        elif kind == 'text':
            p += [('display_as', q('NATIVE_TEXT_FIELD')), ('cSize', size or 40), ('cMaxlength', maxlen or 255),
                  ('field_template', ident(fld)), ('item_template_options', q('#DEFAULT#')),
                  ('encrypt_session_state_yn', q('N')), ('attribute_01', q('N')), ('attribute_02', q('N')),
                  ('attribute_04', q('TEXT')), ('attribute_05', q('BOTH'))]
        elif kind == 'password':
            p += [('display_as', q('NATIVE_PASSWORD')), ('cSize', 30), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('is_persistent', q('N')),
                  ('encrypt_session_state_yn', q('N')), ('attribute_01', q('Y'))]
        elif kind == 'textarea':
            p += [('display_as', q('NATIVE_TEXTAREA')), ('cSize', 60), ('cMaxlength', maxlen or 4000),
                  ('cHeight', height or 4), ('field_template', ident(fld)), ('item_template_options', q('#DEFAULT#')),
                  ('encrypt_session_state_yn', q('N')), ('attribute_01', q('Y')), ('attribute_02', q('N')),
                  ('attribute_03', q('N')), ('attribute_04', q('BOTH'))]
        elif kind == 'number':
            p += [('display_as', q('NATIVE_NUMBER_FIELD')), ('cSize', 15), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_03', q('left')), ('attribute_04', q('decimal'))]
        elif kind == 'date':
            p += [('display_as', q('NATIVE_DATE_PICKER_APEX')), ('cSize', 20), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('N')), ('attribute_02', q('POPUP')), ('attribute_03', q('NONE')),
                  ('attribute_06', q('NONE')), ('attribute_09', q('N')), ('attribute_11', q('Y'))]
            if not fmt:
                p.insert(8, ('format_mask', q('DD-MON-YYYY')))
        elif kind == 'datetime':
            p += [('display_as', q('NATIVE_DATE_PICKER_APEX')), ('cSize', 20), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('N')), ('attribute_02', q('POPUP')), ('attribute_03', q('NONE')),
                  ('attribute_06', q('NONE')), ('attribute_09', q('N')), ('attribute_11', q('Y'))]
            if not fmt:
                p.insert(8, ('format_mask', q('DD-MON-YYYY HH24:MI')))
        elif kind == 'select':
            p += [('display_as', q('NATIVE_SELECT_LIST')), ('lov', q(lov)), ('lov_display_null', q('YES')),
                  ('cHeight', 1), ('field_template', ident(fld)), ('item_template_options', q('#DEFAULT#')),
                  ('lov_display_extra', q('NO')), ('encrypt_session_state_yn', q('N')), ('attribute_01', q('NONE'))]
        elif kind == 'radio':
            p += [('display_as', q('NATIVE_RADIOGROUP')), ('lov', q(lov)), ('lov_display_null', q('NO')),
                  ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#:t-Form-fieldContainer--radioButtonGroup')),
                  ('lov_display_extra', q('NO')), ('encrypt_session_state_yn', q('N')), ('attribute_01', q('6')),
                  ('attribute_02', q('SUBMIT')), ('attribute_03', q('Y')), ('attribute_04', q('HORIZONTAL')),
                  ('attribute_05', q('N'))]
        elif kind == 'radiolist':   # radio group without auto submit
            p += [('display_as', q('NATIVE_RADIOGROUP')), ('lov', q(lov)), ('lov_display_null', q('NO')),
                  ('field_template', ident(fld)), ('item_template_options', q('#DEFAULT#')),
                  ('lov_display_extra', q('NO')), ('encrypt_session_state_yn', q('N')), ('attribute_01', q('1')),
                  ('attribute_02', q('NONE')), ('attribute_03', q('N')), ('attribute_05', q('N'))]
        elif kind == 'checkbox':
            p += [('display_as', q('NATIVE_CHECKBOX')), ('lov', q(lov)), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('lov_display_extra', q('NO')),
                  ('encrypt_session_state_yn', q('N')), ('attribute_01', q('1')), ('attribute_02', q('VERTICAL'))]
        elif kind == 'yesno':
            p += [('display_as', q('NATIVE_YES_NO')), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('Y'))]
        elif kind == 'display':
            p += [('display_as', q('NATIVE_DISPLAY_ONLY')), ('field_template', ident(T['fld_opt_above'])),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('Y')), ('attribute_02', q('VALUE')), ('attribute_04', q('Y')),
                  ('attribute_05', q('PLAIN'))]
        elif kind == 'rating':
            p += [('display_as', q('NATIVE_STAR_RATING')), ('field_template', ident(fld)),
                  ('item_template_options', q('#DEFAULT#')), ('encrypt_session_state_yn', q('N')),
                  ('attribute_01', q('5')), ('attribute_02', q('Y'))]
        else:
            raise ValueError(kind)
        if colspan:
            p += [('colspan', colspan)]
        if not newline:
            p += [('begin_on_new_line', q('N'))]
        self.out.append(call('wwv_flow_imp_page.create_page_item', p))
        return name

    # buttons -------------------------------------------------------------------------------------------
    def button(self, region, name, label, action='SUBMIT', url=None, hot=False, position='NEXT', icon=None,
               cond_exists=None, cond_not_exists=None, confirm=None, seq=None):
        bid = self.app.ids()
        self.btn_seq += 10
        p = [('id', ident(bid)), ('button_sequence', seq or self.btn_seq),
             ('button_plug_id', ident(region)), ('button_name', q(name)),
             ('button_action', q({'SUBMIT': 'SUBMIT', 'URL': 'REDIRECT_URL', 'DA': 'DEFINED_BY_DA'}[action])),
             ('button_template_options', q('#DEFAULT#:t-Button--iconLeft' if icon else '#DEFAULT#')),
             ('button_template_id', ident(T['btn_icon_text'] if icon else T['btn_text'])),
             ('button_is_hot', q('Y') if hot else None), ('button_image_alt', q(label)),
             ('button_position', q(position)),
             ('button_redirect_url', q(url) if action == 'URL' else None),
             ('confirm_message', q(confirm) if confirm else None),
             ('confirm_style', q('danger') if confirm else None)]
        for cnd in (cond_exists, cond_not_exists):
            if cnd:
                self.records.append(('cond', f'{self.app.id}:{self.id} button {name}', cnd, None))
        if cond_exists:
            p += [('button_condition', q(cond_exists)), ('button_condition_type', q('EXISTS'))]
        if cond_not_exists:
            p += [('button_condition', q(cond_not_exists)), ('button_condition_type', q('NOT_EXISTS'))]
        if icon:
            p.append(('icon_css_classes', q(icon)))
        self.out.append(call('wwv_flow_imp_page.create_page_button', p))
        if action == 'DA':
            eid = self.app.ids()
            self.out.append(call('wwv_flow_imp_page.create_page_da_event', [
                ('id', ident(eid)), ('name', q('Cancel dialog')), ('event_sequence', 10),
                ('triggering_element_type', q('BUTTON')), ('triggering_button_id', ident(bid)),
                ('bind_type', q('bind')), ('execution_type', q('IMMEDIATE')), ('bind_event_type', q('click'))]))
            self.out.append(call('wwv_flow_imp_page.create_page_da_action', [
                ('id', ident(self.app.ids())), ('event_id', ident(eid)), ('event_result', q('TRUE')),
                ('action_sequence', 10), ('execute_on_page_init', q('N')), ('action', q('NATIVE_DIALOG_CANCEL'))]))
        return bid

    # processes and branches ---------------------------------------------------------------------------
    def process(self, name, code, point='AFTER_SUBMIT', when_button=None, when_request=None, success=None, seq=None):
        pid = self.app.ids()
        self.records.append(('plsql', f'{self.app.id}:{self.id} process "{name}"', code, None))
        p = [('id', ident(pid)), ('process_sequence', seq or 10 * (1 + sum(1 for o in self.out if 'create_page_process' in o))),
             ('process_point', q(point)), ('process_type', q('NATIVE_PLSQL')), ('process_name', q(name)),
             ('process_sql_clob', q(code)), ('process_clob_language', q('PLSQL')),
             ('error_display_location', q('INLINE_IN_NOTIFICATION'))]
        if when_button:
            p.append(('process_when_button_id', ident(when_button)))
        if when_request:
            p += [('process_when', q(when_request)),
                  ('process_when_type', q('REQUEST_IN_CONDITION' if ',' in when_request else 'REQUEST_EQUALS_CONDITION'))]
        if success:
            p.append(('process_success_message', q(success)))
        p.append(('internal_uid', pid))
        self.out.append(call('wwv_flow_imp_page.create_page_process', p))
        return pid

    def close_dialog(self, requests):
        pid = self.app.ids()
        self.out.append(call('wwv_flow_imp_page.create_page_process', [
            ('id', ident(pid)), ('process_sequence', 900), ('process_point', q('AFTER_SUBMIT')),
            ('process_type', q('NATIVE_CLOSE_WINDOW')), ('process_name', q('Close dialog')),
            ('attribute_02', q('N')), ('error_display_location', q('INLINE_IN_NOTIFICATION')),
            ('process_when', q(requests)), ('process_when_type', q('REQUEST_IN_CONDITION')), ('internal_uid', pid)]))

    def branch(self, page=None, url=None, point='AFTER_PROCESSING', name='Go', seq=10, items=None):
        if url is None:
            url = f'f?p=&APP_ID.:{page if page is not None else self.id}:&SESSION.::&DEBUG.:::&success_msg=#SUCCESS_MSG#'
            if items:
                names, vals = zip(*items)
                url = f'f?p=&APP_ID.:{page}:&SESSION.::&DEBUG.::{",".join(names)}:{",".join(vals)}&success_msg=#SUCCESS_MSG#'
        self.out.append(call('wwv_flow_imp_page.create_page_branch', [
            ('id', ident(self.app.ids())), ('branch_name', q(name)), ('branch_action', q(url)),
            ('branch_point', q(point)), ('branch_type', q('REDIRECT_URL')), ('branch_sequence', seq)]))

    # render --------------------------------------------------------------------------------------------
    def render(self):
        tmpl = {'modal': T['page_modal'], 'login': T['page_login'], 'minimal': T['page_minimal']}.get(
            self.template or ('modal' if self.mode == 'MODAL' else None))
        cmap = '12' if self.template == 'login' else '10' if self.mode == 'MODAL' else '18' if self.has_ir else '16'
        p = [('id', self.id), ('name', q(self.name)), ('alias', q(self.alias) if self.alias else None),
             ('page_mode', q('MODAL') if self.mode == 'MODAL' else None),
             ('step_title', q(self.title)), ('warn_on_unsaved_changes', q('N')),
             ('first_item', q('AUTO_FIRST_ITEM') if self.template == 'login' else None),
             ('autocomplete_on_off', q('OFF')),
             ('inline_css', q(self.inline_css) if self.inline_css else None),
             ('step_template', ident(tmpl) if tmpl else None), ('page_template_options', q('#DEFAULT#')),
             ('required_role', ident(self.app.scheme_id(self.auth)) if self.auth else None),
             ('dialog_chained', q('N') if self.mode == 'MODAL' else None),
             ('page_is_public_y_n', q('Y') if self.public else None),
             ('protection_level', q(self.protection)), ('page_component_map', q(cmap))]
        head = call('wwv_flow_imp_page.create_page', p)
        return (f'prompt --application/pages/page_{self.id:05d}\nbegin\n' + head + '\n' + '\n'.join(self.out)
                + '\nend;\n/\n')


class App:
    def __init__(self, app_id, alias, name, base_export, home=1):
        self.id, self.alias, self.name, self.home = app_id, alias, name, home
        self.ids = Ids(60_000_000_000_000 + app_id * 10_000_000)
        self.blocks = split_blocks(base_export)
        self.schemes = {}       # name -> (id, body, evaluation)
        self.pages = []
        self.items = []         # application items
        self.nav = []           # (label, page, icon, scheme, pages_current)
        self.navbar = []
        self.files = []         # (file_name, mime, bytes)
        self.app_processes = [] # (name, code, request_list)
        self.auth_id = self.ids()
        self.list_nav = self.ids()
        self.list_bar = self.ids()

    def scheme(self, name, body, per_page=False):
        if name not in self.schemes:
            self.schemes[name] = (self.ids(), body, per_page)
        return self.schemes[name][0]

    def scheme_id(self, name):
        return self.schemes[name][0]

    # -------------------------------------------------------------------------------------------------
    def render(self):
        b = dict(self.blocks)
        env = b['application/set_environment']
        env = re.sub(r"p_default_application_id=>\d+", f"p_default_application_id=>{self.id}", env)
        env = re.sub(r"p_default_owner=>'[^']*'", "p_default_owner=>'LMS'", env)
        # a distinct id offset per application, so the five apps (and any app built from the same theme export)
        # never share component ids in one workspace
        env = re.sub(r"p_default_id_offset=>\d+", f"p_default_id_offset=>{5_200_000_000_000_000_000 + self.id * 10_000_000_000_000_000}", env)
        env = re.sub(r"prompt APPLICATION \d+ - .*", f"prompt APPLICATION {self.id} - {self.name}", env)
        env = re.sub(r'(?s)--\s*\n-- Application Export:.*?--   Instance ID:\s+\d+\n--\n',
                     f'--\n-- Generated import for "{self.name}" (application {self.id}).\n'
                     '-- Theme blocks copied from an APEX 24.1 export; pages and shared components generated.\n'
                     '-- STATUS: generated, NOT yet imported or run on APEX.\n--\n', env)
        out = [env, b['application/delete_application']]
        out.append('prompt --application/create_application\nbegin\n' + call('wwv_imp_workspace.create_flow', [
            ('id', 'wwv_flow.g_flow_id'), ('owner', "nvl(wwv_flow_application_install.get_schema,'LMS')"),
            ('name', f"nvl(wwv_flow_application_install.get_application_name,{q(self.name)})"),
            ('alias', f"nvl(wwv_flow_application_install.get_application_alias,{q(self.alias.upper())})"),
            ('page_view_logging', q('YES')), ('page_protection_enabled_y_n', q('Y')),
            ('checksum_salt', q(secrets.token_hex(32).upper())), ('bookmark_checksum_function', q('SH512')),
            ('compatibility_mode', q('21.2')), ('accessible_read_only', q('N')),
            ('session_state_commits', q('IMMEDIATE')), ('flow_language', q('en')),
            ('flow_language_derived_from', q('SESSION')), ('date_format', q('DD-MON-YYYY')),
            ('date_time_format', q('DD-MON-YYYY HH24:MI')), ('timestamp_format', q('DS')),
            ('timestamp_tz_format', q('DS')), ('direction_right_to_left', q('N')),
            ('flow_image_prefix ', "nvl(wwv_flow_application_install.get_image_prefix,'')"),
            ('documentation_banner', q('Enterprise LMS - generated from LMS_PROJECT (02_DATABASE + 03_APEX specifications).')),
            ('authentication_id', ident(self.auth_id)), ('application_tab_set', 1), ('logo_type', q('T')),
            ('logo_text', q(self.name)), ('public_user', q('APEX_PUBLIC_USER')),
            ('proxy_server', "nvl(wwv_flow_application_install.get_proxy,'')"),
            ('no_proxy_domains', "nvl(wwv_flow_application_install.get_no_proxy_domains,'')"),
            ('flow_version', q('Release 1.0')), ('flow_status', q('AVAILABLE_W_EDIT_LINK')),
            ('flow_unavailable_text', q('The learning system is temporarily unavailable.')),
            ('exact_substitutions_only', q('Y')), ('browser_cache', q('N')), ('browser_frame', q('D')),
            ('runtime_api_usage', q('T')), ('pass_ecid', q('N')), ('rejoin_existing_sessions', q('N')),
            ('csv_encoding', q('Y')), ('auto_time_zone', q('N')),
            ('error_handling_function', q('lms_apex_pkg.error_handler')), ('tokenize_row_search', q('N')),
            ('substitution_string_01', q('APP_NAME')), ('substitution_value_01', q(self.name)),
            ('file_prefix ', "nvl(wwv_flow_application_install.get_static_app_file_prefix,'')"),
            ('files_version', 1), ('print_server_type', q('NATIVE')), ('file_storage', q('DB')), ('is_pwa', q('N')),
        ])
            + '\nend;\n/\n')
        css = ':'.join('#APP_FILES#' + f for f, m, _ in self.files if f.endswith('.css'))
        js = ':'.join('#APP_FILES#' + f for f, m, _ in self.files if f.endswith('.js') and f.startswith('app'))
        out.append('prompt --application/user_interfaces\nbegin\n' + call('wwv_flow_imp_shared.create_user_interface', [
            ('id', ident(self.ids())), ('theme_id', 42), ('home_url', q(f'f?p=&APP_ID.:{self.home}:&SESSION.')),
            ('login_url', q('f?p=&APP_ID.:LOGIN:&APP_SESSION.::&DEBUG.:::')), ('theme_style_by_user_pref', 'false'),
            ('global_page_id', 0), ('navigation_list_id', ident(self.list_nav)),
            ('navigation_list_position', q('SIDE')), ('navigation_list_template_id', ident(T['list_side'])),
            ('nav_list_template_options', q('#DEFAULT#:t-TreeNav--styleA')),
            ('css_file_urls', q(css) if css else None), ('javascript_file_urls', q(js) if js else None),
            ('nav_bar_type', q('LIST')), ('nav_bar_list_id', ident(self.list_bar)),
            ('nav_bar_list_template_id', ident(T['list_navbar'])), ('nav_bar_template_options', q('#DEFAULT#'))])
            + '\nend;\n/\n')
        # lists
        out.append(self._list('desktop_navigation_menu', 'Desktop Navigation Menu', self.list_nav, self.nav))
        out.append(self._list('desktop_navigation_bar', 'Desktop Navigation Bar', self.list_bar, self.navbar))
        out.append('prompt --application/shared_components/navigation/listentry\nbegin\nnull;\nend;\n/\n')
        # static files
        for fname, mime, data in self.files:
            hexs = data.hex().upper()
            rows = [hexs[i:i + 400] for i in range(0, len(hexs), 400)]
            body = 'wwv_flow_imp.g_varchar2_table := wwv_flow_imp.empty_varchar2_table;\n' + ''.join(
                f"wwv_flow_imp.g_varchar2_table({i + 1}) := '{r}';\n" for i, r in enumerate(rows))
            out.append(f'prompt --application/shared_components/files/{re.sub(r"[^a-z0-9]", "_", fname.lower())}\nbegin\n'
                       + body + call('wwv_flow_imp_shared.create_app_static_file', [
                           ('id', ident(self.ids())), ('file_name', q(fname)), ('mime_type', q(mime)),
                           ('file_charset', q('utf-8')),
                           ('file_content ', 'wwv_flow_imp.varchar2_to_blob(wwv_flow_imp.g_varchar2_table)')])
                       + '\nend;\n/\n')
        # authorization schemes
        for name, (sid, body, per_page) in self.schemes.items():
            out.append(f'prompt --application/shared_components/security/authorizations/{name.lower()}\nbegin\n'
                       + call('wwv_flow_imp_shared.create_security_scheme', [
                           ('id', ident(sid)), ('name', q(name)), ('scheme_type', q('NATIVE_FUNCTION_BODY')),
                           ('attribute_01', q(body)),
                           ('error_message', q('You do not have access to this page.')), ('version_scn', 1),
                           ('caching', q('BY_USER_BY_PAGE_VIEW' if per_page else 'BY_USER_BY_SESSION'))])
                       + '\nend;\n/\n')
        # application items
        for it in self.items:
            out.append(f'prompt --application/shared_components/logic/application_items/{it.lower()}\nbegin\n'
                       + call('wwv_flow_imp_shared.create_flow_item', [
                           ('id', ident(self.ids())), ('name', q(it)), ('protection_level', q('I')), ('version_scn', 1)])
                       + '\nend;\n/\n')
        for name, code, req in self.app_processes:
            out.append(f'prompt --application/shared_components/logic/application_processes/{name.lower()}\nbegin\n'
                       + call('wwv_flow_imp_shared.create_flow_process', [
                           ('id', ident(self.ids())), ('process_sequence', 1), ('process_point', q('BEFORE_HEADER')),
                           ('process_type', q('NATIVE_PLSQL')), ('process_name', q(name)),
                           ('process_sql_clob', q(code)), ('process_clob_language', q('PLSQL')),
                           ('process_when', q(req) if req else None),
                           ('process_when_type', q('REQUEST_IN_CONDITION') if req else None),
                           ('version_scn', 1)])
                       + '\nend;\n/\n')
        # theme and fixed blocks, in export order
        for name, text in self.blocks:
            if name.startswith(THEME_PREFIXES):
                out.append(text if text.endswith('\n') else text + '\n')
            if name == 'application/shared_components/logic/build_options':
                out.append(self._auth())
        for pg in sorted(self.pages, key=lambda x: x.id):
            out.append(pg.render())
        out.append(b['application/end_environment'])
        return ''.join(out)

    def _list(self, slug, name, lid, entries):
        s = (f'prompt --application/shared_components/navigation/lists/{slug}\nbegin\n'
             + call('wwv_flow_imp_shared.create_list', [('id', ident(lid)), ('name', q(name)),
                                                         ('list_status', q('PUBLIC')), ('version_scn', 1)]) + '\n')
        parents = {}
        for i, e in enumerate(entries):
            label, target, icon, scheme, current, parent = (list(e) + [None] * 6)[:6]
            iid = self.ids()
            parents[label] = iid
            if isinstance(target, int):
                target = f'f?p=&APP_ID.:{target}:&SESSION.::&DEBUG.:::'
            p = [('id', ident(iid)), ('list_item_display_sequence', (i + 1) * 10), ('list_item_link_text', q(label)),
                 ('list_item_link_target', q(target) if target else None), ('list_item_icon', q(icon) if icon else None),
                 ('parent_list_item_id', ident(parents[parent]) if parent else None),
                 ('security_scheme', ident(self.scheme_id(scheme)) if scheme else None)]
            if current:
                p += [('list_item_current_type', q('COLON_DELIMITED_PAGE_LIST')),
                      ('list_item_current_for_pages', q(current))]
            else:
                p += [('list_item_current_type', q('NEVER'))]
            s += call('wwv_flow_imp_shared.create_list_item', p) + '\n'
        return s + 'end;\n/\n'

    def _auth(self):
        return ('prompt --application/shared_components/security/authentications/oracle_apex_accounts\nbegin\n'
                + call('wwv_flow_imp_shared.create_authentication', [
                    ('id', ident(self.auth_id)), ('name', q('Oracle APEX Accounts')),
                    ('scheme_type', q('NATIVE_APEX_ACCOUNTS')), ('invalid_session_type', q('LOGIN')),
                    ('post_auth_process', q('lms_apex_pkg.post_auth')),
                    ('use_secure_cookie_yn', q('N')), ('ras_mode', 0), ('version_scn', 1),
                    ('comments', q('Development scheme: APEX workspace accounts. Usernames must match LMS_USERS.USERNAME '
                                   '(upper case). For production switch to the corporate SSO scheme and keep the '
                                   'post-authentication procedure.'))])
                + '\nend;\n/\n')
