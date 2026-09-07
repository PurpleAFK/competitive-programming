from common import *
def limits():
    hard = resource.getrlimit(resource.RLIMIT_FSIZE)[1]
    cap = 16 * 1024 ** 2 if hard == resource.RLIM_INFINITY else min(hard, 16 * 1024 ** 2)
    resource.setrlimit(resource.RLIMIT_FSIZE, (cap, cap))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

def execute(argv, cwd, inp=None, out=None, err=None, timeout=3, bounded=True):
    start = time.monotonic()
    proc = None
    expired = False
    paths = [f for f in (inp, out, err) if f is not None]
    for i, f in enumerate(paths):
        for g in paths[:i]:
            if f.resolve() == g.resolve() or (f.exists() and g.exists() and f.samefile(g)):
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
            proc = subprocess.Popen(argv, cwd=cwd, stdin=stdin, stdout=files[0], stderr=files[1], start_new_session=True, preexec_fn=limits if bounded else None)
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
    return (None if expired else proc.returncode, time.monotonic() - start)

def compile_cpp(src, p, debug=False):
    tag = hashlib.sha256(str(src.resolve()).encode()).hexdigest()[:12]
    out = p / '.cf/bin' / (src.stem + '-' + tag + ('-debug' if debug else '-release'))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)
    default = '-std=c++20 -O1 -g -D_GLIBCXX_ASSERTIONS -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer' if debug else '-std=c++20 -O2 -pipe'
    flags = shlex.split(os.environ.get('CF_DEBUGFLAGS' if debug else 'CF_CXXFLAGS', default + ' -Wall -Wextra -Wshadow'))
    flags += ['-ULOCAL'] + (['-DLOCAL'] if debug else [])
    cxx = shlex.split(os.environ.get('CF_CXX', 'g++'))
    if not cxx:
        fail('CF_CXX is empty.')
    candidate = out.with_name(out.name + '.tmp')
    try:
        code, _ = execute(cxx + flags + [str(src), '-o', str(candidate)], p, timeout=120, bounded=False)
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
    lines = list(difflib.unified_diff(a, b, 'expected/previous', 'actual/current', lineterm=''))
    if not lines and expected != actual:
        lines = ['Byte/line-ending difference.', repr(expected[:500]), repr(actual[:500])]
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
        code, _ = execute(check + [str(inp), str(actual), str(expected)], p, out=base.with_suffix('.check-out'), err=base.with_suffix('.check-err'), timeout=a.timeout)
        if code != 0:
            show(base.with_suffix('.check-out'))
            show(base.with_suffix('.check-err'))
        return 'PASS' if code == 0 else 'WA' if code == 1 else 'CHECKER ERROR'
    e, o = (expected.read_bytes(), actual.read_bytes())
    return 'PASS' if (e == o if a.exact else e.split() == o.split()) else 'WA'

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
        code, elapsed = execute([binary], p, inp, actual, error, a.timeout)
        verdict = 'TLE' if code is None else 'RE' if code else compare(a, check, p, inp, inp.with_suffix('.out'), actual, base)
        print(f'{verdict:14} {inp.relative_to(p)}  {elapsed * 1000:.0f} ms')
        if verdict == 'PASS':
            passed += 1
        if verdict == 'WA' and (not check):
            diff_bytes(inp.with_suffix('.out').read_bytes(), actual.read_bytes())
        show(error)
    print(f"{passed}/{len(pairs)} local tests passed; logs: {p / '.cf/run'}")
    return int(passed != len(pairs))
