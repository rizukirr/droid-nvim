" Syntax highlighting for adb logcat output in droid.nvim.
"
" Targets the default `adb logcat -v threadtime` format:
"   2024-01-15 10:23:45.123  1234  5678 I MyTag: message
"
" Also handles the time-only variant (no leading date) and the
" `--------- beginning of <buffer>` markers adb emits between buffers.

if exists("b:current_syntax")
    finish
endif

" Date (optional) + time + millis at line start.
syntax match logcatTimestamp /\v^%(\d{4}-\d{2}-\d{2}\s+)?\d{2}:\d{2}:\d{2}\.\d+/

" PID and TID columns: the two integers between the timestamp and the
" single-letter level marker.
syntax match logcatPidTid /\v\s+\zs\d+\s+\d+\ze\s+[VDIWEF]\s/

" Single-letter level marker. \zs/\ze anchor the highlight to the letter
" alone so each level can carry its own color.
syntax match logcatLevelV /\v\s\zsV\ze\s+\S+:/
syntax match logcatLevelD /\v\s\zsD\ze\s+\S+:/
syntax match logcatLevelI /\v\s\zsI\ze\s+\S+:/
syntax match logcatLevelW /\v\s\zsW\ze\s+\S+:/
syntax match logcatLevelE /\v\s\zsE\ze\s+\S+:/
syntax match logcatLevelF /\v\s\zsF\ze\s+\S+:/

" Tag: non-whitespace, non-colon run between the level char and the
" colon that separates the tag from the message body.
syntax match logcatTag /\v\s[VDIWEF]\s+\zs[^:[:space:]]+\ze:/

" Buffer-boundary markers from adb logcat.
syntax match logcatHeader /^--------- .*/

" Default highlight links. Users can override with `:hi logcatLevelE …`
" or via their colorscheme.
hi def link logcatTimestamp Comment
hi def link logcatPidTid    Number
hi def link logcatLevelV    Comment
hi def link logcatLevelD    Function
hi def link logcatLevelI    String
hi def link logcatLevelW    WarningMsg
hi def link logcatLevelE    ErrorMsg
hi def link logcatLevelF    ErrorMsg
hi def link logcatTag       Identifier
hi def link logcatHeader    Special

let b:current_syntax = "logcat"
