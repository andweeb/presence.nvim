" Define autocommands to handle auto-update events
function presence#SetAutoCmds()
    augroup presence_events
        autocmd!
        if exists("g:presence_auto_update") && g:presence_auto_update
            autocmd BufRead * lua package.loaded.presence:update()
            autocmd InsertEnter * lua package.loaded.presence:update(nil, true)
            autocmd VimLeavePre * lua package.loaded.presence:unregister_self()
        endif
    augroup END
endfunction
