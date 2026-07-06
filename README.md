# Immich Snapshot Tool

An Immich Backup Tool. This tool creates the complete snapshot of the immich library, database as-a-whole backup.

This guide explains how the script works, what it asks for, and how to run it safely on your own server.

If you prefer running incremental backups, then check out the sibiling repo on [Immich Incremental Backup](https://github.com/akshayskrishna/Immich-Incremental-Snapshot)

## What this tool does

Immich Snapshot helps you create a consistent backup of an Immich Docker deployment by:

- asking which Immich compose folder to use
- asking where backups should be stored
- optionally asking for an external library path
- optionally installing a cron schedule
- creating a database dump
- automatically stops Immich briefly before copying media
- copies the Immich media storage
- copies the external library (if provided)
- automatically starts Immich again after completion (even if something fails)

> [!IMPORTANT]
>
> - backup folder should be created before running the script
> - Immich service is expected to be running while running the script.

## How it works

### 1) Select the Immich Docker folder

The script first asks whether the current folder is the Immich Docker folder.

- If yes, it uses the current working directory.
- If no, it asks for the correct path.
- It validates that a supported Docker Compose file exists before continuing.

### 2) Choose the backup destination

Next, it asks where the backup should be stored.

- The destination must already exist.
- The destination must be writable.
- The script refuses to back up into a path that looks like part of the source tree.

### 3) Optional external library

If your Immich setup has an external library, the script asks for its path.

- If provided, the path is validated.
- If not, the script skips this step.

### 4) Optional cron setup

The script can optionally create a cron entry.

Available schedule choices:

- Daily
- Weekly
- Twice a month
- Once a month
- Perform once now

If a scheduled backup is chosen, the script asks for the missing schedule details such as:

- hour of day [0 - 23]
- day of week for weekly runs
- day of month for monthly runs
- two days of month for twice-monthly runs

### 5) Database backup

The script creates an Immich PostgreSQL dump as part of the backup.

- It tries common environment variables used by Immich/Postgres containers.
- It compresses the dump with gzip.
- It verifies that the dump was created successfully.

### 6) Stop Immich safely

Before copying media, the script stops the compose stack briefly.

This reduces the chance of a partial or inconsistent file copy.

### 7) Copy media and external library

The script copies:

- the Immich media storage directory
- the external library directory, if one was provided

It uses `rsync` so the copy is readable, efficient, and easy to follow.

### 8) Bring Immich back up

The script uses cleanup logic so Immich is started again even if a step fails.

That is important because backups should not leave services stopped.

## Usage

### Download the script

```bash
wget https://raw.githubusercontent.com/akshayskrishna/Immich-Backup-Snapshot/main/backup-immich-snapshot.sh
```

### Interactive (recommended)

```bash
bash backup-immich-template.sh
```

### Incremental variant

If you have a large Immich library and want to avoid re-copying unchanged data every run, use the incremental companion script [Immich Incremental Backup](https://github.com/akshayskrishna/Immich-Incremental-Snapshot)

### One-time non-interactive run

```bash
bash backup-immich-template.sh \
  --once \
  --yes \
  --immich-dir /path/to/immich-app \
  --backup-dir /path/to/backups \
  --media-dir /path/to/immich-media \
  --db-service immich_postgres
```

### With an external library

```bash
bash backup-immich-template.sh \
  --once \
  --yes \
  --immich-dir /path/to/immich-app \
  --backup-dir /path/to/backups \
  --media-dir /path/to/immich-media \
  --external-library /path/to/external/library \
  --db-service immich_postgres
```

## Safety notes

- The backup destination must already exist.
- The script does not create destructive changes to your data.
- The script avoids backing up into the source tree.
- Cron setup is optional.
- Review the script before running it on a production server.

## Requirements

The script expects these tools to be available:

- `bash`
- `docker`
- `rsync`
- `gzip`
- `sed`
- `awk`
- `grep`
- `mktemp`

## Banner inspiration

The ASCII branding style in this script is inspired by:

- [shinshin86/oh-my-logo](https://github.com/shinshin86/oh-my-logo)

## Recommended workflow

1. Test the script interactively first.
2. Confirm the compose folder and backup destination.
3. Verify the database dump is created.
4. Check the copied media files.
5. Only then schedule cron if everything looks correct.

## Restore companion

If you need to recover from one of these backups, use the restore helper in the sibling repo at [Immich Restore](https://github.com/akshayskrishna/Immich-Snapshot-Restore)

The restore script checks the manifest written by the backup script before it restores the database or files.
