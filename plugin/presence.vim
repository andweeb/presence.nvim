" Define autocommands to handle auto-update events
augroup presence_events
    autocmd!
    if g:presence_auto_update
        autocmd BufRead * lua package.loaded.presence:update()
    endif
augroup END

" Fallback to setting up the plugin automatically
if !exists("g:presence_has_setup")
lua << EOF
    local Presence = require("presence"):setup()
    Presence.log:debug("Custom setup not detected, plugin set up using defaults")
EOF
endif
