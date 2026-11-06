// Madeira runtime functions the copied Madeira Dock files call (MadeiraDock/,
// verbatim). Native builds link Madeira's own definitions; interface builds
// use NativeRuntime/InterfaceOnlyStubs.c.
#ifndef MADEIRA_DOCK_ABI_H
#define MADEIRA_DOCK_ABI_H

int wine_process_is_running(void);
int wineserver_is_running(void);
void madeira_seed_prefix_if_needed(const char *prefix_path);

#endif
