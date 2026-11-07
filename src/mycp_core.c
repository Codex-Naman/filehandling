#include "mycp_core.h"

#include <errno.h>
#include <string.h>

static int compare_blocks(const uint8_t *left, const uint8_t *right,
                          size_t count)
{
    return (memcmp(left, right, count) == 0) ? 1 : 0;
}

int mycp_core_copy(const mycp_core_io_t *io, uint8_t *buffer,
                   size_t buffer_size, uint64_t expected_size,
                   uint64_t *copied)
{
    int status = 0;
    uint64_t total = 0U;

    if ((io == NULL) || (io->read == NULL) || (io->write == NULL) ||
        (buffer == NULL) || (buffer_size == 0U) || (copied == NULL)) {
        status = -1;
    } else {
        int finished = 0;
        while (finished == 0) {
            size_t count = 0U;
            if (io->read(io->context, buffer, buffer_size, &count) != 0) {
                status = -1;
                finished = 1;
            } else if (count == 0U) {
                finished = 1;
            } else if (io->write(io->context, buffer, count) != 0) {
                status = -1;
                finished = 1;
            } else {
                total += (uint64_t)count;
            }
        }
    }

    if (copied != NULL) {
        *copied = total;
    }
    if ((status == 0) && (total != expected_size)) {
        errno = EIO;
        status = -1;
    }
    return status;
}

int mycp_core_verify(const mycp_core_io_t *source, const mycp_core_io_t *destination,
                     uint8_t *source_buffer, uint8_t *destination_buffer,
                     size_t buffer_size)
{
    int status = 0;

    if ((source == NULL) || (destination == NULL) ||
        (source->read == NULL) || (destination->read == NULL) ||
        (source_buffer == NULL) || (destination_buffer == NULL) ||
        (buffer_size == 0U)) {
        status = -1;
    } else {
        int finished = 0;
        while (finished == 0) {
            size_t source_count = 0U;
            size_t destination_count = 0U;
            if ((source->read(source->context, source_buffer, buffer_size,
                              &source_count) != 0) ||
                (destination->read(destination->context, destination_buffer,
                                    buffer_size, &destination_count) != 0)) {
                status = -1;
                finished = 1;
            } else if ((source_count != destination_count) ||
                       (compare_blocks(source_buffer, destination_buffer,
                                       source_count) == 0)) {
                errno = EIO;
                status = -1;
                finished = 1;
            } else if (source_count == 0U) {
                finished = 1;
            } else {
                finished = 0;
            }
        }
    }
    return status;
}

int mycp_core_prefix_matches(const mycp_core_io_t *source,
                             const mycp_core_io_t *destination,
                             uint8_t *source_buffer, uint8_t *destination_buffer,
                             size_t buffer_size, uint64_t prefix_size,
                             int *matches)
{
    int status = 0;
    int result = 1;

    if ((source == NULL) || (destination == NULL) ||
        (source->read == NULL) || (destination->read == NULL) ||
        (source_buffer == NULL) || (destination_buffer == NULL) ||
        (buffer_size == 0U) || (matches == NULL)) {
        status = -1;
    } else {
        uint64_t remaining = prefix_size;
        while ((remaining > 0U) && (result != 0) && (status == 0)) {
            size_t requested = (remaining < (uint64_t)buffer_size) ?
                               (size_t)remaining : buffer_size;
            size_t source_count = 0U;
            size_t destination_count = 0U;
            if ((source->read(source->context, source_buffer, requested,
                              &source_count) != 0) ||
                (destination->read(destination->context, destination_buffer,
                                    requested, &destination_count) != 0)) {
                status = -1;
            } else if ((source_count != destination_count) ||
                       (compare_blocks(source_buffer, destination_buffer,
                                       source_count) == 0)) {
                result = 0;
            } else if (source_count == 0U) {
                result = 0;
            } else {
                remaining -= (uint64_t)source_count;
            }
        }
    }

    if (matches != NULL) {
        *matches = result;
    }
    return status;
}
