#!/usr/bin/env bash
set -euo pipefail

preview_lines=40
script_name="$(basename "$0")"

render_preview() {
  local session="$1" window="${2:-0}" lines="${3:-$preview_lines}"
  local tmpfile="/tmp/.s-preview-$$"

  screen -S "$session" -p "$window" -X hardcopy "$tmpfile" 2>/dev/null || true

  # hardcopy via -X is async; wait briefly for the file
  for _ in 1 2 3 4 5; do [ -f "$tmpfile" ] && break; sleep 0.05; done

  if [ -f "$tmpfile" ]; then
    local cols="${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}"
    tr -d '\000\033' < "$tmpfile" | iconv -f utf-8 -t utf-8 -c | cut -c1-"$cols" | tac | sed '/./,$!d' | tac | tail -n "$lines" || true
    rm -f "$tmpfile"
  else
    echo "[could not capture]"
  fi
}

if [ "${1:-}" = "--preview" ]; then
  render_preview "${2:-}" "${3:-0}" "${4:-$preview_lines}"
  exit 0
fi

if [ "${1:-}" = "--remote-preview" ]; then
  host="${2:-}"; session="${3:-}"; window="${4:-0}"; lines="${5:-$preview_lines}"
  ssh ${S_SSH_MUX:-} "$host" bash -s -- "$session" "$window" "$lines" <<'REMOTE'
    session="$1" window="$2" lines="$3"
    tmpfile="/tmp/.s-preview-$$"
    screen -S "$session" -p "$window" -X hardcopy "$tmpfile" 2>/dev/null || true
    for _ in 1 2 3 4 5; do [ -f "$tmpfile" ] && break; sleep 0.05; done
    if [ -f "$tmpfile" ]; then
      tr -d '\000\033' < "$tmpfile" | tac | sed '/./,$!d' | tac | tail -n "$lines"
      rm -f "$tmpfile"
    fi
REMOTE
  exit 0
fi

while getopts ":n:h" opt; do
  case "$opt" in
    n) preview_lines="$OPTARG" ;;
    h) echo "Usage: ${script_name} [@host] [name] [-n LINES]"; exit 0 ;;
    :) echo "Missing argument for -$OPTARG" >&2; exit 2 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

# Remote host support: s @host [name]
if [ $# -ge 1 ] && [[ "$1" == @* ]]; then
  remote_host="${1#@}"
  ssh_mux=(-o ControlMaster=auto -o "ControlPath=/tmp/.s-ssh-%r@%h:%p" -o ControlPersist=5m)
  shift

  if [ $# -ge 1 ]; then
    # s @host name — attach or create named session
    name="$1"
    if ssh "${ssh_mux[@]}" "$remote_host" screen -ls 2>/dev/null | tr -d '\r' | grep -qF ".$name"; then
      exec ssh -t "${ssh_mux[@]}" "$remote_host" screen -d -r "$name"
    else
      exec ssh -t "${ssh_mux[@]}" "$remote_host" screen -S "$name"
    fi
  fi

  # s @host — pick from remote sessions
  sessions=()
  while read -r full_id state; do
    sessions+=("${full_id}	${full_id#*.}	${state}")
  done < <(ssh "${ssh_mux[@]}" "$remote_host" screen -ls 2>/dev/null | tr -d '\r' | awk '/\(Attached\)|\(Detached\)/ {print $1, $NF}' | sort -t. -k2)

  if [ "${#sessions[@]}" -eq 0 ]; then
    exec ssh -t "${ssh_mux[@]}" "$remote_host" screen -S "$(date +%Y-%m-%d)"
  fi

  if command -v fzf >/dev/null 2>&1; then
    # list needs: sessions + prompt + header + border lines
    preview_size=$(( $(tput lines 2>/dev/null || echo 40) - ${#sessions[@]} - 7 ))
    [ "$preview_size" -lt 3 ] && preview_size=3
    selected="$(
      printf '%s\n' "${sessions[@]}" \
        | fzf \
          --cycle \
          --layout=reverse \
          --border \
          --delimiter=$'\t' \
          --with-nth=2,3 \
          --prompt="screen@${remote_host}> " \
          --header='Enter: attach | Esc: cancel' \
          --listen \
          --bind "start:execute-silent(while sleep 1; do curl -s -XPOST localhost:\$FZF_PORT -d refresh-preview || break; done &)" \
          --preview-window="down,${preview_size},follow" \
          --preview "S_SSH_MUX='-o ControlMaster=auto -o ControlPath=/tmp/.s-ssh-%r@%h:%p -o ControlPersist=5m' $0 --remote-preview ${remote_host} {1} 0 \$FZF_PREVIEW_LINES"
    )"
    [ -z "${selected:-}" ] && exit 0
    full_id="$(printf '%s' "$selected" | cut -f1)"
  else
    echo "Sessions on ${remote_host}:" >&2
    for i in "${!sessions[@]}"; do
      row="${sessions[$i]}"
      name="$(echo "$row" | cut -f2)"
      state="$(echo "$row" | cut -f3)"
      echo "  [$((i + 1))] ${name}  ${state}" >&2
    done
    echo >&2
    read -r -p "Select (blank to cancel): " choice
    [ -z "${choice:-}" ] && exit 0
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sessions[@]}" ]; then
      echo "Invalid selection." >&2; exit 2
    fi
    full_id="$(echo "${sessions[$((choice - 1))]}" | cut -f1)"
  fi

  exec ssh -t "${ssh_mux[@]}" "$remote_host" screen -d -r "$full_id"
fi

# s <name> — attach or create
if [ $# -ge 1 ]; then
  name="$1"
  if screen -ls 2>/dev/null | grep -qF ".$name"; then
    exec screen -d -r "$name"
  else
    exec screen -S "$name"
  fi
fi

# s (no args) — pick from running sessions
sessions=()
while read -r full_id state; do
  sessions+=("${full_id}	${full_id#*.}	${state}")
done < <(screen -ls 2>/dev/null | awk '/\(Attached\)|\(Detached\)/ {print $1, $NF}' | sort -t. -k2)

if [ "${#sessions[@]}" -eq 0 ]; then
  exec screen -S "$(date +%Y-%m-%d)"
fi

if command -v fzf >/dev/null 2>&1; then
  # list needs: sessions + prompt + header + border lines
  preview_size=$(( $(tput lines 2>/dev/null || echo 40) - ${#sessions[@]} - 7 ))
  [ "$preview_size" -lt 3 ] && preview_size=3
  selected="$(
    printf '%s\n' "${sessions[@]}" \
      | fzf \
        --cycle \
        --layout=reverse \
        --border \
        --delimiter=$'\t' \
        --with-nth=2,3 \
        --prompt='screen> ' \
        --header='Enter: attach | Esc: cancel' \
        --listen \
        --bind "start:execute-silent(while sleep 1; do curl -s -XPOST localhost:\$FZF_PORT -d refresh-preview || break; done &)" \
        --preview-window="down,${preview_size},follow" \
        --preview "$0 --preview {1} 0 \$FZF_PREVIEW_LINES"
  )"
  [ -z "${selected:-}" ] && exit 0
  full_id="$(printf '%s' "$selected" | cut -f1)"
else
  echo "Sessions:" >&2
  for i in "${!sessions[@]}"; do
    row="${sessions[$i]}"
    name="$(echo "$row" | cut -f2)"
    state="$(echo "$row" | cut -f3)"
    echo "  [$((i + 1))] ${name}  ${state}" >&2
  done
  echo >&2
  read -r -p "Select (blank to cancel): " choice
  [ -z "${choice:-}" ] && exit 0
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#sessions[@]}" ]; then
    echo "Invalid selection." >&2; exit 2
  fi
  full_id="$(echo "${sessions[$((choice - 1))]}" | cut -f1)"
fi

if [ -n "${STY:-}" ]; then
  screen -X detach
  exec screen -r "$full_id"
else
  exec screen -d -r "$full_id"
fi
