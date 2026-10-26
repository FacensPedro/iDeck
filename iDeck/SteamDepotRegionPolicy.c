#include "SteamDepotRegionPolicy.h"
#include <ctype.h>
#include <stddef.h>
#include <string.h>

int ideck_steam_black_desert_is_regional_depot(uint32_t depot_id) {
    return depot_id >= 582661u && depot_id <= 582669u;
}

static int country_in(const char *country, const char *countries) {
    if (!country || strlen(country) != 2) return 0;
    char code[3] = {
        (char)toupper((unsigned char)country[0]),
        (char)toupper((unsigned char)country[1]), 0
    };
    const char *candidate = countries;
    while (*candidate) {
        if (candidate[0] == code[0] && candidate[1] == code[1] &&
            (candidate[2] == 0 || candidate[2] == ' '))
            return 1;
        candidate = strchr(candidate, ' ');
        if (!candidate) break;
        ++candidate;
    }
    return 0;
}

uint32_t ideck_steam_black_desert_preferred_depot(const char *country_code) {
    if (country_in(country_code, "BR AR BO CL CO EC PY PE UY VE GY SR GF")) return 582668u;
    if (country_in(country_code, "RU BY KZ")) return 582662u;
    if (country_in(country_code, "TH")) return 582663u;
    if (country_in(country_code, "SG MY ID PH VN BN KH LA MM")) return 582664u;
    if (country_in(country_code, "TR")) return 582665u;
    if (country_in(country_code, "JP")) return 582666u;
    if (country_in(country_code, "TW HK MO")) return 582667u;
    return 582669u;
}
