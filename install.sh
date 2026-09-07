#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash install.sh [workspace-root] [old-kit-directory-or-old-install.sh]
#
# No old installer is executed, and no interactive shell is launched.

root=${1:-"$HOME/cf-contests"}
old=${2:-"${XDG_DATA_HOME:-$HOME/.local/share}/cf-contest"}

python3 - "$root" "$old" <<'PY_INSTALL'
import ast, copy, os, re, shutil, sys, tempfile
from pathlib import Path

root = Path(sys.argv[1]).expanduser().resolve()
old = Path(sys.argv[2]).expanduser().resolve()
required = ('cf.py', 'cf.lua', 'solution.cpp', 'brute.cpp', 'gen.cpp')

# Read the earlier code as data, never execute its installer.
if old.is_dir():
    missing = [name for name in required if not (old / name).is_file()]
    if missing:
        raise SystemExit(
            f'Missing {missing} in {old}.\n'
            'Pass the previous inline kit directory, or its install.sh, '
            'as argument 2.'
        )
    source = {name: (old / name).read_text() for name in required}

elif old.is_file():
    text = old.read_text()
    source = {}
    pattern = (
        r'cat\s*>\s*"\$stage/([^"\n]+)"\s*'
        r'<<\s*[\'\"]([^\'\"\n]+)[\'\"]\r?\n'
    )
    for match in re.finditer(pattern, text):
        end = re.search(
            r'^' + re.escape(match[2]) + r'\r?$',
            text[match.end():],
            re.M,
        )
        if end:
            source[match[1]] = text[
                match.end():match.end() + end.start()
            ]

    if any(name not in source for name in required):
        raise SystemExit(
            'Could not find the previous inline installer payloads '
            'in that file.'
        )
else:
    raise SystemExit(
        f'Previous inline kit not found: {old}\n'
        'Pass its directory or saved install.sh as argument 2.'
    )

if sys.version_info < (3, 11):
    raise SystemExit('Python 3.11 or newer is required.')

if (root / 'scripts').exists() or (root / 'scripts').is_symlink():
    raise SystemExit(
        f'Refusing to overwrite {root / "scripts"}.\n'
        'Choose a root without an existing scripts directory.'
    )

if root.exists() and not root.is_dir():
    raise SystemExit('Argument 1 must be a workspace directory.')

if (
    (root / 'templates').is_symlink()
    or (
        (root / 'templates').exists()
        and not (root / 'templates').is_dir()
    )
):
    raise SystemExit(
        'templates must be a real directory, not a symlink or file.'
    )

tree = ast.parse(source['cf.py'])
functions = {
    n.name: n for n in tree.body
    if isinstance(n, ast.FunctionDef)
}

groups = {
    'common.py':
        'fail stamp ident idx key atomic write_json metadata '
        'locked context problem',
    'fetch.py':
        'pre_text parse_page scaffold',
    'runner.py':
        'limits execute compile_cpp show diff_bytes checker compare tests',
    'stress.py':
        'stress',
    'editor.py':
        'browser edit',
}

needed = set('positive arguments main restore'.split())
for names in groups.values():
    needed.update(names.split())

if not needed <= functions.keys():
    raise SystemExit(
        'This is not the previous inline cf.py version; '
        'no files were changed.'
    )


class Rewrite(ast.NodeTransformer):
    def visit_BinOp(self, node):
        node = self.generic_visit(node)
        if (
            isinstance(node.op, ast.Div)
            and isinstance(node.left, ast.Name)
            and node.left.id == 'ROOT'
            and isinstance(node.right, ast.Constant)
        ):
            paths = {
                'solution.cpp': "ROOT / 'template.cpp'",
                'brute.cpp': "ROOT / 'templates' / 'brute.cpp'",
                'gen.cpp': "ROOT / 'templates' / 'gen.cpp'",
                'cf.py': "ROOT / 'scripts' / 'cf'",
                'cf.lua': "ROOT / 'scripts' / 'nvim.lua'",
            }
            if node.right.value in paths:
                return ast.parse(
                    paths[node.right.value], mode='eval'
                ).body
        return node

    def visit_Constant(self, node):
        if node.value == 'cf-contest inline 1.0':
            return ast.Constant('cf-contest modular 1.0')
        return node

    def visit_Expr(self, node):
        node = self.generic_visit(node)
        call = node.value
        if (
            isinstance(call, ast.Call)
            and isinstance(call.func, ast.Attribute)
            and call.func.attr == 'add_argument'
            and call.args
            and isinstance(call.args[0], ast.Constant)
            and call.args[0].value == 'problem'
        ):
            extra = ast.parse(
                "if cmd == 'archive': "
                "q.add_argument('contest_id', nargs='?')"
            ).body[0]
            return [node, extra]
        return node

    def visit_If(self, node):
        node = self.generic_visit(node)
        if ast.unparse(node.test) == "a.command == 'archive' and a.problem":
            return ast.parse("""
if a.command == 'archive':
    if a.contest_id:
        if not a.problem:
            fail('Use archive CONTEST or archive PROBLEM CONTEST.')
        a.contest = ident(a.contest_id)
    else:
        a.contest = ident(a.problem) if a.problem else a.contest
        a.problem = None
""").body[0]
        return node

    def visit_Call(self, node):
        node = self.generic_visit(node)
        if isinstance(node.func, ast.Name) and node.func.id == 'archive':
            node.args.append(
                ast.Attribute(
                    value=ast.Name(id='a', ctx=ast.Load()),
                    attr='problem',
                    ctx=ast.Load(),
                )
            )
        return node


def render(names):
    body = [
        copy.deepcopy(functions[name])
        for name in names.split()
    ]
    module = Rewrite().visit(
        ast.Module(body=body, type_ignores=[])
    )
    ast.fix_missing_locations(module)
    return (
        ast.unparse(module)
        .replace('cf_inline_cli', 'cf_modular_cli')
        + '\n'
    )


imports = '\n'.join(
    ast.unparse(n) for n in tree.body
    if isinstance(n, (ast.Import, ast.ImportFrom))
)
common_head = imports + """
ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT
MARK = '.cf-contest.json'

"""

files = {}
for filename, names in groups.items():
    head = (
        common_head if filename == 'common.py'
        else 'from common import *\n'
    )
    if filename == 'stress.py':
        head += (
            'from runner import compile_cpp, checker, execute, '
            'compare, show, diff_bytes\n'
        )
    files[filename] = head + render(names)

# Retain compatibility with tar.gz archives made by the previous kit.
legacy = copy.deepcopy(functions['restore'])
legacy.name = 'restore_tar'
legacy = Rewrite().visit(legacy)
ast.fix_missing_locations(legacy)

files['archiving.py'] = (
    'from common import *\n\n'
    + ast.unparse(legacy)
    + '\n\n'
    + r'''
def excluded(rel):
    return (
        '.cf' in rel.parts
        or '__pycache__' in rel.parts
        or rel.name.endswith(('.swp', '.swo', '~'))
    )


def inventory(folder):
    result = {}
    for f in sorted(folder.rglob('*')):
        rel = f.relative_to(folder)
        if excluded(rel):
            continue
        if f.is_symlink() or not (f.is_file() or f.is_dir()):
            fail('Snapshot refuses links/special files: ' + str(f))
        if f.is_file():
            with f.open('rb') as stream:
                result[str(rel)] = hashlib.file_digest(
                    stream, 'sha256'
                ).hexdigest()
        else:
            result[str(rel)] = None
    return result


def copy_verified(source, target):
    source = source.resolve()

    if target.resolve().is_relative_to(source):
        fail('Archive destination must be outside the source directory.')
    if target.exists() or target.is_symlink():
        fail(
            'Destination already exists; nothing was overwritten: '
            + str(target)
        )

    before = inventory(source)
    target.parent.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(
        prefix='.snapshot-', dir=target.parent
    ))

    try:
        def ignore(directory, names):
            return [
                name for name in names
                if excluded(
                    (Path(directory) / name).relative_to(source)
                )
            ]

        shutil.copytree(source, stage / 'data', ignore=ignore)

        if (
            inventory(stage / 'data') != before
            or inventory(source) != before
        ):
            fail(
                'Files changed during copying. Originals are intact; '
                'save your files and retry.'
            )

        if target.exists() or target.is_symlink():
            fail('Destination appeared during copying; not overwritten.')

        (stage / 'data').rename(target)
    finally:
        shutil.rmtree(stage)

    return target


def archive(folder, m, label=None):
    cid = key(m['id'], m['kind'] == 'gym')

    if label:
        selected, _, name = problem(folder, m, label)
        base = HOME / 'archive' / 'problems' / cid / name.lower()
        description = f'problem {name} of contest {m["id"]}'
    else:
        selected = folder
        base = HOME / 'archive' / 'contests' / cid
        description = f'whole contest {m["id"]}'

    saved = copy_verified(selected, base / stamp())
    print(
        f'Archived {description}:\n{saved}\n'
        'Working files kept in place.'
    )


def restore(source):
    source = source.expanduser().resolve()

    if source.is_file():
        return restore_tar(source)

    if not (source / MARK).is_file():
        fail(
            'Select a whole-contest snapshot containing '
            '.cf-contest.json. Problem-only snapshots can be '
            'copied back manually.'
        )

    m = metadata(source)
    cid = key(m['id'], m['kind'] == 'gym')

    with locked(cid):
        target = HOME / 'contests' / cid
        copy_verified(source, target)
        atomic(HOME / '.active', cid.encode())

    print('Restored: ' + str(target))
'''
)

files['cf'] = """#!/usr/bin/env python3
from common import *
from fetch import scaffold
from runner import compile_cpp, tests, execute, show, diff_bytes
from stress import stress
from editor import edit, browser
from archiving import archive, restore

""" + render('positive arguments main') + """
if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('Interrupted.', file=sys.stderr)
        sys.exit(130)
    except (
        RuntimeError, OSError, ValueError, KeyError,
        subprocess.SubprocessError,
    ) as e:
        print('cf: ' + str(e), file=sys.stderr)
        sys.exit(2)
"""

# Give the new editor integration its own state and point it at scripts/cf.
lua = source['cf.lua'].replace(
    'CFContestInline', 'CFContestModular'
)
lua = (
    lua.replace('cf_inline_', 'cf_modular_')
    .replace('CfContestInlineSession', 'CfContestModularSession')
)
lua = lua.replace(
    'if _G.CFContestModular then return _G.CFContestModular end',
    'if _G.CFContestModular and '
    '_G.CFContestModular.cli == vim.g.cf_modular_cli '
    'then return _G.CFContestModular end',
)
lua = lua.replace(
    'local cli = assert(vim.g.cf_modular_cli)',
    'local cli = assert(vim.g.cf_modular_cli)\n'
    'M.cli = cli\n'
    'pcall(api.nvim_del_augroup_by_name, "CfContestInlineSession")\n'
    'pcall(api.nvim_del_augroup_by_name, "CfContestSession")',
)

# Replace this kit's runtime :Cf commands rather than retaining old ones.
lua, count = re.subn(
    r'local function make\(name, callback, opts\).*?\nend',
    'local function make(name, callback, opts)\n'
    '  opts = opts or {}\n'
    '  opts.force = true\n'
    '  api.nvim_create_user_command(name, callback, opts)\n'
    'end',
    lua,
    count=1,
    flags=re.S,
)
if count != 1:
    raise SystemExit(
        'Unrecognized cf.lua version; no files were installed.'
    )
files['nvim.lua'] = lua

files['shell.sh'] = r'''# Source in your EXISTING Bash/Zsh shell, after old CP aliases.
# Only the in-memory cf, cfc, switch and archive commands are replaced.
if [ -n "${BASH_VERSION-}" ]; then
    _cf_source=${BASH_SOURCE[0]}
elif [ -n "${ZSH_VERSION-}" ]; then
    _cf_source=${(%):-%N}
else
    printf '%s\n' 'shell.sh requires Bash or Zsh.' >&2
    return 2
fi

CF_CONTEST_ROOT=$(command python3 -c \
    'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent.parent)' \
    "$_cf_source") || return
export CF_CONTEST_ROOT

case "$PATH" in
    "$CF_CONTEST_ROOT/scripts"|"$CF_CONTEST_ROOT/scripts:"*) ;;
    *) export PATH="$CF_CONTEST_ROOT/scripts:$PATH" ;;
esac

unset _cf_source

for _cf_name in cf cfc switch archive; do
    builtin unalias "$_cf_name" 2>/dev/null || :
    builtin unset -f "$_cf_name" 2>/dev/null || :
done
unset _cf_name

function cf {
    command "$CF_CONTEST_ROOT/scripts/cf" "$@"
}

function cfc {
    if builtin test "$#" -lt 1; then
        builtin printf '%s\n' 'usage: cfc ID [--gym]' >&2
        return 2
    fi
    builtin local _cf_id=$1 _cf_dir
    builtin shift
    _cf_dir=$(command "$CF_CONTEST_ROOT/scripts/cf" \
        path --contest "$_cf_id" "$@") || return
    builtin cd -- "$_cf_dir"
}

function switch {
    builtin local _cf_file
    _cf_file=$(command "$CF_CONTEST_ROOT/scripts/cf" \
        path "$@" --file) || return

    if ! builtin test -f "$_cf_file"; then
        builtin printf 'Missing source: %s\n' "$_cf_file" >&2
        return 2
    fi

    builtin cd -- "${_cf_file%/*}" || return
    command "$CF_CONTEST_ROOT/scripts/cf" edit
}

function archive {
    command "$CF_CONTEST_ROOT/scripts/cf" archive "$@"
}

builtin :
'''

# Check all generated Python before publishing anything.
for name, text in files.items():
    if name.endswith('.py') or name == 'cf':
        compile(text, name, 'exec')

root.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(
    prefix='.cf-modular-install-', dir=root
))
created = []
published = False

try:
    scripts = stage / 'scripts'
    scripts.mkdir()

    for name, text in files.items():
        (scripts / name).write_text(text)
    (scripts / 'cf').chmod(0o755)

    # Preserve existing templates and every contest/archive.
    templates = {
        root / 'template.cpp': source['solution.cpp'],
        root / 'templates/brute.cpp': source['brute.cpp'],
        root / 'templates/gen.cpp': source['gen.cpp'],
    }
    for path, text in templates.items():
        if not path.exists() and not path.is_symlink():
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open('x') as f:
                created.append(path)
                f.write(text)

    if (root / 'scripts').exists() or (root / 'scripts').is_symlink():
        raise RuntimeError(
            'scripts appeared during installation; refusing to overwrite it.'
        )

    scripts.rename(root / 'scripts')
    published = True
except BaseException:
    if not published:
        for path in created:
            path.unlink(missing_ok=True)
    raise
finally:
    shutil.rmtree(stage)

print(f'Installed modular scripts in: {root / "scripts"}')
print(
    'No new shell was started. No shell rc, Neovim config, '
    'or contest source was edited.'
)
print('Run in your CURRENT Bash/Zsh shell:')
import shlex
print('  source ' + shlex.quote(str(root / 'scripts/shell.sh')))
print(
    'Commands: archive 2259 | archive a 2259 | '
    'cf parse 2259 | switch a'
)
PY_INSTALL
