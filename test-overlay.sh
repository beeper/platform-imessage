#!/bin/bash
# Interactive REPL for testing iMessage deep links with and without overlay.
# Uses messages from kishan.bagaria@automattic.com chat.

set -uo pipefail

GUIDS=(
    "56AC586E-FFBD-4E15-83FA-90F3191177E0"
    "93A1CF7D-82C2-4567-9F2F-DA4810746E4F"
    "EC11CDF2-CA9D-43F6-A4BF-A62BFB764BD2"
    "0E891846-98A8-46E3-87E9-3D8566EEAA8E"
    "00DD5423-1097-4E2F-A2C6-CCBA1E9FF5A3"
)
DESCS=(
    "yo (sent, Feb 24)"
    "one two three (sent, Feb 4)"
    "test (sent, Feb 4)"
    "hey (sent, Feb 4)"
    "yo (sent, Feb 11)"
)

show_help() {
    echo ""
    echo "commands:"
    echo "  <number>           open message # with overlay=1"
    echo "  <number> no        open message # without overlay"
    echo "  <guid>             open arbitrary guid with overlay=1"
    echo "  <guid> no          open arbitrary guid without overlay"
    echo "  list               show available messages"
    echo "  help               show this help"
    echo "  q                  quit"
    echo ""
}

show_list() {
    echo ""
    for i in "${!GUIDS[@]}"; do
        echo "  $i) ${DESCS[$i]}"
        echo "     ${GUIDS[$i]}"
    done
    echo ""
}

open_link() {
    local guid="$1"
    local overlay="$2"

    local url
    if [[ "$overlay" == "1" ]]; then
        url="imessage://open?message-guid=${guid}&overlay=1"
    else
        url="imessage://open?message-guid=${guid}"
    fi

    echo "  -> $url"
    open "$url"
}

echo "=== iMessage deep link tester ==="
show_list
show_help

while true; do
    printf "> "
    read -r input || break
    [[ -z "$input" ]] && continue

    case "$input" in
        q|quit|exit) break ;;
        help) show_help ;;
        list) show_list ;;
        *)
            read -r first second <<< "$input"
            overlay="1"
            [[ "$second" == "no" ]] && overlay="0"

            if [[ "$first" =~ ^[0-9]+$ ]] && (( first >= 0 && first < ${#GUIDS[@]} )); then
                guid="${GUIDS[$first]}"
                desc="${DESCS[$first]}"
                echo "  message: $desc"
                echo "  overlay: $([[ $overlay == 1 ]] && echo "yes" || echo "no")"
                open_link "$guid" "$overlay"
            elif [[ "$first" =~ ^[A-F0-9-]+$ ]]; then
                echo "  guid: $first"
                echo "  overlay: $([[ $overlay == 1 ]] && echo "yes" || echo "no")"
                open_link "$first" "$overlay"
            else
                echo "  unknown command: $input"
                show_help
            fi
            ;;
    esac
done
