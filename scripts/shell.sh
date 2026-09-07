# Source in your EXISTING Bash/Zsh shell, after old CP aliases.
# Only the in-memory cf, cfc, switch and archive commands are replaced.
if [ -n "${BASH_VERSION-}" ]; then
    _cf_source=${BASH_SOURCE[0]}
elif [ -n "${ZSH_VERSION-}" ]; then
    _cf_source=${(%):-%N}
else
    printf '%s\n' 'shell.sh requires Bash or Zsh.' >&2
    return 2
fi

CF_CONTEST_ROOT=$(command python3 -c \
    'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent.parent)' \
    "$_cf_source") || return
export CF_CONTEST_ROOT

case "$PATH" in
    "$CF_CONTEST_ROOT/scripts"|"$CF_CONTEST_ROOT/scripts:"*) ;;
    *) export PATH="$CF_CONTEST_ROOT/scripts:$PATH" ;;
esac

unset _cf_source

for _cf_name in cf cfc switch archive; do
    builtin unalias "$_cf_name" 2>/dev/null || :
    builtin unset -f "$_cf_name" 2>/dev/null || :
done
unset _cf_name

function cf {
    command "$CF_CONTEST_ROOT/scripts/cf" "$@"
}

function cfc {
    if builtin test "$#" -lt 1; then
        builtin printf '%s\n' 'usage: cfc ID [--gym]' >&2
        return 2
    fi
    builtin local _cf_id=$1 _cf_dir
    builtin shift
    _cf_dir=$(command "$CF_CONTEST_ROOT/scripts/cf" \
        path --contest "$_cf_id" "$@") || return
    builtin cd -- "$_cf_dir"
}

function switch {
    builtin local _cf_file
    _cf_file=$(command "$CF_CONTEST_ROOT/scripts/cf" \
        path "$@" --file) || return

    if ! builtin test -f "$_cf_file"; then
        builtin printf 'Missing source: %s\n' "$_cf_file" >&2
        return 2
    fi

    builtin cd -- "${_cf_file%/*}" || return
    command "$CF_CONTEST_ROOT/scripts/cf" edit
}

function archive {
    command "$CF_CONTEST_ROOT/scripts/cf" archive "$@"
}

unalias croot cfclean 2>/dev/null || :

function croot {
    builtin cd -- "${CF_CONTEST_ROOT:-$HOME/cf-contests}"
}

function cfclean {
    # Leave the problem directory before removing it.
    croot || return
    command python3 "$PWD/scripts/clean.py" "$@"
}

builtin :
