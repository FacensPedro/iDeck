#ifndef IDECK_STEAM_NATIVE_CORE_H
#define IDECK_STEAM_NATIVE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// SHA-1 remains required by Steam's depot and cloud protocols. Do not use it
// as a security primitive for credentials or application signing.
enum { IDECK_STEAM_SHA1_BYTES = 20 };

typedef struct IDeckSteamVerifier IDeckSteamVerifier;

// Reuses an 4 MiB aligned read window across adjacent chunks in a game file.
// A missing file, symlink or non-regular file returns NULL (all chunks are
// considered pending for download).
IDeckSteamVerifier *ideck_steam_verifier_open(const char *path);
bool ideck_steam_verifier_check(IDeckSteamVerifier *reader, uint64_t offset,
                               size_t length, const uint8_t expected_sha[20]);
void ideck_steam_verifier_close(IDeckSteamVerifier *reader);

// Streaming SHA-1 used for Steam Cloud local saves. No whole-file Data copy.
// Rejects symbolic links and non-regular files.
bool ideck_steam_sha1_file(const char *path, uint8_t out_sha[20]);

// Lowercase hex encoder. output_capacity must be >= count*2+1.
bool ideck_steam_hex_encode(const uint8_t *bytes, size_t count,
                            char *output, size_t output_capacity);

// Steam's depot container stores an AES-ECB-encrypted IV (first 16 bytes),
// followed by AES-256-CBC/PKCS7 ciphertext. The caller owns output storage;
// zero on success, nonzero on invalid input/decryption failure.
int32_t ideck_steam_decrypt_chunk(const uint8_t *input, size_t input_length,
                                  const uint8_t *key, size_t key_length,
                                  uint8_t *output, size_t output_capacity,
                                  size_t *output_length);

#ifdef __cplusplus
}
#endif
#endif
