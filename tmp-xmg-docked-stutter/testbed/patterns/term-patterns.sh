#!/bin/bash
# The same kinds of content as static-patterns.html, drawn by the terminal itself (Konsole
# draws with the CPU; Firefox draws the HTML page with the GPU). Put Konsole full screen
# (Ctrl+Shift+F) on the monitor that shows static, run this, and step with Enter.
# At each pattern, type s + Enter if you see static, c + Enter if it's clean, or just Enter
# to skip. The list of answers is printed at the end.
set -u
[ -t 1 ] || { echo "run it in a terminal" >&2; exit 1; }
rows=$(tput lines) cols=$(tput cols)
names=() answers=()

fill() {   # fill the screen with background colour R G B
    printf '\e[48;2;%s;%s;%sm\e[H\e[2J' "$1" "$2" "$3"
    local line; line=$(printf '%*s' "$cols" '')
    for ((r = 1; r < rows; r++)); do printf '%s\n' "$line"; done
}
text() {   # fill with random text, foreground R G B on background R G B
    printf '\e[38;2;%s;%s;%sm\e[48;2;%s;%s;%sm\e[H\e[2J' "$@"
    LC_ALL=C tr -dc 'a-z0-9_./:=+#$%&*() -' < /dev/urandom | fold -w "$cols" | head -n $((rows - 1))
}
checker() {   # half-block checkerboard: one terminal cell per square
    printf '\e[38;2;255;255;255m\e[48;2;0;0;0m\e[H\e[2J'
    local a b r; a=$(printf '▀▄%.0s' $(seq 1 $((cols / 2)))); b=$(printf '▄▀%.0s' $(seq 1 $((cols / 2))))
    for ((r = 1; r < rows; r++)); do if ((r % 2)); then printf '%s\n' "$a"; else printf '%s\n' "$b"; fi; done
}
show() {   # NAME COMMAND...
    local name=$1 a; shift
    "$@"
    printf '\e[0m\e[%d;1H\e[2K%s  [s static / c clean / Enter skip] ' "$rows" "$name"
    read -r a
    names+=("$name"); case $a in s*) answers+=(static) ;; c*) answers+=(clean) ;; *) answers+=(-) ;; esac
}

show "black" fill 0 0 0
show "white" fill 255 255 255
show "mid grey" fill 128 128 128
show "terminal: light text on Breeze dark" text 252 252 252 35 38 39
show "file manager: dark text on light" text 35 38 39 252 252 252
show "red" fill 255 0 0
show "green" fill 0 255 0
show "blue" fill 0 0 255
show "checkerboard (one cell per square)" checker
printf '\e[0m\e[H\e[2J'
for i in "${!names[@]}"; do printf '%2d  %-7s %s\n' $((i + 1)) "${answers[$i]}" "${names[$i]}"; done
