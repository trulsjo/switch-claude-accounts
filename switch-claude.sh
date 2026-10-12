# Use separate claude accounts based on presence of .claude-account file
# 1. Core Logic: Determines the correct configuration directory
# Sets REPLY to the nearest file named $1 in $PWD or an ancestor, or "" if none.
# Pure bash, no subprocesses: this runs before every prompt.
_find_upward() {
    local dir="$PWD"
    REPLY=""
    while :; do
        if [[ -f "$dir/$1" ]]; then
            REPLY="$dir/$1"
            return
        fi
        # Linked git worktree (e.g. ~/.herdr/worktrees/...): its .git is a file
        # "gitdir: <main>/.git/worktrees/<name>", so continue from the main checkout.
        # <main> is C:/..., /..., or relative to the worktree (worktree.useRelativePaths)
        if [[ -f "$dir/.git" ]]; then
            local line="" p="" s re='^gitdir:[[:space:]]*(.+)[/\\]\.git[/\\]worktrees[/\\]'
            local -a parts out=()
            read -r line < "$dir/.git"
            if [[ "$line" =~ $re ]]; then
                p="${BASH_REMATCH[1]//\\//}"
                if [[ "$p" =~ ^([A-Za-z]):/(.*) ]]; then
                    p="/${BASH_REMATCH[1],,}/${BASH_REMATCH[2]}"
                elif [[ "$p" != /* ]]; then
                    p="$dir/$p"
                fi
                # Collapse . and .. so the parent walk below climbs real folders
                IFS=/ read -ra parts <<< "$p"
                for s in "${parts[@]}"; do
                    case "$s" in
                        ''|.) ;;
                        ..) (( ${#out[@]} )) && unset 'out[-1]' ;;
                        *) out+=("$s") ;;
                    esac
                done
                printf -v dir '/%s' "${out[@]}"
                continue
            fi
        fi
        [[ -z "$dir" ]] && return   # "" means we just checked /$1
        dir="${dir%/*}"
    done
}

_get_claude_context() {
    local content=""
    _find_upward .claude-account
    # read trims surrounding whitespace; strip a CRLF file's \r too
    [[ -n "$REPLY" ]] && read -r content < "$REPLY"
    content="${content%$'\r'}"

    if [[ "$content" == "personal" ]]; then
        CLAUDE_ACTIVE_PATH="$HOME/.claude-personal"
        CLAUDE_ACTIVE_TYPE="Personal"
        CLAUDE_ACTIVE_COLOR="36" # Cyan
    else
        # Empty = leave CLAUDE_CONFIG_DIR unset so Claude uses its defaults
        # (~/.claude and ~/.claude.json)
        CLAUDE_ACTIVE_PATH=""
        CLAUDE_ACTIVE_TYPE="Work"
        CLAUDE_ACTIVE_COLOR="32" # Green
    fi
}

# 2. Main Wrapper: Overrides 'claude' command to set environment on execution
claude() {
    _get_claude_context
    if [[ -n "$CLAUDE_ACTIVE_PATH" ]]; then
        CLAUDE_CONFIG_DIR="$CLAUDE_ACTIVE_PATH" command claude "$@"
    else
        (unset CLAUDE_CONFIG_DIR; command claude "$@")
    fi
}

# 3. Helper Function: Quick account configuration for the current folder
switch_claude_account() {
    local target_file="$PWD/.claude-account" choice="${1:-personal}"
    case "$choice" in
        work|personal)
            echo "$choice" > "$target_file"
            _get_claude_context
            echo -e "\e[${CLAUDE_ACTIVE_COLOR}mCreated marker file. This folder and subfolders now use $CLAUDE_ACTIVE_TYPE.\e[0m"
            ;;
        *)
            echo "Usage: switch_claude_account [personal|work]" >&2
            return 1
            ;;
    esac
}
alias use-personal="switch_claude_account personal"

# Set or clear GH_TOKEN from the nearest .gh-token (same lookup as the pwsh profile)
_get_gh_token() {
    local token=""
    _find_upward .gh-token
    if [[ -n "$REPLY" ]]; then
        read -r token < "$REPLY"
        export GH_TOKEN="${token%$'\r'}"
    else
        unset GH_TOKEN
    fi
}

# 4. Prompt: refresh context before every prompt.
# With oh-my-posh (source this AFTER `eval "$(oh-my-posh init bash ...)"`): its
# hook calls set_poshcontext after capturing $? and before rendering, so the
# theme's "text" segment can show {{ .Env.CLAUDE_ACCOUNT }}.
if declare -F _omp_hook > /dev/null; then
    set_poshcontext() {
        _get_gh_token
        _get_claude_context
        export CLAUDE_ACCOUNT="$CLAUDE_ACTIVE_TYPE"
    }
    return 0 2> /dev/null
fi
# Without it: the escapes live in PS1 itself, because \[ \] are only
# interpreted there, not inside expanded variables
if [[ ! "$PROMPT_COMMAND" =~ _get_claude_context ]]; then
    PROMPT_COMMAND="_get_claude_context${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
fi
if [[ ! "$PROMPT_COMMAND" =~ _get_gh_token ]]; then
    PROMPT_COMMAND="_get_gh_token; $PROMPT_COMMAND"
fi
# Prepend to the existing prompt (guarded so re-sourcing doesn't add it twice)
if [[ "$PS1" != *CLAUDE_ACTIVE_TYPE* ]]; then
    PS1='\[\e[${CLAUDE_ACTIVE_COLOR}m\]Claude: ${CLAUDE_ACTIVE_TYPE}\[\e[0m\] '"$PS1"
fi
