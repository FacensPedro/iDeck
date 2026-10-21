#include <stdlib.h>

__attribute__((constructor))
void init_live_container_hook() {
    setenv("CFNETWORK_DIAGNOSTICS", "3", 1);
    setenv("OS_ACTIVITY_DT_MODE", "enable", 1);
}
