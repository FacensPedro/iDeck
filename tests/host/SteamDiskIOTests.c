#include "../../iDeck/SteamDiskIO.h"
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    char dir[] = "/tmp/ideck-diskio-XXXXXX";
    assert(mkdtemp(dir));
    char path[512];
    assert(snprintf(path, sizeof(path), "%s/game.dat", dir) > 0);
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    assert(ftruncate(fd, 4096) == 0);
    assert(close(fd) == 0);
    const unsigned char sample[] = {0x4d, 0x5a, 0x01, 0x02, 0x03, 0xff};
    uint64_t written = 123;
    assert(ideck_steam_write_chunk(path, sample, sizeof(sample), 20, 0, &written) == 0);
    assert(written == sizeof(sample));
    written = 123;
    assert(ideck_steam_write_chunk(path, sample, sizeof(sample), 20, 1, &written) == 0);
    assert(written == 0);
    unsigned char changed[sizeof(sample)];
    memcpy(changed, sample, sizeof(changed));
    changed[0] ^= 0xff;
    assert(ideck_steam_write_chunk(path, changed, sizeof(changed), 20, 1, &written) == 0);
    assert(written == sizeof(changed));
    fd = open(path, O_RDONLY);
    assert(fd >= 0);
    unsigned char readback[sizeof(sample)] = {0};
    assert(pread(fd, readback, sizeof(readback), 20) == sizeof(readback));
    assert(memcmp(readback, changed, sizeof(readback)) == 0);
    assert(close(fd) == 0);
    assert(ideck_steam_write_chunk(NULL, sample, sizeof(sample), 0, 0, &written) == EINVAL);
    assert(ideck_steam_write_chunk(path, sample, sizeof(sample), UINT64_MAX, 0, &written) == EINVAL);
    char linkpath[512];
    assert(snprintf(linkpath, sizeof(linkpath), "%s/alias", dir) > 0);
    assert(symlink(path, linkpath) == 0);
    assert(ideck_steam_write_chunk(linkpath, sample, sizeof(sample), 0, 0, &written) != 0);
    assert(unlink(linkpath) == 0);
    assert(unlink(path) == 0);
    assert(rmdir(dir) == 0);
    puts("PASS: native disk I/O retries, dedupe, path safety");
    return 0;
}
