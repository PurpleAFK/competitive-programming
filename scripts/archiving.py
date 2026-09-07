from common import *

def restore_tar(file):
    parent = HOME / 'contests'
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.restore-', dir=parent) as temp:
        with tarfile.open(file) as tar:
            members = tar.getmembers()
            roots, seen = (set(), set())
            for m in members:
                path = PurePosixPath(m.name)
                if path.is_absolute() or '..' in path.parts or (not path.parts) or (not (m.isfile() or m.isdir())):
                    fail('Unsafe archive member.')
                if str(path) in seen:
                    fail('Duplicate archive member.')
                seen.add(str(path))
                roots.add(path.parts[0])
            if len(roots) != 1 or sum((m.size for m in members)) > 8 * 1024 ** 3:
                fail('Invalid/oversized archive.')
            k = roots.pop()
            if not re.fullmatch('(gym-)?[1-9][0-9]{0,8}', k):
                fail('Invalid archive root.')
            for m in members:
                out = Path(temp) / m.name
                if m.isdir():
                    out.mkdir(parents=True, exist_ok=True)
                else:
                    out.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(m) as f, out.open('xb') as g:
                        shutil.copyfileobj(f, g)
                    out.chmod(m.mode & 511)
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

    saved = copy_verified(selected, base)

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
