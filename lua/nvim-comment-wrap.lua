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

-- A general-purpose matcher that simply detemrines if it is a comment
-- node or not.
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

-- State Management --

-- Tracks whether we should be doing anythign
local enabled = false

-- Previoius values for options managed by the plugin
local prev = nil

-- Captures the current values for options managed by the plugin into the
-- prev variable.
local function capture_opts()
	prev = {
		tw = vim.bo.textwidth,
		com = vim.bo.comments,
		-- Use 'o' to avoid working with the table form by reference
		fo = vim.o.formatoptions,
	}
end

-- Restores the values of optiodns managed by the plugin (requires that
-- capture_opts has been called prior).
local function restore_opts()
	if prev == nil then
		return
	end
	vim.bo.textwidth = prev.tw
	vim.o.formatoptions = prev.fo
	vim.bo.comments = prev.com
end

-- Whether or not we were in comment the last time we ran, avoids work
-- when the current node hasn't changed.
local last_in_comment = nil

-- autocmd management --

local cmd_group = vim.api.nvim_create_augroup("nvim_comment_wrap", {})

-- Convenience to create an autocmd under the plugins group
local function create_cw_autocmd(event, callback)
	local opts = {
		callback = callback,
		group = cmd_group,
	}
	vim.api.nvim_create_autocmd(event, opts)
end

local function insert_enter()
	capture_opts()
	last_in_comment = nil
	M.update()
end

local function insert_leave()
	restore_opts()
	M.status = ""
	prev = nil
	last_in_comment = nil
end

local function cursor_moved_i()
	M.update()
end

-- Public interface

-- Useful for including in status lines etc... contains a wrap icon, with
-- the current text width setting when the plugin has modified wrapping
-- mode due to the cursor being inside a comment. Empty at other times.
M.status = ""

-- The default configuration for the plugin
M.default_opts = {
	textwidth = 74,
	formatoptions = {
		add = "tca",
		remove = "l",
	},
	matcher = M.matchers.generic,
	filetype = {
		python = {
			comments = 'b:#,b:##,sfl-3:""",mb: ,e-3:"""',
			matcher = M.matchers.python,
		},
	},
}

M.get_comment_opts = function(buf)
	if not buf then
		buf = vim.api.nvim_get_current_buf()
	end

	local opts = {
		textwidth = M.opts.textwidth,
		formatoptions = M.opts.formatoptions,
		comments = M.opts.comments,
		matcher = M.opts.matcher,
	}

	local ft = vim.bo[buf].filetype
	local ft_opts = M.opts.filetype[ft]
	if ft_opts then
		opts = vim.tbl_deep_extend("force", opts, ft_opts)
	end

	return opts
end

M.setup = function(opts)
	opts = opts or {}
	M.opts = vim.tbl_deep_extend("force", M.default_opts, opts)
	M.enable()
end

M.enable = function()
	if enabled then
		return
	end

	if not M.opts then
		M.opts = vim.tbl_deep_extend("force", {}, M.default_opts)
	end

	vim.api.nvim_clear_autocmds({ group = cmd_group })
	create_cw_autocmd("InsertEnter", insert_enter)
	create_cw_autocmd("InsertLeavePre", insert_leave)
	create_cw_autocmd("CursorMovedI", M.utils.debounce(cursor_moved_i, 100))
	enabled = true
end

M.disable = function()
	if not enabled then
		return
	end
	vim.api.nvim_clear_autocmds({ group = cmd_group })
	enabled = false
end

-- Updates options based on the current cursor position
M.update = function()
	if not enabled then
		return
	end

	local in_comment = M.in_comment()
	if in_comment == last_in_comment then
		return
	end

	if in_comment == true then
		local opts = M.get_comment_opts()

		vim.bo.textwidth = opts.textwidth

		if opts.comments and opts.comments ~= "" then
			vim.bo.comments = opts.comments
		end

		if opts.formatoptions then
			if opts.formatoptions.add and opts.formatoptions.add ~= "" then
				vim.opt.formatoptions:append(opts.formatoptions.add)
			end
			if opts.formatoptions.remove and opts.formatoptions.remove ~= "" then
				vim.opt.formatoptions:remove(opts.formatoptions.remove)
			end
		end
	else
		restore_opts()
	end

	if in_comment == true then
		M.status = " " .. tostring(vim.bo.tw)
	else
		M.status = ""
	end

	last_in_comment = in_comment
end

-- Returns whether the cursor is currently within a comment, or nil in the
-- case of any treesitter errors.
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

	local opts = M.get_comment_opts(buf)
	return opts.matcher(node, buf)
end

-- Convenience function for development, that reloads the plugin.
M.reload = function()
	M.disable()
	package.loaded["nvim-comment-wrap"] = nil
	require("nvim-comment-wrap").enable()
end

return M
