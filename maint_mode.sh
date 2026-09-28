#!/usr/bin/env bash
# ---------------------------------------------------------
#            Proxmox Maintenance Mode (revised)
#  Based on Darkhand81/ProxmoxMaintenanceMode
#  Temporarily disable autostart (onboot) for all VMs/CTs on
#  this node, then restore exactly those guests afterwards.
#  Sends an alert through the Proxmox notification system.
#
#  Usage: maintmode.sh [on|off|status|test-notify]
#         (no argument = interactive toggle)
#
#  Both "on" and "off" are safe to rerun: if a run is
#  interrupted, running the same command again finishes it.
# ---------------------------------------------------------

set -uo pipefail

LOCKFILE="/root/maintmode.lock"     # present = maintenance mode is ON
LASTFILE="/root/maintmode.last"     # copy of the last restored list, for reference
RUNLOCK="/run/maintmode.run"        # prevents two copies running at once
QEMU_DIR="/etc/pve/qemu-server"
LXC_DIR="/etc/pve/lxc"

# Notification method (can also be set from the environment, e.g.
# NOTIFY_METHOD=api ./maintmode.sh on):
#   sendmail - mail to root. Proxmox feeds it into the global notification
#              system as a "system-mail" notification. Officially supported,
#              but the severity is always "unknown".
#   api      - call PVE::Notify directly: real severity and a custom field
#              type=maintmode you can use in matchers. NOT officially
#              supported and may break after a Proxmox update; if it fails,
#              the script falls back to sendmail.
#   none     - no notifications.
NOTIFY_METHOD="${NOTIFY_METHOD:-sendmail}"
TEMPLATE_DIR="/etc/pve/notification-templates/default"
HOST=$(hostname)

# ---------------------------------------------------------
# Output helpers
# ---------------------------------------------------------

IS_TTY=0
[[ -t 1 ]] && IS_TTY=1

clear_line() { (( IS_TTY )) && printf '\r\033[K'; return 0; }
say()  { clear_line; echo "$@"; }
warn() { clear_line; echo "$@" >&2; }
die()  { warn "Error: $*"; exit 1; }

# progress <current> <total> <text>
# Draws a progress bar on the current line (only in an interactive terminal;
# in logs or cron output you get the plain per-guest lines instead).
progress() {
  (( IS_TTY )) || return 0
  local cur=$1 total=$2 text=$3 width=25 filled bar rest
  filled=$(( (cur - 1) * width / total ))
  printf -v bar  '%*s' "$filled" '';            bar=${bar// /#}
  printf -v rest '%*s' $(( width - filled )) ''; rest=${rest// /.}
  printf '\r\033[K[%s%s] %d/%d %s' "$bar" "$rest" "$cur" "$total" "${text:0:60}"
}

confirm() {
  local answer
  read -rp "$1 (y/n) " answer
  [[ $answer =~ ^[Yy]$ ]]
}

# Print a list indented, or nothing if empty
fmt_list() { (( $# )) && printf '  %s\n' "$@"; }

# ---------------------------------------------------------
# Startup checks
# ---------------------------------------------------------

[[ $EUID -eq 0 ]] || die "must run as root (try sudo)."
command -v qm >/dev/null && command -v pct >/dev/null \
  || die "qm/pct not found - is this a Proxmox host?"
[[ -d /etc/pve/local ]] || die "/etc/pve is not available - is pve-cluster running?"

exec 9>"$RUNLOCK" || die "cannot create $RUNLOCK"
flock -n 9 || die "another copy of this script is already running."

on_interrupt() {
  clear_line
  echo >&2
  if [[ -f $LOCKFILE ]]; then
    warn "Interrupted. Nothing is lost: every guest touched so far is recorded in $LOCKFILE."
    warn "Run '$0 status' to check, then '$0 on' to finish enabling or '$0 off' to restore."
  else
    warn "Interrupted before any change was made."
  fi
  exit 130
}
trap on_interrupt INT TERM

# ---------------------------------------------------------
# Notifications
# ---------------------------------------------------------

notify_sendmail() {
  local sev=$1 title=$2 msg=$3
  [[ -x /usr/sbin/sendmail ]] || return 1
  printf 'To: root\nSubject: [%s] %s\n\n%s\n' "${sev^^}" "$title" "$msg" \
    | /usr/sbin/sendmail -i root
}

# Custom Handlebars templates used by the "api" method. Created once, in the
# official override directory; they don't touch any built-in template.
ensure_templates() {
  [[ -f $TEMPLATE_DIR/maintmode-subject.txt.hbs ]] && return 0
  mkdir -p "$TEMPLATE_DIR" || return 1
  printf '%s\n' '{{ title }}'              > "$TEMPLATE_DIR/maintmode-subject.txt.hbs" &&
  printf '%s\n' '{{ message }}'            > "$TEMPLATE_DIR/maintmode-body.txt.hbs" &&
  printf '%s\n' '<pre>{{ message }}</pre>' > "$TEMPLATE_DIR/maintmode-body.html.hbs"
}

notify_api() {
  ensure_templates || return 1
  LEVEL=$1 TITLE=$2 MESSAGE=$3 NODE=$HOST perl -MPVE::Notify -e '
    my $data = {
      %{ PVE::Notify::common_template_data() },
      title   => $ENV{TITLE},
      message => $ENV{MESSAGE},
    };
    PVE::Notify::notify($ENV{LEVEL}, "maintmode", $data,
      { type => "maintmode", hostname => $ENV{NODE} });
  '
}

# notify <info|notice|warning|error> <title> <message>
# A failed notification only prints a warning; it never aborts the script.
notify() {
  local sev=$1 title=$2 msg=$3
  [[ $NOTIFY_METHOD == none ]] && return 0
  say "Sending notification ($NOTIFY_METHOD)..."
  if [[ $NOTIFY_METHOD == api ]]; then
    if notify_api "$sev" "$title" "$msg"; then
      say "Notification sent."
      return 0
    fi
    warn "Warning: PVE::Notify call failed, falling back to sendmail."
  fi
  if notify_sendmail "$sev" "$title" "$msg"; then
    say "Notification sent."
  else
    warn "Warning: the notification could not be sent."
  fi
}

# ---------------------------------------------------------
# Guest helpers (read the config files directly: much faster
# than calling qm/pct config once per guest)
# ---------------------------------------------------------

guest_cmd() { [[ $1 == VM ]] && echo qm || echo pct; }
conf_path() { [[ $1 == VM ]] && echo "$QEMU_DIR/$2.conf" || echo "$LXC_DIR/$2.conf"; }

# conf_value <file> <key>: value from the guest's current config.
# Stops at the first [section] so snapshots and pending changes are ignored.
conf_value() {
  awk -v k="$2" '/^\[/ {exit} index($0, k ": ") == 1 {print substr($0, length(k) + 3); exit}' \
    "$1" 2>/dev/null
}

# label <type> <id>: "VM 100 (webserver)"
label() {
  local f name
  f=$(conf_path "$1" "$2")
  name=$(conf_value "$f" "$([[ $1 == VM ]] && echo name || echo hostname)")
  echo "$1 $2${name:+ ($name)}"
}

# Print "VM <id>" / "CT <id>" for every guest that currently has autostart on
scan_onboot() {
  local f id
  for f in "$QEMU_DIR"/*.conf; do
    [[ -e $f ]] || continue
    id=${f##*/}; id=${id%.conf}
    [[ $(conf_value "$f" onboot) == 1 ]] && echo "VM $id"
  done
  for f in "$LXC_DIR"/*.conf; do
    [[ -e $f ]] || continue
    id=${f##*/}; id=${id%.conf}
    [[ $(conf_value "$f" onboot) == 1 ]] && echo "CT $id"
  done
  return 0
}

# Lockfile entries in canonical form ("VM 100"); also converts the original
# script's format ("VM100") in place.
read_lockfile() {
  sed -i -E 's/^(VM|CT) ?([0-9]+)[[:space:]]*$/\1 \2/' "$LOCKFILE"
  grep -E '^(VM|CT) [0-9]+$' "$LOCKFILE"
}

# ---------------------------------------------------------
# Maintenance mode
# ---------------------------------------------------------

enable_maint() {
  local resume=0 total i=0 entry type id cmd lbl err title msg
  local entries=() recorded=() ok_list=() fail_list=()
  [[ -f $LOCKFILE ]] && resume=1

  say "Scanning guest configs on $HOST..."
  mapfile -t entries < <(scan_onboot)
  total=${#entries[@]}

  if (( total == 0 )); then
    if (( resume )); then
      say "Maintenance mode is already ON and complete: no guest has autostart enabled."
    else
      say "No VMs/CTs have autostart enabled. Nothing to do."
    fi
    return 0
  fi

  (( resume )) && say "Maintenance mode is already ON, but some guests still have autostart enabled. Finishing the job."
  say "Found $total guest(s) with autostart enabled:"
  for entry in "${entries[@]}"; do
    read -r type id <<< "$entry"
    say "  $(label "$type" "$id")"
  done
  say ""
  say "Disabling autostart:"

  touch "$LOCKFILE" || die "cannot write $LOCKFILE"
  for entry in "${entries[@]}"; do
    i=$(( i + 1 ))
    read -r type id <<< "$entry"
    cmd=$(guest_cmd "$type")
    lbl=$(label "$type" "$id")

    # Record BEFORE changing, so an interrupted run can never leave a guest
    # disabled without a record of it.
    grep -qxF "$entry" "$LOCKFILE" || echo "$entry" >> "$LOCKFILE"

    progress "$i" "$total" "$lbl: disabling autostart..."
    if err=$("$cmd" set "$id" --onboot 0 2>&1 >/dev/null); then
      say "  [$i/$total] $lbl: autostart disabled"
    else
      warn "  [$i/$total] $lbl: FAILED - ${err%%$'\n'*}"
      fail_list+=("$lbl")
    fi
  done
  clear_line

  # Everything recorded that now has autostart off (includes guests from an
  # earlier, interrupted run)
  mapfile -t recorded < <(read_lockfile)
  for entry in "${recorded[@]}"; do
    read -r type id <<< "$entry"
    [[ $(conf_value "$(conf_path "$type" "$id")" onboot) == 1 ]] || ok_list+=("$(label "$type" "$id")")
  done

  title="Maintenance mode enabled on $HOST"
  (( resume )) && title+=" (resumed)"
  (( ${#fail_list[@]} )) && title+=" - with errors"

  msg=$(cat <<EOF
Maintenance mode was enabled on $HOST at $(date '+%F %T').

Autostart at boot is disabled for:
$(fmt_list "${ok_list[@]}" || echo "  (none)")
$( (( ${#fail_list[@]} )) && printf '\nFAILED - these guests will STILL start at boot:\n%s\n' "$(fmt_list "${fail_list[@]}")")

Run "$0 off" to restore autostart when maintenance is finished.
EOF
)

  say ""
  notify warning "$title" "$msg"
  say ""
  if (( ${#fail_list[@]} )); then
    warn "Maintenance mode is ON, but ${#fail_list[@]} guest(s) could not be changed and will still start at boot."
    warn "Fix the cause (e.g. a guest lock) and run '$0 on' again."
    return 1
  fi
  say "Maintenance mode is ON: ${#ok_list[@]} guest(s) will not start at boot."
  say "Run '$0 off' to restore."
}

disable_maint() {
  local total i=0 entry type id cmd lbl err f msg
  local entries=() done_list=() gone_list=() fail_entries=() fail_list=()

  mapfile -t entries < <(read_lockfile)
  total=${#entries[@]}
  say "Restoring autostart for $total guest(s) on $HOST:"

  for entry in "${entries[@]}"; do
    i=$(( i + 1 ))
    read -r type id <<< "$entry"
    cmd=$(guest_cmd "$type")
    f=$(conf_path "$type" "$id")

    if [[ ! -f $f ]]; then
      warn "  [$i/$total] $entry: no longer exists on this node, skipping"
      gone_list+=("$entry")
      continue
    fi

    lbl=$(label "$type" "$id")
    # Already restored (e.g. by an earlier, interrupted run): nothing to do
    if [[ $(conf_value "$f" onboot) == 1 ]]; then
      say "  [$i/$total] $lbl: already enabled"
      done_list+=("$lbl")
      continue
    fi

    progress "$i" "$total" "$lbl: enabling autostart..."
    if err=$("$cmd" set "$id" --onboot 1 2>&1 >/dev/null); then
      say "  [$i/$total] $lbl: autostart enabled"
      done_list+=("$lbl")
    else
      warn "  [$i/$total] $lbl: FAILED - ${err%%$'\n'*}"
      fail_entries+=("$entry")
      fail_list+=("$lbl")
    fi
  done
  clear_line

  msg=$(cat <<EOF
Maintenance mode was disabled on $HOST at $(date '+%F %T').

Autostart at boot has been restored for:
$(fmt_list "${done_list[@]}" || echo "  (none)")
$( (( ${#gone_list[@]} )) && printf '\nSkipped (guest no longer exists):\n%s\n' "$(fmt_list "${gone_list[@]}")")
$( (( ${#fail_list[@]} )) && printf '\nFAILED - maintenance mode is still ON for:\n%s\n' "$(fmt_list "${fail_list[@]}")")
EOF
)

  say ""
  if (( ${#fail_list[@]} )); then
    # Keep only the failures in the lockfile so a rerun retries just those
    printf '%s\n' "${fail_entries[@]}" > "$LOCKFILE"
    notify error "Maintenance mode restore FAILED on $HOST" "$msg"
    say ""
    warn "${#fail_list[@]} guest(s) could not be restored; maintenance mode stays ON for them."
    warn "Fix the cause (e.g. a guest lock) and run '$0 off' again."
    return 1
  fi

  mv -f "$LOCKFILE" "$LASTFILE"
  notify info "Maintenance mode disabled on $HOST" "$msg"
  say ""
  say "Maintenance mode is OFF. Restored list saved to $LASTFILE."
}

show_status() {
  local entry type id f state pending
  if [[ ! -f $LOCKFILE ]]; then
    say "Maintenance mode is OFF."
    return 0
  fi

  say "Maintenance mode is ON. Recorded guests:"
  while read -r entry; do
    read -r type id <<< "$entry"
    f=$(conf_path "$type" "$id")
    if [[ ! -f $f ]]; then
      state="no longer exists"
    elif [[ $(conf_value "$f" onboot) == 1 ]]; then
      state="autostart ON"
    else
      state="autostart off"
    fi
    say "  $(label "$type" "$id"): $state"
  done < <(read_lockfile)

  pending=$(scan_onboot | wc -l)
  if (( pending )); then
    say ""
    say "Note: $pending guest(s) currently have autostart enabled."
    say "Run '$0 on' to finish enabling, or '$0 off' to restore everything."
  fi
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

case "${1:-toggle}" in
  on)
    enable_maint          # resumes automatically if a previous run was interrupted
    ;;
  off)
    [[ -f $LOCKFILE ]] || die "not in maintenance mode."
    disable_maint
    ;;
  status)
    show_status
    ;;
  test-notify)
    notify info "Maintenance mode test on $HOST" \
      "This is a test notification from $0 (method: $NOTIFY_METHOD)."
    ;;
  toggle)
    if [[ -f $LOCKFILE ]]; then
      show_status
      echo
      if [[ -n $(scan_onboot) ]]; then
        read -rp "Maintenance mode looks incomplete. [c]ontinue enabling, [r]estore autostart, or [q]uit? " answer
        case $answer in
          c|C) enable_maint ;;
          r|R) disable_maint ;;
          *)   say "Exiting." ;;
        esac
      elif confirm "Restore autostart for these guests?"; then
        disable_maint
      else
        say "Exiting."
      fi
    else
      if confirm "Enable maintenance mode and disable autostart for all VMs/CTs?"; then
        enable_maint
      else
        say "Exiting."
      fi
    fi
    ;;
  *)
    echo "Usage: $0 [on|off|status|test-notify]"
    exit 2
    ;;
esac