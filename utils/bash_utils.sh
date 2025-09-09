#!/usr/bin/bash
############################
# This script provides utility functions for other scripts
############################

# usage: confirm "YOUR_OPTIONAL_TEXT" && COMMAND (do something in case "&&" evaluates to true)
confirm() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure?} [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

confirm_default_yes() {
    # call with a prompt string or use a default
    read -r -p "${1:-Are you sure?} [Y/n] " response
    case "$response" in
        [nN][oO]|[nN]) 
            false
            ;;
        *)
            true
            ;;
    esac
}

# USAGE (both confirm and confirm_default_yes) #

# Import
# source "path/to/bash_utils.sh"

# Default (no else) #
# confirm_default_yes "This could be your question!" && echo "You answered with Yes!"

# If Else structure #
# if confirm_default_yes "Echo a command?"; then
#     echo "IF command"
# else
#     echo "ELSE command"
# fi

# Capture result (true/false in a var) #
# confirm_default_yes "Echo a command?"
# result=$?

# if [ $result -eq 0 ]; then
#     echo "User confirmed (result true)."
# else
#     echo "User did not confirm (result false)."
# fi

###

seperator() {
    local char="$1"
    local amount="$2"

    for (( i=0; i < amount; i++ )); do
        printf "%s" "$char"
    done
    printf "\n"
}

# USAGE #
# seperator "-" 100