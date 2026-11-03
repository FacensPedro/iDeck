/* Interface-only builds link no Madeira runtime: these stand in for the
 * runtime functions the copied Madeira Dock files reference. Native builds
 * link Madeira's own and compile none of this. */
#if !(defined(IDECK_NATIVE_MADEIRA_ENABLED) && IDECK_NATIVE_MADEIRA_ENABLED)
#include "MadeiraDockABI.h"

int wine_process_is_running(void) { return 0; }
int wineserver_is_running(void) { return 0; }
void madeira_seed_prefix_if_needed(const char *prefix_path) { (void)prefix_path; }
#endif
