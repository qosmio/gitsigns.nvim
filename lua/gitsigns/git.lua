local wrap = require('gitsigns.async').wrap
local scheduler = require('gitsigns.async').scheduler

local gsd = require("gitsigns.debug")
local util = require('gitsigns.util')
local subprocess = require('gitsigns.subprocess')

local gs_hunks = require("gitsigns.hunks")
local Hunk = gs_hunks.Hunk

local uv = vim.loop
local startswith = vim.startswith

local dprint = require("gitsigns.debug").dprint











local M = {BlameInfo = {}, Version = {}, RepoInfo = {}, Repo = {}, FileProps = {}, Obj = {}, }

































































































local in_git_dir = function(file)
   for _, p in ipairs(vim.split(file, util.path_sep)) do
      if p == '.git' then
         return true
      end
   end
   return false
end

local Obj = M.Obj
local Repo = M.Repo

local function parse_version(version)
   assert(version:match('%d+%.%d+%.%w+'), 'Invalid git version: ' .. version)
   local ret = {}
   local parts = vim.split(version, '%.')
   ret.major = tonumber(parts[1])
   ret.minor = tonumber(parts[2])

   if parts[3] == 'GIT' then
      ret.patch = 0
   else
      ret.patch = tonumber(parts[3])
   end

   return ret
end


local function check_version(version)
   if M.version.major < version[1] then
      return false
   end
   if version[2] and M.version.minor < version[2] then
      return false
   end
   if version[3] and M.version.patch < version[3] then
      return false
   end
   return true
end



M.command = wrap(function(args, spec, callback)
   spec = spec or {}
   spec.command = spec.command or 'git'
   spec.args = spec.command == 'git' and
   { '--no-pager', '--literal-pathspecs', unpack(args) } or args
   subprocess.run_job(spec, function(_, _, stdout, stderr)
      if not spec.suppress_stderr then
         if stderr then
            gsd.eprint(stderr)
         end
      end

      local stdout_lines = vim.split(stdout or '', '\n', true)



      if stdout_lines[#stdout_lines] == '' then
         stdout_lines[#stdout_lines] = nil
      end

      if gsd.verbose then
         gsd.vprintf('%d lines:', #stdout_lines)
         for i = 1, math.min(10, #stdout_lines) do
            gsd.vprintf('\t%s', stdout_lines[i])
         end
      end

      callback(stdout_lines, stderr)
   end)
end, 3)

M.diff = function(file_cmp, file_buf, indent_heuristic, diff_algo)
   return M.command({
      '-c', 'core.safecrlf=false',
      'diff',
      '--color=never',
      '--' .. (indent_heuristic and '' or 'no-') .. 'indent-heuristic',
      '--diff-algorithm=' .. diff_algo,
      '--patch-with-raw',
      '--unified=0',
      file_cmp,
      file_buf,
   })

end

local function process_abbrev_head(gitdir, head_str, path, cmd)
   if not gitdir then
      return head_str
   end
   if head_str == 'HEAD' then
      local short_sha = M.command({ 'rev-parse', '--short', 'HEAD' }, {
         command = cmd or 'git',
         suppress_stderr = true,
         cwd = path,
      })[1] or ''
      if gsd.debug_mode and short_sha ~= '' then
         short_sha = 'HEAD'
      end
      if util.path_exists(gitdir .. '/rebase-merge') or
         util.path_exists(gitdir .. '/rebase-apply') then
         return short_sha .. '(rebasing)'
      end
      return short_sha
   end
   return head_str
end

local has_cygpath = jit and jit.os == 'Windows' and vim.fn.executable('cygpath') == 1

local cygpath_convert

if has_cygpath then
   cygpath_convert = function(path)
      return M.command({ '-aw', path }, { command = 'cygpath' })[1]
   end
end

local function normalize_path(path)
   if path and has_cygpath and not uv.fs_stat(path) then


      path = cygpath_convert(path)
   end
   return path
end

M.get_repo_info = function(path, cmd, gitdir, toplevel)


   local has_abs_gd = check_version({ 2, 13 })
   local git_dir_opt = has_abs_gd and '--absolute-git-dir' or '--git-dir'



   scheduler()

   local args = {}

   if gitdir then
      vim.list_extend(args, { '--git-dir', gitdir })
   end

   if toplevel then
      vim.list_extend(args, { '--work-tree', toplevel })
   end

   vim.list_extend(args, {
      'rev-parse', '--show-toplevel', git_dir_opt, '--abbrev-ref', 'HEAD',
   })

   local results = M.command(args, {
      command = cmd or 'git',
      suppress_stderr = true,
      cwd = path,
   })

   local ret = {
      toplevel = normalize_path(results[1]),
      gitdir = normalize_path(results[2]),
   }
   ret.abbrev_head = process_abbrev_head(ret.gitdir, results[3], path, cmd)
   if ret.gitdir and not has_abs_gd then
      ret.gitdir = uv.fs_realpath(ret.gitdir)
   end
   ret.detached = ret.toplevel and ret.gitdir ~= ret.toplevel .. '/.git'
   return ret
end

M.set_version = function(version)
   if version ~= 'auto' then
      M.version = parse_version(version)
      return
   end
   local results = M.command({ '--version' })
   local line = results[1]
   assert(line)
   assert(type(line) == 'string', 'Unexpected output: ' .. line)
   assert(startswith(line, 'git version'), 'Unexpected output: ' .. line)
   local parts = vim.split(line, '%s+')
   M.version = parse_version(parts[3])
end






Repo.command = function(self, args, spec)
   spec = spec or {}
   spec.cwd = self.toplevel

   local args1 = {
      '--git-dir', self.gitdir,
   }

   if self.detached then
      vim.list_extend(args1, { '--work-tree', self.toplevel })
   end

   vim.list_extend(args1, args)

   return M.command(args1, spec)
end

Repo.files_changed = function(self)
   local results = self:command({ 'status', '--porcelain', '--ignore-submodules' })

   local ret = {}
   for _, line in ipairs(results) do
      if line:sub(1, 2):match('^.M') then
         ret[#ret + 1] = line:sub(4, -1)
      end
   end
   return ret
end


Repo.get_show_text = function(self, object, encoding)
   local stdout, stderr = self:command({ 'show', object }, { suppress_stderr = true })

   if encoding ~= 'utf-8' then
      scheduler()
      for i, l in ipairs(stdout) do

         if vim.fn.type(l) == vim.v.t_string then
            stdout[i] = vim.fn.iconv(l, encoding, 'utf-8')
         end
      end
   end

   return stdout, stderr
end

Repo.update_abbrev_head = function(self)
   self.abbrev_head = M.get_repo_info(self.toplevel).abbrev_head
end

Repo.new = function(dir, gitdir, toplevel)
   local self = setmetatable({}, { __index = Repo })

   self.username = M.command({ 'config', 'user.name' })[1]
   local info = M.get_repo_info(dir, nil, gitdir, toplevel)
   for k, v in pairs(info) do
      (self)[k] = v
   end


   if M.enable_yadm and not self.gitdir then
      if vim.startswith(dir, os.getenv('HOME')) and
         #M.command({ 'ls-files', dir }, { command = 'yadm' }) ~= 0 then
         M.get_repo_info(dir, 'yadm', gitdir, toplevel)
         local yadm_info = M.get_repo_info(dir, 'yadm', gitdir, toplevel)
         for k, v in pairs(yadm_info) do
            (self)[k] = v
         end
      end
   end

   return self
end






Obj.command = function(self, args, spec)
   return self.repo:command(args, spec)
end

Obj.update_file_info = function(self, update_relpath, silent)
   local old_object_name = self.object_name
   local props = self:file_info(self.file, silent)

   if update_relpath then
      self.relpath = props.relpath
   end
   self.object_name = props.object_name
   self.mode_bits = props.mode_bits
   self.has_conflicts = props.has_conflicts
   self.i_crlf = props.i_crlf
   self.w_crlf = props.w_crlf

   return old_object_name ~= self.object_name
end

Obj.file_info = function(self, file, silent)
   local results, stderr = self:command({
      '-c', 'core.quotepath=off',
      'ls-files',
      '--stage',
      '--others',
      '--exclude-standard',
      '--eol',
      file or self.file,
   }, { suppress_stderr = true })

   if stderr and not silent then


      if not stderr:match('^warning: could not open directory .*: No such file or directory') then
         gsd.eprint(stderr)
      end
   end

   local result = {}
   for _, line in ipairs(results) do
      local parts = vim.split(line, '\t')
      if #parts > 2 then
         local eol = vim.split(parts[2], '%s+')
         result.i_crlf = eol[1] == 'i/crlf'
         result.w_crlf = eol[2] == 'w/crlf'
         result.relpath = parts[3]
         local attrs = vim.split(parts[1], '%s+')
         local stage = tonumber(attrs[3])
         if stage <= 1 then
            result.mode_bits = attrs[1]
            result.object_name = attrs[2]
         else
            result.has_conflicts = true
         end
      else
         result.relpath = parts[2]
      end
   end
   return result
end

Obj.get_show_text = function(self, revision)
   if not self.relpath then
      return {}
   end

   local stdout, stderr = self.repo:get_show_text(revision .. ':' .. self.relpath, self.encoding)

   if not self.i_crlf and self.w_crlf then

      for i = 1, #stdout do
         stdout[i] = stdout[i] .. '\r'
      end
   end

   return stdout, stderr
end

Obj.unstage_file = function(self)
   self:command({ 'reset', self.file })
end

Obj.run_blame = function(self, lines, lnum, ignore_whitespace)
   if not self.object_name or self.repo.abbrev_head == '' then



      return {
         author = 'Not Committed Yet',
         ['author_mail'] = '<not.committed.yet>',
         committer = 'Not Committed Yet',
         ['committer_mail'] = '<not.committed.yet>',
      }
   end

   local args = {
      'blame',
      '--contents', '-',
      '-L', lnum .. ',+1',
      '--line-porcelain',
      self.file,
   }

   if ignore_whitespace then
      args[#args + 1] = '-w'
   end

   local ignore_file = self.repo.toplevel .. '/.git-blame-ignore-revs'
   if uv.fs_stat(ignore_file) then
      vim.list_extend(args, { '--ignore-revs-file', ignore_file })
   end

   local results = self:command(args, { writer = lines })
   if #results == 0 then
      return
   end
   local header = vim.split(table.remove(results, 1), ' ')

   local ret = {}
   ret.sha = header[1]
   ret.orig_lnum = tonumber(header[2])
   ret.final_lnum = tonumber(header[3])
   ret.abbrev_sha = string.sub(ret.sha, 1, 8)
   for _, l in ipairs(results) do
      if not startswith(l, '\t') then
         local cols = vim.split(l, ' ')
         local key = table.remove(cols, 1):gsub('-', '_')
         ret[key] = table.concat(cols, ' ')
         if key == 'previous' then
            ret.previous_sha = cols[1]
            ret.previous_filename = cols[2]
         end
      end
   end
   return ret
end

Obj.ensure_file_in_index = function(self)
   if not self.object_name or self.has_conflicts then
      if not self.object_name then

         self:command({ 'add', '--intent-to-add', self.file })
      else


         local info = string.format('%s,%s,%s', self.mode_bits, self.object_name, self.relpath)
         self:command({ 'update-index', '--add', '--cacheinfo', info })
      end

      self:update_file_info()
   end
end

Obj.stage_lines = function(self, lines)
   local stdout = self:command({
      'hash-object', '-w', '--path', self.relpath, '--stdin',
   }, { writer = lines })

   local new_object = stdout[1]

   self:command({
      'update-index', '--cacheinfo', string.format('%s,%s,%s', self.mode_bits, new_object, self.relpath),
   })
end

Obj.stage_hunks = function(self, hunks, invert)
   self:ensure_file_in_index()
   self:command({
      'apply', '--whitespace=nowarn', '--cached', '--unidiff-zero', '-',
   }, {
      writer = gs_hunks.create_patch(self.relpath, hunks, self.mode_bits, invert),
   })
end

Obj.has_moved = function(self)
   local out = self:command({ 'diff', '--name-status', '-C', '--cached' })
   local orig_relpath = self.orig_relpath or self.relpath
   for _, l in ipairs(out) do
      local parts = vim.split(l, '%s+')
      if #parts == 3 then
         local orig, new = parts[2], parts[3]
         if orig_relpath == orig then
            self.orig_relpath = orig_relpath
            self.relpath = new
            self.file = self.repo.toplevel .. '/' .. new
            return new
         end
      end
   end
end

Obj.new = function(file, encoding, gitdir, toplevel)
   if in_git_dir(file) then
      dprint('In git dir')
      return nil
   end
   local self = setmetatable({}, { __index = Obj })

   self.file = file
   self.encoding = encoding
   self.repo = Repo.new(util.dirname(file), gitdir, toplevel)

   if not self.repo.gitdir then
      dprint('Not in git repo')
      return nil
   end


   local silent = gitdir ~= nil and toplevel ~= nil

   self:update_file_info(true, silent)

   return self
end

return M
