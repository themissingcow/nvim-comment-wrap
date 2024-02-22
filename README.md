# nvim-comment-wrap

Automatically adjust `textwidth`, `formatoptions` and `commment`
settings when you are typing a code comment.

## Why

70-80 characters is generally suggested as the preferred width for Human
readable text. Many codebases limit comments to this width to help make
them more legible, whilst allowing longer lines for the code itself.

Neovim's text wrap settings generally apply to the whole buffer, with
this plugin (which uses Tree-sitter_, you can specify different settings
when the cursor is inside a comment block.

## Usage

Once installed, the plugin will adjust settings as you navigate.
I highly recommend displaying the status string in your status line till
you get the hang of how it works.

### The `w` format option

By default, the plugin sets the `w` format option for comments. This
stops the entire paragraph being reformatted as line lengths change.
Without it, when working with code, the paragraph movement doesn't
detect the end of the comment and your code gets sucked up into the
text. It also prohibits adding lists to your comments.

The `w` option isn't as useful though if you are editing existing,
simple comments. It can leave unbalanced paragraphs.

The plugin provides a convenience toggle - `<C-k>` that can be used to
toggle `w` in `formatoptions` from normal or insert mode.

## Install

Install using your favorite package manager, eg Lazy:

```lua
{
    'themissingcow/nvim-comment-wrap',
    opts = {}
},
```

The plugin provides a basic status message that can be useful to help
keep track of what has been changed, this shows an integration with
lualine:

```lua
sections = {
  lualine_x = {
    function () return require("nvim-comment-wrap").status end,
    'filename', 'encoding', 'fileformat', 'filetype'},
  }
}

```

## Options

The default options are hopefully fairly useful, but can be customized
as needed.

```lua
local comment_wrap = require("nvim-comment-wrap")
comment_wrap.setup({
    keys = {
        -- Remove/set to empty to disable
        toggle_paragraph_wrap = "<C-k>",
    },
    -- These are applied to all comments, unless overriden by filetype
    -- specific options.
    comment_opts = {
        textwidth = 72,
        formatoptions = {
            add = "tnjwrcaq",
            remove = "l",
        },
        -- formatoptions = "<string>" also supported to replace
        -- comments = ""
        matcher = comment_wrap.matchers.generic,
        filetype = {
            python = {
                comments = 'b:#,b:##,sfl-3:""",mb: ,e-3:"""',
                matcher = comment_wrap.matchers.python,
            },
        },
    },
    global_opts = {
        -- options as per coment_opts, but applied when a file is
        -- opened, this is a convenient way to override what the ft
        -- plugin sets, which otherwise requires autocmds, or additional
        -- files on disk.
        filetype = {},
    },
})
```
