#ifndef IDECK_STEAM_DEPOT_REGION_POLICY_H
#define IDECK_STEAM_DEPOT_REGION_POLICY_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Black Desert (582660) publishes mutually exclusive regional depots.
// Return the preferred depot for the device's ISO-3166-1 alpha-2 region.
// If the Steam account only has another depot, the caller must still verify
// its Steam license and select from the metadata actually available.
uint32_t ideck_steam_black_desert_preferred_depot(const char *country_code);
// The nine public depots are region alternatives, not additive content.
int ideck_steam_black_desert_is_regional_depot(uint32_t depot_id);
#ifdef __cplusplus
}
#endif
#endif
