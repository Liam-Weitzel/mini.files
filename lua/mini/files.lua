







local MiniFiles = {}
local H = {}

MiniFiles.setup = function(config)
  _G.MiniFiles = MiniFiles

  config = H.setup_config(config)

  H.apply_config(config)

  H.create_autocommands(config)

  H.create_default_hl()
end

MiniFiles.config = {
  content = {
    filter = nil,
    highlight = nil,
    prefix = nil,
    sort = nil,
  },

  mappings = {
    close       = 'q',
    go_in       = 'l',
    go_in_plus  = 'L',
    go_out      = 'h',
    go_out_plus = 'H',
    mark_goto   = "'",
    mark_set    = 'm',
    reset       = '<BS>',
    reveal_cwd  = '@',
    show_help   = 'g?',
    synchronize = '=',
    trim_left   = '<',
    trim_right  = '>',
    copy_relative_path = 'ypr',
    copy_absolute_path = 'ypa',
    open_with_default = 'gx',
    open_in_explorer = 'gX',
  },

  options = {
    permanent_delete = true,
    use_as_default_explorer = true,
  },

  windows = {
    max_number = math.huge,
    preview = false,
    width_focus = 50,
    width_nofocus = 15,
    width_preview = 25,
  },
}

MiniFiles.open = function(path, use_latest, opts)
  path = H.fs_full_path(path or vim.fn.getcwd())

  local fs_type = H.fs_get_type(path)
  if fs_type == nil then H.error('`path` is not a valid path ("' .. path .. '")') end

  local entry_name
  if fs_type == 'file' then
    path, entry_name = H.fs_get_parent(path), H.fs_get_basename(path)
  end

  if use_latest == nil then use_latest = true end

  local did_close = MiniFiles.close()
  if did_close == false then return end

  local explorer
  if use_latest then explorer = H.explorer_path_history[path] end
  explorer = explorer or H.explorer_new(path)

  explorer.opts = H.normalize_opts(nil, opts)
  explorer.target_window = vim.api.nvim_get_current_win()

  explorer = H.explorer_focus_on_entry(explorer, path, entry_name)

  H.explorer_refresh(explorer)

  H.latest_paths[vim.api.nvim_get_current_tabpage()] = path

  H.explorer_track_lost_focus()

  H.trigger_event('MiniFilesExplorerOpen')
end

MiniFiles.refresh = function(opts)
  local explorer = H.explorer_get()
  if explorer == nil then return end

  local content_opts = (opts or {}).content or {}
  local force_update = #vim.tbl_keys(content_opts) > 0

  if force_update then force_update = H.explorer_ignore_pending_fs_actions(explorer, 'Update buffers') end

  explorer.opts = H.normalize_opts(explorer.opts, opts)

  H.explorer_refresh(explorer, { force_update = force_update })
end

MiniFiles.synchronize = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  local fs_actions = H.explorer_compute_fs_actions(explorer)
  if fs_actions ~= nil then
    local msg = table.concat(H.fs_actions_to_lines(fs_actions), '\n')
    local confirm_res = vim.fn.confirm(msg, '&Yes\n&No\n&Cancel', 1, 'Question')
    if confirm_res == 3 then return false end
    if confirm_res == 1 then H.fs_actions_apply(fs_actions) end
  end

  H.explorer_refresh(explorer, { force_update = true })
  return true
end

MiniFiles.reset = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  explorer.branch = { explorer.anchor }
  explorer.depth_focus = 1

  for _, view in pairs(explorer.views) do
    view.cursor = { 1, 0 }
  end

  H.explorer_refresh(explorer, { skip_update_cursor = true })
end

MiniFiles.close = function()
  pcall(vim.loop.timer_stop, H.timers.focus)

  local explorer = H.explorer_get(nil, true)
  if explorer == nil then return nil end

  if not H.explorer_ignore_pending_fs_actions(explorer, 'Close') then return false end

  -- Clear any active image preview
  H.clear_image_preview()

  H.trigger_event('MiniFilesExplorerClose')

  explorer = H.explorer_ensure_target_window(explorer)
  pcall(vim.api.nvim_set_current_win, explorer.target_window)

  explorer = H.explorer_update_cursors(explorer)

  for i, win_id in pairs(explorer.windows) do
    H.window_close(win_id)
    explorer.windows[i] = nil
  end

  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf_id = vim.api.nvim_win_get_buf(win_id)
    if vim.bo[buf_id].filetype == 'minifiles-help' then vim.api.nvim_win_close(win_id, true) end
  end

  for path, view in pairs(explorer.views) do
    explorer.views[path] = H.view_invalidate_buffer(H.view_encode_cursor(view))
  end

  local tabpage_id, anchor = vim.api.nvim_get_current_tabpage(), explorer.anchor
  H.explorer_path_history[anchor] = explorer
  H.opened_explorers[tabpage_id] = nil

  return true
end

MiniFiles.go_in = function(opts)
  local explorer = H.explorer_get()
  if explorer == nil then return end

  opts = vim.tbl_deep_extend('force', { close_on_file = false }, opts or {})

  local should_close = opts.close_on_file
  if should_close then
    local fs_entry = MiniFiles.get_fs_entry()
    should_close = fs_entry ~= nil and fs_entry.fs_type == 'file'
  end

  local cur_line = vim.fn.line('.')
  explorer = H.explorer_go_in_range(explorer, vim.api.nvim_get_current_buf(), cur_line, cur_line)

  H.explorer_refresh(explorer)

  if should_close then MiniFiles.close() end
end

MiniFiles.go_out = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  if explorer.depth_focus == 1 then
    explorer = H.explorer_open_root_parent(explorer)
  else
    explorer.depth_focus = explorer.depth_focus - 1
  end

  H.explorer_refresh(explorer)
end

MiniFiles.trim_left = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  explorer = H.explorer_trim_branch_left(explorer)
  H.explorer_refresh(explorer)
end

MiniFiles.trim_right = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  explorer = H.explorer_trim_branch_right(explorer)
  H.explorer_refresh(explorer)
end

MiniFiles.reveal_cwd = function()
  local state = MiniFiles.get_explorer_state()
  if state == nil then return end
  local branch, depth_focus = state.branch, state.depth_focus

  local cwd = H.fs_full_path(vim.fn.getcwd())
  local cwd_ancestor_pattern = string.format('^%s/.', vim.pesc(cwd))
  while branch[1]:find(cwd_ancestor_pattern) ~= nil do
    table.insert(branch, 1, H.fs_get_parent(branch[1]))
    depth_focus = depth_focus + 1
  end

  MiniFiles.set_branch(branch, { depth_focus = depth_focus })
end

MiniFiles.show_help = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  local buf_id = vim.api.nvim_get_current_buf()
  if not H.is_opened_buffer(buf_id) then return end

  H.explorer_show_help(explorer, buf_id, vim.api.nvim_get_current_win())
end

MiniFiles.copy_relative_path = function()
  local fs_entry = MiniFiles.get_fs_entry()
  if fs_entry == nil then return end

  local cwd = vim.fn.getcwd()
  local relative_path = vim.fn.fnamemodify(fs_entry.path, ':~:.')
  vim.fn.setreg('+', relative_path)
  vim.fn.setreg('"', relative_path)
  H.notify('Copied relative path: ' .. relative_path)
end

MiniFiles.copy_absolute_path = function()
  local fs_entry = MiniFiles.get_fs_entry()
  if fs_entry == nil then return end

  local absolute_path = vim.fn.fnamemodify(fs_entry.path, ':p')
  vim.fn.setreg('+', absolute_path)
  vim.fn.setreg('"', absolute_path)
  H.notify('Copied absolute path: ' .. absolute_path)
end

MiniFiles.open_with_default = function()
  local fs_entry = MiniFiles.get_fs_entry()
  if fs_entry == nil then return end

  local cmd = string.format('xdg-open %s >/dev/null 2>&1 &', vim.fn.shellescape(fs_entry.path))
  vim.fn.system(cmd)
end

MiniFiles.open_in_explorer = function()
  local fs_entry = MiniFiles.get_fs_entry()
  if fs_entry == nil then return end

  local path = fs_entry.fs_type == 'directory' and fs_entry.path or vim.fn.fnamemodify(fs_entry.path, ':h')
  local cmd = string.format('xdg-open %s', vim.fn.shellescape(path))
  vim.fn.system(cmd)
  H.notify('Opened in file explorer: ' .. path)
end

MiniFiles.get_fs_entry = function(buf_id, line)
  buf_id = H.validate_opened_buffer(buf_id)
  line = H.validate_line(buf_id, line)

  local path_id = H.match_line_path_id(H.get_bufline(buf_id, line))
  return H.get_fs_entry_from_path_index(path_id)
end

MiniFiles.get_explorer_state = function()
  local explorer = H.explorer_get()
  if explorer == nil then return end

  H.explorer_ensure_target_window(explorer)
  local windows = {}
  for _, win_id in ipairs(explorer.windows) do
    local buf_id = vim.api.nvim_win_get_buf(win_id)
    local path = (H.opened_buffers[buf_id] or {}).path
    table.insert(windows, { win_id = win_id, path = path })
  end

  return {
    anchor = explorer.anchor,
    bookmarks = vim.deepcopy(explorer.bookmarks),
    branch = vim.deepcopy(explorer.branch),
    depth_focus = explorer.depth_focus,
    target_window = explorer.target_window,
    windows = windows,
  }
end

MiniFiles.set_target_window = function(win_id)
  if not H.is_valid_win(win_id) then H.error('`win_id` should be valid window identifier.') end

  local explorer = H.explorer_get()
  if explorer == nil then return end

  explorer.target_window = win_id
end

MiniFiles.set_branch = function(branch, opts)
  local explorer = H.explorer_get()
  if explorer == nil then return end

  branch = H.validate_branch(branch)
  opts = opts or {}
  local depth_focus = opts.depth_focus or math.huge
  if type(depth_focus) ~= 'number' then H.error('`depth_focus` should be a number') end
  local max_depth = #branch - (H.fs_get_type(branch[#branch]) == 'file' and 1 or 0)
  depth_focus = math.min(math.max(math.floor(depth_focus), 1), max_depth)

  explorer.branch, explorer.depth_focus = branch, depth_focus
  for i = 1, #branch - 1 do
    local parent, child = branch[i], H.fs_get_basename(branch[i + 1])
    local parent_view = explorer.views[parent] or {}
    parent_view.cursor = child
    explorer.views[parent] = parent_view
  end

  H.explorer_refresh(explorer, { skip_update_cursor = true })
  H.explorer_refresh(explorer)
end

MiniFiles.set_bookmark = function(id, path, opts)
  local explorer = H.explorer_get()
  if explorer == nil then return end

  if not (type(id) == 'string' and id:len() == 1) then H.error('Bookmark id should be single character') end
  local is_valid_path = vim.is_callable(path)
    or (type(path) == 'string' and H.fs_get_type(vim.fn.expand(path)) == 'directory')
  if not is_valid_path then H.error('Bookmark path should be a valid path to directory or a callable.') end
  opts = opts or {}
  if not (opts.desc == nil or type(opts.desc) == 'string') then H.error('Bookmark description should be string') end

  explorer.bookmarks[id] = { path = path, desc = opts.desc }
end

MiniFiles.get_latest_path = function() return H.latest_paths[vim.api.nvim_get_current_tabpage()] end

MiniFiles.default_filter = function(fs_entry) return true end

MiniFiles.default_prefix = function(fs_entry)
  if _G.MiniIcons ~= nil then
    local category = fs_entry.fs_type == 'directory' and 'directory' or 'file'
    local icon, hl = _G.MiniIcons.get(category, fs_entry.path)
    return icon .. ' ', hl
  end

  if fs_entry.fs_type == 'directory' then return ' ', 'MiniFilesDirectory' end
  local has_devicons, devicons = pcall(require, 'nvim-web-devicons')
  if not has_devicons then return ' ', 'MiniFilesFile' end

  local icon, hl = devicons.get_icon(fs_entry.name, nil, { default = false })
  return (icon or '') .. ' ', hl or 'MiniFilesFile'
end

MiniFiles.default_sort = function(fs_entries)
  local res = vim.tbl_map(
    function(x)
      return {
        fs_type = x.fs_type,
        name = x.name,
        path = x.path,
        lower_name = x.name:lower(),
        is_dir = x.fs_type == 'directory',
      }
    end,
    fs_entries
  )

  table.sort(res, H.compare_fs_entries)

  return vim.tbl_map(function(x) return { name = x.name, fs_type = x.fs_type, path = x.path } end, res)
end

MiniFiles.default_highlight = function(fs_entry)
  return fs_entry.fs_type == 'directory' and 'MiniFilesDirectory' or 'MiniFilesFile'
end

H.default_config = vim.deepcopy(MiniFiles.config)

H.ns_id = {
  highlight = vim.api.nvim_create_namespace('MiniFilesHighlight'),
}

H.timers = {
  focus = vim.loop.new_timer(),
}

H.path_index = {}

H.explorer_path_history = {}

H.opened_explorers = {}

H.latest_paths = {}

H.opened_buffers = {}

H.is_windows = vim.loop.os_uname().sysname == 'Windows_NT'

H.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(H.default_config), config or {})

  H.check_type('content', config.content, 'table')
  H.check_type('content.filter', config.content.filter, 'function', true)
  H.check_type('content.highlight', config.content.highlight, 'function', true)
  H.check_type('content.prefix', config.content.prefix, 'function', true)
  H.check_type('content.sort', config.content.sort, 'function', true)

  H.check_type('mappings', config.mappings, 'table')
  H.check_type('mappings.close', config.mappings.close, 'string')
  H.check_type('mappings.go_in', config.mappings.go_in, 'string')
  H.check_type('mappings.go_in_plus', config.mappings.go_in_plus, 'string')
  H.check_type('mappings.go_out', config.mappings.go_out, 'string')
  H.check_type('mappings.go_out_plus', config.mappings.go_out_plus, 'string')
  H.check_type('mappings.mark_goto', config.mappings.mark_goto, 'string')
  H.check_type('mappings.mark_set', config.mappings.mark_set, 'string')
  H.check_type('mappings.reset', config.mappings.reset, 'string')
  H.check_type('mappings.reveal_cwd', config.mappings.reveal_cwd, 'string')
  H.check_type('mappings.show_help', config.mappings.show_help, 'string')
  H.check_type('mappings.synchronize', config.mappings.synchronize, 'string')
  H.check_type('mappings.trim_left', config.mappings.trim_left, 'string')
  H.check_type('mappings.trim_right', config.mappings.trim_right, 'string')
  H.check_type('mappings.copy_relative_path', config.mappings.copy_relative_path, 'string')
  H.check_type('mappings.copy_absolute_path', config.mappings.copy_absolute_path, 'string')
  H.check_type('mappings.open_with_default', config.mappings.open_with_default, 'string')
  H.check_type('mappings.open_in_explorer', config.mappings.open_in_explorer, 'string')

  H.check_type('options', config.options, 'table')
  H.check_type('options.use_as_default_explorer', config.options.use_as_default_explorer, 'boolean')
  H.check_type('options.permanent_delete', config.options.permanent_delete, 'boolean')

  H.check_type('windows', config.windows, 'table')
  H.check_type('windows.max_number', config.windows.max_number, 'number')
  H.check_type('windows.preview', config.windows.preview, 'boolean')
  H.check_type('windows.width_focus', config.windows.width_focus, 'number')
  H.check_type('windows.width_nofocus', config.windows.width_nofocus, 'number')
  H.check_type('windows.width_preview', config.windows.width_preview, 'number')

  return config
end

H.apply_config = function(config) MiniFiles.config = config end

H.create_autocommands = function(config)
  local gr = vim.api.nvim_create_augroup('MiniFiles', {})

  local au = function(event, pattern, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
  end

  if config.options.use_as_default_explorer then
    vim.cmd('silent! autocmd! FileExplorer *')
    vim.cmd('autocmd VimEnter * ++once silent! autocmd! FileExplorer *')

    au('BufEnter', '*', H.track_dir_edit, 'Track directory edit')
  end

  au('VimResized', '*', MiniFiles.refresh, 'Refresh on resize')
  au('ColorScheme', '*', H.create_default_hl, 'Ensure colors')
end

H.create_default_hl = function()
  local hi = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  hi('MiniFilesBorder',         { link = 'FloatBorder' })
  hi('MiniFilesBorderModified', { link = 'DiagnosticFloatingWarn' })
  hi('MiniFilesCursorLine',     { link = 'CursorLine' })
  hi('MiniFilesDirectory',      { link = 'Directory'   })
  hi('MiniFilesFile',           {})
  hi('MiniFilesNormal',         { link = 'NormalFloat' })
  hi('MiniFilesTitle',          { link = 'FloatTitle'  })
  hi('MiniFilesTitleFocused',   { link = 'FloatTitle' })
end

H.get_config = function(config)
  return vim.tbl_deep_extend('force', MiniFiles.config, vim.b.minifiles_config or {}, config or {})
end

H.normalize_opts = function(explorer_opts, opts)
  opts = vim.tbl_deep_extend('force', H.get_config(), explorer_opts or {}, opts or {})
  opts.content.filter = opts.content.filter or MiniFiles.default_filter
  opts.content.highlight = opts.content.highlight or MiniFiles.default_highlight
  opts.content.prefix = opts.content.prefix or MiniFiles.default_prefix
  opts.content.sort = opts.content.sort or MiniFiles.default_sort

  return opts
end

H.track_dir_edit = function(data)
  if vim.api.nvim_get_current_buf() ~= data.buf then return end

  if vim.b.minifiles_processed_dir then
    local alt_buf = vim.fn.bufnr('#')
    if alt_buf ~= data.buf and vim.fn.buflisted(alt_buf) == 1 then vim.api.nvim_win_set_buf(0, alt_buf) end
    return vim.api.nvim_buf_delete(data.buf, { force = true })
  end

  local path = vim.api.nvim_buf_get_name(0)
  if vim.fn.isdirectory(path) ~= 1 then return end

  vim.bo.bufhidden = 'wipe'
  vim.b.minifiles_processed_dir = true

  vim.schedule(function() MiniFiles.open(path, false) end)
end

H.explorer_new = function(path)
  return {
    branch = { path },
    depth_focus = 1,
    views = {},
    windows = {},
    anchor = path,
    target_window = vim.api.nvim_get_current_win(),
    bookmarks = {},
    opts = {},
  }
end

H.explorer_get = function(tabpage_id, ignore_visibility)
  tabpage_id = tabpage_id or vim.api.nvim_get_current_tabpage()
  local res = H.opened_explorers[tabpage_id]

  if ignore_visibility or H.explorer_is_visible(res) then return res end

  H.opened_explorers[tabpage_id] = nil
  return nil
end

H.explorer_is_visible = function(explorer)
  if explorer == nil then return nil end
  for _, win_id in ipairs(explorer.windows) do
    if H.is_valid_win(win_id) then return true end
  end
  return false
end

H.explorer_refresh = function(explorer, opts)
  explorer = H.explorer_normalize(explorer)
  if explorer.is_corrupted then
    explorer.is_corrupted = false
    MiniFiles.close()
    return
  end
  if #explorer.branch == 0 then return end
  opts = opts or {}

  -- Clear image preview if we're no longer in preview mode
  local preview_depth = explorer.depth_focus + 1
  local has_preview = explorer.opts.windows.preview and preview_depth <= #explorer.branch
  if not has_preview and H.current_image_preview then
    H.clear_image_preview()
  end

  if not opts.skip_update_cursor then explorer = H.explorer_update_cursors(explorer) end

  for path, view in pairs(explorer.views) do
    if not H.fs_is_present_path(path) then
      H.buffer_delete(view.buf_id)
      explorer.views[path] = nil
    end
  end

  if opts.force_update then
    for path, view in pairs(explorer.views) do
      view = H.view_encode_cursor(view)
      if H.opened_buffers[view.buf_id] then H.opened_buffers[view.buf_id].children_path_ids = nil end
      H.buffer_update(view.buf_id, path, explorer.opts, not view.was_focused)
      explorer.views[path] = view
    end
  end

  for depth = 1, #explorer.branch do
    explorer = H.explorer_sync_cursor_and_branch(explorer, depth)
  end

  for _, win_id in ipairs(explorer.windows) do
    if H.is_valid_win(win_id) then
      local buf_id = vim.api.nvim_win_get_buf(win_id)
      H.opened_buffers[buf_id].win_id = nil
    end
  end

  local depth_range = H.compute_visible_depth_range(explorer, explorer.opts)

  local cur_win_col, cur_win_count = 0, 0
  for depth = depth_range.from, depth_range.to do
    cur_win_count = cur_win_count + 1
    local cur_width = H.explorer_refresh_depth_window(explorer, depth, cur_win_count, cur_win_col)

    cur_win_col = cur_win_col + cur_width + 2
  end

  for depth = cur_win_count + 1, #explorer.windows do
    H.window_close(explorer.windows[depth])
    explorer.windows[depth] = nil
  end

  local win_focus_count = explorer.depth_focus - depth_range.from + 1
  local win_id_focused = explorer.windows[win_focus_count]
  H.window_focus(win_id_focused)

  local tabpage_id = vim.api.nvim_win_get_tabpage(win_id_focused)
  H.opened_explorers[tabpage_id] = explorer

  return explorer
end

H.explorer_track_lost_focus = function()
  local track = vim.schedule_wrap(function()
    local ft = vim.bo.filetype
    if ft == 'minifiles' or ft == 'minifiles-help' then return end

    -- Don't close if we have an active image preview to prevent interrupting image viewing
    if H.current_image_preview then return end

    local cur_win_id = vim.api.nvim_get_current_win()
    MiniFiles.close()
    pcall(vim.api.nvim_set_current_win, cur_win_id)
  end)
  H.timers.focus:start(1000, 1000, track)
end

H.explorer_normalize = function(explorer)
  local norm_branch = {}
  for _, path in ipairs(explorer.branch) do
    if not H.fs_is_present_path(path) then break end
    table.insert(norm_branch, path)
  end

  local cur_max_depth = #norm_branch

  explorer.branch = norm_branch
  explorer.depth_focus = math.min(math.max(explorer.depth_focus, 1), cur_max_depth)

  for i = cur_max_depth + 1, #explorer.windows do
    H.window_close(explorer.windows[i])
    explorer.windows[i] = nil
  end

  for _, win_id in pairs(explorer.windows) do
    if not H.is_valid_win(win_id) then explorer.is_corrupted = true end
  end

  return explorer
end

H.explorer_sync_cursor_and_branch = function(explorer, depth)
  if #explorer.branch < depth then return explorer end

  local path, path_to_right = explorer.branch[depth], explorer.branch[depth + 1]
  local view = explorer.views[path]
  if view == nil then return explorer end

  local buf_id, cursor = view.buf_id, view.cursor
  if cursor == nil then return explorer end

  local cursor_path
  if type(cursor) == 'table' and H.is_valid_buf(buf_id) then
    local l = H.get_bufline(buf_id, cursor[1])
    cursor_path = H.path_index[H.match_line_path_id(l)] or H.fs_child_path(path, l .. '\000')
  elseif type(cursor) == 'string' then
    cursor_path = H.fs_child_path(path, cursor)
  else
    return explorer
  end

  if cursor_path == path_to_right then return explorer end

  for i = depth + 1, #explorer.branch do
    explorer.branch[i] = nil
  end
  explorer.depth_focus = math.min(explorer.depth_focus, #explorer.branch)

  local show_preview = explorer.opts.windows.preview
  local is_cur_buf = explorer.depth_focus == depth
  if show_preview and is_cur_buf then table.insert(explorer.branch, cursor_path) end

  return explorer
end

H.explorer_go_in_range = function(explorer, buf_id, from_line, to_line)
  local files, path, line = {}, nil, nil
  for i = from_line, to_line do
    local fs_entry = MiniFiles.get_fs_entry(buf_id, i) or {}
    if fs_entry.fs_type == 'file' then table.insert(files, fs_entry.path) end
    if fs_entry.fs_type == 'directory' then
      path, line = fs_entry.path, i
    end
    if fs_entry.fs_type == nil and fs_entry.path == nil then
      local entry = vim.inspect(H.get_bufline(buf_id, i))
      H.notify('Line ' .. entry .. ' does not have proper format. Did you modify without synchronization?', 'WARN')
    end
    if fs_entry.fs_type == nil and fs_entry.path ~= nil then
      local path_resolved = vim.fn.resolve(fs_entry.path)
      local symlink_info = path_resolved == fs_entry.path and ''
        or (' Looks like miscreated symlink (resolved to ' .. path_resolved .. ').')
      H.notify('Path ' .. fs_entry.path .. ' is not present on disk.' .. symlink_info, 'WARN')
    end
  end

  for _, file_path in ipairs(files) do
    explorer = H.explorer_open_file(explorer, file_path)
  end

  if path ~= nil then
    explorer = H.explorer_open_directory(explorer, path, explorer.depth_focus + 1)

    local win_id = H.opened_buffers[buf_id].win_id
    if H.is_valid_win(win_id) then vim.api.nvim_win_set_cursor(win_id, { line, 0 }) end
  end

  return explorer
end

H.explorer_focus_on_entry = function(explorer, path, entry_name)
  if entry_name == nil then return explorer end

  explorer.depth_focus = H.explorer_get_path_depth(explorer, path)
  if explorer.depth_focus == nil then
    explorer.branch, explorer.depth_focus = { path }, 1
  end

  local path_view = explorer.views[path] or {}
  path_view.cursor = entry_name
  explorer.views[path] = path_view

  return explorer
end

H.explorer_compute_fs_actions = function(explorer)
  local fs_diffs = {}
  for _, view in pairs(explorer.views) do
    local dir_fs_diff = H.buffer_compute_fs_diff(view.buf_id)
    if #dir_fs_diff > 0 then vim.list_extend(fs_diffs, dir_fs_diff) end
  end
  if #fs_diffs == 0 then return nil end

  local create, delete_map, raw_copy = {}, {}, {}

  for _, diff in ipairs(fs_diffs) do
    if diff.from == nil then
      table.insert(create, { action = 'create', dir = diff.dir, to = diff.to })
    elseif diff.to == nil then
      delete_map[diff.from] = true
    else
      table.insert(raw_copy, diff)
    end
  end

  local rename, move, copy = {}, {}, {}
  for _, diff in pairs(raw_copy) do
    local action, target = 'copy', copy
    if delete_map[diff.from] then
      if diff.to == (diff.from .. '/') and H.fs_get_type(diff.from) == 'file' then
        target, action, diff.from = create, 'create', nil
      else
        action = H.fs_get_parent(diff.from) == H.fs_get_parent(diff.to) and 'rename' or 'move'
        target = action == 'rename' and rename or move
        delete_map[diff.from] = nil
      end
    end
    table.insert(target, { action = action, dir = diff.dir, from = diff.from, to = diff.to })
  end

  local delete, is_trash = {}, not explorer.opts.options.permanent_delete
  local trash_dir = H.fs_child_path(vim.fn.stdpath('data'), 'mini.files/trash')
  for p, _ in pairs(delete_map) do
    local to = is_trash and H.fs_child_path(trash_dir, H.fs_get_basename(p)) or nil
    table.insert(delete, { action = 'delete', from = p, to = to })
  end

  local before_delete, after_delete = {}, {}
  for _, arr in ipairs({ move, rename, copy, create }) do
    for _, diff in ipairs(arr) do
      local will_be_deleted = false
      for _, del in ipairs(delete) do
        local del_from_dir = del.from .. '/'
        local from_is_affected = del.from == diff.from or vim.startswith(diff.from or '', del_from_dir)
        local to_is_affected = vim.startswith(diff.to, del_from_dir) and diff.to ~= del_from_dir
        will_be_deleted = will_be_deleted or from_is_affected or to_is_affected
      end
      table.insert(will_be_deleted and before_delete or after_delete, diff)
    end
  end

  local res = {}
  vim.list_extend(res, before_delete)
  vim.list_extend(res, delete)
  vim.list_extend(res, after_delete)
  return res
end

H.explorer_update_cursors = function(explorer)
  for _, win_id in ipairs(explorer.windows) do
    if H.is_valid_win(win_id) then
      local buf_id = vim.api.nvim_win_get_buf(win_id)
      local path = H.opened_buffers[buf_id].path
      explorer.views[path].cursor = vim.api.nvim_win_get_cursor(win_id)
    end
  end

  return explorer
end

H.explorer_refresh_depth_window = function(explorer, depth, win_count, win_col)
  local path = explorer.branch[depth]
  local views, windows, opts = explorer.views, explorer.windows, explorer.opts

  local win_is_focused = depth == explorer.depth_focus
  local win_is_preview = opts.windows.preview and (depth == (explorer.depth_focus + 1))
  local cur_width = win_is_focused and opts.windows.width_focus
    or (win_is_preview and opts.windows.width_preview or opts.windows.width_nofocus)

  local view = views[path] or {}
  view = H.view_ensure_proper(view, path, opts, win_is_focused, win_is_preview)
  views[path] = view

  local config = {
    col = win_col,
    height = vim.api.nvim_buf_line_count(view.buf_id),
    width = cur_width,
    title = win_count == 1 and H.fs_shorten_path(H.fs_full_path(path)) or H.fs_get_basename(path),
  }
  config.title = ' ' .. H.sanitize_string(config.title) .. ' '

  local win_id = windows[win_count]
  if not H.is_valid_win(win_id) then
    H.window_close(win_id)
    win_id = H.window_open(view.buf_id, config)
    windows[win_count] = win_id
  end

  H.window_update(win_id, config)

  H.window_set_view(win_id, view)

  H.trigger_event('MiniFilesWindowUpdate', { buf_id = vim.api.nvim_win_get_buf(win_id), win_id = win_id })

  explorer.views = views
  explorer.windows = windows

  return cur_width
end

H.explorer_get_path_depth = function(explorer, path)
  for depth, depth_path in pairs(explorer.branch) do
    if path == depth_path then return depth end
  end
end

H.explorer_ignore_pending_fs_actions = function(explorer, action_name)
  if H.explorer_compute_fs_actions(explorer) == nil then return true end

  local msg = string.format('There are pending file system actions\n\n%s without synchronization?', action_name)
  local confirm_res = vim.fn.confirm(msg, '&Yes\n&No', 1, 'Question')
  return confirm_res == 1
end

H.explorer_open_file = function(explorer, path)
  explorer = H.explorer_ensure_target_window(explorer)
  H.edit(path, explorer.target_window)
  return explorer
end

H.explorer_ensure_target_window = function(explorer)
  if not H.is_valid_win(explorer.target_window) then explorer.target_window = H.get_first_valid_normal_window() end
  return explorer
end

H.explorer_open_directory = function(explorer, path, target_depth)
  explorer.depth_focus = target_depth

  local show_new_path_at_depth = path ~= explorer.branch[target_depth]
  if show_new_path_at_depth then
    explorer.branch[target_depth] = path
    explorer = H.explorer_trim_branch_right(explorer)
  end

  return explorer
end

H.explorer_open_root_parent = function(explorer)
  local root = explorer.branch[1]
  local root_parent = H.fs_get_parent(root)
  if root_parent == nil then return explorer end

  table.insert(explorer.branch, 1, root_parent)

  return H.explorer_focus_on_entry(explorer, root_parent, H.fs_get_basename(root))
end

H.explorer_trim_branch_right = function(explorer)
  for i = explorer.depth_focus + 1, #explorer.branch do
    explorer.branch[i] = nil
  end
  return explorer
end

H.explorer_trim_branch_left = function(explorer)
  local new_branch = {}
  for i = explorer.depth_focus, #explorer.branch do
    table.insert(new_branch, explorer.branch[i])
  end
  explorer.branch = new_branch
  explorer.depth_focus = 1
  return explorer
end

H.explorer_show_help = function(explorer, explorer_buf_id, explorer_win_id)
  local buf_mappings = vim.api.nvim_buf_get_keymap(explorer_buf_id, 'n')
  local map_data, desc_width = {}, 0
  for _, data in ipairs(buf_mappings) do
    if data.desc ~= nil then
      map_data[data.desc] = data.lhs:lower() == '<lt>' and '<' or data.lhs
      desc_width = math.max(desc_width, data.desc:len())
    end
  end

  local desc_arr = vim.tbl_keys(map_data)
  table.sort(desc_arr)
  local map_format = string.format('%%-%ds │ %%s', desc_width)

  local lines = { 'Buffer mappings:', '' }
  for _, desc in ipairs(desc_arr) do
    table.insert(lines, string.format(map_format, desc, map_data[desc]))
  end
  table.insert(lines, '')

  local bookmark_ids = vim.tbl_keys(explorer.bookmarks)
  if #bookmark_ids > 0 then
    table.insert(lines, 'Bookmarks:')
    table.insert(lines, '')
    table.sort(bookmark_ids)
    for _, id in ipairs(bookmark_ids) do
      local data = explorer.bookmarks[id]
      local desc = data.desc or (vim.is_callable(data.path) and data.path() or data.path)
      table.insert(lines, id .. ' │ ' .. desc)
    end
    table.insert(lines, '')
  end

  table.insert(lines, '(Press `q` to close)')

  local buf_id = vim.api.nvim_create_buf(false, true)
  H.set_buflines(buf_id, lines)
  H.set_buf_name(buf_id, 'help')

  vim.keymap.set('n', 'q', '<Cmd>close<CR>', { buffer = buf_id, desc = 'Close this window' })

  vim.b[buf_id].minicursorword_disable = true
  vim.b[buf_id].miniindentscope_disable = true

  vim.bo[buf_id].filetype = 'minifiles-help'
  vim.bo[buf_id].bufhidden = 'wipe'

  local line_widths = vim.tbl_map(vim.fn.strdisplaywidth, lines)
  local max_line_width = math.max(unpack(line_widths))

  local config = vim.api.nvim_win_get_config(explorer_win_id)
  config.relative = 'win'
  config.row = 0
  config.col = 0
  config.width = max_line_width
  config.height = #lines
  config.title = " 'mini.files' help "
  config.zindex = config.zindex + 1
  local default_border = (vim.fn.exists('+winborder') == 1 and vim.o.winborder ~= '') and vim.o.winborder or 'single'
  config.border = config.border or default_border
  config.style = 'minimal'

  local win_id = vim.api.nvim_open_win(buf_id, false, config)
  H.window_update_highlight(win_id, 'NormalFloat', 'MiniFilesNormal')
  H.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitle')
  H.window_update_highlight(win_id, 'CursorLine', 'MiniFilesCursorLine')
  vim.wo[win_id].cursorline = true
  local culopt = vim.wo[win_id].cursorlineopt
  if culopt:find('line') == nil then vim.wo[win_id].cursorlineopt = culopt .. ',line' end

  vim.api.nvim_set_current_win(win_id)
  return win_id
end

H.compute_visible_depth_range = function(explorer, opts)
  local width_focus, width_nofocus = opts.windows.width_focus + 2, opts.windows.width_nofocus + 2

  local has_preview = explorer.opts.windows.preview and explorer.depth_focus < #explorer.branch
  local width_preview = has_preview and (opts.windows.width_preview + 2) or width_nofocus

  local max_number = 1
  if (width_focus + width_preview) <= vim.o.columns then max_number = max_number + 1 end
  if (width_focus + width_preview + width_nofocus) <= vim.o.columns then
    max_number = max_number + math.floor((vim.o.columns - width_focus - width_preview) / width_nofocus)
  end

  max_number = math.min(math.max(max_number, 1), opts.windows.max_number)

  local branch_depth, depth_focus = #explorer.branch, explorer.depth_focus
  local n_panes = math.min(branch_depth, max_number)

  local to = math.min(branch_depth, math.floor(depth_focus + 0.5 * n_panes))
  local from = math.max(1, to - n_panes + 1)
  to = from + math.min(n_panes, branch_depth) - 1

  return { from = from, to = to }
end

H.view_ensure_proper = function(view, path, opts, is_focused, is_preview)
  local needs_recreate, needs_reprocess = not H.is_valid_buf(view.buf_id), not view.was_focused and is_focused

  -- Force update for image files in preview mode to ensure image preview is triggered
  local needs_image_update = is_preview and H.is_image_file(path)

  if needs_recreate then
    H.buffer_delete(view.buf_id)
    view.buf_id = H.buffer_create(path, opts.mappings)
  end
  if needs_recreate or needs_reprocess or needs_image_update then
    local cache_undolevels = vim.bo[view.buf_id].undolevels
    vim.bo[view.buf_id].undolevels = -1
    H.buffer_update(view.buf_id, path, opts, is_preview)
    vim.bo[view.buf_id].undolevels = cache_undolevels
  else
  end
  view.was_focused = view.was_focused or is_focused

  view.cursor = view.cursor or { 1, 0 }
  if type(view.cursor) == 'string' then view = H.view_decode_cursor(view) end

  return view
end

H.view_encode_cursor = function(view)
  local buf_id, cursor = view.buf_id, view.cursor
  if not H.is_valid_buf(buf_id) or type(cursor) ~= 'table' then return view end

  local l = H.get_bufline(buf_id, cursor[1])
  view.cursor = H.match_line_entry_name(l)
  return view
end

H.view_decode_cursor = function(view)
  local buf_id, cursor = view.buf_id, view.cursor
  if not H.is_valid_buf(buf_id) or type(cursor) ~= 'string' then return view end

  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  for i, l in ipairs(lines) do
    if cursor == H.match_line_entry_name(l) then view.cursor = { i, 0 } end
  end

  if type(view.cursor) ~= 'table' then view.cursor = { 1, 0 } end

  return view
end

H.view_invalidate_buffer = function(view)
  H.buffer_delete(view.buf_id)
  view.buf_id = nil
  return view
end

H.view_track_cursor = vim.schedule_wrap(function(data)
  local buf_id = data.buf
  local buf_data = H.opened_buffers[buf_id]
  if buf_data == nil then return end

  local win_id = buf_data.win_id
  if not H.is_valid_win(win_id) then return end

  local cur_cursor = H.window_tweak_cursor(win_id, buf_id)

  local tabpage_id = vim.api.nvim_win_get_tabpage(win_id)
  local explorer = H.explorer_get(tabpage_id)
  if explorer == nil then return end

  local buf_depth = H.explorer_get_path_depth(explorer, buf_data.path)
  if buf_depth == nil then return end

  local view = explorer.views[buf_data.path]
  if view ~= nil then
    view.cursor = cur_cursor
    explorer.views[buf_data.path] = view
  end

  explorer = H.explorer_sync_cursor_and_branch(explorer, buf_depth)

  H.explorer_refresh(explorer)
end)

H.view_track_text_change = function(data)
  local buf_id = data.buf
  local new_n_modified = H.opened_buffers[buf_id].n_modified + 1
  H.opened_buffers[buf_id].n_modified = new_n_modified
  local win_id = H.opened_buffers[buf_id].win_id
  if new_n_modified > 0 and H.is_valid_win(win_id) then H.window_update_border_hl(win_id) end

  if not H.is_valid_win(win_id) then return end

  local cur_height = vim.api.nvim_win_get_height(win_id)
  local n_lines = vim.api.nvim_buf_line_count(buf_id)
  local new_height = math.min(n_lines, H.window_get_max_height())
  vim.api.nvim_win_set_height(win_id, new_height)

  if cur_height ~= new_height then
    H.trigger_event('MiniFilesWindowUpdate', { buf_id = buf_id, win_id = win_id })
    new_height = vim.api.nvim_win_get_height(win_id)
  end

  local last_visible_line = vim.fn.line('w0', win_id) + new_height - 1
  local out_of_buf_lines = last_visible_line - n_lines
  if out_of_buf_lines > 0 then
    local cursor = vim.api.nvim_win_get_cursor(win_id)
    vim.cmd('normal! ' .. out_of_buf_lines .. '\25')
    vim.api.nvim_win_set_cursor(win_id, cursor)
  end
end

H.buffer_create = function(path, mappings)
  local buf_id = vim.api.nvim_create_buf(false, true)
  H.set_buf_name(buf_id, path)

  H.opened_buffers[buf_id] = { path = path }

  vim.bo[buf_id].filetype = 'minifiles'

  if H.fs_is_imaginary_path(path) then return buf_id end

  H.buffer_make_mappings(buf_id, mappings)

  local augroup = vim.api.nvim_create_augroup('MiniFiles', { clear = false })
  local au = function(events, desc, callback)
    vim.api.nvim_create_autocmd(events, { group = augroup, buffer = buf_id, desc = desc, callback = callback })
  end

  au({ 'CursorMoved', 'CursorMovedI', 'TextChangedP' }, 'Tweak cursor position', H.view_track_cursor)
  au({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, 'Track buffer modification', H.view_track_text_change)

  vim.b[buf_id].minicursorword_disable = true

  H.trigger_event('MiniFilesBufferCreate', { buf_id = buf_id })

  return buf_id
end

H.buffer_make_mappings = function(buf_id, mappings)
  local go_in_with_count = function()
    for _ = 1, vim.v.count1 do
      MiniFiles.go_in()
    end
  end

  local go_in_plus = function()
    for _ = 1, vim.v.count1 do
      MiniFiles.go_in({ close_on_file = true })
    end
  end

  local go_out_with_count = function()
    for _ = 1, vim.v.count1 do
      MiniFiles.go_out()
    end
  end

  local go_out_plus = function()
    go_out_with_count()
    MiniFiles.trim_right()
  end

  local go_in_visual = function()
    if vim.fn.mode() ~= 'V' then return mappings.go_in end

    local line_1, line_2 = vim.fn.line('v'), vim.fn.line('.')
    local from_line, to_line = math.min(line_1, line_2), math.max(line_1, line_2)
    vim.schedule(function()
      local explorer = H.explorer_get()
      explorer = H.explorer_go_in_range(explorer, buf_id, from_line, to_line)
      H.explorer_refresh(explorer)
    end)

    return [[<C-\><C-n>]]
  end

  local mark_goto = function()
    local id = H.getcharstr()
    if id == nil then return end
    local data = MiniFiles.get_explorer_state().bookmarks[id]
    if data == nil then return H.notify('No bookmark with id ' .. vim.inspect(id), 'WARN') end

    local path = data.path
    if vim.is_callable(path) then path = path() end
    local is_valid_path = type(path) == 'string' and H.fs_get_type(vim.fn.expand(path)) == 'directory'
    if not is_valid_path then return H.notify('Bookmark path should be a valid path to directory', 'WARN') end

    local state = MiniFiles.get_explorer_state()
    MiniFiles.set_bookmark("'", state.branch[state.depth_focus], { desc = 'Before latest jump' })
    MiniFiles.set_branch({ path })
  end

  local mark_set = function()
    local id = H.getcharstr()
    if id == nil then return end
    local state = MiniFiles.get_explorer_state()
    MiniFiles.set_bookmark(id, state.branch[state.depth_focus])
    H.notify('Bookmark ' .. vim.inspect(id) .. ' is set', 'INFO')
  end

  local buf_map = function(mode, lhs, rhs, desc)
    H.map(mode, lhs, rhs, { buffer = buf_id, desc = desc, nowait = true })
  end

  buf_map('n', mappings.close,       MiniFiles.close,       'Close')
  buf_map('n', mappings.go_in,       go_in_with_count,      'Go in entry')
  buf_map('n', mappings.go_in_plus,  go_in_plus,            'Go in entry plus')
  buf_map('n', mappings.go_out,      go_out_with_count,     'Go out of directory')
  buf_map('n', mappings.go_out_plus, go_out_plus,           'Go out of directory plus')
  buf_map('n', mappings.mark_goto,   mark_goto,             'Go to bookmark')
  buf_map('n', mappings.mark_set,    mark_set,              'Set bookmark')
  buf_map('n', mappings.reset,       MiniFiles.reset,       'Reset')
  buf_map('n', mappings.reveal_cwd,  MiniFiles.reveal_cwd,  'Reveal cwd')
  buf_map('n', mappings.show_help,   MiniFiles.show_help,   'Show Help')
  buf_map('n', mappings.synchronize, MiniFiles.synchronize, 'Synchronize')
  buf_map('n', mappings.trim_left,   MiniFiles.trim_left,   'Trim branch left')
  buf_map('n', mappings.trim_right,  MiniFiles.trim_right,  'Trim branch right')
  buf_map('n', mappings.copy_relative_path, MiniFiles.copy_relative_path, 'Copy relative path')
  buf_map('n', mappings.copy_absolute_path, MiniFiles.copy_absolute_path, 'Copy absolute path')
  buf_map('n', mappings.open_with_default, MiniFiles.open_with_default, 'Open with default app')
  buf_map('n', mappings.open_in_explorer, MiniFiles.open_in_explorer, 'Open in file explorer')

  H.map('x', mappings.go_in, go_in_visual, { buffer = buf_id, desc = 'Go in selected entries', expr = true })
end

H.buffer_update = function(buf_id, path, opts, is_preview)
  if not H.is_valid_buf(buf_id) then
    return
  end

  local fs_type = H.fs_get_type(path)
  if fs_type == 'directory' then H.buffer_update_directory(buf_id, path, opts, is_preview) end
  if fs_type == 'file' then H.buffer_update_file(buf_id, path, opts, is_preview) end
  if fs_type == nil then H.set_buflines(buf_id, { '-No-fs-entry-' .. string.rep('-', opts.windows.width_preview) }) end

  local data = { buf_id = buf_id, win_id = H.opened_buffers[buf_id].win_id }
  if fs_type ~= nil then H.trigger_event('MiniFilesBufferUpdate', data) end

  H.opened_buffers[buf_id].n_modified = -1
end

H.buffer_update_directory = function(buf_id, path, opts, is_preview)
  local children_path_ids = H.opened_buffers[buf_id].children_path_ids
  local fs_entries = children_path_ids == nil and H.fs_read_dir(path, opts.content)
    or vim.tbl_map(H.get_fs_entry_from_path_index, children_path_ids)
  H.opened_buffers[buf_id].children_path_ids = children_path_ids
    or vim.tbl_map(function(x) return x.path_id end, fs_entries)

  local path_width = math.floor(math.log10(#H.path_index)) + 1
  local line_format = '/%0' .. path_width .. 'd/%s/%s'

  local lines, icon_hl, name_hl = {}, {}, {}
  local prefix_fun, hl_fun = opts.content.prefix, opts.content.highlight
  local n_computed_prefixes = is_preview and vim.o.lines or math.huge
  for i, entry in ipairs(fs_entries) do
    local prefix, hl, name
    if i <= n_computed_prefixes then
      prefix, hl = prefix_fun(entry)
    end
    prefix, hl, name = prefix or '', hl or '', H.sanitize_string(entry.name)
    table.insert(lines, string.format(line_format, H.path_index[entry.path], prefix, name))
    table.insert(icon_hl, hl)
    table.insert(name_hl, hl_fun(entry) or 'MiniFilesNormal')
  end

  H.set_buflines(buf_id, lines)

  local ns_id = H.ns_id.highlight
  vim.api.nvim_buf_clear_namespace(buf_id, ns_id, 0, -1)

  local set_hl = function(line, col, hl_opts) H.set_extmark(buf_id, ns_id, line, col, hl_opts) end

  for i, l in ipairs(lines) do
    local icon_start, name_start = l:match('^/%d+/().-()/')

    local icon_opts = { hl_group = icon_hl[i], end_col = name_start - 1, right_gravity = false }
    set_hl(i - 1, icon_start - 1, icon_opts)

    local name_opts = { hl_group = name_hl[i], end_row = i, end_col = 0, right_gravity = false }
    set_hl(i - 1, name_start - 1, name_opts)
  end
end

H.buffer_update_file = function(buf_id, path, opts, is_preview)
  local fd, width_preview = vim.loop.fs_open(path, 'r', 1), opts.windows.width_preview
  if fd == nil then return H.set_buflines(buf_id, { '-No-access' .. string.rep('-', width_preview) }) end

  -- Check if this is an image file and we're in preview mode
  if is_preview and H.is_image_file(path) then
    vim.loop.fs_close(fd)
    -- For image files, set placeholder content and defer actual rendering
    -- The image will be rendered after the window is properly set up
    local empty_lines = {}
    for i = 1, 15 do
      table.insert(empty_lines, '')
    end
    -- Use direct API call to avoid vim.inspect issues with newlines
    vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, empty_lines)

    -- Mark this buffer for image preview
    if not H.opened_buffers[buf_id] then
      H.opened_buffers[buf_id] = { path = path }
    end
    H.opened_buffers[buf_id].pending_image_preview = path
    return
  end

  local is_text = vim.loop.fs_read(fd, 1024):find('\0') == nil
  vim.loop.fs_close(fd)
  if not is_text then return H.set_buflines(buf_id, { '-Non-text-file' .. string.rep('-', width_preview) }) end

  local has_lines, read_res = pcall(vim.fn.readfile, path, '', vim.o.lines)
  local lines = has_lines and vim.split(table.concat(read_res, '\n'), '\n') or {}

  H.set_buflines(buf_id, lines)

  if H.buffer_should_highlight(buf_id) then
    local ft = vim.filetype.match({ buf = buf_id, filename = path })
    local has_lang, lang = pcall(vim.treesitter.language.get_lang, ft)
    lang = has_lang and lang or ft
    local has_parser, parser = pcall(vim.treesitter.get_parser, buf_id, lang, { error = false })
    has_parser = has_parser and parser ~= nil
    if has_parser then has_parser = pcall(vim.treesitter.start, buf_id, lang) end
    if not has_parser then vim.bo[buf_id].syntax = ft end
  end
end

H.buffer_delete = function(buf_id)
  if buf_id == nil then return end
  pcall(vim.api.nvim_buf_delete, buf_id, { force = true })
  H.opened_buffers[buf_id] = nil
end

H.buffer_compute_fs_diff = function(buf_id)
  if not H.is_modified_buffer(buf_id) then return {} end

  local path = H.opened_buffers[buf_id].path
  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  local res, present_path_ids = {}, {}

  for _, l in ipairs(lines) do
    local path_id = H.match_line_path_id(l)
    local path_from = H.path_index[path_id]

    local name_to = path_id ~= nil and l:sub(H.match_line_offset(l)) or l

    local path_to = H.fs_child_path(path, name_to) .. (vim.endswith(name_to, '/') and '/' or '')

    if l:find('^%s*$') == nil and H.sanitize_string(path_from) ~= H.sanitize_string(path_to) then
      table.insert(res, { from = path_from, to = path_to, dir = path })
    elseif path_id ~= nil then
      present_path_ids[path_id] = true
    end
  end

  local ref_path_ids = H.opened_buffers[buf_id].children_path_ids
  for _, ref_id in ipairs(ref_path_ids) do
    if not present_path_ids[ref_id] then table.insert(res, { from = H.path_index[ref_id], to = nil, dir = path }) end
  end

  return res
end

H.buffer_should_highlight = function(buf_id)
  local buf_size = vim.api.nvim_buf_call(buf_id, function() return vim.fn.line2byte(vim.fn.line('$') + 1) end)
  return buf_size <= 1000000 and buf_size <= 1000 * vim.api.nvim_buf_line_count(buf_id)
end

H.is_opened_buffer = function(buf_id) return H.opened_buffers[buf_id] ~= nil end

H.is_modified_buffer = function(buf_id)
  local data = H.opened_buffers[buf_id]
  return data ~= nil and data.n_modified > 0
end

H.match_line_entry_name = function(l)
  if l == nil then return nil end
  local offset = H.match_line_offset(l)
  local res = l:sub(offset):gsub('/.*$', '')
  return res
end

H.match_line_offset = function(l)
  if l == nil then return nil end
  return l:match('^/.-/.-/()') or 1
end

H.match_line_path_id = function(l)
  if l == nil then return nil end

  local id_str = l:match('^/(%d+)')
  local ok, res = pcall(tonumber, id_str)
  if not ok then return nil end
  return res
end

H.window_open = function(buf_id, config)
  config.anchor = 'NW'
  config.border = (vim.fn.exists('+winborder') == 1 and vim.o.winborder ~= '') and vim.o.winborder or 'single'
  config.focusable = true
  config.relative = 'editor'
  config.style = 'minimal'
  config.zindex = 99

  config.row = 1

  local win_id = vim.api.nvim_open_win(buf_id, false, config)

  vim.wo[win_id].concealcursor = 'nvic'
  vim.wo[win_id].foldenable = false
  vim.wo[win_id].foldmethod = 'manual'
  vim.wo[win_id].wrap = false

  vim.api.nvim_win_call(win_id, function()
    vim.fn.matchadd('Conceal', [[^/\d\+/]])
    vim.fn.matchadd('Conceal', [[^/\d\+/[^/]*\zs/\ze]])
  end)

  H.window_update_highlight(win_id, 'NormalFloat', 'MiniFilesNormal')
  H.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitle')
  H.window_update_highlight(win_id, 'CursorLine', 'MiniFilesCursorLine')

  H.trigger_event('MiniFilesWindowOpen', { buf_id = buf_id, win_id = win_id })

  return win_id
end

H.window_update = function(win_id, config)
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local max_height = H.window_get_max_height()

  config.row = has_tabline and 1 or 0
  config.height = config.height ~= nil and math.min(config.height, max_height) or nil
  config.width = config.width ~= nil and math.min(config.width, vim.o.columns) or nil

  if type(config.title) == 'string' then config.title = H.fit_to_width(config.title, config.width) end

  local win_config = vim.api.nvim_win_get_config(win_id)
  config.border, config.title_pos = win_config.border, win_config.title_pos

  config.relative = 'editor'
  vim.api.nvim_win_set_config(win_id, config)

  H.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitle')

  vim.wo[win_id].conceallevel = 3
end

H.window_update_highlight = function(win_id, new_from, new_to)
  local new_entry = new_from .. ':' .. new_to
  local replace_pattern = string.format('(%s:[^,]*)', vim.pesc(new_from))
  local new_winhighlight, n_replace = vim.wo[win_id].winhighlight:gsub(replace_pattern, new_entry)
  if n_replace == 0 then new_winhighlight = new_winhighlight .. ',' .. new_entry end

  vim.wo[win_id].winhighlight = new_winhighlight
end

H.window_focus = function(win_id)
  vim.api.nvim_set_current_win(win_id)
  H.window_update_highlight(win_id, 'FloatTitle', 'MiniFilesTitleFocused')
end

H.window_close = function(win_id)
  if win_id == nil then return end
  local has_buffer, buf_id = pcall(vim.api.nvim_win_get_buf, win_id)
  if has_buffer then H.opened_buffers[buf_id].win_id = nil end
  pcall(vim.api.nvim_win_close, win_id, true)
end

H.window_set_view = function(win_id, view)
  local buf_id, buf_data = view.buf_id, H.opened_buffers[view.buf_id]
  H.win_set_buf(win_id, buf_id)
  buf_data.win_id = win_id

  pcall(H.window_set_cursor, win_id, view.cursor)
  vim.wo[win_id].cursorline = H.fs_get_type(buf_data.path) == 'directory'
  local culopt = vim.wo[win_id].cursorlineopt
  if culopt:find('line') == nil then vim.wo[win_id].cursorlineopt = culopt .. ',line' end

  H.window_update_border_hl(win_id)

  -- Check for pending image preview and render it now that window is ready
  if buf_data.pending_image_preview then
    local image_path = buf_data.pending_image_preview
    buf_data.pending_image_preview = nil
    vim.schedule(function()
      if H.is_valid_win(win_id) and H.is_valid_buf(buf_id) then
        -- Check if this is still the current buffer data for this path
        -- Skip if buffer has been reassigned to a different path
        if H.opened_buffers[buf_id] and H.opened_buffers[buf_id].path == image_path then
          pcall(H.show_image_preview, buf_id, image_path, win_id)
        else
        end
      else
      end
    end)
  end
end

H.window_set_cursor = function(win_id, cursor)
  if type(cursor) ~= 'table' then return end

  vim.api.nvim_win_set_cursor(win_id, cursor)

  H.window_tweak_cursor(win_id, vim.api.nvim_win_get_buf(win_id))
end

H.window_tweak_cursor = function(win_id, buf_id)
  local cursor = vim.api.nvim_win_get_cursor(win_id)
  local l = H.get_bufline(buf_id, cursor[1])

  local cur_offset = H.match_line_offset(l)
  if cursor[2] < (cur_offset - 1) then
    cursor[2] = cur_offset - 1
    vim.api.nvim_win_set_cursor(win_id, cursor)
    vim.cmd('normal! 1000zh')
  end

  return cursor
end

H.window_update_border_hl = function(win_id)
  if not H.is_valid_win(win_id) then return end
  local buf_id = vim.api.nvim_win_get_buf(win_id)

  local border_hl = H.is_modified_buffer(buf_id) and 'MiniFilesBorderModified' or 'MiniFilesBorder'
  H.window_update_highlight(win_id, 'FloatBorder', border_hl)
end

H.window_get_max_height = function()
  local has_tabline = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
  local has_statusline = vim.o.laststatus > 0
  return vim.o.lines - vim.o.cmdheight - (has_tabline and 1 or 0) - (has_statusline and 1 or 0) - 2
end

H.fs_read_dir = function(path, content_opts)
  local fs = vim.loop.fs_scandir(path)
  local res = {}
  if not fs then return res end

  local name, fs_type = vim.loop.fs_scandir_next(fs)
  while name do
    if not (fs_type == 'file' or fs_type == 'directory') then fs_type = H.fs_get_type(H.fs_child_path(path, name)) end
    table.insert(res, { fs_type = fs_type, name = name, path = H.fs_child_path(path, name) })
    name, fs_type = vim.loop.fs_scandir_next(fs)
  end

  res = content_opts.sort(vim.tbl_filter(content_opts.filter, res))

  for _, entry in ipairs(res) do
    entry.path_id = H.add_path_to_index(entry.path)
  end

  return res
end

H.add_path_to_index = function(path)
  local cur_id = H.path_index[path]
  if cur_id ~= nil then return cur_id end

  local new_id = #H.path_index + 1
  H.path_index[new_id] = path
  H.path_index[path] = new_id

  return new_id
end

H.get_fs_entry_from_path_index = function(path_id)
  local path = H.path_index[path_id]
  if path == nil then return nil end
  return { fs_type = H.fs_get_type(path), name = H.fs_get_basename(path), path = path }
end


H.replace_path_in_index = function(from, to)
  local from_id, to_id = H.path_index[from], H.path_index[to]
  H.path_index[from_id], H.path_index[to] = to, from_id
  if to_id then H.path_index[to_id] = nil end
  H.path_index[from] = nil
end

H.compare_fs_entries = function(a, b)
  if a.is_dir and not b.is_dir then return true end
  if not a.is_dir and b.is_dir then return false end

  return a.lower_name < b.lower_name
end

H.fs_normalize_path = function(path) return (path:gsub('/+', '/'):gsub('(.)/$', '%1')) end
if H.is_windows then
  H.fs_normalize_path = function(path) return (path:gsub('\\', '/'):gsub('([^/])/+', '%1/'):gsub('(.)[\\/]$', '%1')) end
end

H.fs_is_imaginary_path = function(path) return path:sub(-1) == '\000' end

H.fs_is_present_path = function(path) return vim.loop.fs_stat(path) ~= nil and not H.fs_is_imaginary_path(path) end

H.fs_child_path = function(dir, name) return H.fs_normalize_path(string.format('%s/%s', dir, name)) end

H.fs_full_path = function(path) return H.fs_normalize_path(vim.fn.fnamemodify(path, ':p')) end

H.fs_shorten_path = function(path)
  path = H.fs_normalize_path(path)
  local home_dir = H.fs_normalize_path(vim.loop.os_homedir() or '~')
  return (path:gsub('^' .. vim.pesc(home_dir), '~'))
end

H.fs_get_basename = function(path) return H.fs_normalize_path(path):match('[^/]+$') end

H.fs_get_parent = function(path)
  path = H.fs_full_path(path)

  local is_top = H.fs_is_windows_top(path) or path == '/'
  if is_top then return nil end

  local res = H.fs_normalize_path(path:match('^.*/'))
  local suffix = H.fs_is_windows_top(res) and '/' or ''
  return res .. suffix
end

H.fs_is_windows_top = function(path) return H.is_windows and path:find('^%w:[\\/]?$') ~= nil end

H.fs_get_type = function(path)
  if not (not H.fs_is_imaginary_path(path) and H.fs_is_present_path(path)) then return nil end
  return vim.fn.isdirectory(path) == 1 and 'directory' or 'file'
end

H.fs_actions_to_lines = function(fs_actions)
  local short = H.fs_shorten_path
  local dir
  local rel = function(p) return vim.startswith(p, dir .. '/') and p:sub(#dir + 2):gsub('/$', '') or short(p) end

  local actions_per_dir = {}
  for _, diff in ipairs(fs_actions) do
    dir = diff.action == 'create' and diff.dir or H.fs_get_parent(diff.from)

    local action, l = diff.action, nil
    local to_type = (diff.to or ''):sub(-1) == '/' and 'directory' or 'file'
    local del_type = diff.to == nil and 'permanently' or 'to trash'
    if action == 'create' then l = string.format("CREATE │ %s (%s)",  rel(diff.to), to_type) end
    if action == 'delete' then l = string.format("DELETE │ %s (%s)",  rel(diff.from), del_type) end
    if action == 'copy'   then l = string.format("COPY   │ %s => %s", rel(diff.from), rel(diff.to)) end
    if action == 'move'   then l = string.format("MOVE   │ %s => %s", rel(diff.from), rel(diff.to)) end
    if action == 'rename' then l = string.format("RENAME │ %s => %s", rel(diff.from), rel(diff.to)) end

    local dir_actions = actions_per_dir[dir] or {}
    table.insert(dir_actions, '  ' .. H.sanitize_string(l))
    actions_per_dir[dir] = dir_actions
  end

  local res = { 'CONFIRM FILE SYSTEM ACTIONS', '' }
  for path, dir_actions in pairs(actions_per_dir) do
    table.insert(res, short(path))
    vim.list_extend(res, dir_actions)
    table.insert(res, '')
  end

  return res
end

H.fs_actions_apply = function(fs_actions)
  for i = 1, #fs_actions do
    local diff, action = fs_actions[i], fs_actions[i].action
    local ok, success = pcall(H.fs_do[action], diff.from, diff.to)
    if ok and success then
      local to = action == 'create' and diff.to:gsub('/$', '') or diff.to
      local data = { action = action, from = diff.from, to = to }
      local action_titlecase = action:sub(1, 1):upper() .. action:sub(2)
      H.trigger_event('MiniFilesAction' .. action_titlecase, data)

      local has_moved = to ~= nil and not (action == 'copy' or action == 'create')
      if has_moved then H.adjust_after_move(diff.from, to, fs_actions, i + 1) end
    end
  end
end

H.fs_do = {}

H.fs_do.create = function(_, path)
  if H.fs_is_present_path(path) then return H.warn_existing_path(path, 'create') end

  vim.fn.mkdir(H.fs_get_parent(path), 'p')

  local fs_type = path:sub(-1) == '/' and 'directory' or 'file'
  if fs_type == 'directory' then return vim.fn.mkdir(path) == 1 end
  return vim.fn.writefile({}, path) == 0
end

H.fs_do.copy = function(from, to)
  if H.fs_is_present_path(to) then return H.warn_existing_path(from, 'copy') end

  local from_type = H.fs_get_type(from)
  if from_type == nil then return false end

  vim.fn.mkdir(H.fs_get_parent(to), 'p')

  if from_type == 'file' then return vim.loop.fs_copyfile(from, to) end

  local fs_entries = H.fs_read_dir(from, { filter = function() return true end, sort = function(x) return x end })
  vim.fn.mkdir(to)

  local success = true
  for _, entry in ipairs(fs_entries) do
    success = success and H.fs_do.copy(entry.path, H.fs_child_path(to, entry.name))
  end

  return success
end

H.fs_do.delete = function(from, to)
  if to == nil then return vim.fn.delete(from, 'rf') == 0 end
  pcall(vim.fn.delete, to, 'rf')
  return H.fs_do.move(from, to, true)
end

H.fs_do.move = function(from, to, skip_buf_rename)
  if H.fs_is_present_path(to) then return H.warn_existing_path(from, 'move or rename') end

  vim.fn.mkdir(H.fs_get_parent(to), 'p')
  local success, _, err_code = vim.loop.fs_rename(from, to)

  if err_code == 'EXDEV' then
    success = H.fs_do.copy(from, to)
    if success then success = pcall(vim.fn.delete, from, 'rf') end
    if not success then pcall(vim.fn.delete, to, 'rf') end
  end

  if not success then return success end

  H.replace_path_in_index(from, to)

  if not skip_buf_rename then
    for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
      H.rename_loaded_buffer(buf_id, from, to)
    end
  end

  return success
end

H.fs_do.rename = H.fs_do.move

H.rename_loaded_buffer = function(buf_id, from, to)
  if not (vim.api.nvim_buf_is_loaded(buf_id) and vim.bo[buf_id].buftype == '') then return end
  local cur_name = H.fs_normalize_path(vim.api.nvim_buf_get_name(buf_id))

  local new_name = cur_name:gsub('^' .. vim.pesc(from), to)
  if cur_name == new_name then return end

  vim.api.nvim_buf_set_name(buf_id, vim.fn.fnamemodify(new_name, ':.'))

  vim.api.nvim_buf_call(buf_id, function() vim.cmd('silent! write! | edit') end)
end

H.warn_existing_path = function(path, action)
  H.notify(string.format('Can not %s %s. Target path already exists.', action, path), 'WARN')
  return false
end

H.adjust_after_move = function(from, to, fs_actions, start_ind)
  local from_dir_pattern, to_dir = '^' .. vim.pesc(from .. '/'), to .. '/'
  for i = start_ind, #fs_actions do
    local diff = fs_actions[i]
    if diff.from ~= nil then diff.from = diff.from == from and to or diff.from:gsub(from_dir_pattern, to_dir) end
    if diff.to ~= nil then diff.to = diff.to:gsub(from_dir_pattern, to_dir) end
  end
end

H.validate_opened_buffer = function(x)
  if x == nil or x == 0 then x = vim.api.nvim_get_current_buf() end
  if not H.is_opened_buffer(x) then H.error('`buf_id` should be an identifier of an opened directory buffer.') end
  return x
end

H.validate_line = function(buf_id, x)
  x = x or vim.fn.line('.')
  if not (type(x) == 'number' and 1 <= x and x <= vim.api.nvim_buf_line_count(buf_id)) then
    H.error('`line` should be a valid line number in buffer ' .. buf_id .. '.')
  end
  return x
end

H.validate_branch = function(x)
  if not (H.islist(x) and x[1] ~= nil) then H.error('`branch` should be array with at least one element') end
  local res = {}
  for i, p in ipairs(x) do
    if type(p) ~= 'string' then H.error('`branch` contains not string: ' .. vim.inspect(p)) end
    p = H.fs_full_path(p)
    if not H.fs_is_present_path(p) then H.error('`branch` contains not present path: ' .. vim.inspect(p)) end
    res[i] = p
  end
  for i = 2, #res do
    local parent, child = res[i - 1], res[i]
    if (parent .. '/' .. child:match('[^/]+$')) ~= res[i] then
      H.error('`branch` contains not a parent-child pair: ' .. vim.inspect(parent) .. ' and ' .. vim.inspect(child))
    end
  end
  if #res == 1 and H.fs_get_type(res[1]) == 'file' then H.error('`branch` should contain at least one directory') end
  return res
end

H.error = function(msg) error('(mini.files) ' .. msg, 0) end

H.check_type = function(name, val, ref, allow_nil)
  if type(val) == ref or (ref == 'callable' and vim.is_callable(val)) or (allow_nil and val == nil) then return end
  H.error(string.format('`%s` should be %s, not %s', name, ref, type(val)))
end

H.set_buf_name = function(buf_id, name) vim.api.nvim_buf_set_name(buf_id, 'minifiles://' .. buf_id .. '/' .. name) end

H.notify = function(msg, level_name) vim.notify('(mini.files) ' .. msg, vim.log.levels[level_name]) end

H.map = function(mode, lhs, rhs, opts)
  if lhs == '' then return end
  opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
  vim.keymap.set(mode, lhs, rhs, opts)
end

H.edit = function(path, win_id)
  if type(path) ~= 'string' then return end
  local b = vim.api.nvim_win_get_buf(win_id or 0)
  local try_mimic_buf_reuse = (vim.fn.bufname(b) == '' and vim.bo[b].buftype ~= 'quickfix' and not vim.bo[b].modified)
    and (#vim.fn.win_findbuf(b) == 1 and vim.deep_equal(vim.fn.getbufline(b, 1, '$'), { '' }))
  local buf_id = vim.fn.bufadd(vim.fn.fnamemodify(path, ':.'))
  pcall(vim.api.nvim_win_set_buf, win_id or 0, buf_id)
  vim.bo[buf_id].buflisted = true
  if try_mimic_buf_reuse then pcall(vim.api.nvim_buf_delete, b, { unload = false }) end
  return buf_id
end

H.trigger_event = function(event_name, data) vim.api.nvim_exec_autocmds('User', { pattern = event_name, data = data }) end

H.is_valid_buf = function(buf_id) return type(buf_id) == 'number' and vim.api.nvim_buf_is_valid(buf_id) end

H.is_valid_win = function(win_id) return type(win_id) == 'number' and vim.api.nvim_win_is_valid(win_id) end

H.fit_to_width = function(text, width)
  local t_width = vim.fn.strchars(text)
  return t_width <= width and text or ('…' .. vim.fn.strcharpart(text, t_width - width + 1, width - 1))
end

H.get_bufline = function(buf_id, line) return vim.api.nvim_buf_get_lines(buf_id, line - 1, line, false)[1] end

H.set_buflines = function(buf_id, lines)
  local cmd =
    string.format('lockmarks lua vim.api.nvim_buf_set_lines(%d, 0, -1, false, %s)', buf_id, vim.inspect(lines))
  vim.cmd(cmd)
end

H.set_extmark = function(...) pcall(vim.api.nvim_buf_set_extmark, ...) end

H.win_set_buf = function(win_id, buf_id)
  vim.wo[win_id].winfixbuf = false
  vim.api.nvim_win_set_buf(win_id, buf_id)
  vim.wo[win_id].winfixbuf = true
end
if vim.fn.has('nvim-0.10') == 0 then H.win_set_buf = vim.api.nvim_win_set_buf end

H.get_first_valid_normal_window = function()
  for _, win_id in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win_id).relative == '' then return win_id end
  end
end

H.getcharstr = function()
  local ok, char = pcall(vim.fn.getcharstr)
  if not ok or char == '\27' or char == '' then return end
  return char
end

H.sanitize_string = function(x) return ((x or ''):gsub('\n', '<NL>'):gsub('%z', '')) end

H.islist = vim.fn.has('nvim-0.10') == 1 and vim.islist or vim.tbl_islist

-- Image preview functionality
H.image_extensions = { 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'tiff', 'tif', 'webp', 'svg', 'ico' }
H.current_image_preview = nil
H.image_cleanup_scheduled = {}

H.is_image_file = function(path)
  if not path then return false end
  local ext = path:match('%.([^.]+)$')
  if not ext then return false end
  ext = ext:lower()
  for _, img_ext in ipairs(H.image_extensions) do
    if ext == img_ext then return true end
  end
  return false
end

H.cleanup_temp_image_file = function(temp_file)
  if not temp_file then return end
  vim.defer_fn(function()
    pcall(function()
      vim.fn.delete(temp_file)
      local temp_dir = vim.fn.fnamemodify(temp_file, ':h')
      vim.fn.delete(temp_dir, 'd')
    end)
  end, 2000) -- 2000ms delay to ensure image.nvim has fully cleared references
end

H.clear_image_preview = function()
  if H.current_image_preview then
    pcall(function()
      if H.current_image_preview.image then
        H.current_image_preview.image:clear()
      end
      -- Clean up temporary file
      if H.current_image_preview.temp_file then
        H.cleanup_temp_image_file(H.current_image_preview.temp_file)
      end
    end)
    H.current_image_preview = nil
  end

  -- Also clear any lingering images from image.nvim's internal registry
  -- to prevent errors when temp files are deleted
  pcall(function()
    local has_image, image = pcall(require, 'image')
    if has_image then
      -- Use global clear to remove all images from image.nvim
      pcall(function() image.clear() end)

      -- Also clear individual images as backup
      local all_images = image.get_images() or {}
      for _, img in ipairs(all_images) do
        pcall(function() img:clear() end)
      end
    end
  end)
end

H.create_temp_resized_image = function(path, target_width, target_height)
  local temp_dir = vim.fn.tempname()
  vim.fn.mkdir(temp_dir, 'p')
  local temp_file = temp_dir .. '/' .. vim.fn.fnamemodify(path, ':t:r') .. '_resized.' .. vim.fn.fnamemodify(path, ':e')

  -- For GIFs, extract only the first frame to avoid animation issues
  local is_gif = vim.fn.fnamemodify(path, ':e'):lower() == 'gif'
  local source_path = is_gif and (path .. '[0]') or path

  local cmd = string.format(
    'convert "%s" -resize %dx%d\\> "%s"',
    source_path, target_width, target_height, temp_file
  )

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, 'ImageMagick convert failed: ' .. result
  end

  return temp_file
end

H.show_image_preview = function(buf_id, path, win_id)

  -- Only clear if we're showing a different image path
  -- (Don't clear for same image, even if buffer ID is different)
  local current_path = H.current_image_preview and H.opened_buffers[H.current_image_preview.buffer] and H.opened_buffers[H.current_image_preview.buffer].path
  if H.current_image_preview and current_path ~= path then
    H.clear_image_preview()
  end

  -- Validate inputs
  if not H.is_valid_buf(buf_id) or not H.is_valid_win(win_id) then
    return
  end

  -- Check if image.nvim is available
  local has_image, image = pcall(require, 'image')
  if not has_image then
    pcall(H.set_buflines, buf_id, { '-Image preview requires image.nvim plugin-' })
    return
  end

  -- Set buffer content to exactly 15 lines for consistent height
  local empty_lines = {}
  for i = 1, 15 do
    table.insert(empty_lines, '')
  end
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, empty_lines)

  -- Set window height to exactly 15 lines
  if H.is_valid_win(win_id) then
    vim.api.nvim_win_set_height(win_id, 15)
  end

  -- Calculate dimensions for 15 lines height
  local cell_width = 10  -- approximate character width in pixels
  local cell_height = 20 -- approximate character height in pixels
  local target_height = 15 * cell_height
  local target_width = vim.api.nvim_win_get_width(win_id) * cell_width

  -- Create resized temporary image
  local temp_file, err = H.create_temp_resized_image(path, target_width, target_height)
  if not temp_file then
    pcall(H.set_buflines, buf_id, { '-Image resize failed: ' .. (err or 'unknown error') .. '-' })
    return
  end

  -- Verify temp file still exists before creating image
  if vim.fn.filereadable(temp_file) ~= 1 then
    pcall(H.set_buflines, buf_id, { '-Image file no longer available-' })
    return
  end

  -- Create and render image
  local ok_img, img = pcall(image.from_file, temp_file, {
    buffer = buf_id,
    window = win_id,
    x = 0,
    y = 0,
    width = target_width,
    height = target_height,
  })

  if ok_img and img then
    -- Double-check file still exists before rendering
    if vim.fn.filereadable(temp_file) == 1 then
      local ok_render = pcall(function() img:render() end)
      if ok_render then
        H.current_image_preview = {
          image = img,
          temp_file = temp_file,
          buffer = buf_id,
          window = win_id
        }
      else
        pcall(function() img:clear() end)
        pcall(H.set_buflines, buf_id, { '-Failed to render image-' })
        H.cleanup_temp_image_file(temp_file)
      end
    else
      pcall(function() img:clear() end)
      pcall(H.set_buflines, buf_id, { '-Image file was deleted during preview-' })
    end
  else
    pcall(H.set_buflines, buf_id, { '-Failed to create image preview-' })
    H.cleanup_temp_image_file(temp_file)
  end
end

return MiniFiles
