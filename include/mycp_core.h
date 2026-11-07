#ifndef MYCP_CORE_H
#define MYCP_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef int (*mycp_core_read_fn)(void *context, uint8_t *buffer,
                                 size_t capacity, size_t *count);
typedef int (*mycp_core_write_fn)(void *context, const uint8_t *buffer,
                                  size_t count);

typedef struct {
    void *context;
    mycp_core_read_fn read;
    mycp_core_write_fn write;
} mycp_core_io_t;

int mycp_core_copy(const mycp_core_io_t *io, uint8_t *buffer,
                   size_t buffer_size, uint64_t expected_size,
                   uint64_t *copied);
int mycp_core_verify(const mycp_core_io_t *source, const mycp_core_io_t *destination,
                     uint8_t *source_buffer, uint8_t *destination_buffer,
                     size_t buffer_size);
int mycp_core_prefix_matches(const mycp_core_io_t *source,
                             const mycp_core_io_t *destination,
                             uint8_t *source_buffer, uint8_t *destination_buffer,
                             size_t buffer_size, uint64_t prefix_size,
                             int *matches);

#endif
