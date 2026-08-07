// PatchNest KPM Ed25519 verifier.
//
// Usage: kpm-verify <public-key-hex> <signature-hex> <message-file>
// Exit 0 means valid signature, 1 means invalid signature, and 2 means an
// input or system error. The message file is opened read-only and never changed.

#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "monocypher-ed25519.h"

#define MAX_MESSAGE_SIZE (64u * 1024u * 1024u)

static int hex_nibble(char value)
{
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

static int decode_hex(uint8_t *output, size_t output_size, const char *input)
{
    if (input == NULL || strlen(input) != output_size * 2u) {
        return -1;
    }
    for (size_t index = 0; index < output_size; ++index) {
        const int high = hex_nibble(input[index * 2u]);
        const int low = hex_nibble(input[index * 2u + 1u]);
        if (high < 0 || low < 0) {
            return -1;
        }
        output[index] = (uint8_t)((high << 4) | low);
    }
    return 0;
}

static int open_message(const char *path, int *fd_out, const uint8_t **data_out,
                        size_t *size_out)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        return -1;
    }

    struct stat status;
    if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
        close(fd);
        return -1;
    }
    if ((uintmax_t)status.st_size > (uintmax_t)MAX_MESSAGE_SIZE ||
        (uintmax_t)status.st_size > (uintmax_t)SIZE_MAX) {
        close(fd);
        return -1;
    }

    const size_t size = (size_t)status.st_size;
    static const uint8_t empty_message = 0;
    const uint8_t *data = &empty_message;
    if (size > 0u) {
        void *mapping = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mapping == MAP_FAILED) {
            close(fd);
            return -1;
        }
        data = (const uint8_t *)mapping;
    }

    *fd_out = fd;
    *data_out = data;
    *size_out = size;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 4) {
        fprintf(stderr,
                "usage: kpm-verify <public-key-hex> <signature-hex> <message-file>\n");
        return 2;
    }

    uint8_t public_key[32];
    uint8_t signature[64];
    if (decode_hex(public_key, sizeof(public_key), argv[1]) != 0 ||
        decode_hex(signature, sizeof(signature), argv[2]) != 0) {
        fprintf(stderr, "invalid hexadecimal public key or signature\n");
        return 2;
    }

    int fd = -1;
    const uint8_t *message = NULL;
    size_t message_size = 0;
    if (open_message(argv[3], &fd, &message, &message_size) != 0) {
        fprintf(stderr, "cannot read message file: %s\n", strerror(errno));
        crypto_wipe(public_key, sizeof(public_key));
        crypto_wipe(signature, sizeof(signature));
        return 2;
    }

    const int check = crypto_ed25519_check(signature, public_key,
                                            message, message_size);
    if (message_size > 0u) {
        (void)munmap((void *)message, message_size);
    }
    (void)close(fd);
    crypto_wipe(public_key, sizeof(public_key));
    crypto_wipe(signature, sizeof(signature));
    return check == 0 ? 0 : 1;
}
