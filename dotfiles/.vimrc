"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""" => Editor Basic Behavior <= """
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
syntax on                         " Enable syntax highlighting.
filetype plugin indent on         " Enable file type based indentation.
colorscheme murphy                " Change a colorscheme.

set number                        " Display column numbers.
set autoindent                    " Respect indentation when starting a new line.
set expandtab                     " Expand tabs to spaces. Essential in Python.
set cursorline                    " Highlight the line where the cursor is located in Vim.
set tabstop=4                     " Number of spaces tab is counted for.
set shiftwidth=4                  " Number of spaces to use for autoindent.
set backspace=2                   " Fix backspace behavior on most terminals.
set foldmethod=indent             " Indentation-based folding.
set wildmenu                      " Enable enhanced tab autocomplete.
set wildmode=list:longest,full    " Complete till longest string, then open menu.
set hlsearch                      " Highlight search results.
set incsearch                     " Search as you type.
set ignorecase                    " Make all search operations case-insensitive.
set smartcase                     " Enhance the ignorecase option by making searches case-sensitive if the search pattern contains uppercase letters.
set clipboard=unnamed,unnamedplus " Copy into system (*, +) registers.

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""" => Advance Monvement and Navigation <= """
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Map arrow keys nothing so I can get used to hjkl-style movement.
noremap <up> <nop>
noremap <down> <nop>
noremap <left> <nop>
noremap <right> <nop>

" Immediately add a closing quotes or braces in insert mode.
inoremap ' ''<esc>i
inoremap " ""<esc>i
inoremap ( ()<esc>i
inoremap { {}<esc>i
inoremap [ []<esc>i

" MapLeader Mappings
let mapleader = ','       " Map the leader key to a comma.
noremap \ ,
noremap <leader><CR> :nohlsearch<CR> " Search
noremap <leader>w :w<CR>  " Save a file with leader-w.
noremap <leader>q :q<CR>  " Save a file with leader-w.

" delete without yanking
nnoremap <leader>d "_d
vnoremap <leader>d "_d

" K/J keys for 5 times k/j (faster navigation)
noremap <silent> K 5k
noremap <silent> J 5j
" Faster in-line navigation
noremap W 5w
noremap B 5b

" N key: go to the start of the line
noremap <silent> N ^
" I key: go to the end of the line
noremap <silent> I $

" split the screens to up (horizontal), down (horizontal), left (vertical), right (vertical)
noremap <c-w>sh :set nosplitright<CR>:vsplit<CR>:set splitright<CR>
noremap <c-w>sj :set splitbelow<CR>:split<CR>
noremap <c-w>sk :set nosplitbelow<CR>:split<CR>:set splitbelow<CR>
noremap <c-w>sl :set splitright<CR>:vsplit<CR>
" Resize splits with arrow keys
noremap <silent> <c-w><up> :res +5<CR>
noremap <silent> <c-w><down> :res -5<CR>
noremap <silent> <c-w><left> :vertical resize-5<CR>
noremap <silent> <c-w><right> :vertical resize+5<CR>

"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""
""" => Plugin Management <= """
"""""""""""""""""""""""""""""""""""""""""""""""""""""""""""""

" Install vim-plug if it's not already installed (Unix-only).
if empty(glob('~/.vim/autoload/plug.vim'))
  silent !curl -fLo ~/.vim/autoload/plug.vim --create-dirs
    \ https://raw.github.com/junegunn/vim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $MYVIMRC
endif

call plug#begin()  " Manage plugins with vim-plug.

Plug 'scrooloose/nerdtree'
Plug 'tpope/vim-vinegar'
Plug 'easymotion/vim-easymotion'
Plug 'mbbill/undotree'

Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'yggdroot/indentline'
Plug 'tpope/vim-commentary'

" The Language Server Protocol (LSP)
Plug 'prabirshrestha/vim-lsp'
Plug 'mattn/vim-lsp-settings'
Plug 'prabirshrestha/asyncomplete.vim'
Plug 'prabirshrestha/asyncomplete-lsp.vim'

call plug#end()

" NERDTree Config
nnoremap <leader>g :NERDTreeToggle<CR>
nnoremap <leader>v :NERDTreeFind<CR>

" Easymotion Config
nnoremap ss <Plug>(easymotion-s2)

" UndoTree Config
nnoremap <F5> :UndotreeToggle<CR>

" Go LSP Config
autocmd BufWritePre *.go call execute('LspCodeActionSync source.organizeImports')
autocmd BufWritePre *.go LspDocumentFormatSync