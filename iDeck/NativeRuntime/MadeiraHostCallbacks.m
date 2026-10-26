#import <Foundation/Foundation.h>
#import <os/log.h>
#include <stddef.h>

// Optional host-side log sink. Wine's own wine_ui_log remains the sole
// exported implementation in libwineserver.a and dispatches its callback.
void ideck_wine_os_log_sink(const char *message) {
    if (message == NULL) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "[iDeck Wine] %{public}s", message);
}
