# R36SX-ExportTool

> Pulls contents off a MicroSD card with a broken or missing partition table.  
> Most R36S(X) clones ship with low-quality, fake-capacity cards that have this issue.

**Tested on:** Linux (CachyOS)

---

## The Problem

R36S and R36SX handhelds (and many of their clones) come with cheap MicroSD cards that are often:

- Sold as 64 GB but physically 8–16 GB (fake capacity)
- Formatted without a valid MBR or partition table
- Unreadable by standard tools (`fdisk`, file managers, `lsblk`) even though the data is intact

When you plug the card into a Linux machine it shows up as a raw block device with no mountable partitions — even though all your ROMs, saves, and configs are still there.

---

## What This Tool Does

`copy_sdcard.sh` recovers your data by:

1. **Auto-detecting** the USB SD card reader device
2. **Scanning** the raw device for FAT32, FAT16, exFAT, or NTFS filesystem signatures — even without a partition table
3. **Validating** the filesystem using the BIOS Parameter Block (BPB) to confirm the correct byte offset
4. **Mounting** the filesystem read-only and copying everything to a local folder
5. **Falling back** to `mtools` if the kernel cannot mount the card directly

---

## Requirements

| Tool | Purpose | Install |
|---|---|---|
| `rsync` | Fast file copy with stats | usually pre-installed |
| `python3` | BPB validation | usually pre-installed |
| `mtools` | Fallback copy (no mount needed) | `sudo apt install mtools` |
| `ntfs-3g` | NTFS support (optional) | `sudo apt install ntfs-3g` |

---

## Usage

```bash
# Basic — auto-detects card, copies to ~/sdcard_backup
sudo bash copy_sdcard.sh

# Custom destination
sudo bash copy_sdcard.sh --dest /mnt/my_backup

# Specify device manually
sudo bash copy_sdcard.sh --device /dev/sdb

# Dry-run — detect filesystem only, don't copy anything
sudo bash copy_sdcard.sh --dry-run

# Skip confirmation prompt (for scripting)
sudo bash copy_sdcard.sh --yes

# Scan further into the disk (default is 200 MB)
sudo bash copy_sdcard.sh --scan 500

# Show all options
sudo bash copy_sdcard.sh --help
```

### Optional: install system-wide

```bash
sudo cp copy_sdcard.sh /usr/local/bin/copy_sdcard
sudo chmod +x /usr/local/bin/copy_sdcard

# Then simply run:
sudo copy_sdcard
```

---

## How It Works

Most tools assume a card has a standard MBR with a `55 AA` signature at bytes 510–511. These cards don't. Instead, `copy_sdcard.sh`:

1. Reads the first N MB of the raw device with `dd`
2. Scans for filesystem OEM strings (`FAT32   `, `NTFS    `, `EXFAT   `) and calculates the boot sector offset
3. Uses Python to parse the BIOS Parameter Block and verify the FAT table media byte matches the boot sector declaration
4. Mounts with `-o offset=<bytes>` to tell the kernel where the filesystem actually starts
5. Uses `rsync` with `--no-perms --modify-window=1` to avoid false errors caused by FAT's limited timestamp and permission support

---

## Troubleshooting

**No filesystem found**  
Try increasing the scan range: `--scan 500`. If still nothing, the card may be encrypted (BitLocker) or physically dead.

**Mount fails but mtools works**  
The boot sector's `55 AA` signature may be missing. The script automatically falls back to `mtools`, which is more lenient.

**rsync exits with code 23**  
This is normal when copying from FAT32 — it means some file timestamps or attributes couldn't be preserved. All file *content* is copied correctly. Details are in the log file printed at the end.

**`sudo` keeps asking for password**  
Run `sudo -v` in your terminal first to cache credentials, then re-run the script.

---

## Tested Cards & Devices

| Device | Card | Result |
|---|---|---|
| R36SX clone | 64 GB fake-capacity (8 GB actual), FAT32, no MBR | ✅ Full recovery |

> Have a different device or card that worked? Open a PR to add it to the table!

---

## Contributing

PRs and issues welcome. If the script fails on your card, please open an issue and include:

- Output of: `sudo lsblk -o NAME,SIZE,FSTYPE,TRAN,MODEL`
- Output of: `sudo bash copy_sdcard.sh --dry-run --scan 500`

---

## License

MIT — do whatever you want with it.
