from common import *
def pre_text(pre):
    from bs4 import Comment, NavigableString, Tag

    def block(n):
        return isinstance(n, Tag) and n.name in ('div', 'p')

    def children(parent):
        nodes = list(parent.children)
        blocks = any((block(n) for n in nodes))
        out = []
        for i, n in enumerate(nodes):
            if isinstance(n, Comment):
                continue
            if isinstance(n, NavigableString):
                text = str(n).replace('\r\n', '\n').replace('\r', '\n').replace('\xa0', ' ')
                if parent is pre and i == 0 and text.startswith('\n'):
                    text = text[1:]
                if blocks and (not text.strip()):
                    continue
            elif n.name == 'br':
                text = '\n'
            elif n.name in ('script', 'style', 'button'):
                continue
            else:
                text = children(n)
                if block(n) and (not text.endswith('\n')):
                    text += '\n'
            if block(n) and out and (not out[-1].endswith('\n')):
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
        match = re.search('/(contest|gym)/(\\d+)(?:/|$|\\?)', canonical.get('href', ''))
        if match and (match[1] != kind or match[2] != cid):
            fail('HTML belongs to another contest.')
    for statement in soup.select('.problem-statement'):
        title = statement.select_one('.header .title')
        match = re.fullmatch('([A-Za-z][A-Za-z0-9]*)\\.\\s*(.+)', title.get_text(' ', strip=True) if title else '')
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
        result[name] = (match[2], [(pre_text(i), pre_text(o)) for i, o in zip(ins, outs)])
    if not result:
        fail('No statements found: login/Cloudflare, unstarted contest, or changed markup. Use --html.')
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
                    data = f.read(25 * 1024 ** 2 + 1)
            else:
                print('Fetching ' + url, file=sys.stderr)
                req = Request(url, headers={'User-Agent': 'Mozilla/5.0', 'Accept-Language': 'en-US,en;q=0.9'})
                with urlopen(req, timeout=20) as r:
                    data = r.read(25 * 1024 ** 2 + 1)
            if len(data) > 25 * 1024 ** 2:
                fail('HTML exceeds 25 MiB.')
            problems = parse_page(data, cid, kind)
        except Exception as e:
            fail(f'{e}\nSave {url} as HTML, then: cf parse {cid}' + (' --gym' if a.gym else '') + ' --html /path/problems.html')
    target = HOME / 'contests' / k
    with locked(k):
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_symlink():
            fail('Refusing a symlinked workspace.')
        new = not target.exists()
        work = Path(tempfile.mkdtemp(prefix='.' + k + '-', dir=target.parent)) if new else target
        try:
            m = {'version': 1, 'id': cid, 'kind': kind, 'indices': [], 'names': {}} if new else metadata(work)
            if m['id'] != cid or m['kind'] != kind:
                fail('Contest identity mismatch.')
            for name, (title, samples) in problems.items():
                p = work / name.lower()
                if p.is_symlink():
                    fail('Refusing a symlinked problem directory.')
                p.mkdir(exist_ok=True)
                (p / 'tests/custom').mkdir(parents=True, exist_ok=True)
                urlp = f'https://codeforces.com/{kind}/{cid}/problem/{name}'
                templates = [(name.lower() + '.cpp', Path(os.environ.get('CF_TEMPLATE', str(ROOT / 'template.cpp'))).expanduser()), ('brute.cpp', ROOT / 'templates' / 'brute.cpp'), ('gen.cpp', ROOT / 'templates' / 'gen.cpp')]
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
                        stage = Path(tempfile.mkdtemp(prefix='.samples-', dir=s.parent))
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
                        print(name + ': keeping existing samples; --refresh-samples replaces them with a backup.')
                    if not samples:
                        print(name + ': no samples; an empty test suite is NOT a pass.', file=sys.stderr)
                if name not in m['indices']:
                    m['indices'].append(name)
                m['names'][name] = title or m['names'].get(name, name)
                print(f'{name}: {name.lower()}/{name.lower()}.cpp')
            if a.command == 'parse':
                m['indices'] = list(problems) + [x for x in m['indices'] if x not in problems]
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
    print(f'Next: cfc {cid}' + (' --gym' if a.gym else '') + '; switch ' + m['indices'][0].lower())
