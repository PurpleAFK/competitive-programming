from common import *
from runner import compile_cpp, checker, execute, compare, show, diff_bytes
def stress(a, p, src):
    if a.count <= 0 or a.seed < 0 or a.seed + a.count > 2 ** 64:
        fail('Invalid count/unsigned 64-bit seed range.')
    files = [src, p / 'brute.cpp', p / 'gen.cpp']
    saved = {f.name: f.read_bytes() for f in files}
    solution, brute, gen = [compile_cpp(f, p, a.debug if i < 2 else False) for i, f in enumerate(files)]
    if any((f.read_bytes() != saved[f.name] for f in files)):
        fail('Source changed during compilation; retry.')
    check = checker(a, p)
    work = p / '.cf/run/stress'
    work.mkdir(parents=True, exist_ok=True)
    print(f'Seeds {a.seed}..{a.seed + a.count - 1}', flush=True)
    for n, seed in enumerate(range(a.seed, a.seed + a.count), 1):
        for f in work.iterdir():
            if f.is_file():
                f.unlink()
        inp = work / 'input.txt'
        expected = work / 'expected.txt'
        actual = work / 'actual.txt'
        verdict = 'PASS'
        for label, argv, input_file, output, timeout in [('GEN', [gen, str(seed)], None, inp, a.timeout), ('BRUTE', [brute], inp, expected, a.brute_timeout), ('SOLUTION', [solution], inp, actual, a.timeout)]:
            code, _ = execute(argv, p, input_file, output, work / (label + '.stderr'), timeout)
            if code != 0:
                verdict = label + (' TLE' if code is None else ' RE')
                break
        if verdict == 'PASS':
            verdict = compare(a, check, p, inp, expected, actual, work / 'check')
        if verdict != 'PASS':
            dest = p / 'failures' / (stamp() + '-seed-' + str(seed))
            shutil.copytree(work, dest)
            for name, data in saved.items():
                atomic(dest / 'sources' / name, data)
            write_json(dest / 'meta.json', {'seed': seed, 'verdict': verdict, 'debug': a.debug})
            print(f'{verdict}, seed {seed}\nSaved: {dest}')
            for f in dest.glob('*.stderr'):
                show(f)
            if verdict == 'WA' and (not check):
                diff_bytes(expected.read_bytes(), actual.read_bytes())
            return 1
        if n % 100 == 0:
            print(f'{n} matched', flush=True)
    print(f'No mismatch in {a.count} cases.')
    return 0
