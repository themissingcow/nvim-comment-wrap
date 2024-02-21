--- nvim-comment-wrap
--- SPDX-License-Identifier: MIT
--
-- Automatically adapt your line wrapping settings when writing comments.

local M = {}

-- Utilities --

M.utils = {}

-- Returns whether the supplied str starts with query_str
function M.utils.starts_with(str, query_str)
	return string.sub(str, 1, #query_str) == query_str
end

-- Trailing-edge debouncing to minimise impact when typing, adapted from
-- https://github.com/runiq/neovim-throttle-debounce
function M.utils.debounce(fn, ms)
	local timer = vim.loop.new_timer()
	return function(...)
		local argv = { ... }
		local argc = select("#", ...)
		timer:start(ms, 0, function()
			pcall(vim.schedule_wrap(fn), unpack(argv, 1, argc))
		end)
	end
end

-- Retrieves the current cursor position using 0-based line indexing
function M.utils.get_cursor()
	local pos = vim.api.nvim_win_get_cursor(0)
	-- Account for 1-based indexing
	return pos[1] - 1, pos[2]
end

-- Returns whether the supplied TreeSitter node is a comment node
function M.utils.is_generic_comment(node)
	return M.utils.starts_with(node:type(), "comment")
end

-- Returns whether the treesitter query captures the specified node, the
-- lookup is constrained to the current line. Returns nil in the case of a
-- treesitter failure.
function M.utils.ts_query_contains_node(query_str, node, bufnr)
	local parser = vim.treesitter.get_parser(bufnr)

	local ok, query = pcall(vim.treesitter.query.parse, parser:lang(), query_str)
	if not ok then
		return nil
	end

	local row, col = M.utils.get_cursor()

	local tree = parser:tree_for_range({ row, col, row, col })
	if not tree then
		return nil
	end

	for _, n in query:iter_captures(tree:root(), 0, row - 1, row + 1) do
		if n == node then
			return true
		end
	end

	return false
end

-- Matchers --
--
-- A matcher determines whether the supplied TreeSitter node is considered
-- to be a comment. They should return true or false, and nil in the case
-- of incase of any miscelaneous treesitter failues.

M.matchers = {}

-- A general-purpose matcher that detemrines if the supplied node is a
-- comment node or not.
function M.matchers.generic(node, _)
	return M.utils.is_generic_comment(node)
end

-- Python
--
-- Python docstrings parse as normal strings, so we need to filter to
-- strings immediately following a function or class declaration.
--
-- TODO: limit to the first expression_statement node.

local python_docstring_query = [[
(class_definition body: (block (expression_statement (string) @docstrings)))
(function_definition body: (block (expression_statement (string) @docstrings)))
]]

function M.matchers.python(node, bufnr)
	if M.utils.is_generic_comment(node) then
		return true
	end
	if not M.utils.starts_with(node:type(), "string") then
		return false
	end
	if node:type() ~= "string" then
		node = node:parent()
	end
	return M.utils.ts_query_contains_node(python_docstring_query, node, bufnr)
end

-- Private state management --

-- Tracks whether we should be doing anythign
local enabled = false

-- Previoius values for options managed by the plugin
local prev = nil
-- Whether or not we were in comment the last time we ran, avoids work
-- when the current node hasn't changed.
local last_in_comment = nil

-- Resets the plugin-local state and status (not incl, enabled)
local function reset_state()
	prev = nil
	last_in_comment = nil
	M.status = ""
end

-- Captures the current buffer values for options managed by the plugin
-- into the prev variable.
local function capture_opts()
	prev = {
		tw = vim.bo.textwidth,
		com = vim.bo.comments,
		-- Use 'o' to avoid working with the table form by reference
		fo = vim.o.formatoptions,
	}
end

-- Restores the values of options managed by the plugin (requires that
-- capture_opts has been called prior).
local function restore_opts()
	if prev == nil then
		return
	end
	vim.bo.textwidth = prev.tw
	vim.o.formatoptions = prev.fo
	vim.bo.comments = prev.com
end

-- Applies options managed by the plugin using the supplied values. These
-- values should be obtained from get_config_opts_for_* methods. The
-- layout is expected to match that of the *_opts keys in the default_opts
-- table.
local function apply_opts(opts)
	vim.bo.textwidth = opts.textwidth

	if opts.comments and opts.comments ~= "" then
		vim.bo.comments = opts.comments
	end

	if opts.formatoptions then
		-- Support
		--  - formatoptions = ""
		--  - formatoptions = { add = "", remove = "" }
		if type(opts.formatoptions) == "string" then
			vim.o.formatoptions = opts.formatoptions
		else
			if opts.formatoptions.add and opts.formatoptions.add ~= "" then
				vim.opt.formatoptions:append(opts.formatoptions.add)
			end
			if opts.formatoptions.remove and opts.formatoptions.remove ~= "" then
				vim.opt.formatoptions:remove(opts.formatoptions.remove)
			end
		end
	end
end

-- Generates a user-visible status string that (briefly) describes the
-- current state/options.
local function status_string()
	local status = ""
	if last_in_comment then
		status = " " .. tostring(vim.bo.tw)
	end
	if vim.opt.formatoptions:get().w then
		status = status .. "w"
	end
	return status
end

-- Determine the final options from the config, layering filetype
-- specific options over the top-level shared values.
-- Namespace shoudl be a top-level key in the opts table.
local function get_config_opts_for_ft(namespace, ft)
	local opts = {
		textwidth = M.opts[namespace].textwidth,
		formatoptions = M.opts[namespace].formatoptions,
		comments = M.opts[namespace].comments,
		matcher = M.opts[namespace].matcher,
	}

	local ft_opts = M.opts[namespace].filetype[ft]
	if ft_opts then
		opts = vim.tbl_deep_extend("force", opts, ft_opts)
	end
	return opts
end

-- As per get_config_opts_for_ft, but determine the filetype from the
-- specified buffer (defaults to current).
local function get_config_opts_for_buf(namespace, buf)
	if not buf then
		buf = vim.api.nvim_get_current_buf()
	end
	local ft = vim.bo[buf].filetype
	return get_config_opts_for_ft(namespace, ft)
end

-- Updates options based on the current cursor position
local function update()
	if not enabled then
		return
	end

	local in_comment = M.in_comment()

	if in_comment == last_in_comment then
		return
	end
	last_in_comment = in_comment

	if in_comment == true then
		capture_opts()
		-- Get comment-specific options and apply
		local opts = get_config_opts_for_buf("comment_opts")
		apply_opts(opts)
	else
		-- No longer in a comment, restore previous options
		restore_opts()
	end
	M.status = status_string()
end

-- Shortcuts

local function setup_keys(opts)
	if opts.toggle_paragraph_wrap and opts.toggle_paragraph_wrap ~= "" then
		vim.keymap.set({ "i", "n" }, "<c-k>", function()
			require("nvim-comment-wrap").toggle_paragraph_wrap()
		end)
	end
end

local function clear_keys(opts)
	if opts.toggle_paragraph_wrap and opts.toggle_paragraph_wrap ~= "" then
		vim.keymap.del({ "n", "i" }, "<c-k>")
	end
end

-- autocmd management --

local function e_buff_enter()
	capture_opts()
	update()
end

local function e_buff_leave()
	restore_opts()
	reset_state()
end

local function e_file_type(event)
	local ft_opts = get_config_opts_for_ft("global_opts", event.match)
	apply_opts(ft_opts)
end

local cmd_group = vim.api.nvim_create_augroup("nvim_comment_wrap", {})

-- Convenience to create an autocmd under the plugins group
local function create_cw_autocmd(event, callback)
	local opts = {
		callback = callback,
		group = cmd_group,
	}
	vim.api.nvim_create_autocmd(event, opts)
end

local function clear_autocmds()
	vim.api.nvim_clear_autocmds({ group = cmd_group })
end

local function setup_autocmds()
	clear_autocmds()
	create_cw_autocmd("FileType", e_file_type)
	create_cw_autocmd("BufEnter", e_buff_enter)
	create_cw_autocmd("BufLeave", e_buff_leave)
	create_cw_autocmd("CursorMoved", M.utils.debounce(update, 100))
	create_cw_autocmd("CursorMovedI", M.utils.debounce(update, 100))
end

-- Public interface

-- Useful for including in status lines etc... contains a wrap icon, with
-- the current text width setting when the plugin has modified wrapping
-- mode due to the cursor being inside a comment. Empty at other times.
M.status = ""

-- The default configuration for the plugin
M.default_opts = {
	keys = {
		-- Remove/set to empty to disable
		toggle_paragraph_wrap = "<C-k>",
	},
	comment_opts = {
		textwidth = 74,
		formatoptions = {
			add = "tnjwrcaq",
			remove = "l",
		},
		-- formatoptions = "<string>" also supported to replace
		matcher = M.matchers.generic,
		filetype = {
			python = {
				comments = 'b:#,b:##,sfl-3:""",mb: ,e-3:"""',
				matcher = M.matchers.python,
			},
		},
	},
	global_opts = {
		-- options as per coment_opts, but applied when a file is opened,
		-- this is a convenient way to override what the ft plugin sets,
		-- which otherwise requires autocmds, or additional files on disk.
		filetype = {},
	},
}

-- Main init function
M.setup = function(opts)
	opts = opts or {}
	M.opts = vim.tbl_deep_extend("force", M.default_opts, opts)
	M.enable()
end

-- Enables option management, called automatically by setup, wil register
-- key shortcuts and event handlers.
M.enable = function()
	if enabled then
		return
	end

	if not M.opts then
		M.opts = vim.tbl_deep_extend("force", {}, M.default_opts)
	end
	setup_autocmds()
	setup_keys(M.opts.keys)
	reset_state()
	enabled = true
	update()
end

-- Disables the plugin, removing key/event handlers.
M.disable = function()
	if not enabled then
		return
	end
	vim.api.nvim_clear_autocmds({ group = cmd_group })
	clear_keys(M.opts.keys)
	restore_opts()
	reset_state()
	enabled = false
end

-- Returns whether the cursor is currently within a comment in the current
-- buffer, or nil in the case of any treesitter errors.
M.in_comment = function()
	local buf = vim.api.nvim_get_current_buf()
	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return nil
	end

	-- When the cursor is at the end of a line in insert mode, get_node
	-- will return the parent scope (eg, block, etc...). Lookup the
	-- position just before the cursor to make sure we catch the comment.
	local row, col = M.utils.get_cursor()
	local prev_col = math.max(0, col - 1)
	local node = parser:named_node_for_range({ row, prev_col, row, prev_col })
	if not node then
		return false
	end

	local opts = get_config_opts_for_buf("comment_opts", buf)
	return opts.matcher(node, buf)
end

-- Toggle the 'w' formatoption, which allows writing simple multi-line
-- lists etc... when 'r' is also set, at the expense of not reflowing the
-- whole paragraph when editing earlier lines.
M.toggle_paragraph_wrap = function()
	-- Note: needs to support:
	--  - M.opts.formatoptions = ""
	--  - M.opts.formatoptions = { add = "", remove = "" }
	if vim.opt.formatoptions:get().w then
		vim.opt.formatoptions:remove("w")
		if type(M.opts.comment_opts.formatoptions) == "string" then
			M.opts.comment_opts.formatoptions = string.gsub(M.opts.comment_opts.formatoptions, "w", "")
		else
			M.opts.comment_opts.formatoptions.add = string.gsub(M.opts.comment_opts.formatoptions.add, "w", "")
		end
	else
		vim.opt.formatoptions:append("w")
		if type(M.opts.comment_opts.formatoptions) == "string" then
			M.opts.comment_opts.formatoptions = M.opts.comment_opts.formatoptions .. "w"
		else
			M.opts.comment_opts.formatoptions.add = M.opts.comment_opts.formatoptions.add .. "w"
		end
	end
	M.status = status_string()
end

-- Convenience function for development, that reloads the main plugin
-- module.
M.reload = function()
	local name = "nvim-comment-wrap"
	M.disable()
	package.loaded[name] = nil
	require(name).enable()
end

return M
