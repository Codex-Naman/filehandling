# mycp

`mycp` is a Linux proof-of-concept for the file-copy layer of an enterprise backup and recovery system. It copies regular files and directory trees using low-level Linux system calls for byte transfer and metadata operations instead of `fopen`, `fread`, `fwrite`, or `readdir`.

## Build and test

```sh
make
make test
```

## Examples

```sh
./mycp --preserve --verify --progress source.img /backup/source.img
./mycp -r --preserve --resume --progress /srv/data /backup/data
./mycp -r --sync --verify --benchmark --log /var/log/mycp.log /srv/data /backup/data
./mycp --info source.img /dev/null
```

## Backup/recovery mapping

- Basic backup: `SOURCE DEST` copies a file or, with `-r`, a directory tree.
- Incremental synchronization: `--sync` skips regular files whose size and modification time match the destination.
- Recovery of an interrupted file: `--resume` starts at the existing destination length when it is smaller than the source. The destination is truncated if it is not a valid partial prefix candidate.
- Backup validation: `--verify` re-reads source and destination through file descriptors and compares every byte.
- Durability: completed files are flushed with `fsync` before being reported successful.
- Audit trail: `--log PATH` appends timestamped operation and error records.

## Notes

The POC intentionally handles regular files and directories. Symbolic links, ownership/xattrs/ACLs, sparse-file preservation, crash-consistent snapshots, encryption, and remote transport should be added before production deployment. `--sync` uses size plus second-resolution mtime as a fast incremental heuristic; `--verify` should be enabled when content-level validation is required.
