# Proxmox Maintenance Mode

A Bash script that temporarily disables **autostart at boot** (`onboot`) for every VM and container on a Proxmox VE node, then later restores it for exactly the guests it changed. It is meant for host maintenance, where you need to reboot the node, possibly several times, without all the guests starting up.

It alerts you through the Proxmox global notification system when maintenance mode is turned on, when it is turned off, and when something fails.

Based on [Darkhand81/ProxmoxMaintenanceMode](https://github.com/Darkhand81/ProxmoxMaintenanceMode), rewritten for robustness, progress output, resumable runs and notifications.

---

## Requirements

- Proxmox VE 8.1 or newer (for the global notification system; the core function works on older versions)
- A standalone node, run as `root`
- Notifications configured under **Datacenter → Notifications** (the default matcher sending to your SMTP target is enough)

## Installation

```bash
cp maintenance-mode.sh /root/
chmod +x /root/maintenance-mode.sh
./maintenance-mode.sh test-notify   # confirm alerts arrive
```

## Usage

| Command | What it does |
|---|---|
| `./maintenance-mode.sh on` | Disables autostart on every guest that has it, records them, sends a **warning** alert. Resumes an interrupted run. |
| `./maintenance-mode.sh off` | Restores autostart for the recorded guests, sends an **info** alert (or **error** if something failed). Resumes an interrupted run. |
| `./maintenance-mode.sh status` | Shows whether maintenance mode is on and the current autostart state of each recorded guest. |
| `./maintenance-mode.sh test-notify` | Sends a test notification. |
| `./maintenance-mode.sh` | Interactive toggle: asks for confirmation, then turns maintenance mode on or off. |

### Typical workflow

```bash
./maintenance-mode.sh on        # before maintenance
./maintenance-mode.sh status    # check: every guest should show "autostart off"
# ... do your maintenance, reboot as often as needed ...
./maintenance-mode.sh off       # when finished
```

Maintenance mode only affects what happens **at boot**. It does not stop guests that are currently running. Shut them down yourself (or let the host shutdown do it) before rebooting.

### Example output

```
Scanning guest configs on easttower...
Found 3 guest(s) with autostart enabled:
  VM 105 (ollama)
  VM 108 (openwrt)
  CT 107 (pihole)

Disabling autostart:
  [1/3] VM 105 (ollama): autostart disabled
[########.................] 2/3 VM 108 (openwrt): disabling autostart...
```

The progress bar only appears in an interactive terminal. When the output goes to a log or cron, you get the plain per-guest lines.

---

## How it works

1. **Scan.** The script reads the guest configs directly from `/etc/pve/qemu-server/*.conf` and `/etc/pve/lxc/*.conf` and finds every guest with `onboot: 1`. Only the current configuration is read; snapshot and pending sections are ignored. Reading the files is much faster than calling `qm config` / `pct config` once per guest.
2. **Record, then change.** For each guest, the script first writes it to the lockfile and then runs `qm set <id> --onboot 0` or `pct set <id> --onboot 0`. Changes go through the official tools, so Proxmox's own config locking is respected.
3. **Restore.** `off` reads the lockfile and runs `--onboot 1` for each guest. If everything succeeds, the lockfile is moved to `maintmode.last`.

### Files

| Path | Purpose |
|---|---|
| `/root/maintmode.lock` | Exists only while maintenance mode is on. Lists the guests to restore, one per line (`VM 105`, `CT 107`). |
| `/root/maintmode.last` | The list from the last successful restore, kept for reference. |
| `/run/maintmode.run` | Prevents two copies of the script from running at once. |
| `/etc/pve/notification-templates/default/maintmode-*.hbs` | Only created if you use the `api` notification method (see below). |

The lockfile is plain text and can be edited by hand. The script also reads the original script's format (`VM105`).

---

## Interruptions and failures

Every guest is recorded **before** it is changed, so no interruption (Ctrl+C, lost SSH session, crash) can leave a guest disabled without a record of it.

Both `on` and `off` are safe to run again:

- **`on` after an interrupted `on`** scans again, disables the guests that still have autostart on, and adds them to the existing list.
- **`off` after an interrupted `off`** skips guests that were already restored ("already enabled") and finishes the rest.
- **The interactive toggle** detects an incomplete enable and asks whether to **c**ontinue, **r**estore, or **q**uit.
- **`status`** shows the state of each guest and warns if any guest still has autostart enabled.

If a guest can't be changed (for example, because it is locked by a running backup), the script reports the error, sends an alert, and exits with a non-zero code:

- During `on`, the failed guest keeps autostart enabled. Fix the cause and run `on` again.
- During `off`, only the failed guests stay in the lockfile, so maintenance mode stays on for them. Fix the cause and run `off` again.

Guests that were deleted during maintenance are skipped during restore and listed in the alert.

---

## Notifications

The method is set by `NOTIFY_METHOD` near the top of the script. You can also override it for a single run:

```bash
NOTIFY_METHOD=api ./maintenance-mode.sh on
```

| Method | Description |
|---|---|
| `sendmail` (default) | Sends a mail to the local `root` user. Proxmox feeds it into the global notification system as a `system-mail` notification, which the default matcher routes to your targets. **Officially supported.** Proxmox always sets the severity to *unknown*, so the subject is prefixed with `[WARNING]`, `[INFO]` or `[ERROR]` instead. |
| `api` | Calls Proxmox's internal `PVE::Notify` Perl module. Gives real severities and a custom field `type=maintmode` for matcher rules. **Not officially supported** and could break after a Proxmox update; if the call fails, the script falls back to `sendmail`. Creates three small templates in the official override directory on first use. |
| `none` | No notifications. |

| Event | Severity |
|---|---|
| Maintenance mode enabled | warning |
| Maintenance mode disabled | info |
| Restore failed for one or more guests | error |

A failed notification only prints a warning. It never stops or undoes the maintenance-mode change.

---

## Limitations

- **Local node only.** It only acts on guests whose configs are on this node. That is intended for a standalone host. In a cluster, a guest migrated away during maintenance would be skipped on restore.
- **Not for HA-managed guests.** HA resources ignore `onboot`. For HA, use `ha-manager crm-command node-maintenance enable <node>` instead.
- **Boot behavior only.** It does not stop, start or shut down any guest.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `another copy of this script is already running` | Wait for the other run to finish. If none is running, the lock is released automatically when the process exits. |
| `/etc/pve is not available` | The cluster filesystem isn't mounted. Check `systemctl status pve-cluster`. |
| No alert received | Run `test-notify`, then check **Datacenter → Notifications** (matcher and target) and `journalctl -u postfix`. |
| A guest shows `FAILED` | The error from `qm`/`pct` is printed next to it. Usually the guest is locked (backup, snapshot, migration). Wait, then rerun the same command. |
| A guest was missed or needs fixing by hand | `qm set <id> --onboot 1` or `pct set <id> --onboot 1`, and add or remove its line in `/root/maintmode.lock` if needed. |

---

## Changes from the original script

- Correct handling of VMIDs of any length (the original split IDs over 99999)
- Exact matching of `onboot: 1`, with no false matches from descriptions or snapshots
- Guests recorded before being changed, so interruptions are safe
- Resumable `on` and `off`, plus a `status` command
- Errors reported per guest, with a non-zero exit code; failed restores stay in maintenance mode
- Deleted guests skipped during restore
- Fast scanning by reading config files directly
- Progress bar, per-guest counters and guest names in the output
- Protection against running two copies at once
- Alerts through the Proxmox notification system
- Reads lockfiles written by the original script