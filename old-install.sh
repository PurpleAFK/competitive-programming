#!/usr/bin/env bash
set -euo pipefail
umask 077

for cmd in python3 g++ nvim; do
    command -v "$cmd" >/dev/null || {
        echo "Missing $cmd; install the Fedora dependencies first." >&2
        exit 1
    }
done

python3 -c 'import sys; assert sys.version_info >= (3, 11); import bs4' || {
    echo 'Need Python >=3.11 and BeautifulSoup for this python3 interpreter.' >&2
    exit 1
}

data=$(python3 -c \
    'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' \
    "${XDG_DATA_HOME:-$HOME/.local/share}/cf-contest")
bin="$HOME/.local/bin"

if [[ -e "$data" || -L "$data" || -e "$bin/cf-shell" || -L "$bin/cf-shell" ]] \
    || command -v cf-shell >/dev/null 2>&1; then
    echo 'Refusing to overwrite an existing cf-contest installation or cf-shell command.' >&2
    exit 1
fi

mkdir -p "${data%/*}" "$bin"
stage=$(mktemp -d "${data}.tmp.XXXXXX")
installed=0
success=0

cleanup() {
    if [[ -d "$stage" ]]; then rm -rf -- "$stage"; fi
    if [[ $installed == 1 && $success == 0 ]]; then rm -rf -- "$data"; fi
}
trap cleanup EXIT
mkdir -p "$stage/bin"

cat >"$stage/cf.py" <<'PY_CF'
#!/usr/bin/env python3
import argparse, contextlib, difflib, fcntl, hashlib, json, math, os, re
import resource, shlex, shutil, signal, subprocess, sys, tarfile, tempfile, time
from datetime import datetime
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parent
HOME = Path(os.environ.get('CF_HOME', '~/cf-contests')).expanduser().resolve()
MARK = '.cf-contest.json'


def fail(message):
    raise RuntimeError(message)


def stamp():
    return datetime.now().strftime('%Y%m%d-%H%M%S-%f')


def ident(s):
    if not re.fullmatch(r'[1-9][0-9]{0,8}', str(s)):
        fail('Use a positive numeric contest ID.')
    return str(s)


def idx(s):
    s = str(s).upper()
    if not re.fullmatch(r'[A-Z][A-Z0-9]{0,15}', s):
        fail('Invalid problem index: ' + s)
    return s


def key(cid, gym=False):
    return ('gym-' if gym else '') + ident(cid)


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def write_json(path, obj):
    atomic(path, (json.dumps(obj, indent=2) + '\n').encode())


def metadata(folder):
    m = json.loads((folder / MARK).read_text())
    if m.get('version') != 1 or m.get('kind') not in ('contest', 'gym'):
        fail('Unknown workspace format: ' + str(folder))
    ident(m['id'])
    if (not m['indices']
            or any(idx(x) != x for x in m['indices'])
            or len(set(m['indices'])) != len(m['indices'])):
        fail('Invalid problem list in metadata.')
    return m


@contextlib.contextmanager
def locked(k):
    d = HOME / '.locks'
    d.mkdir(parents=True, exist_ok=True)
    with (d / k).open('a') as f:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            fail('Another cf operation is using this contest. Retry when it finishes.')
        yield


def context(a):
    if a.contest:
        folder = HOME / 'contests' / key(a.contest, a.gym)
    else:
        folder = next(
            (p for p in [Path.cwd(), *Path.cwd().parents]
             if (p / MARK).is_file()),
            None,
        )
        if folder is None:
            state = HOME / '.active'
            if not state.is_file():
                fail('Run cf parse ID, then cfc ID.')
            k = state.read_text().strip()
            if not re.fullmatch(r'(gym-)?[1-9][0-9]{0,8}', k):
                fail('Invalid active contest.')
            folder = HOME / 'contests' / k
    return folder, metadata(folder)


def problem(folder, m, label=None, first=False):
    try:
        parts = Path.cwd().relative_to(folder).parts
        current = parts[0].upper() if parts else None
    except ValueError:
        current = None

    if current not in m['indices']:
        current = None

    if label in ('next', 'prev'):
        if not current:
            fail('next/prev need a current problem.')
        i = m['indices'].index(current)
        label = m['indices'][
            (i + (1 if label == 'next' else -1)) % len(m['indices'])
        ]

    name = idx(label) if label else current or (
        m['indices'][0] if first else None
    )
    if name not in m['indices']:
        fail('Select a problem: ' + ' '.join(m['indices']))

    p = folder / name.lower()
    if not p.is_dir():
        fail('Missing problem directory: ' + str(p))
    return p, p / (name.lower() + '.cpp'), name


def pre_text(pre):
    from bs4 import Comment, NavigableString, Tag

    def block(n):
        return isinstance(n, Tag) and n.name in ('div', 'p')

    def children(parent):
        nodes = list(parent.children)
        blocks = any(block(n) for n in nodes)
        out = []

        for i, n in enumerate(nodes):
            if isinstance(n, Comment):
                continue
            if isinstance(n, NavigableString):
                text = (
                    str(n).replace('\r\n', '\n')
                    .replace('\r', '\n').replace('\xa0', ' ')
                )
                # HTML discards one LF immediately following <pre>.
                if parent is pre and i == 0 and text.startswith('\n'):
                    text = text[1:]
                if blocks and not text.strip():
                    continue
            elif n.name == 'br':
                text = '\n'
            elif n.name in ('script', 'style', 'button'):
                continue
            else:
                text = children(n)
                if block(n) and not text.endswith('\n'):
                    text += '\n'

            if block(n) and out and not out[-1].endswith('\n'):
                out.append('\n')
            if text:
                out.append(text)
        return ''.join(out)

    text = children(pre)
    return text if text.endswith('\n') else text + '\n'


def parse_page(data, cid, kind):
    from bs4 import BeautifulSoup

    soup = BeautifulSoup(data, 'html.parser')
    result = {}
    canonical = soup.select_one('link[rel="canonical"]')

    if canonical:
        match = re.search(
            r'/(contest|gym)/(\d+)(?:/|$|\?)',
            canonical.get('href', ''),
        )
        if match and (match[1] != kind or match[2] != cid):
            fail('HTML belongs to another contest.')

    for statement in soup.select('.problem-statement'):
        title = statement.select_one('.header .title')
        match = re.fullmatch(
            r'([A-Za-z][A-Za-z0-9]*)\.\s*(.+)',
            title.get_text(' ', strip=True) if title else '',
        )
        if not match:
            fail('Unrecognized problem heading. Save the all-problems page.')

        name = idx(match[1])
        if name in result:
            fail('Duplicate problem index: ' + name)

        for b in statement.select('.sample-test .input, .sample-test .output'):
            if len(b.select('pre')) != 1:
                fail(name + ': malformed sample block.')

        ins = statement.select('.sample-test .input pre')
        outs = statement.select('.sample-test .output pre')
        if len(ins) != len(outs):
            fail(name + ': unequal sample input/output counts.')

        result[name] = (
            match[2],
            [(pre_text(i), pre_text(o)) for i, o in zip(ins, outs)],
        )

    if not result:
        fail(
            'No statements found: login/Cloudflare, unstarted contest, '
            'or changed markup. Use --html.'
        )
    return result


def scaffold(a):
    cid = ident(a.id)
    k = key(cid, a.gym)
    kind = 'gym' if a.gym else 'contest'
    url = f'https://codeforces.com/{kind}/{cid}/problems?locale=en'

    if a.command == 'init':
        labels = [idx(x) for x in a.indices]
        if len(set(labels)) != len(labels):
            fail('Duplicate problem index.')
        problems = {x: ('', None) for x in labels}
    else:
        try:
            if a.html:
                with Path(a.html).expanduser().open('rb') as f:
                    data = f.read(25 * 1024**2 + 1)
            else:
                print('Fetching ' + url, file=sys.stderr)
                req = Request(url, headers={
                    'User-Agent': 'Mozilla/5.0',
                    'Accept-Language': 'en-US,en;q=0.9',
                })
                with urlopen(req, timeout=20) as r:
                    data = r.read(25 * 1024**2 + 1)

            if len(data) > 25 * 1024**2:
                fail('HTML exceeds 25 MiB.')
            problems = parse_page(data, cid, kind)
        except Exception as e:
            fail(
                f'{e}\nSave {url} as HTML, then: cf parse {cid}'
                + (' --gym' if a.gym else '')
                + ' --html /path/problems.html'
            )

    target = HOME / 'contests' / k
    with locked(k):
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            fail('Refusing a symlinked workspace.')

        new = not target.exists()
        work = (
            Path(tempfile.mkdtemp(prefix='.' + k + '-', dir=target.parent))
            if new else target
        )
        try:
            m = {
                'version': 1, 'id': cid, 'kind': kind,
                'indices': [], 'names': {},
            } if new else metadata(work)

            if m['id'] != cid or m['kind'] != kind:
                fail('Contest identity mismatch.')

            for name, (title, samples) in problems.items():
                p = work / name.lower()
                if p.is_symlink():
                    fail('Refusing a symlinked problem directory.')
                p.mkdir(exist_ok=True)
                (p / 'tests/custom').mkdir(parents=True, exist_ok=True)

                urlp = f'https://codeforces.com/{kind}/{cid}/problem/{name}'
                templates = [
                    (
                        name.lower() + '.cpp',
                        Path(os.environ.get(
                            'CF_TEMPLATE', str(ROOT / 'solution.cpp')
                        )).expanduser(),
                    ),
                    ('brute.cpp', ROOT / 'brute.cpp'),
                    ('gen.cpp', ROOT / 'gen.cpp'),
                ]
                for dest, src in templates:
                    f = p / dest
                    if f.is_symlink():
                        fail('Refusing symlinked source: ' + str(f))
                    if not f.exists():
                        with f.open('x') as out:
                            out.write('// ' + urlp + '\n' + src.read_text())

                if samples is not None:
                    s = p / 'tests/samples'
                    if s.is_symlink():
                        fail('Refusing symlinked samples.')

                    if not s.exists() or a.refresh_samples:
                        stage = Path(tempfile.mkdtemp(
                            prefix='.samples-', dir=s.parent
                        ))
                        backup = None
                        try:
                            for n, pair in enumerate(samples, 1):
                                for ext, text in zip(('in', 'out'), pair):
                                    (stage / f'{n:02d}.{ext}').write_text(text)

                            if s.exists():
                                backup = p / 'sample-backups' / stamp()
                                backup.parent.mkdir(exist_ok=True)
                                s.rename(backup)
                            try:
                                stage.rename(s)
                            except BaseException:
                                if backup is not None:
                                    backup.rename(s)
                                raise
                        finally:
                            if stage.exists():
                                shutil.rmtree(stage)
                    else:
                        print(
                            name + ': keeping existing samples; '
                            '--refresh-samples replaces them with a backup.'
                        )

                    if not samples:
                        print(
                            name + ': no samples; an empty test suite is NOT a pass.',
                            file=sys.stderr,
                        )

                if name not in m['indices']:
                    m['indices'].append(name)
                m['names'][name] = title or m['names'].get(name, name)
                print(f'{name}: {name.lower()}/{name.lower()}.cpp')

            if a.command == 'parse':
                m['indices'] = list(problems) + [
                    x for x in m['indices'] if x not in problems
                ]
            write_json(work / MARK, m)

            ignore = work / '.gitignore'
            if not ignore.exists():
                ignore.write_text('**/.cf/\n*.swp\n*.swo\n*~\n')

            if new:
                work.rename(target)
        finally:
            if new and work.exists():
                shutil.rmtree(work)

        atomic(HOME / '.active', k.encode())

    print('Workspace: ' + str(target))
    print(
        f'Next: cfc {cid}' + (' --gym' if a.gym else '')
        + '; switch ' + m['indices'][0].lower()
    )


def limits():
    hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
    cap = (
        16 * 1024**2 if hard == resource.RLIM_INFINITY
        else min(hard, 16 * 1024**2)
    )
    resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def execute(argv, cwd, inp=None, out=None, err=None, timeout=3, bounded=True):
    start = time.monotonic()
    proc = None
    expired = False

    paths = [f for f in (inp, out, err) if f is not None]
    for i, f in enumerate(paths):
        for g in paths[:i]:
            if (
                f.resolve() == g.resolve()
                or (f.exists() and g.exists() and f.samefile(g))
            ):
                fail('Input, stdout and stderr must be different files.')

    with contextlib.ExitStack() as stack:
        stdin = stack.enter_context(inp.open('rb')) if inp else subprocess.DEVNULL
        files = []
        for path in (out, err):
            if path:
                path.parent.mkdir(parents=True, exist_ok=True)
                files.append(stack.enter_context(path.open('wb')))
            else:
                files.append(None)

        try:
            proc = subprocess.Popen(
                argv, cwd=cwd, stdin=stdin,
                stdout=files[0], stderr=files[1],
                start_new_session=True,
                preexec_fn=limits if bounded else None,
            )
            try:
                proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                expired = True
        finally:
            if proc:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                proc.wait()

    return None if expired else proc.returncode, time.monotonic() - start


def compile_cpp(src, p, debug=False):
    tag = hashlib.sha256(str(src.resolve()).encode()).hexdigest()[:12]
    out = p / '.cf/bin' / (
        src.stem + '-' + tag + ('-debug' if debug else '-release')
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)

    default = (
        '-std=c++20 -O1 -g -D_GLIBCXX_ASSERTIONS '
        '-fsanitize=address,undefined -fno-sanitize-recover=all '
        '-fno-omit-frame-pointer'
        if debug else '-std=c++20 -O2 -pipe'
    )
    flags = shlex.split(os.environ.get(
        'CF_DEBUGFLAGS' if debug else 'CF_CXXFLAGS',
        default + ' -Wall -Wextra -Wshadow',
    ))
    flags += ['-ULOCAL'] + (['-DLOCAL'] if debug else [])
    cxx = shlex.split(os.environ.get('CF_CXX', 'g++'))
    if not cxx:
        fail('CF_CXX is empty.')

    candidate = out.with_name(out.name + '.tmp')
    try:
        code, _ = execute(
            cxx + flags + [str(src), '-o', str(candidate)],
            p, timeout=120, bounded=False,
        )
        if code != 0:
            fail('Compilation failed or timed out: ' + str(src))
        if not candidate.is_file():
            fail('Compiler produced no executable.')
        candidate.rename(out)
    finally:
        candidate.unlink(missing_ok=True)
    return str(out)


def show(path):
    if path.is_file() and path.stat().st_size:
        with path.open('rb') as f:
            text = f.read(8000).decode('utf-8', 'replace')
        print(text, end='' if text.endswith('\n') else '\n')
        if path.stat().st_size > 8000:
            print('... full log: ' + str(path))


def diff_bytes(expected, actual):
    a = expected.decode('utf-8', 'replace').splitlines()
    b = actual.decode('utf-8', 'replace').splitlines()
    lines = list(difflib.unified_diff(
        a, b, 'expected/previous', 'actual/current', lineterm=''
    ))
    if not lines and expected != actual:
        lines = [
            'Byte/line-ending difference.',
            repr(expected[:500]), repr(actual[:500]),
        ]
    for line in lines[:100]:
        print(line[:2000])
    if len(lines) > 100:
        print('... diff truncated')


def checker(a, p):
    if not a.checker:
        return None
    f = Path(a.checker).expanduser().resolve()
    if not f.is_file():
        fail('Checker not found: ' + str(f))
    if f.suffix == '.cpp':
        return [compile_cpp(f, p)]
    return [sys.executable, str(f)] if f.suffix == '.py' else [str(f)]


def compare(a, check, p, inp, expected, actual, base):
    if check:
        code, _ = execute(
            check + [str(inp), str(actual), str(expected)],
            p,
            out=base.with_suffix('.check-out'),
            err=base.with_suffix('.check-err'),
            timeout=a.timeout,
        )
        if code != 0:
            show(base.with_suffix('.check-out'))
            show(base.with_suffix('.check-err'))
        return 'PASS' if code == 0 else 'WA' if code == 1 else 'CHECKER ERROR'

    e, o = expected.read_bytes(), actual.read_bytes()
    return 'PASS' if (
        e == o if a.exact else e.split() == o.split()
    ) else 'WA'


def tests(a, p, src):
    print('Testing ' + str(src), flush=True)
    pairs = sorted((p / 'tests').rglob('*.in'))
    if not pairs:
        fail('No tests. Fetch samples or use cf addtest; this is not a pass.')

    for f in pairs:
        if not f.with_suffix('.out').is_file():
            fail('Missing answer: ' + str(f.with_suffix('.out')))
    for f in (p / 'tests').rglob('*.out'):
        if not f.with_suffix('.in').is_file():
            fail('Orphan answer: ' + str(f))

    binary = compile_cpp(src, p, a.debug)
    check = checker(a, p)
    passed = 0

    for inp in pairs:
        base = p / '.cf/run' / inp.relative_to(p / 'tests')
        actual = base.with_suffix('.actual')
        error = base.with_suffix('.stderr')
        code, elapsed = execute(
            [binary], p, inp, actual, error, a.timeout
        )
        verdict = (
            'TLE' if code is None else 'RE' if code
            else compare(
                a, check, p, inp, inp.with_suffix('.out'), actual, base
            )
        )
        print(f'{verdict:14} {inp.relative_to(p)}  {elapsed*1000:.0f} ms')
        if verdict == 'PASS':
            passed += 1
        if verdict == 'WA' and not check:
            diff_bytes(inp.with_suffix('.out').read_bytes(), actual.read_bytes())
        show(error)

    print(f'{passed}/{len(pairs)} local tests passed; logs: {p / ".cf/run"}')
    return int(passed != len(pairs))


def stress(a, p, src):
    if a.count <= 0 or a.seed < 0 or a.seed + a.count > 2**64:
        fail('Invalid count/unsigned 64-bit seed range.')

    files = [src, p / 'brute.cpp', p / 'gen.cpp']
    saved = {f.name: f.read_bytes() for f in files}
    solution, brute, gen = [
        compile_cpp(f, p, a.debug if i < 2 else False)
        for i, f in enumerate(files)
    ]
    if any(f.read_bytes() != saved[f.name] for f in files):
        fail('Source changed during compilation; retry.')

    check = checker(a, p)
    work = p / '.cf/run/stress'
    work.mkdir(parents=True, exist_ok=True)
    print(f'Seeds {a.seed}..{a.seed+a.count-1}', flush=True)

    for n, seed in enumerate(range(a.seed, a.seed+a.count), 1):
        for f in work.iterdir():
            if f.is_file():
                f.unlink()

        inp = work / 'input.txt'
        expected = work / 'expected.txt'
        actual = work / 'actual.txt'
        verdict = 'PASS'

        for label, argv, input_file, output, timeout in [
            ('GEN', [gen, str(seed)], None, inp, a.timeout),
            ('BRUTE', [brute], inp, expected, a.brute_timeout),
            ('SOLUTION', [solution], inp, actual, a.timeout),
        ]:
            code, _ = execute(
                argv, p, input_file, output,
                work / (label + '.stderr'), timeout,
            )
            if code != 0:
                verdict = label + (' TLE' if code is None else ' RE')
                break

        if verdict == 'PASS':
            verdict = compare(
                a, check, p, inp, expected, actual, work / 'check'
            )

        if verdict != 'PASS':
            dest = p / 'failures' / (stamp() + '-seed-' + str(seed))
            shutil.copytree(work, dest)
            for name, data in saved.items():
                atomic(dest / 'sources' / name, data)
            write_json(dest / 'meta.json', {
                'seed': seed, 'verdict': verdict, 'debug': a.debug,
            })
            print(f'{verdict}, seed {seed}\nSaved: {dest}')
            for f in dest.glob('*.stderr'):
                show(f)
            if verdict == 'WA' and not check:
                diff_bytes(expected.read_bytes(), actual.read_bytes())
            return 1

        if n % 100 == 0:
            print(f'{n} matched', flush=True)

    print(f'No mismatch in {a.count} cases.')
    return 0


def browser(url):
    print(url)
    cmd = shlex.split(os.environ.get('CF_BROWSER', 'xdg-open'))
    if not cmd or not shutil.which(cmd[0]):
        fail('No browser launcher; open the URL manually.')

    p = subprocess.Popen(
        cmd + [url], stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        if p.wait(timeout=2):
            fail('Browser launcher failed; open the URL manually.')
    except subprocess.TimeoutExpired:
        pass


def archive(folder, m):
    dest = HOME / 'archive' / datetime.now().strftime('%Y-%m')
    dest.mkdir(parents=True, exist_ok=True)
    target = dest / (
        key(m['id'], m['kind'] == 'gym') + '-' + stamp() + '.tar.gz'
    )

    def inventory():
        result = {}
        for f in sorted(folder.rglob('*')):
            rel = f.relative_to(folder)
            if '.cf' in rel.parts or f.name.endswith(('.swp', '.swo', '~')):
                continue
            if f.is_symlink() or not (f.is_file() or f.is_dir()):
                fail('Archive refuses links/special files: ' + str(f))
            if f.is_file():
                with f.open('rb') as stream:
                    result[str(rel)] = hashlib.file_digest(
                        stream, 'sha256'
                    ).hexdigest()
            else:
                result[str(rel)] = None
        return result

    prefix = key(m['id'], m['kind'] == 'gym')
    before = inventory()
    temp = target.with_suffix('.tmp')
    try:
        with tarfile.open(temp, 'w:gz', dereference=True) as tar:
            tar.add(folder, arcname=prefix, recursive=False)
            for name in before:
                tar.add(
                    folder / name,
                    arcname=prefix + '/' + name,
                    recursive=False,
                )

        got = {}
        with tarfile.open(temp) as tar:
            for member in tar:
                if member.name == prefix:
                    continue
                name = member.name[len(prefix)+1:]
                if member.isfile():
                    with tar.extractfile(member) as stream:
                        got[name] = hashlib.file_digest(
                            stream, 'sha256'
                        ).hexdigest()
                else:
                    got[name] = None

        if got != before or inventory() != before:
            fail('Files changed during archive. Originals were kept; retry.')
        temp.rename(target)
    finally:
        temp.unlink(missing_ok=True)

    print(
        f'Verified archive: {target}\n'
        'Working directory retained; no original files were deleted.'
    )


def restore(file):
    parent = HOME / 'contests'
    parent.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix='.restore-', dir=parent) as temp:
        with tarfile.open(file) as tar:
            members = tar.getmembers()
            roots, seen = set(), set()

            for m in members:
                path = PurePosixPath(m.name)
                if (
                    path.is_absolute() or '..' in path.parts
                    or not path.parts or not (m.isfile() or m.isdir())
                ):
                    fail('Unsafe archive member.')
                if str(path) in seen:
                    fail('Duplicate archive member.')
                seen.add(str(path))
                roots.add(path.parts[0])

            if len(roots) != 1 or sum(m.size for m in members) > 8 * 1024**3:
                fail('Invalid/oversized archive.')

            k = roots.pop()
            if not re.fullmatch(r'(gym-)?[1-9][0-9]{0,8}', k):
                fail('Invalid archive root.')

            for m in members:
                out = Path(temp) / m.name
                if m.isdir():
                    out.mkdir(parents=True, exist_ok=True)
                else:
                    out.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(m) as f, out.open('xb') as g:
                        shutil.copyfileobj(f, g)
                    out.chmod(m.mode & 0o777)

        work = Path(temp) / k
        m = metadata(work)
        if key(m['id'], m['kind'] == 'gym') != k:
            fail('Archive identity mismatch.')

        with locked(k):
            target = parent / k
            if target.exists() or target.is_symlink():
                fail('Restore never overwrites an existing contest.')
            work.rename(target)
            atomic(HOME / '.active', k.encode())

    print('Restored: ' + str(target))


def edit(src):
    if not src.is_file():
        fail('Source does not exist: ' + str(src))

    lua = (
        f'vim.g.cf_inline_cli={json.dumps(str(ROOT / "cf.py"), ensure_ascii=False)}; '
        f'local m=dofile({json.dumps(str(ROOT / "cf.lua"), ensure_ascii=False)}); '
    )
    if os.environ.get('NVIM'):
        expr = '(function() ' + lua + 'm.open(_A); return 1 end)()'
        quote = lambda s: "'" + s.replace("'", "''") + "'"
        subprocess.run(
            [
                'nvim', '--headless', '--server', os.environ['NVIM'],
                '--remote-expr',
                'luaeval(' + quote(expr) + ',' + quote(str(src)) + ')',
            ],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            check=True, timeout=10,
        )
    else:
        os.chdir(src.parent)
        os.execvp('nvim', ['nvim', str(src), '-c', 'lua ' + lua])


def positive(s):
    n = float(s)
    if not math.isfinite(n) or n <= 0:
        raise argparse.ArgumentTypeError('must be finite and positive')
    return n


def arguments():
    p = argparse.ArgumentParser(prog='cf')
    p.add_argument('--cwd', type=Path)
    p.add_argument('--version', action='version', version='cf-contest inline 1.0')
    sub = p.add_subparsers(dest='command', required=True)

    for cmd in ('parse', 'init'):
        q = sub.add_parser(cmd)
        q.add_argument('id')
        q.add_argument('--gym', action='store_true')
        q.add_argument('--refresh-samples', action='store_true')
        q.add_argument('--html')
        if cmd == 'init':
            q.add_argument('indices', nargs='+')

    q = sub.add_parser('restore')
    q.add_argument('file', type=Path)

    for cmd in (
        'path', 'edit', 'list', 'test', 'run', 'build', 'stress',
        'submit', 'diff', 'open', 'archive', 'addtest',
    ):
        q = sub.add_parser(cmd)
        q.add_argument('--contest')
        q.add_argument('--gym', action='store_true')

        if cmd == 'stress':
            q.add_argument('count', nargs='?', type=int, default=1000)
            q.add_argument('-p', '--problem')
        elif cmd == 'addtest':
            q.add_argument('name')
            q.add_argument('-p', '--problem')
        else:
            q.add_argument('problem', nargs='?')

        if cmd == 'path':
            q.add_argument('--file', action='store_true')
        if cmd == 'list':
            q.add_argument('--indices', action='store_true')
        if cmd in ('test', 'run', 'build', 'stress'):
            q.add_argument('--debug', action='store_true')
        if cmd in ('test', 'run', 'stress'):
            q.add_argument('--timeout', type=positive, default=3)
        if cmd in ('test', 'stress'):
            mode = q.add_mutually_exclusive_group()
            mode.add_argument('--exact', action='store_true')
            mode.add_argument('--checker')
        if cmd in ('run', 'addtest'):
            q.add_argument('--input', type=Path, required=cmd == 'addtest')
        if cmd == 'addtest':
            q.add_argument('--output', type=Path, required=True)
        if cmd == 'stress':
            q.add_argument('--seed', type=int, default=1)
            q.add_argument('--brute-timeout', type=positive, default=10)
        if cmd == 'submit':
            q.add_argument('--no-copy', action='store_true')
            q.add_argument('--no-open', action='store_true')

    return p.parse_args()


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '_args':
        print(json.dumps(shlex.split(sys.argv[2])))
        return 0

    a = arguments()
    if a.cwd:
        os.chdir(a.cwd.expanduser())
    if a.command in ('parse', 'init'):
        scaffold(a)
        return 0
    if a.command == 'restore':
        restore(a.file.expanduser().resolve())
        return 0
    if a.command == 'archive' and a.problem:
        a.contest, a.problem = a.problem, None

    folder, m = context(a)

    if a.command == 'list':
        for name in m['indices']:
            print(name.lower() if a.indices else f'{name:4} {m["names"][name]}')
        return 0

    if (
        a.command == 'path' and not a.file and not a.problem
        and (a.contest or Path.cwd() == folder)
    ):
        print(folder)
        return 0

    if a.command == 'archive':
        with locked(key(m['id'], m['kind'] == 'gym')):
            archive(folder, m)
        return 0

    p, src, name = problem(
        folder, m, a.problem, first=a.command in ('edit', 'path')
    )

    if a.command == 'path':
        print(src if a.file else p)
        return 0
    if a.command == 'edit':
        edit(src)
        return 0

    url = f'https://codeforces.com/{m["kind"]}/{m["id"]}'
    if a.command == 'open':
        browser(url + '/problem/' + name)
        return 0

    with locked(key(m['id'], m['kind'] == 'gym')):
        if a.command == 'test':
            return tests(a, p, src)
        if a.command == 'stress':
            return stress(a, p, src)
        if a.command == 'build':
            print(compile_cpp(src, p, a.debug))

        if a.command == 'run':
            binary = compile_cpp(src, p, a.debug)
            if not a.input:
                return int(subprocess.run([binary], cwd=p).returncode != 0)
            out = p / '.cf/run/manual.out'
            err = p / '.cf/run/manual.err'
            code, elapsed = execute(
                [binary], p, a.input.expanduser().resolve(),
                out, err, a.timeout,
            )
            sys.stdout.buffer.write(out.read_bytes())
            sys.stdout.flush()
            show(err)
            print(
                f'\n{"TLE" if code is None else "OK" if code == 0 else "RE"}: '
                f'{elapsed*1000:.0f} ms',
                file=sys.stderr,
            )
            return int(code != 0)

        if a.command == 'addtest':
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}', a.name):
                fail('Use an alphanumeric test name.')
            pair = [
                p / 'tests/custom' / (a.name + ext)
                for ext in ('.in', '.out')
            ]
            if any(f.exists() or f.is_symlink() for f in pair):
                fail('Test already exists; not overwritten.')
            data = [
                a.input.expanduser().read_bytes(),
                a.output.expanduser().read_bytes(),
            ]
            for f, content in zip(pair, data):
                atomic(f, content)
            print('Added: ' + a.name)

        if a.command in ('submit', 'diff'):
            snapshots = sorted((p / 'submissions').glob('*.cpp'))
            data = src.read_bytes()

            if a.command == 'diff':
                if not snapshots:
                    fail('No prepared snapshot; cf submit creates one.')
                old = snapshots[-1].read_bytes()
                diff_bytes(old, data)
                return int(old != data)

            compile_cpp(src, p)
            if src.read_bytes() != data:
                fail('Source changed during compilation; retry.')

            snapshot = p / 'submissions' / (stamp() + '.cpp')
            atomic(snapshot, data)
            print('Prepared snapshot: ' + str(snapshot))

            if re.search(rb'^\s*#\s*include\s*"', data, re.M):
                print('Warning: local includes are NOT inlined.', file=sys.stderr)

            if not a.no_copy:
                subprocess.run(['wl-copy'], input=data, check=True, timeout=5)
            if not a.no_open:
                browser(url + '/submit?problemIndex=' + name)

            print('No submission was sent. Paste and submit in your browser.')

    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('\nInterrupted.', file=sys.stderr)
        sys.exit(130)
    except (
        RuntimeError, OSError, ValueError, KeyError,
        subprocess.SubprocessError,
    ) as e:
        print('cf: ' + str(e), file=sys.stderr)
        sys.exit(2)
PY_CF

cat >"$stage/cf.lua" <<'LUA_CF'
if _G.CFContestInline then return _G.CFContestInline end
local M = {}
_G.CFContestInline = M

local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local cli = assert(vim.g.cf_inline_cli)
local saving, job, output_buf, output_win

local function root(dir)
  while dir and dir ~= '' do
    if uv.fs_stat(dir .. '/.cf-contest.json') then return dir end
    local up = fn.fnamemodify(dir, ':h')
    if up == dir then break end
    dir = up
  end
end

local function message(s)
  vim.notify('cf: ' .. tostring(s), vim.log.levels.ERROR)
end

local function context()
  local file = api.nvim_buf_get_name(0)
  if vim.bo.buftype == '' and file ~= '' then
    local dir = fn.fnamemodify(file, ':h')
    if root(dir) then return dir end
    return nil
  end
  return vim.t.cf_inline_dir
end

local function command(args, dir)
  local argv = { cli }
  if dir then vim.list_extend(argv, { '--cwd', dir }) end
  vim.list_extend(argv, args)
  local lines = fn.systemlist(argv)
  if vim.v.shell_error ~= 0 then
    message(table.concat(lines, '\n'))
    return nil
  end
  return lines
end

local function code_window(target)
  local current, fallback = api.nvim_get_current_win(), nil
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local b = api.nvim_win_get_buf(win)
    if vim.bo[b].buftype == '' and api.nvim_win_get_config(win).relative == '' then
      if target and b == target then return win end
      if win == current then
        fallback = win
      elseif not fallback then
        fallback = win
      end
    end
  end
  return fallback
end

function M.open(file)
  assert(
    file:sub(1, 1) == '/' and uv.fs_stat(file),
    'source file missing: ' .. file
  )
  vim.cmd('stopinsert')
  local b = fn.bufadd(file)
  local win = code_window(b)
  if win then
    api.nvim_set_current_win(win)
  else
    vim.cmd('aboveleft new')
  end
  fn.bufload(b)
  vim.bo[b].buflisted = true
  vim.cmd('hide buffer ' .. b)
  local dir = fn.fnamemodify(file, ':h')
  vim.t.cf_inline_dir = dir
  vim.cmd('tcd ' .. fn.fnameescape(dir))
  return b
end

local function switch(index)
  local dir = context()
  if not dir then return message('Select a contest file first.') end
  local result = command({ 'path', index, '--file' }, dir)
  if result then M.open(result[1]) end
end

local function output()
  if not output_buf or not api.nvim_buf_is_valid(output_buf) then
    return message('No output yet.')
  end
  if not output_win
      or not api.nvim_win_is_valid(output_win)
      or api.nvim_win_get_buf(output_win) ~= output_buf then
    vim.cmd('botright 12split')
    output_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(output_win, output_buf)
  end
  api.nvim_set_current_win(output_win)
  if job and fn.jobwait({ job }, 0)[1] == -1 then
    vim.cmd('startinsert')
  end
end

local function run(action, text, debug)
  if job and fn.jobwait({ job }, 0)[1] == -1 then
    return message('Job still running; :CfOutput then Ctrl-C, or wait.')
  end

  local raw = command({ '_args', text })
  if not raw then return end
  local args = fn.json_decode(table.concat(raw, '\n'))

  -- Do not save A and accidentally run an unsaved B.
  local values = {
    ['--timeout']=true, ['--checker']=true, ['--input']=true,
    ['--seed']=true, ['--brute-timeout']=true,
  }
  local i, count = 1, false
  while i <= #args do
    local arg = args[i]
    local flag = arg:match('^([^=]+)')
    if flag == '--contest' or flag == '--gym'
        or flag == '--problem' or arg:sub(1,2) == '-p' then
      return message('Switch with :Cf INDEX first; editor runners use the selected problem.')
    end
    if values[arg] then
      i = i + 1
    elseif arg:sub(1,1) ~= '-' then
      if action == 'stress' and not count then
        count = true
      else
        return message('Switch with :Cf INDEX first.')
      end
    end
    i = i + 1
  end

  local dir = context()
  if not dir then return message('Not in a contest problem.') end
  local found = command({ 'path' }, dir)
  if not found then return end
  dir = found[1]

  if uv.fs_stat(dir .. '/.cf-contest.json') then
    return message('Select a problem with :Cf INDEX first.')
  end

  if action ~= 'open' then
    saving = true
    local ok, err = pcall(function()
      for _, b in ipairs(api.nvim_list_bufs()) do
        if vim.bo[b].buftype == '' and vim.bo[b].modified
            and api.nvim_buf_get_name(b):sub(1,#dir+1) == dir .. '/' then
          api.nvim_buf_call(b, function() vim.cmd('silent update') end)
          assert(not vim.bo[b].modified, 'Buffer remains modified after writing.')
        end
      end
    end)
    saving = false
    if not ok then return message(err) end
  end

  if debug then table.insert(args, 1, '--debug') end
  local interactive = action == 'run'
  for _, arg in ipairs(args) do
    if arg == '--input' or arg:match('^%-%-input=') then
      interactive = false
    end
  end

  local code = code_window()
  if not code then
    local file = command({ 'path', '--file' }, dir)
    if not file then return end
    M.open(file[1])
    code = api.nvim_get_current_win()
  end

  vim.cmd('stopinsert')
  if output_win and api.nvim_win_is_valid(output_win)
      and api.nvim_win_get_buf(output_win) == output_buf
      and api.nvim_win_get_tabpage(output_win) == api.nvim_get_current_tabpage() then
    api.nvim_set_current_win(output_win)
  else
    api.nvim_set_current_win(code)
    vim.cmd('botright 12split')
    output_win = api.nvim_get_current_win()
  end

  local old = output_buf
  output_buf = api.nvim_create_buf(false, true)
  vim.bo[output_buf].bufhidden = 'hide'
  api.nvim_win_set_buf(output_win, output_buf)

  if old and api.nvim_buf_is_valid(old) and #fn.win_findbuf(old) == 0 then
    api.nvim_buf_delete(old, { force=true })
  end

  local b = output_buf
  local argv = { cli, '--cwd', dir, action }
  vim.list_extend(argv, args)
  job = fn.termopen(argv, {
    cwd=dir,
    on_exit=function(_, code_)
      vim.schedule(function()
        if api.nvim_buf_is_valid(b) then vim.b[b].cf_exit_code = code_ end
      end)
    end,
  })

  if interactive then
    vim.cmd('startinsert')
  else
    api.nvim_set_current_win(code)
  end
end

local function make(name, callback, opts)
  if fn.exists(':' .. name) == 0 then
    api.nvim_create_user_command(name, callback, opts or {})
  end
end

make('Cf', function(o) switch(o.args) end, {
  nargs=1,
  complete=function(lead)
    local dir = context()
    if not dir then return {} end
    local list = command({ 'list', '--indices' }, dir) or {}
    return vim.tbl_filter(function(s)
      return s:lower():sub(1,#lead) == lead:lower()
    end, list)
  end,
})
make('CfNext', function() switch('next') end)
make('CfPrev', function() switch('prev') end)
make('CfOutput', output)

for _, spec in ipairs({
  {'CfTest','test'}, {'CfDebug','test',true}, {'CfRun','run'},
  {'CfStress','stress'}, {'CfSubmit','submit'}, {'CfDiff','diff'},
  {'CfOpen','open'},
}) do
  local action, debug = spec[2], spec[3]
  make(spec[1], function(o) run(action, o.args, debug) end, { nargs='*' })
end

local function enter()
  if saving or vim.bo.buftype ~= '' then return end
  local file = api.nvim_buf_get_name(0)
  local dir = fn.fnamemodify(file, ':h')
  if not file:match('%.cpp$') or not root(dir) then return end

  vim.t.cf_inline_dir = dir
  vim.cmd('tcd ' .. fn.fnameescape(dir))
  for key, cmd in pairs({
    ['<F5>']='CfTest', ['<F6>']='CfDebug',
    ['<leader>cn']='CfNext', ['<leader>cp']='CfPrev',
    ['<leader>cs']='CfSubmit',
  }) do
    if fn.maparg(key, 'n') == '' then
      vim.keymap.set('n', key, '<Cmd>' .. cmd .. '<CR>', {
        buffer=true, silent=true,
      })
    end
  end
end

api.nvim_create_autocmd('BufEnter', {
  group=api.nvim_create_augroup('CfContestInlineSession', { clear=true }),
  callback=enter,
})
enter()
return M
LUA_CF

cat >"$stage/solution.cpp" <<'CPP_MAIN'
#include <bits/stdc++.h>
using namespace std;
using ll = long long;
#define all(v) (v).begin(), (v).end()
#ifdef LOCAL
#define debug(x) cerr << #x << " = " << (x) << '\n'
#else
#define debug(x) ((void)0)
#endif

void solve() {

}

int main() {
    ios::sync_with_stdio(false);
    cin.tie(nullptr);
    int t = 1;
    // cin >> t;  // Enable only when the input starts with a test count.
    while (t--) solve();
}
CPP_MAIN

cat >"$stage/brute.cpp" <<'CPP_BRUTE'
#include <bits/stdc++.h>
using namespace std;

int main() {
    // Replace with a correct small-input solution.
    cerr << "Implement brute.cpp before running cf stress.\n";
    return 2;
}
CPP_BRUTE

cat >"$stage/gen.cpp" <<'CPP_GEN'
#include <bits/stdc++.h>
using namespace std;

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    mt19937_64 rng(stoull(argv[1]));

    // Example format only. Adapt to the actual problem and constraints.
    int n = 1 + rng() % 8;
    cout << n << '\n';
    for (int i = 0; i < n; ++i)
        cout << int(rng() % 21) - 10 << (i + 1 == n ? '\n' : ' ');
}
CPP_GEN

cat >"$stage/cf-shell.py" <<'PY_SHELL'
#!/usr/bin/env python3
import os, sys
from pathlib import Path

root = Path(__file__).resolve().parent
os.environ['CF_KIT'] = str(root)
os.environ['CF_HOME'] = str(
    Path(os.environ.get('CF_HOME', '~/cf-contests')).expanduser().resolve()
)
Path(os.environ['CF_HOME']).mkdir(parents=True, exist_ok=True)
os.execvp(
    'bash',
    ['bash', '--rcfile', str(root / 'shellrc'), '-i', *sys.argv[1:]],
)
PY_SHELL

cat >"$stage/shellrc" <<'SHELL_RC'
# Loaded only inside the explicitly launched contest shell.
if [[ -r "$HOME/.bashrc" ]]; then source "$HOME/.bashrc"; fi
export PATH="$CF_KIT/bin:$PATH"

for _cf_name in cf cfc switch cft cfd cfs; do
    builtin unalias "$_cf_name" 2>/dev/null || :
    builtin unset -f "$_cf_name" 2>/dev/null || :
done
unset _cf_name

function cfc {
    if [[ $# -lt 1 ]]; then
        printf 'usage: cfc ID [--gym]\n' >&2
        return 2
    fi
    local id=$1 dir
    shift
    dir=$(command cf path --contest "$id" "$@") || return
    builtin cd -- "$dir"
}

function switch {
    local file
    file=$(command cf path "$@" --file) || return
    [[ -f "$file" ]] || {
        printf 'Missing source: %s\n' "$file" >&2
        return 2
    }
    builtin cd -- "${file%/*}" || return
    command cf edit
}

alias cft='cf test'
alias cfd='cf test --debug'
alias cfs='cf stress'

builtin cd -- "$CF_HOME" || return
printf 'Contest shell: %s\ncf parse ID; cfc ID; switch a\nexit returns to your original setup.\n' "$CF_HOME"
SHELL_RC

chmod 755 "$stage/cf.py" "$stage/cf-shell.py"
ln -s ../cf.py "$stage/bin/cf"
mv -T -- "$stage" "$data"
installed=1
ln -s "$data/cf-shell.py" "$bin/cf-shell"
success=1

printf '\nInstalled without editing your repo, shell rc, or Neovim config.\n'
printf 'Start: %s/cf-shell\n' "$bin"
printf 'Then: cf parse ID; cfc ID; switch a\n'
printf 'Template: %s/solution.cpp (or set CF_TEMPLATE to your existing template).\n' "$data"
