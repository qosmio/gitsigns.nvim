local void = require('gitsigns.async').void
local awrap = require('gitsigns.async').wrap
local scheduler = require('gitsigns.async').scheduler

local gs_cache = require('gitsigns.cache')
local CacheEntry = gs_cache.CacheEntry
local cache = gs_cache.cache

local Signs = require('gitsigns.signs')

local Status = require("gitsigns.status")

local debounce_trailing = require('gitsigns.debounce').debounce_trailing
local throttle_by_id = require('gitsigns.debounce').throttle_by_id
local gs_debug = require("gitsigns.debug")
local dprint = gs_debug.dprint
local dprintf = gs_debug.dprintf
local eprint = gs_debug.eprint
local subprocess = require('gitsigns.subprocess')
local util = require('gitsigns.util')
local run_diff = require('gitsigns.diff')
local git = require('gitsigns.git')
local uv = require('gitsigns.uv')

local gs_hunks = require("gitsigns.hunks")
local Hunk = gs_hunks.Hunk

local config = require('gitsigns.config').config

local api = vim.api

local signs

local M = {}










local schedule_if_buf_valid = function(buf, cb)
   vim.schedule(function()
      if vim.api.nvim_buf_is_valid(buf) then
         cb()
      end
   end)
end

local scheduler_if_buf_valid = awrap(schedule_if_buf_valid, 2)

local function apply_win_signs(bufnr, hunks, top, bot, clear)
   if clear then
      signs:remove(bufnr)
   end


   hunks = hunks or {}





   if clear and hunks[1] then
      signs:add(bufnr, gs_hunks.calc_signs(hunks[1], hunks[1].added.start, hunks[1].added.start))
   end

   for _, hunk in ipairs(hunks) do
      if top <= hunk.vend and bot >= hunk.added.start then
         signs:add(bufnr, gs_hunks.calc_signs(hunk, top, bot))
      end
      if hunk.added.start > bot then
         break
      end
   end
end

M.on_lines = function(buf, first, last_orig, last_new)
   local bcache = cache[buf]
   if not bcache then
      dprint('Cache for buffer was nil. Detaching')
      return true
   end

   signs:on_lines(buf, first, last_orig, last_new)



   if signs:contains(buf, first, last_new) then

      bcache.force_next_update = true
   end

   M.update_debounced(buf, cache[buf])
end

local ns = api.nvim_create_namespace('gitsigns')

local function apply_word_diff(bufnr, row)

   if vim.fn.foldclosed(row + 1) ~= -1 then
      return
   end

   if not cache[bufnr] or not cache[bufnr].hunks then
      return
   end

   local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
   if not line then

      return
   end

   local lnum = row + 1

   local hunk = gs_hunks.find_hunk(lnum, cache[bufnr].hunks)
   if not hunk then

      return
   end

   if hunk.added.count ~= hunk.removed.count then

      return
   end

   local pos = lnum - hunk.added.start + 1

   local added_line = hunk.added.lines[pos]
   local removed_line = hunk.removed.lines[pos]

   local _, added_regions = require('gitsigns.diff_int').run_word_diff({ removed_line }, { added_line })

   local cols = #line

   for _, region in ipairs(added_regions) do
      local rtype, scol, ecol = region[2], region[3] - 1, region[4] - 1
      if ecol == scol then

         ecol = scol + 1
      end

      local hl_group = rtype == 'add' and 'GitSignsAddLnInline' or
      rtype == 'change' and 'GitSignsChangeLnInline' or
      'GitSignsDeleteLnInline'

      local opts = {
         ephemeral = true,
         priority = 1000,
      }

      if ecol > cols and ecol == scol + 1 then

         opts.virt_text = { { ' ', hl_group } }
         opts.virt_text_pos = 'overlay'
      else
         opts.end_col = ecol
         opts.hl_group = hl_group
      end

      api.nvim_buf_set_extmark(bufnr, ns, row, scol, opts)
      api.nvim__buf_redraw_range(bufnr, row, row + 1)
   end
end

local ns_rm = api.nvim_create_namespace('gitsigns_removed')

local VIRT_LINE_LEN = 300

local function clear_deleted(bufnr)
   local marks = api.nvim_buf_get_extmarks(bufnr, ns_rm, 0, -1, {})
   for _, mark in ipairs(marks) do
      api.nvim_buf_del_extmark(bufnr, ns_rm, mark[1])
   end
end

function M.show_deleted(bufnr, nsd, hunk)
   local virt_lines = {}

   for i, line in ipairs(hunk.removed.lines) do
      local vline = {}
      local last_ecol = 1

      if config.word_diff then
         local regions = require('gitsigns.diff_int').run_word_diff(
         { hunk.removed.lines[i] }, { hunk.added.lines[i] })

         for _, region in ipairs(regions) do
            local rline, scol, ecol = region[1], region[3], region[4]
            if rline > 1 then
               break
            end
            vline[#vline + 1] = { line:sub(last_ecol, scol - 1), 'GitSignsDeleteVirtLn' }
            vline[#vline + 1] = { line:sub(scol, ecol - 1), 'GitSignsDeleteVirtLnInline' }
            last_ecol = ecol
         end
      end

      if #line > 0 then
         vline[#vline + 1] = { line:sub(last_ecol, -1), 'GitSignsDeleteVirtLn' }
      end


      local padding = string.rep(' ', VIRT_LINE_LEN - #line)
      vline[#vline + 1] = { padding, 'GitSignsDeleteVirtLn' }

      virt_lines[i] = vline
   end

   local topdelete = hunk.added.start == 0 and hunk.type == 'delete'

   local row = topdelete and 0 or hunk.added.start - 1
   api.nvim_buf_set_extmark(bufnr, nsd, row, -1, {
      virt_lines = virt_lines,

      virt_lines_above = hunk.type ~= 'delete' or topdelete,
   })
end

function M.show_added(bufnr, nsw, hunk)
   local start_row = hunk.added.start - 1

   for offset = 0, hunk.added.count - 1 do
      local row = start_row + offset
      api.nvim_buf_set_extmark(bufnr, nsw, row, 0, {
         end_row = row + 1,
         hl_group = 'GitSignsAddPreview',
         hl_eol = true,
         priority = 1000,
      })
   end

   local _, added_regions = require('gitsigns.diff_int').run_word_diff(hunk.removed.lines, hunk.added.lines)

   for _, region in ipairs(added_regions) do
      local offset, rtype, scol, ecol = region[1] - 1, region[2], region[3] - 1, region[4] - 1
      api.nvim_buf_set_extmark(bufnr, nsw, start_row + offset, scol, {
         end_col = ecol,
         hl_group = rtype == 'add' and 'GitSignsAddInline' or
         rtype == 'change' and 'GitSignsChangeInline' or
         'GitSignsDeleteInline',
         priority = 1001,
      })
   end
end

local function update_show_deleted(bufnr)
   local bcache = cache[bufnr]

   clear_deleted(bufnr)
   if config.show_deleted then
      for _, hunk in ipairs(bcache.hunks) do
         M.show_deleted(bufnr, ns_rm, hunk)
      end
   end
end

local update_cnt = 0





M.update = throttle_by_id(function(bufnr, bcache)
   local __FUNC__ = 'update'
   bcache = bcache or cache[bufnr]
   if not bcache then
      eprint('Cache for buffer ' .. bufnr .. ' was nil')
      return
   end

   scheduler_if_buf_valid(bufnr)
   local buftext = util.buf_lines(bufnr)
   local git_obj = bcache.git_obj

   if not bcache.compare_text or config._refresh_staged_on_update then
      bcache.compare_text = git_obj:get_show_text(bcache:get_compare_rev())
   end

   local old_hunks = bcache.hunks
   bcache.hunks = run_diff(bcache.compare_text, buftext)

   scheduler_if_buf_valid(bufnr)


   if bcache.force_next_update or gs_hunks.compare_heads(bcache.hunks, old_hunks) then


      apply_win_signs(bufnr, bcache.hunks, vim.fn.line('w0'), vim.fn.line('w$'), true)

      update_show_deleted(bufnr)
      bcache.force_next_update = false

      api.nvim_exec_autocmds('User', {
         pattern = 'GitSignsUpdate',
         modeline = false,
      })
   end
   local summary = gs_hunks.get_summary(bcache.hunks)
   summary.head = git_obj.repo.abbrev_head
   Status:update(bufnr, summary)

   update_cnt = update_cnt + 1

   dprintf('updates: %s, jobs: %s', update_cnt, subprocess.job_cnt)
end, true)

M.detach = function(bufnr, keep_signs)
   if not keep_signs then
      signs:remove(bufnr)
   end
end

local function handle_moved(bufnr, bcache, old_relpath)
   local git_obj = bcache.git_obj
   local do_update = false

   local new_name = git_obj:has_moved()
   if new_name then
      dprintf('File moved to %s', new_name)
      git_obj.relpath = new_name
      if not git_obj.orig_relpath then
         git_obj.orig_relpath = old_relpath
      end
      do_update = true
   elseif git_obj.orig_relpath then
      local orig_file = git_obj.repo.toplevel .. util.path_sep .. git_obj.orig_relpath
      if git_obj:file_info(orig_file).relpath then
         dprintf('Moved file reset')
         git_obj.relpath = git_obj.orig_relpath
         git_obj.orig_relpath = nil
         do_update = true
      end
   else

   end

   if do_update then
      git_obj.file = git_obj.repo.toplevel .. util.path_sep .. git_obj.relpath
      bcache.file = git_obj.file
      git_obj:update_file_info()
      scheduler()
      api.nvim_buf_set_name(bufnr, bcache.file)
   end
end


M.watch_gitdir = function(bufnr, gitdir)
   if not config.watch_gitdir.enable then
      return
   end

   dprintf('Watching git dir')
   local w = uv.new_fs_poll(true)
   w:start(gitdir, config.watch_gitdir.interval, void(function(err)
      local __FUNC__ = 'watcher_cb'
      if err then
         dprintf('Git dir update error: %s', err)
         return
      end
      dprint('Git dir update')

      local bcache = cache[bufnr]

      if not bcache then



         dprint('Has detached, aborting')
         return
      end

      local git_obj = bcache.git_obj

      git_obj.repo:update_abbrev_head()

      scheduler()
      Status:update(bufnr, { head = git_obj.repo.abbrev_head })

      local was_tracked = git_obj.object_name ~= nil
      local old_relpath = git_obj.relpath

      if not git_obj:update_file_info() then
         dprint('File not changed')
         return
      end

      if config.watch_gitdir.follow_files and was_tracked and not git_obj.object_name then


         handle_moved(bufnr, bcache, old_relpath)
      end


      bcache.compare_text = nil

      M.update(bufnr, bcache)
   end))
   return w
end

local cwd_watcher

M.update_cwd_head = void(function()
   if cwd_watcher then
      cwd_watcher:stop()
   else
      cwd_watcher = uv.new_fs_poll(true)
   end

   local cwd = vim.loop.cwd()
   local gitdir, head


   for _, bcache in pairs(cache) do
      local repo = bcache.git_obj.repo
      if repo.toplevel == cwd then
         head = repo.abbrev_head
         gitdir = repo.gitdir
         break
      end
   end

   if not head or not gitdir then
      local info = git.get_repo_info(cwd)
      gitdir = info.gitdir
      head = info.abbrev_head
   end

   scheduler()
   vim.g.gitsigns_head = head

   if not gitdir then
      return
   end

   local towatch = gitdir .. '/HEAD'

   if cwd_watcher:getpath() == towatch then

      return
   end


   cwd_watcher:start(
   towatch,
   config.watch_gitdir.interval,
   void(function(err)
      local __FUNC__ = 'cwd_watcher_cb'
      if err then
         dprintf('Git dir update error: %s', err)
         return
      end
      dprint('Git cwd dir update')

      local new_head = git.get_repo_info(cwd).abbrev_head
      scheduler()
      vim.g.gitsigns_head = new_head
   end))

end)

M.reset_signs = function()
   signs:reset()
end

M.setup = function()


   api.nvim_set_decoration_provider(ns, {
      on_win = function(_, _, bufnr, topline, botline_guess)
         local bcache = cache[bufnr]
         if not bcache or not bcache.hunks then
            return false
         end
         local botline = math.min(botline_guess, api.nvim_buf_line_count(bufnr))
         apply_win_signs(bufnr, bcache.hunks, topline + 1, botline + 1)

         if not (config.word_diff and config.diff_opts.internal) then
            return false
         end
      end,
      on_line = function(_, _winid, bufnr, row)
         apply_word_diff(bufnr, row)
      end,
   })

   signs = Signs.new(config.signs)
   M.update_debounced = debounce_trailing(config.update_debounce, void(M.update))
end

return M
