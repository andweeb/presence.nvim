<img src="https://gist.githubusercontent.com/andweeb/df3216345530234289b87cf5080c2c60/raw/8de399cfed82c137f793e9f580027b5246bc4379/presence.nvim.png" alt="presence.nvim">&#x200B;

**[Features](#features)** | **[Installation](#installation)** | **[Configuration](#configuration)** | **[Troubleshooting](#troubleshooting)** | **[Contributing](#contributing)**

> Discord [Rich Presence](https://discord.com/rich-presence) plugin for Neovim

<img src="https://gist.githubusercontent.com/andweeb/df3216345530234289b87cf5080c2c60/raw/4b07351547ae9a6bfdcbc1f915889b90a5349242/presence-demo.gif" alt="demo.gif">

## Features
* Simple and unobtrusive
* Support for macOS, Linux, and Windows[\*](#notes)
* No Python/Node providers (or CoC) required
* Startup time is fast(er than other Rich Presence plugins, by [kind of a lot](https://github.com/andweeb/presence.nvim/wiki/Plugin-Comparisons))
* Written in Lua and configurable in Lua (but also configurable in VimL if you want)

## Installation
Use your favorite plugin manager
* [packer](https://github.com/wbthomason/packer.nvim): `use 'andweeb/presence.nvim'`
* [vim-plug](https://github.com/junegunn/vim-plug): `Plug 'andweeb/presence.nvim'`

#### Notes
* Requires [Neovim nightly](https://github.com/neovim/neovim/releases/tag/nightly) (0.5)
* Windows is [partially supported](https://github.com/andweeb/presence.nvim/projects/1#card-60537963), WSL is [not yet supported](https://github.com/andweeb/presence.nvim/projects/1#card-60537961)

## Configuration
Rich Presence works right out of the box after installation, so configuration is optional. For those that do want to override default behaviors, however, configuration options are available in either Lua or VimL.

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

## Troubleshooting
* Ensure that Discord is running
* Ensure that your Neovim version is on v0.5
* Ensure Game Activity is enabled in your Discord settings
* Enable logging and inspect the logs after opening a buffer
    * Set the `log_level` setup option or `g:presence_log_level` to `"debug"`
    * Load a file and see the logs with `:messages`
* If there is a `Failed to get Discord IPC socket` error, your particular OS may not yet be supported
    * Create a [new issue](https://github.com/andweeb/presence.nvim/issues/new) if one does not exist for your OS yet

## Contributing
Pull requests are very welcome, feel free to open an issue to work on any of the open [todo items](https://github.com/andweeb/presence.nvim/projects/1?add_cards_query=is%3Aopen)!

Asset additions and changes are also welcome! Supported file types can be found in [`file_assets.lua`](lua/presence/file_assets.lua) and their referenced asset files can be found [in this folder](https://www.dropbox.com/sh/j8913f0gav3toeh/AADxjn0NuTprGFtv3Il1Pqz-a?dl=0).
