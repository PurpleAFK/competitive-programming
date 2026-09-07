import argparse, contextlib, difflib, fcntl, hashlib, json, math, os, re
import resource, shlex, shutil, signal, subprocess, sys, tarfile, tempfile, time
from datetime import datetime
from pathlib import Path, PurePosixPath
from urllib.request import Request, urlopen
ROOT = Path(__file__).resolve().parents[1]
HOME = ROOT
MARK = '.cf-contest.json'

def fail(message):
    raise RuntimeError(message)

def stamp():
    return datetime.now().strftime('%Y%m%d-%H%M%S-%f')

def ident(s):
    if not re.fullmatch('[1-9][0-9]{0,8}', str(s)):
        fail('Use a positive numeric contest ID.')
    return str(s)

def idx(s):
    s = str(s).upper()
    if not re.fullmatch('[A-Z][A-Z0-9]{0,15}', s):
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
    if not m['indices'] or any((idx(x) != x for x in m['indices'])) or len(set(m['indices'])) != len(m['indices']):
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
        folder = next((p for p in [Path.cwd(), *Path.cwd().parents] if (p / MARK).is_file()), None)
        if folder is None:
            state = HOME / '.active'
            if not state.is_file():
                fail('Run cf parse ID, then cfc ID.')
            k = state.read_text().strip()
            if not re.fullmatch('(gym-)?[1-9][0-9]{0,8}', k):
                fail('Invalid active contest.')
            folder = HOME / 'contests' / k
    return (folder, metadata(folder))

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
        label = m['indices'][(i + (1 if label == 'next' else -1)) % len(m['indices'])]
    name = idx(label) if label else current or (m['indices'][0] if first else None)
    if name not in m['indices']:
        fail('Select a problem: ' + ' '.join(m['indices']))
    p = folder / name.lower()
    if not p.is_dir():
        fail('Missing problem directory: ' + str(p))
    return (p, p / (name.lower() + '.cpp'), name)
