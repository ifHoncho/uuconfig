#!/usr/bin/env bash
#
# autoupdate — Interactive & scriptable configurator for unattended-upgrades
#              on Debian / Ubuntu and other apt-based systems.
#
# Configures automatic (unattended) package upgrades: what gets upgraded,
# when it runs, reboot behaviour, cleanup, exclusions and mail reports.
#
# Run with no arguments for a guided setup, or pass flags to run it in one
# line without prompts.  See `autoupdate -h`.
#
set -uo pipefail

VERSION="1.0.0"
PROG="${0##*/}"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

# ------------------------------------------------------------------- paths ---
CONF_50="/etc/apt/apt.conf.d/50unattended-upgrades"
CONF_20="/etc/apt/apt.conf.d/20auto-upgrades"
TIMER_DIR="/etc/systemd/system/apt-daily-upgrade.timer.d"
TIMER_OVERRIDE="${TIMER_DIR}/override.conf"
STAMP="$(date +%Y%m%d-%H%M%S)"

# ----------------------------------------------------------------- colours ---
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; RED=$'\e[31m'; GRN=$'\e[32m'
  YLW=$'\e[33m'; BLU=$'\e[34m'; CYN=$'\e[36m'; RST=$'\e[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; CYN=""; RST=""
fi

# --------------------------------------------------------------- messaging ---
info() { printf '%s\n' "$*"; }
step() { printf '%s→%s %s\n' "$BLU" "$RST" "$*"; }
ok()   { printf '%s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YLW" "$RST" "$*" >&2; }
err()  { printf '%s✗ %s%s\n' "$RED" "$*" "$RST" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s────────────────────────────────────────────────────────────%s\n' "$DIM" "$RST"; }

banner() {
  printf '\n%s%s%s%s %s· automatic upgrade configurator%s\n\n' \
    "$BOLD" "$CYN" "$PROG" "$RST" "$DIM" "$RST"
}

# ---------------------------------------------------------- config defaults ---
# These doubles as the baseline for flag (non-interactive) mode.  The
# interactive wizard passes its own friendlier per-question defaults.
UPDATE_TYPE="security"      # security | all
RUN_TIME="04:00"           # daily upgrade time (HH:MM, 24h)
AUTO_REBOOT="false"
REBOOT_TIME="02:00"
REBOOT_WITH_USERS="false"
RM_KERNELS="false"         # remove old/unused kernels
RM_DEPS="false"            # autoremove unused dependencies
AUTOCLEAN="false"          # weekly cache autoclean
ONLY_AC="false"            # laptops: only on mains power
MAIL_ENABLED="false"
MAIL_ADDR=""
MAIL_REPORT="on-change"    # on-change | only-on-error | always
EXCLUDES=""

DRY_RUN="false"
ANY_FLAG="false"

# ------------------------------------------------- package-index / picker ---
PKG_DB=""                  # temp file: "normalized<TAB>name" table (built once)
PKG_DB_READY="false"
PICK_ROWS=8                # how many matches to show at once
PK_COLS=80                 # terminal width (measured when the picker starts)
PK_OLD_STTY=""             # saved terminal mode, restored when the picker exits

# live-picker state (kept at file scope so the small helpers can share it)
PK_TOK=""
PK_LINES=0
pk_query=""
pk_sel=0
pk_msg=""
pk_done=0
pk_cancel=0
pk_cands=()
pk_chosen=()

# distro detection results
DISTRO_ID="debian"
DISTRO_LIKE=""
DISTRO_NAME="Debian-based system"
ORIGIN_STYLE="debian"      # ubuntu | debian
UNKNOWN_DISTRO="false"

# --------------------------------------------------------------- help text ---
usage() {
cat <<EOF
${BOLD}${PROG}${RST} — configure unattended-upgrades on Debian/Ubuntu/apt systems

${BOLD}USAGE${RST}
  ${PROG}                 Run the interactive, guided setup
  ${PROG} [options]       Run non-interactively using flags (no prompts)
  ${PROG} -h              Show this help

${BOLD}WHAT GETS UPGRADED${RST}
  -s            Security updates only            ${DIM}(default)${RST}
  -a            All updates (security + regular)

${BOLD}SCHEDULE${RST}
  -t HH:MM      Time of day to install upgrades  ${DIM}(default 04:00)${RST}

${BOLD}REBOOT${RST}
  -r            Reboot automatically if required  ${DIM}(default time 02:00)${RST}
  -R HH:MM      Reboot automatically at this time ${DIM}(implies -r)${RST}
  -u            Reboot even if users are logged in

${BOLD}CLEANUP${RST}
  -k            Remove old / unused kernel packages
  -d            Remove unused dependencies (autoremove)
  -c            Autoclean the package cache weekly

${BOLD}EXCLUSIONS${RST}
  -x LIST       Never auto-upgrade these packages (comma/space separated)
                ${DIM}e.g. -x "docker-ce,mysql-server"${RST}
                ${DIM}(the guided setup offers a live, fuzzy package search)${RST}

${BOLD}NOTIFICATIONS${RST}
  -m ADDR       Email address for upgrade reports
  -M WHEN       When to mail: on-change | only-on-error | always
                ${DIM}(default on-change; needs a working mail transport)${RST}

${BOLD}POWER${RST}
  -p            Only run while on AC power (recommended for laptops)

${BOLD}CONTROL${RST}
  -n            Dry run — show exactly what would change, modify nothing
  -h            Show this help and exit
  -V            Show version and exit

${BOLD}NOTES${RST}
  • Flags can be bundled: ${DIM}${PROG} -srkdc${RST} = security-only updates,
    auto-reboot, kernel + dependency cleanup and weekly autoclean.
  • When bundling, put any flag that takes a value ${BOLD}last${RST}: ${DIM}${PROG} -srk -R 03:00${RST}.
  • This tool needs root; it re-runs itself with sudo when required.

${BOLD}EXAMPLES${RST}
  ${PROG}                         Guided interactive setup
  ${PROG} -a -t 03:00 -r -kdc     All updates at 03:00, auto-reboot, full cleanup
  ${PROG} -s -x "docker-ce"       Security only, never touch docker-ce
  ${PROG} -n -a -r -R 02:30       Preview an "all + reboot at 02:30" setup
EOF
}

# ----------------------------------------------------------- input helpers ---
validate_time()  { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
validate_email() { [[ "$1" == *?@?*.?* ]]; }

# ask_yes_no PROMPT [default y|n] -> returns 0 for yes, 1 for no
ask_yes_no() {
  local prompt="$1" default="${2:-n}" reply hint
  if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  while true; do
    read -r -p "$prompt $hint " reply || return 1
    reply="${reply:-$default}"
    case "${reply,,}" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     printf 'Please answer y or n.\n' >&2 ;;
    esac
  done
}

# ask_input PROMPT DEFAULT [validator] -> echoes the chosen value on stdout
ask_input() {
  local prompt="$1" default="${2:-}" validator="${3:-}" reply
  while true; do
    if [[ -n "$default" ]]; then
      read -r -p "$prompt [$default]: " reply || return 1
      reply="${reply:-$default}"
    else
      read -r -p "$prompt: " reply || return 1
    fi
    if [[ -n "$validator" ]] && ! "$validator" "$reply"; then
      printf '%sThat doesn'\''t look valid, please try again.%s\n' "$YLW" "$RST" >&2
      continue
    fi
    printf '%s' "$reply"
    return 0
  done
}

# ask_choice PROMPT OPTION... -> echoes the zero-based index of the choice
ask_choice() {
  local prompt="$1"; shift
  local -a options=("$@")
  local i choice
  printf '%s\n' "$prompt" >&2
  for i in "${!options[@]}"; do
    printf '  %s%d)%s %s\n' "$BOLD" "$((i + 1))" "$RST" "${options[$i]}" >&2
  done
  while true; do
    read -r -p "Choice [1]: " choice || return 1
    choice="${choice:-1}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      printf '%s' "$((choice - 1))"
      return 0
    fi
    printf '%sPlease enter a number between 1 and %d.%s\n' "$YLW" "${#options[@]}" "$RST" >&2
  done
}

# --------------------------------------------------------- system checks ---
require_apt() {
  command -v apt-get >/dev/null 2>&1 \
    || die "This tool needs an apt-based system (Debian, Ubuntu, Mint, ...)."
}

detect_distro() {
  if [[ -r /etc/os-release ]]; then
    # Source in subshells so os-release's own vars (VERSION, NAME, ...) never
    # leak into and clobber this script's globals.
    # shellcheck disable=SC1091
    DISTRO_ID="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-debian}")"
    # shellcheck disable=SC1091
    DISTRO_LIKE="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")"
    # shellcheck disable=SC1091
    DISTRO_NAME="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${ID:-debian}}")"
  fi
  if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_LIKE" == *ubuntu* ]]; then
    ORIGIN_STYLE="ubuntu"
  elif [[ "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" == *debian* ]]; then
    ORIGIN_STYLE="debian"
  else
    ORIGIN_STYLE="debian"
    UNKNOWN_DISTRO="true"
  fi
}

ensure_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] && return 0
  if command -v sudo >/dev/null 2>&1; then
    step "Root privileges are required — re-running with sudo…"
    exec sudo "$SELF" "$@"
  fi
  die "Please run this tool as root (e.g. with sudo)."
}

uu_installed() {
  dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null \
    | grep -q "install ok installed"
}

# ------------------------------------------------------------ excludes ---
# Normalise EXCLUDES (comma/space separated) into a clean space-separated list.
excludes_list() {
  local raw="${EXCLUDES//,/ }" w out=""
  for w in $raw; do
    [[ -n "$w" ]] && out+="$w "
  done
  printf '%s' "${out% }"
}
excludes_pretty() { local l; l="$(excludes_list)"; printf '%s' "${l// /, }"; }

# ------------------------------------------------------- package search ---
# Build the searchable package table once (best-effort). Produces a file of
# "normalized<TAB>realname" lines, where the normalized column is lower-cased
# with punctuation stripped so fuzzy matching can ignore hyphens/dots/etc.
pkg_db_init() {
  [[ "$PKG_DB_READY" == "true" ]] && return 0
  command -v apt-cache >/dev/null 2>&1 || return 1
  local tmp
  tmp="$(mktemp 2>/dev/null)" || return 1
  # apt-cache pkgnames is the fast path — it reads apt's binary cache.
  apt-cache pkgnames 2>/dev/null \
    | awk '{o=$0; n=tolower($0); gsub(/[^a-z0-9]/,"",n); if(n!="") print n"\t"o}' \
    | LC_ALL=C sort -u > "$tmp" 2>/dev/null
  if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; return 1; fi
  PKG_DB="$tmp"
  PKG_DB_READY="true"
  return 0
}

# pkg_exists NAME -> 0 if NAME is a known package name (exact match)
pkg_exists() {
  [[ "$PKG_DB_READY" == "true" ]] || return 2
  awk -F'\t' -v n="$1" '$2==n{found=1; exit} END{exit(found?0:1)}' "$PKG_DB"
}

# pkg_search QUERY -> prints up to PICK_ROWS ranked matches, best first.
# Matching is punctuation-insensitive subsequence ("dockce" -> docker-*),
# which tolerates missing characters and many transpositions. A fast grep
# pre-filter keeps each keystroke well under ~50ms even on ~100k packages.
pkg_search() {
  [[ "$PKG_DB_READY" == "true" ]] || return 1
  local raw="$1" q pat i c tab
  tab="$(printf '\t')"
  q="$(printf '%s' "$raw" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9')"
  (( ${#q} < 2 )) && return 0
  # subsequence regex confined to the normalized (pre-tab) column
  pat="^[^$tab]*"
  for (( i=0; i<${#q}; i++ )); do c="${q:i:1}"; pat+="${c}[^$tab]*"; done
  pat+="$tab"
  LC_ALL=C grep -E "$pat" "$PKG_DB" 2>/dev/null \
    | awk -F'\t' -v q="$q" '
        function issub(qq,s,   i,j,lq,ls){
          lq=length(qq); ls=length(s); j=1;
          for(i=1;i<=ls&&j<=lq;i++) if(substr(s,i,1)==substr(qq,j,1)) j++;
          return (j>lq) }
        { s=$1;
          if(s==q)            sc=0;      # exact
          else if(index(s,q)==1) sc=1;   # prefix
          else if(index(s,q)>1)  sc=2;   # substring
          else if(issub(q,s))    sc=3;   # subsequence
          else next;
          print sc"\t"length($2)"\t"$2 }' \
    | LC_ALL=C sort -k1,1n -k2,2n -k3,3 \
    | awk -F'\t' -v n="$PICK_ROWS" 'NR<=n{print $3}'
}

# --------------------------------------------------- live package picker ---
pk_in_chosen() {
  local x
  (( ${#pk_chosen[@]} )) || return 1
  for x in "${pk_chosen[@]}"; do [[ "$x" == "$1" ]] && return 0; done
  return 1
}

pk_join_chosen() {
  local out="" x
  (( ${#pk_chosen[@]} )) || return 0
  for x in "${pk_chosen[@]}"; do out+="${out:+, }$x"; done
  printf '%s' "$out"
}

pk_toggle() {
  local name="$1" x found=0 new=()
  if (( ${#pk_chosen[@]} )); then
    for x in "${pk_chosen[@]}"; do
      if [[ "$x" == "$name" ]]; then found=1; else new+=("$x"); fi
    done
  fi
  if (( found )); then
    pk_chosen=("${new[@]}"); pk_msg="removed ${name}"
  else
    pk_chosen+=("$name"); pk_msg="added ${name}"
  fi
}

# Repopulate pk_cands from the current query and keep pk_sel in range.
pk_refresh() {
  pk_cands=()
  local line
  if [[ "$PKG_DB_READY" == "true" ]] && (( ${#pk_query} >= 2 )); then
    while IFS= read -r line; do
      [[ -n "$line" ]] && pk_cands+=("$line")
    done < <(pkg_search "$pk_query")
  fi
  (( pk_sel < 0 )) && pk_sel=0
  if (( ${#pk_cands[@]} == 0 )); then
    pk_sel=0
  elif (( pk_sel >= ${#pk_cands[@]} )); then
    pk_sel=$(( ${#pk_cands[@]} - 1 ))
  fi
}

# Truncate a plain (ANSI-free) string to WIDTH display columns, adding an
# ellipsis when it doesn't fit. Package names are ASCII, so length == width.
pk_trunc() {
  local s="$1" w="$2"
  (( w < 1 )) && return 0
  if (( ${#s} <= w )); then printf '%s' "$s"; else printf '%s…' "${s:0:w-1}"; fi
}

# Draw (or redraw in place) the picker block on stderr.
#
# Every line is terminated with ESC[K (clear to end of line) so that when a
# line gets shorter between redraws — a backspaced query, a shorter match —
# no stale characters are left behind. ESC[J after the block clears any lines
# left over when the block itself gets shorter. Text is truncated to the
# terminal width so a long name can't wrap and desync the cursor maths.
pk_render() {
  local eol=$'\e[K\n' buf="" i name marker line disp q
  local cols="${PK_COLS:-80}" namew qw ew
  (( cols < 20 )) && cols=20
  namew=$(( cols - 5 )); (( namew < 8 )) && namew=8
  qw=$(( cols - 12 ));   (( qw < 8 ))    && qw=8
  ew=$(( cols - 14 ));   (( ew < 8 ))    && ew=8

  # Search line — show the tail of an over-long query so the caret stays visible.
  q="$pk_query"
  (( ${#q} > qw )) && q="…${q: -$((qw - 1))}"
  buf+="  ${BOLD}Search:${RST} ${q}${CYN}▏${RST}${eol}"

  if [[ "$PKG_DB_READY" != "true" ]]; then
    buf+="  ${DIM}(package index unavailable — type a name, Tab to add)${RST}${eol}"
  elif (( ${#pk_query} < 2 )); then
    buf+="  ${DIM}type at least 2 characters to search…${RST}${eol}"
  elif (( ${#pk_cands[@]} == 0 )); then
    buf+="  ${DIM}no matches — Tab adds \"$(pk_trunc "$pk_query" "$((cols - 24))")\" as typed${RST}${eol}"
  else
    for i in "${!pk_cands[@]}"; do
      name="${pk_cands[$i]}"
      disp="$(pk_trunc "$name" "$namew")"
      marker="  "
      pk_in_chosen "$name" && marker="${GRN}✓${RST} "
      if (( i == pk_sel )); then
        line="${CYN}❯${RST} ${marker}${BOLD}${disp}${RST}"
      else
        line="  ${marker}${disp}"
      fi
      buf+="${line}${eol}"
    done
  fi

  if (( ${#pk_chosen[@]} )); then
    buf+="  ${DIM}Excluding:${RST} $(pk_trunc "$(pk_join_chosen)" "$ew")${eol}"
  else
    buf+="  ${DIM}Excluding: nothing yet${RST}${eol}"
  fi
  if [[ -n "$pk_msg" ]]; then
    buf+="  ${YLW}$(pk_trunc "$pk_msg" "$((cols - 2))")${RST}${eol}"
  else
    buf+="  ${DIM}$(pk_trunc "↑/↓ move · Tab add/remove · Enter done · Esc clear" "$((cols - 2))")${RST}${eol}"
  fi

  (( PK_LINES > 0 )) && printf '\e[%dA' "$PK_LINES" >&2
  printf '\r%s\e[J' "$buf" >&2
  local nlc="${buf//[!$'\n']/}"
  PK_LINES=${#nlc}
}

# Decode one keypress from the terminal into a logical token in PK_TOK.
pk_read_key() {
  local k rest
  if ! IFS= read -rsn1 k; then
    if (( pk_cancel )); then PK_TOK="cancel"; else PK_TOK="enter"; fi
    return
  fi
  case "$k" in
    "")            PK_TOK="enter" ;;
    $'\t')         PK_TOK="tab" ;;
    $'\x7f'|$'\b') PK_TOK="bs" ;;
    $'\x07')       PK_TOK="cancel" ;;   # Ctrl-G
    $'\e')
      rest=""
      IFS= read -rsn2 -t 0.05 rest 2>/dev/null
      case "$rest" in
        '[A'|'OA') PK_TOK="up" ;;
        '[B'|'OB') PK_TOK="down" ;;
        '[C'|'OC'|'[D'|'OD') PK_TOK="noop" ;;
        *)         PK_TOK="esc" ;;
      esac ;;
    *)
      if [[ "$k" == [[:print:]] ]]; then PK_TOK="chr:$k"; else PK_TOK="noop"; fi ;;
  esac
}

# Apply one logical token to the picker state.
pk_handle_key() {
  local tok="$1" lit
  case "$tok" in
    up)    (( pk_sel > 0 )) && pk_sel=$(( pk_sel - 1 )); pk_msg="" ;;
    down)  (( pk_sel < ${#pk_cands[@]} - 1 )) && pk_sel=$(( pk_sel + 1 )); pk_msg="" ;;
    tab)
      if (( ${#pk_cands[@]} > 0 )); then
        pk_toggle "${pk_cands[$pk_sel]}"
      elif [[ -n "${pk_query//[[:space:]]/}" ]]; then
        lit="$(printf '%s' "$pk_query" | tr -d '[:space:]')"
        pk_toggle "$lit"
        if [[ "$PKG_DB_READY" == "true" ]] && ! pkg_exists "$lit"; then
          pk_msg="added ${lit} (not in index)"
        fi
      fi
      pk_query=""; pk_sel=0; pk_refresh ;;
    enter)  pk_done=1 ;;
    bs)     pk_query="${pk_query%?}"; pk_sel=0; pk_msg=""; pk_refresh ;;
    esc)    if [[ -n "$pk_query" ]]; then pk_query=""; pk_sel=0; pk_msg=""; pk_refresh; else pk_done=1; fi ;;
    cancel) pk_cancel=1; pk_done=1 ;;
    noop)   : ;;
    chr:*)  pk_query+="${tok#chr:}"; pk_sel=0; pk_msg=""; pk_refresh ;;
  esac
}

# Non-interactive fallback: plain typed entry, validated against the index.
pick_excludes_fallback() {
  local entry
  entry="$(ask_input "Packages to exclude (space/comma separated)" "$(excludes_pretty)")"
  EXCLUDES="$entry"
  warn_unknown_excludes
}

# Restore the terminal after the picker (cursor + original tty mode). Safe to
# call more than once.
pk_cleanup() {
  printf '\e[?25h' >&2                        # show cursor
  if [[ -n "$PK_OLD_STTY" ]]; then
    stty "$PK_OLD_STTY" 2>/dev/null
    PK_OLD_STTY=""
  fi
}

# Interactive, fuzzy, live package picker. Populates EXCLUDES.
pick_excludes() {
  pkg_db_init || true

  # Need a real terminal for the live picker; otherwise fall back.
  if [[ ! -t 0 || ! -t 1 || "${TERM:-}" == "dumb" ]]; then
    pick_excludes_fallback
    return
  fi

  pk_query=""; pk_sel=0; pk_msg=""; pk_done=0; pk_cancel=0
  pk_cands=(); pk_chosen=(); PK_LINES=0

  # Measure the terminal width so long names/lists can't wrap and desync redraws.
  PK_COLS="$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-80}")"
  [[ "$PK_COLS" =~ ^[0-9]+$ ]] || PK_COLS=80

  # Put the terminal into raw, no-echo mode for the whole session. Without this
  # the tty echoes and line-buffers any keys that arrive while we're rendering
  # or searching between reads, which corrupts the display when typing quickly.
  PK_OLD_STTY=""
  if command -v stty >/dev/null 2>&1; then
    PK_OLD_STTY="$(stty -g 2>/dev/null || true)"
    [[ -n "$PK_OLD_STTY" ]] && stty -echo -icanon min 1 time 0 2>/dev/null
  fi

  # seed with anything already excluded (e.g. from an -x default)
  local seed
  for seed in $(excludes_list); do pk_chosen+=("$seed"); done

  info "${DIM}Start typing a package name — matches appear live. Tab to add.${RST}" >&2
  printf '\e[?25l' >&2                       # hide cursor while drawing
  pk_refresh
  pk_render

  # Make sure the terminal is put back even if interrupted.
  trap 'pk_cleanup; pk_cancel=1; pk_done=1' INT
  while (( ! pk_done )); do
    pk_read_key
    pk_handle_key "$PK_TOK"
    pk_render
  done
  trap - INT

  (( PK_LINES > 0 )) && printf '\e[%dA\r\e[J' "$PK_LINES" >&2   # erase the block
  pk_cleanup                                   # restore cursor + tty mode

  EXCLUDES="${pk_chosen[*]}"
  if (( pk_cancel )); then
    warn "Exclusion picker cancelled."
  fi
  if (( ${#pk_chosen[@]} )); then
    ok "Excluding ${#pk_chosen[@]} package(s): $(pk_join_chosen)"
  else
    info "${DIM}No packages excluded.${RST}"
  fi
}

# Warn (non-fatally) about excluded names that aren't in the package index.
warn_unknown_excludes() {
  [[ -n "$(excludes_list)" ]] || return 0
  pkg_db_init || return 0
  [[ "$PKG_DB_READY" == "true" ]] || return 0
  local w unknown=()
  for w in $(excludes_list); do
    pkg_exists "$w" || unknown+=("$w")
  done
  (( ${#unknown[@]} )) && \
    warn "These excluded package(s) aren't in the package index: ${unknown[*]}"
  return 0
}

# --------------------------------------------------- config file renderers ---
render_origins() {
  # NB: ${distro_id}/${distro_codename} are written literally on purpose —
  # unattended-upgrades expands them itself, so single quotes are correct.
  # shellcheck disable=SC2016
  if [[ "$ORIGIN_STYLE" == "ubuntu" ]]; then
    printf 'Unattended-Upgrade::Allowed-Origins {\n'
    printf '    "${distro_id}:${distro_codename}-security";\n'
    printf '    "${distro_id}ESMApps:${distro_codename}-apps-security";\n'
    printf '    "${distro_id}ESM:${distro_codename}-infra-security";\n'
    if [[ "$UPDATE_TYPE" == "all" ]]; then
      printf '    "${distro_id}:${distro_codename}";\n'
      printf '    "${distro_id}:${distro_codename}-updates";\n'
    fi
    printf '};\n'
  else
    printf 'Unattended-Upgrade::Origins-Pattern {\n'
    printf '    "origin=Debian,codename=${distro_codename},label=Debian-Security";\n'
    printf '    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";\n'
    if [[ "$UPDATE_TYPE" == "all" ]]; then
      printf '    "origin=Debian,codename=${distro_codename},label=Debian";\n'
      printf '    "origin=Debian,codename=${distro_codename}-updates";\n'
    fi
    printf '};\n'
  fi
}

render_blacklist() {
  printf 'Unattended-Upgrade::Package-Blacklist {\n'
  local w
  for w in $(excludes_list); do
    printf '    "%s";\n' "$w"
  done
  printf '};\n'
}

render_conf_50() {
  printf '// Managed by %s v%s — generated %s\n' "$PROG" "$VERSION" "$(date)"
  printf '// Re-run "%s" to change these settings.\n\n' "$PROG"
  render_origins
  printf '\n'
  render_blacklist
  printf '\n'
  printf 'Unattended-Upgrade::Automatic-Reboot "%s";\n' "$AUTO_REBOOT"
  printf 'Unattended-Upgrade::Automatic-Reboot-WithUsers "%s";\n' "$REBOOT_WITH_USERS"
  printf 'Unattended-Upgrade::Automatic-Reboot-Time "%s";\n\n' "$REBOOT_TIME"
  printf 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "%s";\n' "$RM_KERNELS"
  printf 'Unattended-Upgrade::Remove-New-Unused-Dependencies "%s";\n' "$RM_DEPS"
  printf 'Unattended-Upgrade::Remove-Unused-Dependencies "%s";\n\n' "$RM_DEPS"
  printf 'Unattended-Upgrade::OnlyOnACPower "%s";\n\n' "$ONLY_AC"
  if [[ "$MAIL_ENABLED" == "true" ]]; then
    printf 'Unattended-Upgrade::Mail "%s";\n' "$MAIL_ADDR"
    printf 'Unattended-Upgrade::MailReport "%s";\n\n' "$MAIL_REPORT"
  fi
  printf 'Unattended-Upgrade::AutoFixInterruptedDpkg "true";\n'
  printf 'Unattended-Upgrade::MinimalSteps "true";\n'
  printf 'Unattended-Upgrade::InstallOnShutdown "false";\n'
  printf 'Unattended-Upgrade::SyslogEnable "true";\n'
}

render_conf_20() {
  local ac_iv="0"; [[ "$AUTOCLEAN" == "true" ]] && ac_iv="7"
  printf '// Managed by %s v%s\n' "$PROG" "$VERSION"
  printf 'APT::Periodic::Update-Package-Lists "1";\n'
  printf 'APT::Periodic::Download-Upgradeable-Packages "1";\n'
  printf 'APT::Periodic::Unattended-Upgrade "1";\n'
  printf 'APT::Periodic::AutocleanInterval "%s";\n' "$ac_iv"
}

render_timer() {
  printf '# Managed by %s v%s\n' "$PROG" "$VERSION"
  printf '[Timer]\n'
  printf 'OnCalendar=\n'
  printf 'OnCalendar=*-*-* %s\n' "$RUN_TIME"
  printf 'RandomizedDelaySec=0\n'
  printf 'Persistent=true\n'
}

# ------------------------------------------------------------- summary ---
human_update_type() {
  [[ "$UPDATE_TYPE" == "all" ]] \
    && printf 'All updates (security + regular)' \
    || printf 'Security updates only'
}
yn() { [[ "$1" == "true" ]] && printf 'Yes' || printf 'No'; }

print_summary() {
  hr
  info "${BOLD}Review — here is what will be configured${RST}"
  hr
  printf '  %-21s %s\n' "System:"        "$DISTRO_NAME"
  printf '  %-21s %s\n' "Upgrades:"      "$(human_update_type)"
  printf '  %-21s %s\n' "Runs daily at:" "$RUN_TIME  ${DIM}(catches up on next boot if missed)${RST}"
  if [[ "$AUTO_REBOOT" == "true" ]]; then
    local who="only when nobody is logged in"
    [[ "$REBOOT_WITH_USERS" == "true" ]] && who="even if users are logged in"
    printf '  %-21s %s\n' "Auto-reboot:" "Yes, at $REBOOT_TIME ($who)"
  else
    printf '  %-21s %s\n' "Auto-reboot:" "No ${DIM}(kernel updates need a manual reboot)${RST}"
  fi
  printf '  %-21s %s\n' "Remove old kernels:"  "$(yn "$RM_KERNELS")"
  printf '  %-21s %s\n' "Remove unused deps:"  "$(yn "$RM_DEPS")"
  printf '  %-21s %s\n' "Weekly autoclean:"    "$(yn "$AUTOCLEAN")"
  printf '  %-21s %s\n' "Only on AC power:"    "$(yn "$ONLY_AC")"
  if [[ -n "$(excludes_list)" ]]; then
    printf '  %-21s %s\n' "Never upgrade:"     "$(excludes_pretty)"
  else
    printf '  %-21s %s\n' "Never upgrade:"     "${DIM}(nothing excluded)${RST}"
  fi
  if [[ "$MAIL_ENABLED" == "true" ]]; then
    printf '  %-21s %s\n' "Email reports:"     "$MAIL_ADDR ($MAIL_REPORT)"
  else
    printf '  %-21s %s\n' "Email reports:"     "Off"
  fi
  hr
}

# ---------------------------------------------------------------- apply ---
backup_if_exists() {
  local f="$1"
  if [[ -e "$f" ]]; then
    cp -a "$f" "${f}.autoupdate.bak-${STAMP}" \
      && ok "Backed up $(basename "$f") → ${f}.autoupdate.bak-${STAMP}"
  fi
}

install_uu() {
  if uu_installed; then
    ok "unattended-upgrades is already installed."
    return 0
  fi
  step "Installing unattended-upgrades…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq            || die "apt-get update failed."
  apt-get install -y -qq unattended-upgrades >/dev/null \
    || die "Failed to install unattended-upgrades."
  ok "Installed unattended-upgrades."
}

write_conf_50() { render_conf_50 > "$CONF_50" || die "Could not write $CONF_50"; ok "Wrote $CONF_50"; }
write_conf_20() { render_conf_20 > "$CONF_20" || die "Could not write $CONF_20"; ok "Wrote $CONF_20"; }
write_timer() {
  mkdir -p "$TIMER_DIR" || die "Could not create $TIMER_DIR"
  render_timer > "$TIMER_OVERRIDE" || die "Could not write $TIMER_OVERRIDE"
  ok "Wrote $TIMER_OVERRIDE"
}

enable_services() {
  step "Reloading systemd and enabling timers…"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || warn "systemctl daemon-reload failed."
    systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 \
      || warn "Could not enable the apt-daily timers."
    systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 \
      || warn "Could not enable the unattended-upgrades service."
    ok "Timers and service enabled."
  else
    warn "systemd not found — scheduling relies on cron/anacron on this system."
  fi
}

validate_config() {
  step "Validating apt configuration…"
  if apt-config dump >/dev/null 2>&1; then
    ok "Configuration parses cleanly."
  else
    warn "apt reported a parsing problem — please review $CONF_50."
  fi
}

apply_all() {
  hr
  step "Applying configuration…"
  install_uu
  backup_if_exists "$CONF_20"
  backup_if_exists "$CONF_50"
  backup_if_exists "$TIMER_OVERRIDE"
  write_conf_20
  write_conf_50
  write_timer
  enable_services
  validate_config
  hr
  ok "${BOLD}All done.${RST} Automatic upgrades are configured."
  info ""
  info "Handy commands:"
  info "  • Test a run now (changes nothing):  ${DIM}sudo unattended-upgrade --dry-run --debug${RST}"
  info "  • See the next scheduled run:        ${DIM}systemctl list-timers apt-daily-upgrade.timer${RST}"
  info "  • Read the last run's log:           ${DIM}less /var/log/unattended-upgrades/unattended-upgrades.log${RST}"
  [[ "$MAIL_ENABLED" == "true" ]] \
    && info "  • Email reports need a working mail transport (e.g. postfix or msmtp)."
}

preview() {
  print_summary
  info "${BOLD}Planned file contents${RST} ${DIM}(dry run — nothing is written)${RST}"
  hr
  printf '%s# %s%s\n' "$DIM" "$CONF_20" "$RST"
  render_conf_20 | sed 's/^/    /'
  printf '\n%s# %s%s\n' "$DIM" "$CONF_50" "$RST"
  render_conf_50 | sed 's/^/    /'
  printf '\n%s# %s%s\n' "$DIM" "$TIMER_OVERRIDE" "$RST"
  render_timer | sed 's/^/    /'
  hr
  info "Re-run without ${DIM}-n${RST} (as root) to apply."
}

# ------------------------------------------------------------ interactive ---
run_interactive() {
  banner
  info "This will set up automatic (unattended) upgrades on:"
  info "  ${BOLD}${DISTRO_NAME}${RST}"
  info ""
  info "${DIM}Tip: you can run this in one line with flags — try '${PROG} -h'.${RST}"

  local sel msel
  hr
  info "${BOLD}What to upgrade${RST}"
  sel="$(ask_choice "Which upgrades should be installed automatically?" \
      "Security updates only (recommended)" \
      "All updates (security + regular)")"
  [[ "$sel" == "1" ]] && UPDATE_TYPE="all" || UPDATE_TYPE="security"

  hr
  info "${BOLD}Schedule${RST}"
  RUN_TIME="$(ask_input "Time of day to install upgrades (24h HH:MM)" "$RUN_TIME" validate_time)"

  hr
  info "${BOLD}Reboots${RST}"
  info "Some updates (e.g. new kernels) only take effect after a reboot."
  if ask_yes_no "Allow automatic reboots when required?" "n"; then
    AUTO_REBOOT="true"
    REBOOT_TIME="$(ask_input "Reboot at what time (24h HH:MM)" "$REBOOT_TIME" validate_time)"
    ask_yes_no "Reboot even if users are still logged in?" "n" && REBOOT_WITH_USERS="true"
  fi

  hr
  info "${BOLD}Cleanup${RST}"
  ask_yes_no "Remove old, unused kernels? (frees /boot space)" "y" && RM_KERNELS="true"
  ask_yes_no "Automatically remove unused dependencies? (autoremove)" "n" && RM_DEPS="true"
  ask_yes_no "Autoclean the package cache weekly?" "y" && AUTOCLEAN="true"

  hr
  info "${BOLD}Exclusions${RST}"
  info "These packages will be held back and never upgraded automatically."
  if ask_yes_no "Exclude specific packages from auto-upgrades?" "n"; then
    pick_excludes
  fi

  hr
  info "${BOLD}Power${RST}"
  ask_yes_no "Only run while on AC power? (recommended for laptops)" "n" && ONLY_AC="true"

  hr
  info "${BOLD}Notifications${RST}"
  if ask_yes_no "Email a report after upgrades run?" "n"; then
    MAIL_ENABLED="true"
    MAIL_ADDR="$(ask_input "Send reports to which email address" "$MAIL_ADDR" validate_email)"
    msel="$(ask_choice "When should reports be sent?" \
        "Only when something changed (on-change)" \
        "Only when an error occurred (only-on-error)" \
        "Always")"
    case "$msel" in
      0) MAIL_REPORT="on-change" ;;
      1) MAIL_REPORT="only-on-error" ;;
      2) MAIL_REPORT="always" ;;
    esac
  fi
}

# ---------------------------------------------------------------- main ---
main() {
  local OPTIND opt
  while getopts ":hVsarR:ut:m:M:x:pkdcn" opt; do
    ANY_FLAG="true"
    case "$opt" in
      h) usage; exit 0 ;;
      V) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
      s) UPDATE_TYPE="security" ;;
      a) UPDATE_TYPE="all" ;;
      r) AUTO_REBOOT="true" ;;
      R) AUTO_REBOOT="true"; REBOOT_TIME="$OPTARG" ;;
      u) REBOOT_WITH_USERS="true" ;;
      t) RUN_TIME="$OPTARG" ;;
      m) MAIL_ENABLED="true"; MAIL_ADDR="$OPTARG" ;;
      M) MAIL_REPORT="$OPTARG" ;;
      x) EXCLUDES="$OPTARG" ;;
      p) ONLY_AC="true" ;;
      k) RM_KERNELS="true" ;;
      d) RM_DEPS="true" ;;
      c) AUTOCLEAN="true" ;;
      n) DRY_RUN="true" ;;
      :)  die "Option -$OPTARG requires an argument. See '$PROG -h'." ;;
      \?) die "Unknown option -$OPTARG. See '$PROG -h'." ;;
    esac
  done

  require_apt
  detect_distro
  [[ "$UNKNOWN_DISTRO" == "true" ]] && \
    warn "Unrecognised distribution '$DISTRO_ID'; using Debian-style origins — review $CONF_50 afterwards."

  # Validate any flag-provided values up front (before asking for sudo).
  validate_time "$RUN_TIME"    || die "Invalid schedule time '$RUN_TIME' (use HH:MM, 24h)."
  validate_time "$REBOOT_TIME" || die "Invalid reboot time '$REBOOT_TIME' (use HH:MM, 24h)."
  case "$MAIL_REPORT" in
    on-change|only-on-error|always) ;;
    *) die "Invalid -M value '$MAIL_REPORT' (use on-change | only-on-error | always)." ;;
  esac

  # If packages were excluded via -x, flag any that apt doesn't recognise.
  [[ "$ANY_FLAG" == "true" ]] && warn_unknown_excludes

  # Dry run needs no privileges and never writes anything.
  if [[ "$DRY_RUN" == "true" ]]; then
    preview
    exit 0
  fi

  ensure_root "$@"

  if [[ "$ANY_FLAG" == "true" ]]; then
    # Non-interactive express lane: show what's happening, then apply.
    banner
    print_summary
    apply_all
  else
    # Guided interactive setup with a final confirmation screen.
    run_interactive
    print_summary
    if ask_yes_no "Apply these settings now?" "n"; then
      apply_all
    else
      info "Aborted — no changes were made."
      exit 0
    fi
  fi
}

# Only run main when executed directly (not when sourced for testing).
# `return` only succeeds inside a sourced script, so this also works when
# run via process substitution or `bash -c "$(curl ...)"`, where BASH_SOURCE
# is empty and comparing it against "$0" would otherwise skip main entirely.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
