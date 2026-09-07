#!/usr/bin/env python3
"""Delete working contests, leaving the rest of the setup intact."""
import argparse
import contextlib
import re
import shutil
import sys

from common import ROOT, locked

ID = re.compile(r'(?:gym-)?[1-9][0-9]{0,8}\Z')


def identity(path):
    s = path.lstat()
    return s.st_dev, s.st_ino, s.st_mode


def forget_missing_active(base):
    active = ROOT / '.active'

    if active.is_symlink():
        active.unlink()  # Remove the link, never its target.
    elif active.is_file():
        try:
            name = active.read_text().strip()
        except UnicodeError:
            name = ''

        if not ID.fullmatch(name) or not (base / name).is_dir():
            active.unlink()


def main():
    parser = argparse.ArgumentParser(
        description='Delete working contests; keep archives and setup.'
    )
    parser.add_argument(
        'target', help='contest ID, gym-ID, or all'
    )
    parser.add_argument(
        '-y', '--yes', action='store_true',
        help='skip the deletion confirmation',
    )
    args = parser.parse_args()

    if args.target != 'all' and not ID.fullmatch(args.target):
        parser.error('use a numeric contest ID, gym-ID, or all')

    base = ROOT / 'contests'

    if base.is_symlink():
        raise RuntimeError(
            'Refusing to clean a symlinked contests directory.'
        )

    if not base.exists():
        forget_missing_active(base)
        print('No working contests to remove.')
        return 0

    if not base.is_dir():
        raise RuntimeError(f'Not a directory: {base}')

    targets = (
        sorted(base.iterdir())
        if args.target == 'all'
        else [base / args.target]
    )

    if not targets:
        forget_missing_active(base)
        print('The contests directory is already empty.')
        return 0

    for path in targets:
        if not path.exists() and not path.is_symlink():
            raise RuntimeError(f'Not found: {path}')

    before = {
        path: identity(path)
        for path in [base, *targets]
    }

    print(f'Working directory: {base}\nWill permanently remove:')
    for path in targets:
        print('  ' + repr(path.name))
    print('Top-level archive/, scripts/ and templates are not removed.')

    if not args.yes:
        token = 'DELETE ' + args.target
        if input(f'Type {token!r} to continue: ').strip() != token:
            print('Cancelled.')
            return 1

    names = {
        path.name for path in targets
        if ID.fullmatch(path.name)
    }

    # Catch running cf operations, including in-progress parses.
    if args.target == 'all' and (ROOT / '.locks').is_dir():
        names.update(
            path.name for path in (ROOT / '.locks').iterdir()
            if ID.fullmatch(path.name)
        )

    with contextlib.ExitStack() as stack:
        for name in sorted(names):
            stack.enter_context(locked(name))

        if any(
            identity(path) != saved
            for path, saved in before.items()
        ):
            raise RuntimeError(
                'Directory entries changed during confirmation; retry.'
            )

        try:
            for path in targets:
                if path.is_symlink() or not path.is_dir():
                    path.unlink()
                else:
                    shutil.rmtree(path)
        finally:
            forget_missing_active(base)

    print(f'Removed {len(targets)} item(s). Kept {base}.')

    if args.target == 'all' and any(base.iterdir()):
        print(
            'New entries appeared during cleanup; '
            'those were left untouched.'
        )

    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except EOFError:
        print('\nCancelled: no confirmation received.', file=sys.stderr)
        raise SystemExit(1)
    except KeyboardInterrupt:
        print(
            '\nInterrupted; removals already completed cannot be undone.',
            file=sys.stderr,
        )
        raise SystemExit(130)
    except (OSError, RuntimeError) as e:
        print(f'cfclean: {e}', file=sys.stderr)
        raise SystemExit(2)
