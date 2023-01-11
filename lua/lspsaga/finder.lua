local api, lsp, fn, uv = vim.api, vim.lsp, vim.fn, vim.loop
local config = require('lspsaga').config
local insert = table.insert

local Finder = {}

function Finder:init_data()
  self.methods = {
    'textDocument/definition',
    'textDocument/implementation',
    'textDocument/references',
  }
  self.titles = {
    [self.methods[1]] = '● Definition',
    [self.methods[2]] = '● Implements',
    [self.methods[3]] = '● References',
  }
  self.window = require('lspsaga.window')
  self.libs = require('lspsaga.libs')
end

function Finder:lsp_finder()
  self:init_data()
  self.client = self.libs.get_client_by_cap('implementationProvider')

  -- push a tag stack
  local pos = api.nvim_win_get_cursor(0)
  self.current_word = fn.expand('<cword>')
  local from = { api.nvim_get_current_buf(), pos[1], pos[2], 0 }
  local items = { { tagname = self.current_word, from = from } }
  fn.settagstack(api.nvim_get_current_win(), { items = items }, 't')

  self.request_result = {}
  local params = lsp.util.make_position_params()
  for i, method in pairs(self.methods) do
    if i == 2 and self.client then
      self:do_request(params, method)
    end

    if i ~= 2 then
      self:do_request(params, method)
    end
  end

  self:get_file_icon()
  -- make a spinner
  self:loading_bar()
end

function Finder:loading_bar()
  -- calculate our floating window size
  local win_height = math.ceil(vim.o.lines * 0.6)
  local win_width = math.ceil(vim.o.columns * 0.8)

  -- and its starting position
  local row = math.ceil((vim.o.lines - win_height) / 2 - 1)
  local col = math.ceil(vim.o.columns - win_width)

  local opts = {
    relative = 'editor',
    height = 2,
    width = 20,
    row = row,
    col = col,
  }

  local content_opts = {
    contents = {},
    highlight = {
      normal = 'FinderNormal',
      border = 'FinderBorder',
    },
    enter = false,
  }

  local spin_buf, spin_win = self.window.create_win_with_border(content_opts, opts)
  local spin_config = {
    spinner = {
      '█▁▁▁▁▁▁▁▁▁',
      '██▁▁▁▁▁▁▁▁',
      '███▁▁▁▁▁▁▁',
      '████▁▁▁▁▁▁',
      '█████▁▁▁▁▁',
      '██████▁▁▁▁',
      '███████▁▁▁',
      '████████▁▁ ',
      '█████████▁',
      '██████████',
    },
    interval = 15,
    timeout = config.request_timeout,
  }
  api.nvim_buf_set_option(spin_buf, 'modifiable', true)

  self.request_status = {}

  -- if server not support textDocument/implementation
  if not self.client then
    self.request_status[self.methods[2]] = true
    self.request_result[self.methods[2]] = {}
  end

  local spin_frame = 1
  local spin_timer = uv.new_timer()
  local start_request = uv.now()
  spin_timer:start(
    0,
    spin_config.interval,
    vim.schedule_wrap(function()
      spin_frame = spin_frame == 11 and 1 or spin_frame
      local msg = ' LOADING' .. string.rep('.', spin_frame > 3 and 3 or spin_frame)
      local spinner = ' ' .. spin_config.spinner[spin_frame]
      pcall(api.nvim_buf_set_lines, spin_buf, 0, -1, false, { msg, spinner })
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, 'FinderSpinnerTitle', 0, 0, -1)
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, 'FinderSpinner', 1, 0, -1)
      spin_frame = spin_frame + 1

      if uv.now() - start_request >= spin_config.timeout and not spin_timer:is_closing() then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then
          api.nvim_buf_delete(spin_buf, { force = true })
        end
        self.window.nvim_close_valid_window(spin_win)
        vim.notify('request timeout')
        return
      end

      if
        (
          self.request_status[self.methods[1]]
          and self.request_status[self.methods[2]]
          and self.request_status[self.methods[3]]
        ) and not spin_timer:is_closing()
      then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then
          api.nvim_buf_delete(spin_buf, { force = true })
        end
        self.window.nvim_close_valid_window(spin_win)
        self:render_finder()
      end
    end)
  )
end

function Finder:do_request(params, method)
  if method == self.methods[3] then
    params.context = { includeDeclaration = false }
  end
  lsp.buf_request_all(self.current_buf, method, params, function(results)
    local result = {}
    for _, res in pairs(results or {}) do
      if res.result and not (res.result.uri or res.result.targetUri) then
        self.libs.merge_table(result, res.result)
      elseif res.result and (res.result.uri or res.result.targetUri) then
        -- this work for some servers like exlixir
        table.insert(result, res.result)
      end
    end

    self.request_result[method] = result
    self.request_status[method] = true
  end)
end

function Finder:get_file_icon()
  local res = self.libs.icon_from_devicon(vim.bo.filetype)
  if #res == 0 then
    self.f_icon = ''
  else
    self.f_icon = res[1] .. ' '
    self.f_hl = res[2]
  end
end

function Finder:get_uri_scope(method, start_lnum, end_lnum)
  if method == self.methods[1] then
    self.def_scope = { start_lnum, end_lnum }
  end

  if method == self.methods[2] then
    self.imp_scope = { start_lnum, end_lnum }
  end

  if method == self.methods[3] then
    self.ref_scope = { start_lnum, end_lnum }
  end
end

function Finder:render_finder()
  self.root_dir = self.libs.get_lsp_root_dir()

  self.contents = {}
  self.short_link = {}
  self.buf_filetype = api.nvim_buf_get_option(0, 'filetype')

  local lnum, start_lnum = 0, 0

  local generate_contents = function(tbl, method)
    start_lnum = lnum
    for _, val in pairs(tbl) do
      insert(self.contents, val[1])
      lnum = lnum + 1

      if val[2] then
        self.short_link[lnum] = val[2]
      end
    end
    self:get_uri_scope(method, start_lnum, lnum - 1)
  end

  for i, method in pairs(self.methods) do
    local tbl = self:create_finder_contents(self.request_result[method], method)
    if not tbl then
      return
    end

    if i ~= 2 then
      generate_contents(tbl, method)
    end

    if i == 2 and not tbl[1][1]:find('0') then
      generate_contents(tbl, method)
    end
  end
  self:render_finder_result()
end

function Finder:create_finder_contents(result, method)
  local contents = {}

  insert(contents, { self.titles[method] .. '  ' .. #result, false })
  insert(contents, { ' ', false })

  local msgs = {
    [self.methods[1]] = 'No Definition Found',
    [self.methods[2]] = 'No Implement  Found',
    [self.methods[3]] = 'No Reference  Found',
  }

  self.indent = '    '
  if #result == 0 then
    insert(contents, { self.indent .. self.f_icon .. msgs[method], false })
    insert(contents, { ' ', false })
    return contents
  end

  for _, res in ipairs(result) do
    local uri = res.targetUri or res.uri
    if uri == nil then
      vim.notify('miss uri in server response')
      return
    end
    local bufnr = vim.uri_to_bufnr(uri)
    if not api.nvim_buf_is_loaded(bufnr) then
      fn.bufload(bufnr)
    end
    local link = vim.uri_to_fname(uri) -- returns lowercase drive letters on Windows
    if self.libs.iswin then
      link = link:gsub('^%l', link:sub(1, 1):upper())
    end
    local short_name
    local path_sep = self.libs.path_sep
    -- reduce filename length by root_dir or home dir
    if self.root_dir and link:find(self.root_dir, 1, true) then
      short_name = link:sub(self.root_dir:len() + 2)
    else
      local _split = vim.split(link, path_sep)
      if #_split >= 4 then
        short_name = table.concat(_split, path_sep, #_split - 2, #_split)
      end
    end

    local target_line = self.indent .. self.f_icon .. short_name

    local range = res.targetRange or res.range
    local lines = api.nvim_buf_get_lines(
      bufnr,
      range.start.line - config.preview.lines_above,
      range['end'].line + 1 + config.preview.lines_below,
      false
    )

    local link_with_preview = {
      link = link,
      preview = lines,
      row = range.start.line + 1,
      col = range.start.character + 1,
      _end_col = range['end'].character,
    }
    insert(contents, { target_line, link_with_preview })
  end
  insert(contents, { ' ', false })
  return contents
end

function Finder:render_finder_result()
  if next(self.contents) == nil then
    return
  end
  -- get dimensions
  local width = api.nvim_get_option('columns')
  local height = api.nvim_get_option('lines')

  -- calculate our floating window size
  local win_height = math.ceil(height * 0.8)
  local win_width = math.ceil(width * 0.8)

  -- and its starting position
  local row = math.ceil((height - win_height) * 0.7)
  local col = math.ceil((width - win_width))
  local opts = {
    style = 'minimal',
    relative = 'editor',
    row = row,
    col = col,
  }

  local max_height = math.ceil((height - 4) * 0.5)
  if #self.contents > max_height then
    opts.height = max_height
  end

  local content_opts = {
    contents = self.contents,
    filetype = 'lspsagafinder',
    enter = true,
    highlight = {
      border = 'FinderBorder',
      normal = 'FinderNormal',
    },
  }

  if fn.has('nvim-0.9') == 1 then
    local theme = require('lspsaga').theme()
    opts.title = {
      { theme.left, 'TitleSymbol' },
      { ' ', 'TitleIcon' },
      { self.current_word, 'TitleString' },
      { theme.right, 'TitleSymbol' },
    }
  end

  self.bufnr, self.winid = self.window.create_win_with_border(content_opts, opts)
  api.nvim_buf_set_option(self.bufnr, 'buflisted', false)
  api.nvim_win_set_var(self.winid, 'lsp_finder_win_opts', opts)
  api.nvim_win_set_option(self.winid, 'cursorline', false)

  self:set_cursor()

  local finder_group = api.nvim_create_augroup('lspsaga_finder', { clear = true })
  api.nvim_create_autocmd('CursorMoved', {
    group = finder_group,
    buffer = self.bufnr,
    callback = function()
      self:set_cursor()
      self:auto_open_preview()
    end,
  })

  local events = { 'WinClosed', 'WinLeave' }

  api.nvim_create_autocmd(events, {
    group = finder_group,
    buffer = self.bufnr,
    callback = function()
      self:quit_with_clear()
      if finder_group then
        pcall(api.nvim_del_augroup_by_id, finder_group)
      end
      -- make sure close all finder preview window
      for _, win in pairs(api.nvim_list_wins()) do
        local ok, id = pcall(api.nvim_win_get_var, win, 'finder_preview')
        if ok then
          pcall(api.nvim_win_close, id, true)
        end
      end
    end,
  })

  local virt_hi = 'FinderVirtText'

  local ns_id = api.nvim_create_namespace('lspsagafinder')
  api.nvim_buf_set_extmark(0, ns_id, 1, 0, {
    virt_text = { { '│', virt_hi } },
    virt_text_pos = 'overlay',
  })

  for i = self.def_scope[1] + 2, self.def_scope[2] - 1, 1 do
    local virt_texts = {}
    api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderFileName', 1 + i, 0, -1)
    if self.f_hl then
      api.nvim_buf_add_highlight(self.bufnr, -1, self.f_hl, i, 0, #self.indent + #self.f_icon)
    end

    if i == self.def_scope[2] - 1 then
      insert(virt_texts, { '└', virt_hi })
      insert(virt_texts, { '───', virt_hi })
    else
      insert(virt_texts, { '├', virt_hi })
      insert(virt_texts, { '───', virt_hi })
    end

    api.nvim_buf_set_extmark(0, ns_id, i, 0, {
      virt_text = virt_texts,
      virt_text_pos = 'overlay',
    })
  end

  if self.imp_scope then
    api.nvim_buf_set_extmark(0, ns_id, self.imp_scope[1] + 1, 0, {
      virt_text = { { '│', virt_hi } },
      virt_text_pos = 'overlay',
    })

    for i = self.imp_scope[1] + 2, self.imp_scope[2] - 1, 1 do
      local virt_texts = {}
      api.nvim_buf_add_highlight(self.bufnr, -1, 'TargetFileName', 1 + i, 0, -1)
      if self.f_hl then
        api.nvim_buf_add_highlight(self.bufnr, -1, self.f_hl, i, 0, #self.indent + #self.f_icon)
      end

      if i == self.imp_scope[2] - 1 then
        insert(virt_texts, { '└', virt_hi })
        insert(virt_texts, { '───', virt_hi })
      else
        insert(virt_texts, { '├', virt_hi })
        insert(virt_texts, { '───', virt_hi })
      end

      api.nvim_buf_set_extmark(0, ns_id, i, 0, {
        virt_text = virt_texts,
        virt_text_pos = 'overlay',
      })
    end
  end

  api.nvim_buf_set_extmark(0, ns_id, self.ref_scope[1] + 1, 0, {
    virt_text = { { '│', virt_hi } },
    virt_text_pos = 'overlay',
  })

  for i = self.ref_scope[1] + 2, self.ref_scope[2] - 1 do
    local virt_texts = {}
    api.nvim_buf_add_highlight(self.bufnr, -1, 'TargetFileName', i, 0, -1)
    if self.f_hl then
      api.nvim_buf_add_highlight(self.bufnr, -1, self.f_hl, i, 0, #self.indent + #self.f_icon)
    end

    if i == self.ref_scope[2] - 1 then
      insert(virt_texts, { '└', virt_hi })
      insert(virt_texts, { '───', virt_hi })
    else
      insert(virt_texts, { '├', virt_hi })
      insert(virt_texts, { '───', virt_hi })
    end

    api.nvim_buf_set_extmark(0, ns_id, i, 0, {
      virt_text = virt_texts,
      virt_text_pos = 'overlay',
    })
  end
  -- disable some move keys in finder window
  self.libs.disable_move_keys(self.bufnr)
  -- load float window map
  self:apply_float_map()
  self:lsp_finder_highlight()
end

function Finder:apply_float_map()
  local action = config.finder.keys
  local nvim_create_keymap = require('lspsaga.libs').nvim_create_keymap
  local opts = {
    buffer = self.bufnr,
    noremap = true,
    silent = true,
  }

  local open_func = function()
    self:open_link(1)
  end

  local vsplit_func = function()
    self:open_link(2)
  end

  local split_func = function()
    self:open_link(3)
  end

  local tabe_func = function()
    self:open_link(4)
  end

  local quit_func = function()
    self:quit_with_clear()
  end

  local keymaps = {
    { 'n', action.vsplit, vsplit_func, opts },
    { 'n', action.split, split_func, opts },
    { 'n', action.tabe, tabe_func, opts },
    { 'n', action.open, open_func, opts },
    { 'n', action.quit, quit_func, opts },
  }

  nvim_create_keymap(keymaps)
end

function Finder:lsp_finder_highlight()
  local len = string.len('Definition')
  local theme = require('lspsaga').theme()

  for _, v in pairs({ 0, self.ref_scope[1], self.imp_scope and self.imp_scope[1] or nil }) do
    api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderIcon', v, 0, 3)
    api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderType', v, 4, 4 + len)
    api.nvim_buf_add_highlight(
      self.bufnr,
      -1,
      'FinderCount',
      v,
      #theme.left + len + #theme.right,
      -1
    )
  end
end

local finder_ns = api.nvim_create_namespace('finder_select')

function Finder:set_cursor()
  local current_line = api.nvim_win_get_cursor(0)[1]
  local column = #self.indent + #self.f_icon + 1

  local first_def_uri_lnum = self.def_scope[1] + 3
  local last_def_uri_lnum = self.def_scope[2]
  local first_ref_uri_lnum = self.ref_scope[1] + 3
  local last_ref_uri_lnum = self.ref_scope[2]

  local first_imp_uri_lnum = self.imp_scope and self.imp_scope[1] + 3 or -2
  local last_imp_uri_lnum = self.imp_scope and self.imp_scope[2] or -2

  if current_line == 1 then
    fn.cursor(first_def_uri_lnum, column)
  elseif current_line == last_def_uri_lnum + 1 then
    fn.cursor(first_imp_uri_lnum > 0 and first_imp_uri_lnum or first_ref_uri_lnum, column)
  elseif current_line == last_imp_uri_lnum + 1 then
    fn.cursor(first_ref_uri_lnum, column)
  elseif current_line == last_ref_uri_lnum + 1 then
    fn.cursor(first_def_uri_lnum, column)
  elseif current_line == first_ref_uri_lnum - 1 then
    fn.cursor(last_imp_uri_lnum > 0 and last_imp_uri_lnum or last_def_uri_lnum, column)
  elseif current_line == first_imp_uri_lnum - 1 then
    fn.cursor(last_def_uri_lnum, column)
  elseif current_line == first_def_uri_lnum - 1 then
    fn.cursor(last_ref_uri_lnum, column)
  end

  local actual_line = api.nvim_win_get_cursor(0)[1]
  if actual_line == first_def_uri_lnum then
    api.nvim_buf_add_highlight(0, finder_ns, 'FinderSelection', 2, #self.indent + #self.f_icon, -1)
  end

  api.nvim_buf_clear_namespace(0, finder_ns, 0, -1)
  api.nvim_buf_add_highlight(
    0,
    finder_ns,
    'FinderSelection',
    actual_line - 1,
    #self.indent + #self.f_icon,
    -1
  )
end

function Finder:auto_open_preview()
  local current_line = fn.line('.')
  if not self.short_link[current_line] then
    return
  end
  local content = self.short_link[current_line].preview or {}
  local start_pos = self.short_link[current_line].col
  local _end_col = self.short_link[current_line]._end_col

  if next(content) ~= nil then
    local has_var, finder_win_opts = pcall(api.nvim_win_get_var, 0, 'lsp_finder_win_opts')
    if not has_var then
      vim.notify('get finder window options wrong')
      return
    end
    local opts = {
      relative = 'editor',
      -- We'll make sure the preview window is the correct size
      no_size_override = true,
    }

    local finder_width = fn.winwidth(0)
    local finder_height = fn.winheight(0)
    local screen_width = api.nvim_get_option('columns')

    local content_width = 0
    for _, line in ipairs(content) do
      content_width = math.max(fn.strdisplaywidth(line), content_width)
    end

    local border_width
    if config.border_style == 'double' then
      border_width = 4
    else
      border_width = 2
    end

    local max_width = screen_width - finder_win_opts.col - finder_width - border_width - 2

    if max_width > 42 then
      -- Put preview window to the right of the finder window
      local preview_width = math.min(content_width + border_width, max_width)
      opts.col = finder_win_opts.col + finder_width + 2
      opts.row = finder_win_opts.row
      opts.width = preview_width
      opts.height = #self.contents
      if opts.height > finder_height then
        opts.height = finder_height
      end
    else
      -- Put preview window below the finder window
      local max_height = vim.o.lines - finder_win_opts.row - finder_height - border_width - 2
      if max_height <= 3 then
        return
      end -- Don't show preview window if too short
      opts.row = finder_win_opts.row + finder_height + 4
      opts.col = finder_win_opts.col
      opts.width = finder_width
      opts.height = math.min(8, max_height)
    end

    local content_opts = {
      contents = content,
      highlight = {
        border = 'FinderPreviewBorder',
        normal = 'FinderNormal',
      },
    }

    if fn.has('nvim-0.9') == 1 then
      local theme = require('lspsaga').theme()
      opts.title = {
        { theme.left, 'TitleSymbol' },
        { config.ui.preview, 'TitleIcon' },
        { 'Preview', 'TitleString' },
        { theme.right, 'TitleSymbol' },
      }
    end

    self:close_auto_preview_win()

    vim.defer_fn(function()
      opts.noautocmd = true
      self.preview_bufnr, self.preview_winid =
        self.window.create_win_with_border(content_opts, opts)
      vim.treesitter.start(self.preview_bufnr, self.buf_filetype)
      api.nvim_buf_set_option(self.preview_bufnr, 'buflisted', false)
      api.nvim_win_set_var(self.preview_winid, 'finder_preview', self.preview_winid)

      self.libs.scroll_in_preview(self.bufnr, self.preview_winid)

      if not self.preview_hl_ns then
        self.preview_hl_ns = api.nvim_create_namespace('FinderPreview')
      end
      local trimLines = 0
      for _, v in pairs(content) do
        if v == '' then
          trimLines = trimLines + 1
        else
          break
        end
      end
      api.nvim_buf_add_highlight(
        self.preview_bufnr,
        self.preview_hl_ns,
        'FinderPreviewSearch',
        0 + config.preview.lines_above - trimLines,
        start_pos - 1,
        _end_col
      )
    end, 10)
  end
end

function Finder:close_auto_preview_win()
  if self.preview_hl_ns then
    pcall(api.nvim_buf_clear_namespace, self.preview_bufnr, self.preview_hl_ns, 0, -1)
  end
  if self.preview_bufnr and api.nvim_buf_is_loaded(self.preview_bufnr) then
    api.nvim_buf_delete(self.preview_bufnr, { force = true })
    self.preview_bufnr = nil
  end

  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    api.nvim_win_close(self.preview_winid, true)
    self.preview_winid = nil
  end
end

-- action 1 mean enter
-- action 2 mean vsplit
-- action 3 mean split
-- action 4 mean tabe
function Finder:open_link(action_type)
  local action = { 'edit ', 'vsplit ', 'split ', 'tabe ' }
  local current_line = api.nvim_win_get_cursor(0)[1]

  if self.short_link[current_line] == nil then
    vim.notify('[LspSaga] no file link in current line', vim.log.levels.WARN)
    return
  end

  local short_link = self.short_link
  self:quit_float_window()

  -- if buffer not saved save it before jump
  if vim.bo.modified then
    vim.cmd('write')
  end
  api.nvim_command(action[action_type] .. short_link[current_line].link)
  fn.cursor(short_link[current_line].row, short_link[current_line].col)
  self:clear_tmp_data()
end

function Finder:quit_float_window()
  if self.bufnr and api.nvim_buf_is_loaded(self.bufnr) then
    api.nvim_buf_delete(self.bufnr, { force = true })
    self.bufnr = nil
  end

  self:close_auto_preview_win()
  if self.winid and self.winid > 0 then
    self.window.nvim_close_valid_window(self.winid)
    self.winid = nil
  end
end

function Finder:clear_tmp_data()
  for key, val in pairs(self) do
    if type(val) ~= 'function' then
      self[key] = nil
    end
  end
end

function Finder:quit_with_clear()
  self:quit_float_window()
  self:clear_tmp_data()
end

return Finder
