" Define autocommands to handle auto-update events
function presence#SetAutoCmds()
    augroup presence_events
        autocmd!
        if exists("g:presence_auto_update") && g:presence_auto_update
            autocmd BufRead * lua package.loaded.presence:update()
        endif
    augroup END
endfunction
