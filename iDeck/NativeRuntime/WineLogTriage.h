#ifndef IDECK_WINE_LOG_TRIAGE_H
#define IDECK_WINE_LOG_TRIAGE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// Madeira-style bounded recent-log diagnosis. This returns only a category,
// never raw lines, tokens, paths or account data.
typedef enum {
    IDECK_WINE_LOG_NONE = 0,
    IDECK_WINE_LOG_JIT = 1,
    IDECK_WINE_LOG_EXEC_PERMISSION = 2,
    IDECK_WINE_LOG_OOM = 3,
    IDECK_WINE_LOG_ACCESS_VIOLATION = 4,
    IDECK_WINE_LOG_MISSING_DLL = 5
} IDeckWineLogDiagnosis;
int32_t ideck_wine_log_diagnose(const char *path);

#ifdef __cplusplus
}
#endif
#endif
