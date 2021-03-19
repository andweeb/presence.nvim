<img src="https://gist.githubusercontent.com/andweeb/df3216345530234289b87cf5080c2c60/raw/8de399cfed82c137f793e9f580027b5246bc4379/presence.nvim.png" height="120" alt="presence.nvim">&#x200B;
===

Discord [Rich Presence](https://discord.com/rich-presence) plugin for Neovim.

<img src="https://gist.githubusercontent.com/andweeb/df3216345530234289b87cf5080c2c60/raw/4b07351547ae9a6bfdcbc1f915889b90a5349242/presence-demo.gif" alt="demo.gif">

## Features
* Simple and unobtrusive
* No Python/Node providers (or CoC) required
* Startup time is fast(er than other Rich Presence plugins, by [kind of a lot](https://github.com/andweeb/presence.nvim/wiki/Plugin-Comparisons))
* Written in Lua and configurable in Lua (but also configurable in VimL if you want)

## Installation
Use your favorite plugin manager
* [packer](https://github.com/wbthomason/packer.nvim): `use 'andweeb/presence.nvim'`
* [vim-plug](https://github.com/junegunn/vim-plug): `Plug 'andweeb/presence.nvim'`

#### Notes
* Requires [Neovim nightly (v0.5)](https://github.com/neovim/neovim/releases/tag/nightly)
* Linux and macOS is supported, but Windows is **WIP** ([help wanted!](#contributing))

## Configuration
Rich Presence works right out of the box after installation. To override default behaviors, configuration options are available in both Lua and VimL.

### Lua
Require the plugin and call `setup` with a config table with any of the following keys:

```lua
Presence = require("presence"):setup({
    -- This config table shows all available config options with their default values
    auto_update       = true,                       -- Update activity based on autocmd events (if `false`, map or manually execute `:lua Presence:update()`)
    editing_text      = "Editing %s",               -- Editing format string (either string or function(filename: string|nil, buffer: string): string)
    workspace_text    = "Working on %s",            -- Workspace format string (either string or function(git_project_name: string|nil, buffer: string): string)
    neovim_image_text = "The One True Text Editor", -- Text displayed when hovered over the Neovim image
    main_image        = "neovim",                   -- Main image display (either "neovim" or "file")
    client_id         = "793271441293967371",       -- Use your own Discord application client id (not recommended)
    log_level         = nil,                        -- Log messages at or above this level (one of the following: "debug", "info", "warn", "error")
    debounce_timeout  = 15,                         -- Number of seconds to debounce TextChanged events (or calls to `:lua Presence:update(<buf>, true)`)
})
```

### VimL
Or if global variables are more your thing, you can use any of the following instead:
```viml
let g:presence_auto_update       = 1
let g:presence_editing_text      = "Editing %s"
let g:presence_workspace_text    = "Working on %s"
let g:presence_neovim_image_text = "The One True Text Editor"
let g:presence_main_image        = "neovim"
let g:presence_client_id         = "793271441293967371"
let g:presence_log_level
let g:presence_debounce_timeout  = 15
```

## Contributing
Pull requests are very welcome, feel free to open an issue! Here some open todo items:
- [x] Manage workspace state across multiple nvim instances (e.g. tmux)
- [x] Set activity on other autocommands (`TextChanged`, `VimLeavePre`)
- [ ] Set idle activity (track using `CursorMoved`)
- [ ] Use named pipes to support Windows
- [ ] Expose file assets table as a configurable option
- [ ] Manage activity properly in buffers in windows and tabs
- [ ] Retry connection after initial setup or a closed pipe (i.e. after quitting Discord app)
- [ ] Attempt to connect to a range of pipes from `discord-ipc-0` to `discord-ipc-9` (see [note](https://github.com/discord/discord-rpc/blob/master/documentation/hard-mode.md#notes))

Discord asset additions and changes are also welcome! Supported file types can be found in [file_assets.lua](lua/presence/file_assets.lua) and their assets can be found [in this folder](https://www.dropbox.com/sh/j8913f0gav3toeh/AADxjn0NuTprGFtv3Il1Pqz-a?dl=0).
