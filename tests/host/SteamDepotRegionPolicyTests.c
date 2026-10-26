#include "../../iDeck/SteamDepotRegionPolicy.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>

int main(void) {
    assert(ideck_steam_black_desert_is_regional_depot(582660u) == 0);
    assert(ideck_steam_black_desert_is_regional_depot(582661u) == 1);
    assert(ideck_steam_black_desert_is_regional_depot(582668u) == 1);
    assert(ideck_steam_black_desert_is_regional_depot(582669u) == 1);
    assert(ideck_steam_black_desert_is_regional_depot(582670u) == 0);
    assert(ideck_steam_black_desert_preferred_depot("BR") == 582668u);
    assert(ideck_steam_black_desert_preferred_depot("br") == 582668u);
    assert(ideck_steam_black_desert_preferred_depot("PY") == 582668u);
    assert(ideck_steam_black_desert_preferred_depot("JP") == 582666u);
    assert(ideck_steam_black_desert_preferred_depot("RU") == 582662u);
    assert(ideck_steam_black_desert_preferred_depot("TH") == 582663u);
    assert(ideck_steam_black_desert_preferred_depot("TR") == 582665u);
    assert(ideck_steam_black_desert_preferred_depot("TW") == 582667u);
    assert(ideck_steam_black_desert_preferred_depot("SG") == 582664u);
    assert(ideck_steam_black_desert_preferred_depot("US") == 582669u);
    assert(ideck_steam_black_desert_preferred_depot(NULL) == 582669u);
    assert(ideck_steam_black_desert_preferred_depot("BRA") == 582669u);
    puts("PASS: native region depot policy");
    return 0;
}
