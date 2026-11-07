# MISRA boundary

`src/mycp_core.c` is the portable copy/verification core. It is checked by:

```sh
make misra
```

The Linux executable adapter remains in `src/mycp.c` because this project is
explicitly Linux-specific. It uses Linux/POSIX facilities that are outside a
strict portable MISRA core, including file descriptors, `syscall`,
`getdents64`, dynamic allocation for runtime-sized buffers, and POSIX file
metadata APIs. These calls are the platform boundary and are audited with:

```sh
make misra-platform
```

The platform findings must be reviewed and approved as project deviations
for a formal MISRA process. They are not suppressed by the core check.
