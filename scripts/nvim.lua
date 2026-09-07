if _G.CFContestModular and _G.CFContestModular.cli == vim.g.cf_modular_cli then return _G.CFContestModular end
local M = {}
_G.CFContestModular = M

local api, fn = vim.api, vim.fn
local uv = vim.uv or vim.loop
local cli = assert(vim.g.cf_modular_cli)
M.cli = cli
pcall(api.nvim_del_augroup_by_name, "CfContestInlineSession")
pcall(api.nvim_del_augroup_by_name, "CfContestSession")
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
  return vim.t.cf_modular_dir
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
  vim.t.cf_modular_dir = dir
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
  opts = opts or {}
  opts.force = true
  api.nvim_create_user_command(name, callback, opts)
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

  vim.t.cf_modular_dir = dir
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
  group=api.nvim_create_augroup('CfContestModularSession', { clear=true }),
  callback=enter,
})
enter()
return M
