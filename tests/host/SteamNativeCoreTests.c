#include "../../iDeck/SteamNativeCore.h"
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <assert.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char temp[] = "/tmp/ideck-steam-native-XXXXXX";
    assert(mkdtemp(temp) != NULL);
    char path[512];
    assert(snprintf(path, sizeof(path), "%s/game.dat", temp) > 0);
    const size_t megabyte = 1024 * 1024;
    uint8_t *payload = malloc(6 * megabyte);
    assert(payload);
    memset(payload, 0x54, 6 * megabyte);
    memset(payload + 4 * megabyte, 0x6f, 2 * megabyte);

    int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0600);
    assert(fd >= 0);
    assert(write(fd, payload, 6 * megabyte) == (ssize_t)(6 * megabyte));
    assert(close(fd) == 0);

    uint8_t a[20], b[20];
    assert(CC_SHA1(payload, (CC_LONG)megabyte, a));
    assert(CC_SHA1(payload + 4 * megabyte, (CC_LONG)(2 * megabyte), b));
    IDeckSteamVerifier *reader = ideck_steam_verifier_open(path);
    assert(reader != NULL);
    assert(ideck_steam_verifier_check(reader, 0, megabyte, a));
    assert(ideck_steam_verifier_check(reader, 4 * megabyte, 2 * megabyte, b));
    assert(!ideck_steam_verifier_check(reader, 0, megabyte, b));
    assert(!ideck_steam_verifier_check(reader, 5 * megabyte, 2 * megabyte, b));
    assert(!ideck_steam_verifier_check(reader, UINT64_MAX, megabyte, a));
    assert(!ideck_steam_verifier_check(reader, 0, 0, a));
    assert(!ideck_steam_verifier_check(reader, 0, megabyte, NULL));
    // Non-cached long-chunk path, spanning more than the 4 MiB window.
    assert(CC_SHA1(payload, (CC_LONG)(6 * megabyte), a));
    assert(ideck_steam_verifier_check(reader, 0, 6 * megabyte, a));
    ideck_steam_verifier_close(reader);

    assert(ideck_steam_sha1_file(path, b));
    assert(memcmp(a, b, sizeof(a)) == 0);
    char hex[41];
    assert(ideck_steam_hex_encode(b, 20, hex, sizeof(hex)));
    assert(strlen(hex) == 40);
    assert(!ideck_steam_hex_encode(b, 20, hex, 40));

    char alias[512];
    assert(snprintf(alias, sizeof(alias), "%s/link", temp) > 0);
    assert(symlink(path, alias) == 0);
    assert(!ideck_steam_verifier_open(alias));
    assert(!ideck_steam_sha1_file(alias, b));

    // Round-trip a real Steam-compatible AES-ECB encrypted IV and AES-256-CBC
    // PKCS7 payload, then reject bad keys, malformed data and tampered padding.
    uint8_t key[32], iv[16], encrypted[128], output[128];
    for (size_t i = 0; i < 32; ++i) key[i] = (uint8_t)i;
    for (size_t i = 0; i < 16; ++i) iv[i] = (uint8_t)(i + 32);
    const uint8_t plain[] = "Steam chunk native AES compatibility test";
    size_t produced = 0;
    assert(CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionECBMode,
                   key, sizeof(key), NULL, iv, sizeof(iv),
                   encrypted, sizeof(encrypted), &produced) == kCCSuccess);
    assert(produced == 16);
    size_t ciphertext = 0;
    assert(CCCrypt(kCCEncrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding,
                   key, sizeof(key), iv, plain, sizeof(plain),
                   encrypted + 16, sizeof(encrypted) - 16,
                   &ciphertext) == kCCSuccess);
    assert(ideck_steam_decrypt_chunk(encrypted, 16 + ciphertext, key,
                                     sizeof(key), output, sizeof(output),
                                     &produced) == 0);
    assert(produced == sizeof(plain));
    assert(memcmp(output, plain, sizeof(plain)) == 0);
    assert(ideck_steam_decrypt_chunk(encrypted, 16 + ciphertext, key,
                                     31, output, sizeof(output),
                                     &produced) != 0);
    assert(ideck_steam_decrypt_chunk(encrypted, 16 + ciphertext, key,
                                     32, output, 3, &produced) != 0);
    // A CBC flip in the prior ciphertext block deterministically corrupts
    // the last PKCS7 pad byte (0x06 becomes 0x07), unlike a random flip in
    // the final ciphertext block, which can rarely still yield valid padding.
    encrypted[16 + ciphertext - 16 - 1] ^= 0x01;
    // CBC has no authentication: modified ciphertext may still decrypt with
    // valid padding. The chunk's Adler-32 is checked by the Swift pipeline.
    int32_t tampered = ideck_steam_decrypt_chunk(
        encrypted, 16 + ciphertext, key, 32, output, sizeof(output), &produced);
    assert(tampered != 0 || produced != sizeof(plain) ||
           memcmp(output, plain, sizeof(plain)) != 0);
    // A truncated ciphertext is never a valid AES-256-CBC Steam payload.
    assert(ideck_steam_decrypt_chunk(
        encrypted, 15 + ciphertext, key, 32, output, sizeof(output), &produced) != 0);

    free(payload);
    assert(unlink(alias) == 0);
    assert(unlink(path) == 0);
    assert(rmdir(temp) == 0);
    puts("PASS: bounded native Steam SHA-1, file verification, hex encoding and AES-256");
    return 0;
}
