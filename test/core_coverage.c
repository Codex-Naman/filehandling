#include "mycp_core.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

struct memory_io {
    const uint8_t *source;
    size_t source_size;
    size_t source_position;
    uint8_t *destination;
    size_t destination_size;
    size_t destination_position;
    int fail_read;
    int fail_write;
};

static int memory_read(void *context, uint8_t *buffer, size_t capacity, size_t *count)
{
    struct memory_io *io = context;
    size_t remaining;
    size_t amount;

    if (io->fail_read != 0) return -1;
    remaining = io->source_size - io->source_position;
    amount = (remaining < capacity) ? remaining : capacity;
    if (amount > 0U) {
        (void)memcpy(buffer, &io->source[io->source_position], amount);
        io->source_position += amount;
    }
    *count = amount;
    return 0;
}

static int memory_write(void *context, const uint8_t *buffer, size_t count)
{
    struct memory_io *io = context;

    if ((io->fail_write != 0) ||
        (count > (io->destination_size - io->destination_position))) return -1;
    (void)memcpy(&io->destination[io->destination_position], buffer, count);
    io->destination_position += count;
    return 0;
}

static int expect(int condition, const char *message)
{
    if (condition == 0) {
        (void)fprintf(stderr, "core coverage failure: %s\n", message);
        return 1;
    }
    return 0;
}

int main(void)
{
    static const uint8_t source_data[] = "core coverage data";
    uint8_t destination_data[sizeof(source_data)] = { 0U };
    uint8_t source_buffer[4U] = { 0U };
    uint8_t destination_buffer[4U] = { 0U };
    struct memory_io copy_context = {
        source_data, sizeof(source_data), 0U, destination_data,
        sizeof(destination_data), 0U, 0, 0
    };
    struct memory_io source_context = {
        source_data, sizeof(source_data), 0U, NULL, 0U, 0U, 0, 0
    };
    struct memory_io destination_context = {
        destination_data, sizeof(destination_data), 0U, NULL, 0U, 0U, 0, 0
    };
    mycp_core_io_t copy_io = { &copy_context, memory_read, memory_write };
    mycp_core_io_t source_io = { &source_context, memory_read, NULL };
    mycp_core_io_t destination_io = { &destination_context, memory_read, NULL };
    uint64_t copied = 0U;
    int matches = 0;
    int failures = 0;

    failures += expect(mycp_core_copy(&copy_io, source_buffer, sizeof(source_buffer),
                                      sizeof(source_data), &copied) == 0,
                       "copy succeeds");
    copy_context.source_position = 0U;
    copy_context.destination_position = 0U;
    failures += expect(mycp_core_copy(&copy_io, source_buffer, sizeof(source_buffer),
                                      sizeof(source_data) + 1U, &copied) < 0,
                       "size mismatch is reported");

    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    failures += expect(mycp_core_verify(&source_io, &destination_io, source_buffer,
                                        destination_buffer, sizeof(source_buffer)) == 0,
                       "verification succeeds");

    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    destination_data[0] = (uint8_t)'X';
    failures += expect(mycp_core_verify(&source_io, &destination_io, source_buffer,
                                        destination_buffer, sizeof(source_buffer)) < 0,
                       "different data fails verification");

    source_context.source_position = 0U;
    source_context.fail_read = 1;
    failures += expect(mycp_core_verify(&source_io, &destination_io, source_buffer,
                                        destination_buffer, sizeof(source_buffer)) < 0,
                       "verify read failure is reported");
    source_context.fail_read = 0;

    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    destination_data[0] = source_data[0];
    failures += expect(mycp_core_prefix_matches(&source_io, &destination_io, source_buffer,
                                                destination_buffer, sizeof(source_buffer),
                                                sizeof(source_data), &matches) == 0,
                       "matching prefix succeeds");

    destination_data[0] = (uint8_t)'X';
    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    failures += expect(mycp_core_prefix_matches(&source_io, &destination_io, source_buffer,
                                                destination_buffer, sizeof(source_buffer),
                                                sizeof(source_data), &matches) == 0,
                       "mismatching prefix is reported");
    failures += expect(matches == 0, "mismatching prefix result is false");

    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    source_context.fail_read = 1;
    failures += expect(mycp_core_prefix_matches(&source_io, &destination_io, source_buffer,
                                                destination_buffer, sizeof(source_buffer),
                                                1U, &matches) < 0,
                       "prefix read failure is reported");
    source_context.fail_read = 0;
    source_context.source_position = 0U;
    destination_context.source_position = 0U;
    destination_data[0] = source_data[0];
    failures += expect(mycp_core_prefix_matches(&source_io, &destination_io, source_buffer,
                                                destination_buffer, sizeof(source_buffer),
                                                sizeof(source_data) + 1U, &matches) == 0,
                       "short prefix is reported as mismatch");

    copy_context.source_position = 0U;
    copy_context.destination_position = 0U;
    copy_context.fail_write = 1;
    failures += expect(mycp_core_copy(&copy_io, source_buffer, sizeof(source_buffer),
                                      sizeof(source_data), &copied) < 0,
                       "write failure is reported");
    copy_context.fail_write = 0;
    copy_context.fail_read = 1;
    failures += expect(mycp_core_copy(&copy_io, source_buffer, sizeof(source_buffer),
                                      sizeof(source_data), &copied) < 0,
                       "read failure is reported");

    failures += expect(mycp_core_copy(NULL, source_buffer, sizeof(source_buffer),
                                      sizeof(source_data), &copied) < 0,
                       "invalid copy arguments fail");
    failures += expect(mycp_core_verify(NULL, &destination_io, source_buffer,
                                        destination_buffer, sizeof(source_buffer)) < 0,
                       "invalid verify arguments fail");
    failures += expect(mycp_core_prefix_matches(NULL, &destination_io, source_buffer,
                                                destination_buffer, sizeof(source_buffer),
                                                1U, &matches) < 0,
                       "invalid prefix arguments fail");

    return (failures == 0) ? 0 : 1;
}
