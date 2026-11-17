# LMS application import files (Oracle APEX 24.1)

Five application exports built on the database in `../../02_DATABASE` and the page specifications in `../PAGE_SPECIFICATIONS`.

| File | App | Alias | Pages | Audience |
|---|---|---|---|---|
| `f200.sql` | LMS Learning Portal | `LMS` | 22 | everyone |
| `f210.sql` | LMS Instructor Portal | `LMS-INSTRUCTOR` | 21 | instructors, training admins |
| `f220.sql` | LMS Administration | `LMS-ADMIN` | 30 | training and system admins |
| `f230.sql` | LMS Management | `LMS-MANAGER` | 12 | managers, HR |
| `f240.sql` | LMS Analytics | `LMS-ANALYTICS` | 6 | executives, HR, training admins |

**Status: generated and statically checked, NOT yet imported into APEX or run.** Expect to fix a few things on the first import.

## What was checked (and what was not)
Checked by the generator before writing the files:
- every view a page reads exists in `02_DATABASE`, and every column named in an interactive report, a select list or a
  button condition exists in that view (sqlglot parse of each query);
- every `LMS_*_PKG` call names an existing package member with a valid number of arguments;
- every page item a page references is defined on that page;
- each file: balanced quotes and parentheses in every block, unique component ids, every `wwv_flow_imp.id()` reference
  points to a component or theme template defined in the file, ASCII only;
- the Universal Theme 42 blocks are copied unchanged from an export produced by your APEX 24.1 instance, and all
  import-API calls use the parameter names found in that export, with two exceptions:
  `p_post_auth_process` (authentication scheme) and the caching value `BY_USER_BY_SESSION` (authorization schemes).
  Both are standard APEX settings; if the import rejects either, set them in the Builder instead.

Not checked: the import itself, the PL/SQL inside pages (it is compiled at run time), page layout and behaviour.

## Before importing
1. **Use a separate schema** for this design, for example `LMS`. Do not install it into `AUTH`: your existing
   application uses `LMS_*` tables and packages of a different design there, and the names would collide.
2. Install the database (as that schema, UTF-8 client):
   `@00_install.sql`, then `@17_bootstrap_sysadmin.sql <USERNAME> <EMP_NO> "<NAME>" <EMAIL>` with the
   **APEX username you will sign in with**. Optional DEV data: `@10_test_data.sql`.
3. Assign the schema to the APEX workspace (Administration > Manage Workspaces > Workspace to Schema Assignment).
4. The applications use **Oracle APEX Accounts** for development: create an APEX workspace user with the same
   username (Administration > Manage Users and Groups). Sign-in only works for usernames that also exist and are
   ACTIVE in `LMS_USERS` (the post-authentication procedure `lms_apex_pkg.post_auth` checks this).

## Importing
**Builder:** App Builder > Import > choose the file > Install Application: parsing schema = your LMS schema,
Application ID = *Reuse application ID 200 (210, ...) from export file*. Keep the IDs: the navigation between the
apps uses 200-240.

**SQLcl / SQL*Plus:** from this folder, `@install_apps.sql <WORKSPACE> <SCHEMA>`.

Each file has its own id offset, so the five apps can live in one workspace next to your existing application.

## After importing (Shared Components)
- **Session sharing between the five apps:** Authentication Schemes > Oracle APEX Accounts > Session Sharing >
  Type *Workspace Sharing* in every app; otherwise each app asks for sign-in separately.
- **Security attributes:** session idle timeout 1800 s and maximum 28800 s; "Session Timeout URL" = page 9998;
  HTTP response headers from `../SHARED_COMPONENTS/README.md` section 2.
- **Rotate the checksum salt** (Security Attributes > Expire Bookmarks), because the salt in these files is in source control.
- **Arabic:** Globalization > add Arabic (`ar`) to the language map; load `../SHARED_COMPONENTS/text_messages.csv`
  as Text Messages. Page and region titles are English in this version.
- **Production sign-in:** replace Oracle APEX Accounts with the corporate SSO scheme and keep
  `lms_apex_pkg.post_auth` as its post-authentication procedure.

## How these pages differ from the page specifications
Built for a reliable first import, so they use fewer component types than the specifications describe:
- lists are **Interactive Reports** (not Cards, Faceted Search, Interactive Grids or charts); edit forms sit above
  the list on the same page, and row actions (move, remove, cancel, hide) are checksummed links;
- forms are normal pages, not modal dialogs;
- the learning player and the assessment are **server-rendered** (no `player.js` / `assessment.js`): lessons are
  completed with *Mark complete*, quiz answers are saved on Next/Previous/Submit and the deadline is enforced by the
  database; there are no progress heartbeats, so time-on-lesson is not measured;
- lesson files are attached as an object-store key or link (no upload item yet);
- a session is managed in the Instructor portal; the Administration schedule links there.

## Regenerating
The files are produced by `generator/` (Python 3 with `sqlglot`):
```
cd generator
python3 extract_db.py     # reads 02_DATABASE: view columns and package signatures
python3 build.py ..       # writes ../f200.sql ... ../f240.sql and prints any issue found
python3 structcheck.py ../f*.sql
```
Edit the page definitions in `app200.py` ... `app240.py`; shared parts are in `common.py` and `engine.py`.
`theme_ut42_base.sql` holds only the Universal Theme blocks (no application content).
