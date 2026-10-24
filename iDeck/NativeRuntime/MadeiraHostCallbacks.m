#import <Foundation/Foundation.h>
#import <os/log.h>
#include <stddef.h>

void wine_ui_log(const char *message) {
    if (message == NULL) return;
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_INFO, "[iDeck Wine] %{public}s", message);
}
