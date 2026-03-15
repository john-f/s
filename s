#!/usr/bin/env bash
set -euo pipefail

preview_lines=40
script_name="$(basename "$0")"

render_preview() {
  local session="$1" lines="${2:-$preview_lines}"
  shpool hardcopy "$session" 2>/dev/null | tail -n "$lines" || echo "[could not capture]"
}

if [ "${1:-}" = "--preview" ]; then
  render_preview "${2:-}" "${3:-$preview_lines}"
  exit 0
fi

if [ "${1:-}" = "--remote-preview" ]; then
  host="${2:-}"; session="${3:-}"; lines="${4:-$preview_lines}"
  ssh ${S_SSH_MUX:-} "$host" shpool hardcopy "$session" 2>/dev/null | tail -n "$lines"
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
    exec ssh -t "${ssh_mux[@]}" "$remote_host" shpool attach "$name"
  fi

  # s @host — pick from remote sessions
  sessions=()
  while read -r name status; do
    sessions+=("${name}	${name}	${status}")
  done < <(ssh "${ssh_mux[@]}" "$remote_host" shpool list 2>/dev/null | tail -n +2 | awk -F'\t' '{print $1, $3}' | sort)

  if [ "${#sessions[@]}" -eq 0 ]; then
    exec ssh -t "${ssh_mux[@]}" "$remote_host" shpool attach "$(date +%Y-%m-%d)"
  fi

  if command -v fzf >/dev/null 2>&1; then
    # list needs: sessions + prompt + header + border lines
    preview_size=$(( $(tput lines 2>/dev/null || echo 40) - ${#sessions[@]} - 7 ))
    [ "$preview_size" -lt 3 ] && preview_size=3
    selected="$(
      printf '%s\n' "${sessions[@]}" \
        | fzf \
          --cycle \
          --ansi \
          --layout=reverse \
          --border \
          --delimiter=$'\t' \
          --with-nth=2,3 \
          --prompt="shpool@${remote_host}> " \
          --header='Enter: attach | Esc: cancel' \
          --listen \
          --bind "start:execute-silent(while sleep 1; do curl -s -XPOST localhost:\$FZF_PORT -d refresh-preview || break; done &)" \
          --preview-window="down,${preview_size},follow" \
          --preview "S_SSH_MUX='-o ControlMaster=auto -o ControlPath=/tmp/.s-ssh-%r@%h:%p -o ControlPersist=5m' $0 --remote-preview ${remote_host} {1} \$FZF_PREVIEW_LINES"
    )"
    [ -z "${selected:-}" ] && exit 0
    name="$(printf '%s' "$selected" | cut -f1)"
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
    name="$(echo "${sessions[$((choice - 1))]}" | cut -f1)"
  fi

  exec ssh -t "${ssh_mux[@]}" "$remote_host" shpool attach "$name"
fi

# s <name> — attach or create
if [ $# -ge 1 ]; then
  name="$1"
  exec shpool attach "$name"
fi

# s (no args) — pick from running sessions
sessions=()
while read -r name status; do
  sessions+=("${name}	${name}	${status}")
done < <(shpool list 2>/dev/null | tail -n +2 | awk -F'\t' '{print $1, $3}' | sort)

if [ "${#sessions[@]}" -eq 0 ]; then
  exec shpool attach "$(date +%Y-%m-%d)"
fi

if command -v fzf >/dev/null 2>&1; then
  # list needs: sessions + prompt + header + border lines
  preview_size=$(( $(tput lines 2>/dev/null || echo 40) - ${#sessions[@]} - 7 ))
  [ "$preview_size" -lt 3 ] && preview_size=3
  selected="$(
    printf '%s\n' "${sessions[@]}" \
      | fzf \
        --cycle \
        --ansi \
        --layout=reverse \
        --border \
        --delimiter=$'\t' \
        --with-nth=2,3 \
        --prompt='shpool> ' \
        --header='Enter: attach | Esc: cancel' \
        --listen \
        --bind "start:execute-silent(while sleep 1; do curl -s -XPOST localhost:\$FZF_PORT -d refresh-preview || break; done &)" \
        --preview-window="down,${preview_size},follow" \
        --preview "$0 --preview {1} \$FZF_PREVIEW_LINES"
  )"
  [ -z "${selected:-}" ] && exit 0
  name="$(printf '%s' "$selected" | cut -f1)"
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
  name="$(echo "${sessions[$((choice - 1))]}" | cut -f1)"
fi

exec shpool attach "$name"
