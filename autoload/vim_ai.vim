call vim_ai_config#load()

let s:plugin_root = expand('<sfile>:p:h:h')
let s:complete_py = s:plugin_root . "/py/complete.py"
let s:chat_py = s:plugin_root . "/py/chat.py"
let s:roles_py = s:plugin_root . "/py/roles.py"

" remembers last command parameters to be used in AIRedoRun
let s:last_is_selection = 0
let s:last_firstline = 1
let s:last_lastline = 1
let s:last_instruction = ""
let s:last_command = ""
let s:last_config = {}

let s:scratch_buffer_name = ">>> AI chat"

function! s:StartsWith(longer, shorter) abort
  return a:longer[0:len(a:shorter)-1] ==# a:shorter
endfunction

function! s:GetLastScratchBufferName()
  let l:all_buffer_names = map(map(filter(copy(getbufinfo()), 'v:val.listed'), 'v:val.bufnr'), 'bufname(v:val)')
  let l:buffer_name = -1
  for l:name in l:all_buffer_names
    if s:StartsWith(l:name, s:scratch_buffer_name)
      let l:buffer_name = l:name
    endif
  endfor
  return l:buffer_name
endfunction

" Configures ai-chat scratch window.
" - scratch_buffer_keep_open = 0
"   - opens new ai-chat every time
"   - excludes buffer from buffer list
" - scratch_buffer_keep_open = 1
"   - opens last ai-chat buffer
function! vim_ai#MakeScratchWindow()
  let l:keep_open = g:vim_ai_chat['ui']['scratch_buffer_keep_open']
  let l:last_scratch_buffer_name = s:GetLastScratchBufferName()
  if l:keep_open && bufexists(l:last_scratch_buffer_name) && !a:force_new
    let l:current_buffer = bufnr('%')
    " reuse chat buffer
    execute "buffer " . l:last_scratch_buffer_name
    " close new buffer that was created by l:open_cmd
    execute "bd " . l:current_buffer
    return
  endif

  setlocal buftype=nofile
  setlocal noswapfile
  setlocal ft=aichat
  setlocal bufhidden=hide
  if bufexists(s:scratch_buffer_name)
    " spawn another window if chat already exist
    let l:index = 2
    while bufexists(s:scratch_buffer_name . " " . l:index)
      let l:index += 1
    endwhile
    execute "file " . s:scratch_buffer_name . " " . l:index
  else
    execute "file " . s:scratch_buffer_name
  endif
endfunction

function! s:MakeSelectionPrompt(selection, instruction, config)
  let l:selection = ""
  if a:instruction == ""
    let l:selection = a:selection
  elseif !empty(a:selection)
    let l:boundary = a:config['options']['selection_boundary']
    if l:boundary != "" && match(a:selection, l:boundary) == -1
      " NOTE: surround selection with boundary (e.g. #####) in order to eliminate empty responses
      let l:selection = l:boundary . "\n" . a:selection . "\n" . l:boundary
    else
      let l:selection = a:selection
    endif
  endif
  return l:selection
endfunction

function! s:MakePrompt(selection, instruction, config)
  let l:instruction = trim(a:instruction)
  let l:delimiter = l:instruction != "" && a:selection != "" ? ":\n" : ""
  let l:selection = s:MakeSelectionPrompt(a:selection, l:instruction, a:config)
  return join([l:instruction, l:delimiter, l:selection], "")
endfunction

let s:is_handling_paste_mode = 0

function! s:set_paste(config)
  if !a:config['ui']['paste_mode'] | return | endif
  if &paste | return | endif
  set paste
  let g:vim_ai_paste = 1
endfunction

function! s:GetSelectionOrRange(is_selection, ...)
  if a:is_selection
    return s:GetVisualSelection()
  else
    return trim(join(getline(a:1, a:2), "\n"))
  endif
endfunction

function! s:SelectSelectionOrRange(is_selection, ...)
  if a:is_selection
    execute "normal! gv"
  else
    execute 'normal!' . a:1 . 'GV' . a:2 . 'G'
  endif
endfunction

function! s:GetVisualSelection()
  let [line_start, column_start] = getpos("'<")[1:2]
  let [line_end, column_end] = getpos("'>")[1:2]
  let lines = getline(line_start, line_end)
  if len(lines) == 0
    return ''
  endif
  " The exclusive mode means that the last character of the selection area is not included in the operation scope.
  let lines[-1] = lines[-1][: column_end - (&selection == 'inclusive' ? 1 : 2)]
  let lines[0] = lines[0][column_start - 1:]
  return join(lines, "\n")
endfunction

" Complete prompt
" - config       - function scoped vim_ai_complete config
" - a:1          - optional instruction prompt
" - a:2          - optional selection pending (to override g:vim_ai_is_selection_pending)
function! vim_ai#AIRun(config, ...) range abort
  let l:config = vim_ai_config#ExtendDeep(g:vim_ai_complete, a:config)
  let l:instruction = a:0 > 0 ? a:1 : ""
  " l:is_selection used in Python script
  if a:0 > 1
    let l:is_selection = a:2
  else
    let l:is_selection = g:vim_ai_is_selection_pending &&
          \ a:firstline == line("'<") && a:lastline == line("'>")
  endif

  let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  let l:prompt = s:MakePrompt(l:selection, l:instruction, l:config)

  let s:last_command = "complete"
  let s:last_config = a:config
  let s:last_instruction = l:instruction
  let s:last_is_selection = l:is_selection
  let s:last_firstline = a:firstline
  let s:last_lastline = a:lastline

  if empty(trim(getline('.')))
    execute "normal! " . a:lastline . "GA"
  else
    execute "normal! " . a:lastline . "Go"
  endif
  try
    call s:set_paste(l:config)
    execute "py3file " . s:complete_py
  finally
    if exists('g:vim_ai_paste')
      unlet g:vim_ai_paste
      set nopaste
    endif
  endtry
  execute "normal! " . a:lastline . "G"
endfunction

" Edit prompt
" - config       - function scoped vim_ai_edit config
" - a:1          - optional instruction prompt
" - a:2          - optional selection pending (to override g:vim_ai_is_selection_pending)
function! vim_ai#AIEditRun(config, ...) range abort
  let l:config = vim_ai_config#ExtendDeep(g:vim_ai_edit, a:config)
  let l:instruction = a:0 > 0 ? a:1 : ""
  " l:is_selection used in Python script
  if a:0 > 1
    let l:is_selection = a:2
  else
    let l:is_selection = g:vim_ai_is_selection_pending &&
          \ a:firstline == line("'>") && a:lastline == line("'>")
  endif
  let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  let l:prompt = s:MakePrompt(l:selection, l:instruction, l:config)

  let s:last_command = "edit"
  let s:last_config = a:config
  let s:last_instruction = l:instruction
  let s:last_is_selection = l:is_selection
  let s:last_firstline = a:firstline
  let s:last_lastline = a:lastline

  call s:SelectSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  execute "normal! c"
  try
    call s:set_paste(l:config)
    execute "py3file " . s:complete_py
  finally
    if exists('g:vim_ai_paste')
      unlet g:vim_ai_paste
      set nopaste
    endif
  endtry
endfunction

" - a:1          - optional switch to open new chat window
function! s:ReuseOrCreateChatWindow(config, ...)
  if a:0 > 0 && a:1 == 1
    " open new chat window if no active buffer found
    let l:open_conf = a:config['ui']['open_chat_command']
    call s:OpenChatWindow(l:open_conf)
    return
  end

  if &filetype != 'aichat'
    " reuse chat in active window or tab
    let l:chat_win_ids = win_findbuf(bufnr(s:scratch_buffer_name))
    if !empty(l:chat_win_ids)
      call win_gotoid(l:chat_win_ids[0])
      return
    endif

    " reuse .aichat file on the same tab
    let buffer_list_tab = tabpagebuflist(tabpagenr())
    let buffer_list_tab = filter(buffer_list_tab, 'getbufvar(v:val, "&filetype") ==# "aichat"')
    if len(buffer_list_tab) > 0
      call win_gotoid(win_findbuf(buffer_list_tab[0])[0])
      return
    endif

    " reuse any .aichat buffer in the session
    let buffer_list = []
    for i in range(tabpagenr('$'))
      call extend(buffer_list, tabpagebuflist(i + 1))
    endfor
    let buffer_list = filter(buffer_list, 'getbufvar(v:val, "&filetype") ==# "aichat"')
    if len(buffer_list) > 0
      call win_gotoid(win_findbuf(buffer_list[0])[0])
      return
    endif

    " open new chat window if no active buffer found
    let l:open_conf = a:config['ui']['open_chat_command']
    call s:OpenChatWindow(l:open_conf, 0)
  endif
endfunction

" Start and answer the chat
" - uses_range   - true if range passed
" - config       - function scoped vim_ai_chat config
" - a:1          - optional instruction prompt
" - a:2          - optional switch to open new chat window
function! vim_ai#AIChatRun(uses_range, config, ...) range
  let l:config = vim_ai_config#ExtendDeep(g:vim_ai_chat, a:config)
  let l:instruction = ""
  " l:is_selection used in Python script
  if a:uses_range
    let l:is_selection = g:vim_ai_is_selection_pending &&
          \ a:firstline == line("'<") && a:lastline == line("'>")
    let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  else
    let l:is_selection = 0
    let l:selection = ''
  endif

  call s:ReuseOrCreateChatWindow(l:config, exists('a:2') && a:2 == 1)

    let l:prompt = ""
    if a:0 > 0 || a:uses_range
      let l:instruction = a:0 > 0 ? a:1 : ""
      let l:prompt = s:MakePrompt(l:selection, l:instruction, l:config)
    endif

    let s:last_command = "chat"
    let s:last_config = a:config

  try
    call s:set_paste(l:config)
    execute "py3file " . s:chat_py
  finally
    if exists('g:vim_ai_paste')
      unlet g:vim_ai_paste
      set nopaste
    endif
  endtry
endfunction

" Start a new chat
" a:1 - optional preset shorcut (below, right, tab)
function! vim_ai#AINewChatRun(uses_range, config, ...) range
  let l:instruction = a:0 > 0? a:1 : ''
  let l:config = a:config

  if l:instruction =~# '^\v^%(below|right|tab)$'
    let l:instruction = ''
    let l:open_conf = "preset_" . a:1
    if !has_key(l:config, 'ui') | let l:config['ui'] = {} | endif
    " override l:config['ui']['open_chat_command']
    let l:config['ui']['open_chat_command'] = "preset_" . a:1
  else
    if !has_key(l:config, 'ui') | let l:config['ui'] = {} | endif
    if !has_key(l:config['ui'], 'open_chat_command')
      let l:config['ui']['open_chat_command'] = g:vim_ai_chat['ui']['open_chat_command']
    endif
  endif

  exe a:firstline.','.a:lastline.'call vim_ai#AIChatRun(a:uses_range, l:config, l:instruction, 1)'
endfunction

" Repeat last AI command
function! vim_ai#AIRedoRun() abort
  undo
  if s:last_command ==# "complete"
    exe s:last_firstline.",".s:last_lastline . "call vim_ai#AIRun(s:last_config, s:last_instruction, s:last_is_selection)"
  elseif s:last_command ==# "edit"
    exe s:last_firstline.",".s:last_lastline . "call vim_ai#AIEditRun(s:last_config, s:last_instruction, s:last_is_selection)"
  elseif s:last_command ==# "chat"
    " chat does not need prompt, all information are in the buffer already
    call vim_ai#AIChatRun(0, s:last_config)
  endif
endfunction

function! vim_ai#RoleCompletion(A,L,P) abort
  execute "py3file " . s:roles_py
  call map(l:role_list, '"/" . v:val')
  return filter(l:role_list, 'v:val =~ "^' . a:A . '"')
endfunction
