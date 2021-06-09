#!/bin/sh

exec socat UNIX-LISTEN:/var/run/discord-ipc-0,fork,group=discord,umask=007 EXEC:"npiperelay.exe -ep -s //./pipe/discord-ipc-0",nofork
