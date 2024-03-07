call vim_ai_config#load()

let s:plugin_root = expand('<sfile>:p:h:h')
let s:complete_py = s:plugin_root . "/py/complete.py"
let s:chat_py = s:plugin_root . "/py/chat.py"

" remembers last command parameters to be used in AIRedoRun
let s:last_is_selection = 0
let s:last_firstline = 1
let s:last_lastline = 1
let s:last_instruction = ""
let s:last_command = ""
let s:last_config = {}

let s:scratch_buffer_name = ">>> AI chat"

" Configures ai-chat scratch window.
" - scratch_buffer_keep_open = 0
"   - opens new ai-chat every time
" - scratch_buffer_keep_open = 1
"   - opens last ai-chat buffer
"   - keeps the buffer in the buffer list
function! vim_ai#MakeScratchWindow()
  let l:keep_open = g:vim_ai_chat['ui']['scratch_buffer_keep_open']
  if l:keep_open && bufexists(s:scratch_buffer_name)
    " reuse chat buffer
    execute "buffer " . s:scratch_buffer_name
    return
  endif
  setlocal buftype=nofile
  setlocal noswapfile
  setlocal ft=aichat
  if l:keep_open
    setlocal bufhidden=hide
  else
    setlocal bufhidden=wipe
  endif
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
  if empty(a:instruction)
    let l:selection = a:selection
  elseif !empty(a:selection)
    let l:boundary = a:config['options']['selection_boundary']
    if !empty(l:boundary) && match(a:selection, l:boundary) == -1
      " NOTE: surround selection with boundary (e.g. #####) in order to
      " eliminate empty responses
      let l:selection = l:boundary . "\n" . a:selection . "\n" . l:boundary
    else
      let l:selection = a:selection
    endif
  endif
  return l:selection
endfunction

function! s:MakePrompt(config, instruction, selection)
  let l:instruction = trim(a:instruction)
  let l:delimiter = empty(l:instruction) || empty(a:selection) ? "" : ":\n"
  let l:selection = s:MakeSelectionPrompt(a:selection, l:instruction, a:config)
  return join([l:instruction, l:delimiter, l:selection], "")
endfunction

function! s:OpenChatWindow(open_conf)
  let l:open_cmd = has_key(g:vim_ai_open_chat_presets, a:open_conf)
        \ ? g:vim_ai_open_chat_presets[a:open_conf]
        \ : a:open_conf
  execute l:open_cmd
endfunction

function! s:set_paste(config)
  if a:config['ui']['paste_mode']
    setlocal paste
  endif
endfunction

function! s:set_nopaste(config)
  if a:config['ui']['paste_mode']
    setlocal nopaste
  endif
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
  let l:config = a:config
  let l:instruction = a:0 > 0 ? trim(a:1) : ''

  if l:instruction =~# '^/'
    let i = match(l:instruction . ' ', '\s')
    let role = l:instruction[1:i-1]
    let l:instruction = l:instruction[i:-1]
    let l:config = vim_ai_roles#set_config_role(l:config, role)
  endif

  let s:last_config = deepcopy(l:config)

  let l:config = vim_ai_config#ExtendDeep(deepcopy(g:vim_ai_complete), l:config)

  " used for getting in Python script
  let l:is_selection = a:0 > 1 ? a:2 : g:vim_ai_is_selection_pending
  let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)

  let l:prompt = s:MakePrompt(l:config, l:instruction, l:selection)

  let s:last_instruction = l:instruction
  let s:last_is_selection = l:is_selection
  let s:last_command = 'complete'
  let s:last_firstline = a:firstline
  let s:last_lastline = a:lastline

  let l:cursor_on_empty_line = empty(getline('.'))
  call s:set_paste(l:config)
  if l:cursor_on_empty_line
    execute "normal! " . a:lastline . "GA"
  else
    execute "normal! " . a:lastline . "Go"
  endif
  execute 'py3file ' . s:complete_py
  execute "normal! " . a:lastline . "G"
  call s:set_nopaste(l:config)
endfunction

" Edit prompt
" - config       - function scoped vim_ai_edit config
" - a:1          - optional instruction prompt
" - a:2          - optional selection pending (to override g:vim_ai_is_selection_pending)
function! vim_ai#AIEditRun(config, ...) range abort
  let l:config = a:config
  let l:instruction = a:0 > 0 ? trim(a:1) : ''

  if l:instruction =~# '^/'
    let i = match(l:instruction . ' ', '\s')
    let role = l:instruction[1:i-1]
    let l:instruction = l:instruction[i:-1]
    let l:config = vim_ai_roles#set_config_role(l:config, role)
  endif

  let s:last_config = deepcopy(l:config)

  let l:config = vim_ai_config#ExtendDeep(deepcopy(g:vim_ai_edit), l:config)

  " used for getting in Python script
  let l:is_selection = a:0 > 1 ? a:2 : g:vim_ai_is_selection_pending
  let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)

  let l:prompt = s:MakePrompt(l:config, l:instruction, l:selection)

  let s:last_instruction = l:instruction
  let s:last_is_selection = l:is_selection
  let s:last_command = 'edit'
  let s:last_firstline = a:firstline
  let s:last_lastline = a:lastline

  call s:set_paste(l:config)
  call s:SelectSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  execute "normal! c"
  execute 'py3file ' . s:complete_py
  call s:set_nopaste(l:config)
endfunction

" Start and answer the chat
" - uses_range   - true if range passed
" - config       - function scoped vim_ai_chat config
" - a:1          - optional instruction prompt
function! vim_ai#AIChatRun(uses_range, config, ...) range abort
  " l:is_selection used in Python script
  if a:uses_range
    let l:is_selection = g:vim_ai_is_selection_pending
    let l:selection = s:GetSelectionOrRange(l:is_selection, a:firstline, a:lastline)
  else
    let l:is_selection = 0
    let l:selection = ''
  endif

  let l:config = a:config

  if a:0 > 0
    let l:instruction = trim(a:1)
    if l:instruction =~# '^/'
      let i = match(l:instruction . ' ', '\s')
      let role = l:instruction[1:i-1]
      let l:instruction = l:instruction[i:-1]
      let l:config = vim_ai_roles#set_config_role(l:config, role)
    endif
  else
    let l:instruction = ""
  endif

  let s:last_config = deepcopy(l:config)
  let l:config = vim_ai_config#ExtendDeep(deepcopy(g:vim_ai_chat), l:config)

  if a:0 > 0 || a:uses_range
    let l:prompt = s:MakePrompt(l:config, l:instruction, l:selection)
  else
    let l:prompt = ""
  endif

  let s:last_command = 'chat'

  call s:set_paste(l:config)
  if &filetype != 'aichat'
    let l:chat_win_ids = win_findbuf(bufnr(s:scratch_buffer_name))
    if !empty(l:chat_win_ids)
      " TODO: look for first active chat buffer. If .aichat file is used,
      " then reuse chat in active window
      call win_gotoid(l:chat_win_ids[0])
    else
      " open new chat window
      let l:open_conf = l:config['ui']['open_chat_command']
      call s:OpenChatWindow(l:open_conf)
    endif
  endif

  execute 'py3file ' . s:chat_py
  call s:set_nopaste(l:config)
endfunction

" Start a new chat
" a:1 - optional preset shorcut (below, right, tab)
function! vim_ai#AINewChatRun(...) abort
  let l:open_conf = a:0 > 0 ? "preset_" . a:1 : g:vim_ai_chat['ui']['open_chat_command']
  call s:OpenChatWindow(l:open_conf)
  call vim_ai#AIChatRun(0, {})
endfunction

" Repeat last AI command
function! vim_ai#AIRedoRun()
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
