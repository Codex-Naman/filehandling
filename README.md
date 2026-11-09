# mycp

`mycp` is a Linux proof-of-concept for the file-copy layer of an enterprise backup and recovery system. It copies regular files and directory trees using low-level Linux system calls for byte transfer and metadata operations instead of `fopen`, `fread`, `fwrite`, or `readdir`.

## Build and test

On Debian/Ubuntu:

```sh
sudo apt-get install build-essential pkg-config libgtest-dev cppcheck valgrind
```

On RHEL/Fedora-compatible systems:

```sh
sudo dnf install gcc gcc-c++ make pkgconf-pkg-config gtest-devel cppcheck valgrind
```

```sh
make
make test
make integration
make gtest
make valgrind
make coverage
make misra
make misra-platform
```

If test tools are installed in user-owned directories on a company RHEL server,
pass their paths and GoogleTest flags without using `sudo`:

```sh
make cppcheck CPPCHECK="$HOME/tools/cppcheck"
make misra CPPCHECK="$HOME/tools/cppcheck"
make gtest \
  GTEST_CFLAGS="-I$HOME/tools/gtest/include" \
  GTEST_LIBS="-L$HOME/tools/gtest/lib -lgtest_main -lgtest -pthread"
make valgrind VALGRIND="$HOME/tools/valgrind/bin/valgrind"
make coverage GCOV="$HOME/tools/gcc/bin/gcov"
```

The same overrides are accepted by `make test-all`. `CC` and `CXX` can also be
set to user-owned compiler binaries. If a tool is not available system-wide,
the company must provide it or you must build it in a user-writable directory;
the Makefile does not require root access.

The byte-copy, verification, and resume algorithms live in the portable
`src/mycp_core.c`/`include/mycp_core.h` layer. Linux file descriptors and filesystem
syscalls remain in the executable adapter in `src/mycp.c`; see
`MISRA_DEVIATIONS.md` for the platform boundary and its review requirements.

## Examples

```sh
./build/mycp --preserve --verify --progress source.img /backup/source.img
./build/mycp -r --preserve --resume --progress /srv/data /backup/data
./build/mycp -r --sync --verify --benchmark --log /var/log/mycp.log /srv/data /backup/data
./build/mycp --info source.img /dev/null
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
