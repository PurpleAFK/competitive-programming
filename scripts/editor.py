from common import *
def browser(url):
    print(url)
    cmd = shlex.split(os.environ.get('CF_BROWSER', 'xdg-open'))
    if not cmd or not shutil.which(cmd[0]):
        fail('No browser launcher; open the URL manually.')
    p = subprocess.Popen(cmd + [url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    try:
        if p.wait(timeout=2):
            fail('Browser launcher failed; open the URL manually.')
    except subprocess.TimeoutExpired:
        pass

def edit(src):
    if not src.is_file():
        fail('Source does not exist: ' + str(src))
    lua = f"vim.g.cf_modular_cli={json.dumps(str(ROOT / 'scripts' / 'cf'), ensure_ascii=False)}; local m=dofile({json.dumps(str(ROOT / 'scripts' / 'nvim.lua'), ensure_ascii=False)}); "
    if os.environ.get('NVIM'):
        expr = '(function() ' + lua + 'm.open(_A); return 1 end)()'
        quote = lambda s: "'" + s.replace("'", "''") + "'"
        subprocess.run(['nvim', '--headless', '--server', os.environ['NVIM'], '--remote-expr', 'luaeval(' + quote(expr) + ',' + quote(str(src)) + ')'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, check=True, timeout=10)
    else:
        os.chdir(src.parent)
        os.execvp('nvim', ['nvim', str(src), '-c', 'lua ' + lua])
