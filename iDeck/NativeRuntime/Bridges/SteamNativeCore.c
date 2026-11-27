#include "SteamNativeCore.h"
#include "PipelineCounters.h"

#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

enum { IDECK_STEAM_READ_WINDOW = 4 * 1024 * 1024 };

struct IDeckSteamVerifier {
    int fd;
    uint8_t *window;
    uint64_t file_size;
    uint64_t window_start;
    size_t window_length;
};

static int open_regular(const char *path, struct stat *info) {
    if (!path || !*path || !info) return -1;
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fstat(fd, info) != 0 || !S_ISREG(info->st_mode) || info->st_size < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static bool read_exact(int fd, uint8_t *destination, size_t count, uint64_t offset) {
    size_t done = 0;
    while (done < count) {
        ssize_t n = pread(fd, destination + done, count - done,
                          (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        done += (size_t)n;
    }
    return true;
}

IDeckSteamVerifier *ideck_steam_verifier_open(const char *path) {
    struct stat info;
    int fd = open_regular(path, &info);
    if (fd < 0) return NULL;
    IDeckSteamVerifier *reader = calloc(1, sizeof(*reader));
    if (!reader) { close(fd); return NULL; }
    reader->window = malloc(IDECK_STEAM_READ_WINDOW);
    if (!reader->window) {
        close(fd);
        free(reader);
        return NULL;
    }
    reader->fd = fd;
    reader->file_size = (uint64_t)info.st_size;
#ifdef F_NOCACHE
    (void)fcntl(fd, F_NOCACHE, 1);
#endif
#ifdef F_RDAHEAD
    (void)fcntl(fd, F_RDAHEAD, 1);
#endif
    return reader;
}

bool ideck_steam_verifier_check(IDeckSteamVerifier *reader, uint64_t offset,
                                size_t length, const uint8_t expected_sha[20]) {
    if (!reader || !expected_sha || !length || length > UINT32_MAX ||
        offset > reader->file_size || length > reader->file_size - offset ||
        offset > INT64_MAX || length > (uint64_t)INT64_MAX - offset)
        return false;

    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    if (length <= IDECK_STEAM_READ_WINDOW) {
        bool inside = offset >= reader->window_start &&
            offset - reader->window_start <= reader->window_length &&
            length <= reader->window_length - (size_t)(offset - reader->window_start);
        if (!inside) {
            reader->window_start = offset;
            reader->window_length = 0;
            size_t amount = (size_t)(reader->file_size - offset);
            if (amount > IDECK_STEAM_READ_WINDOW) amount = IDECK_STEAM_READ_WINDOW;
            if (!read_exact(reader->fd, reader->window, amount, offset)) return false;
            reader->window_length = amount;
        }
        if (!CC_SHA1(reader->window + (size_t)(offset - reader->window_start),
                     (CC_LONG)length, digest)) return false;
    } else {
        CC_SHA1_CTX sha;
        if (CC_SHA1_Init(&sha) != 1) return false;
        size_t done = 0;
        while (done < length) {
            size_t amount = length - done;
            if (amount > IDECK_STEAM_READ_WINDOW) amount = IDECK_STEAM_READ_WINDOW;
            if (!read_exact(reader->fd, reader->window, amount, offset + done) ||
                CC_SHA1_Update(&sha, reader->window, (CC_LONG)amount) != 1) return false;
            done += amount;
        }
        if (CC_SHA1_Final(digest, &sha) != 1) return false;
        reader->window_length = 0;
    }
    return memcmp(digest, expected_sha, CC_SHA1_DIGEST_LENGTH) == 0;
}

void ideck_steam_verifier_close(IDeckSteamVerifier *reader) {
    if (!reader) return;
    close(reader->fd);
    free(reader->window);
    free(reader);
}

bool ideck_steam_sha1_file(const char *path, uint8_t out_sha[20]) {
    if (!out_sha) return false;
    struct stat info;
    int fd = open_regular(path, &info);
    if (fd < 0) return false;
    uint8_t buffer[64 * 1024];
    CC_SHA1_CTX sha;
    bool success = CC_SHA1_Init(&sha) == 1;
    while (success) {
        ssize_t count = read(fd, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { success = false; break; }
        if (count == 0) break;
        success = CC_SHA1_Update(&sha, buffer, (CC_LONG)count) == 1;
    }
    if (success) success = CC_SHA1_Final(out_sha, &sha) == 1;
    if (close(fd) != 0) success = false;
    return success;
}

bool ideck_steam_hex_encode(const uint8_t *bytes, size_t count,
                            char *output, size_t output_capacity) {
    static const char digits[] = "0123456789abcdef";
    if (!output || (!bytes && count) ||
        count > (SIZE_MAX - 1) / 2 || output_capacity < count * 2 + 1)
        return false;
    for (size_t i = 0; i < count; ++i) {
        output[2 * i] = digits[bytes[i] >> 4];
        output[2 * i + 1] = digits[bytes[i] & 15];
    }
    output[count * 2] = '\0';
    return true;
}

static int32_t ideck_steam_decrypt_chunk_untimed(const uint8_t *input, size_t input_length,
                                  const uint8_t *key, size_t key_length,
                                  uint8_t *output, size_t output_capacity,
                                  size_t *output_length) {
    if (output_length) *output_length = 0;
    if (!input || input_length <= 16 || !key || key_length != 32 ||
        !output || !output_length || input_length - 16 > SIZE_MAX - 16 ||
        output_capacity < input_length - 16 + 16 ||
        (input_length - 16) % 16 != 0)
        return -1;

    uint8_t iv[16];
    size_t iv_bytes = 0;
    CCCryptorStatus status = CCCrypt(kCCDecrypt, kCCAlgorithmAES,
                                    kCCOptionECBMode, key, key_length,
                                    NULL, input, 16, iv, sizeof(iv), &iv_bytes);
    if (status != kCCSuccess || iv_bytes != sizeof(iv)) {
        memset(iv, 0, sizeof(iv));
        return -2;
    }
    status = CCCrypt(kCCDecrypt, kCCAlgorithmAES,
                     kCCOptionPKCS7Padding, key, key_length, iv,
                     input + 16, input_length - 16,
                     output, output_capacity, output_length);
    memset(iv, 0, sizeof(iv));
    if (status != kCCSuccess) {
        *output_length = 0;
        return -3;
    }
    return 0;
}

int32_t ideck_steam_decrypt_chunk(const uint8_t *input, size_t input_length,
                                  const uint8_t *key, size_t key_length,
                                  uint8_t *output, size_t output_capacity,
                                  size_t *output_length) {
    const uint64_t start = ideck_stage_now();
    const int32_t result = ideck_steam_decrypt_chunk_untimed(input, input_length, key, key_length, output, output_capacity, output_length);
    ideck_stage_add(IDECK_STAGE_DECRYPT, (result == 0 && output_length) ? *output_length : 0, start);
    return result;
}
