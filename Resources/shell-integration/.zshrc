# vim:ft=zsh
#
# Compatibility shim: with the current integration model, zmux restores
# ZDOTDIR in .zshenv so this file should never be reached. If it is, restore
# ZDOTDIR and behave like vanilla zsh by sourcing the user's .zshrc.

if [[ -n "${GHOSTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$GHOSTTY_ZSH_ZDOTDIR"
    builtin unset GHOSTTY_ZSH_ZDOTDIR
elif [[ -n "${ZMUX_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$ZMUX_ZSH_ZDOTDIR"
    builtin unset ZMUX_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _zmux_file="${ZDOTDIR-$HOME}/.zshrc"
[[ ! -r "$_zmux_file" ]] || builtin source -- "$_zmux_file"
builtin unset _zmux_file
