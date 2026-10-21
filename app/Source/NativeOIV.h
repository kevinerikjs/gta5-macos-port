// OpenIV packages (GTA-69): .oiv files and unpacked package folders in the Mods folder install the way
// their author's assembly.xml says, by turning into ordinary mod files at PC paths (NativeAssets.m).
#import <Foundation/Foundation.h>

// Returns @[pcPath, fileOnDisk, size] for every file the packages add or edit. *skip gets the Mods-relative
// paths the packages occupy (a .oiv file, or a package folder ending in "/"), which the folder walk leaves
// alone. gameFile(pcPath) gives the game's own loose file for a text/xml edit, or nil. When gameReadable
// is false (the game folder isn't known yet) such edits are left out and *needsGame is set.
NSArray<NSArray *> *pg_oiv_expand(NSString *modsFolder,NSString *(^gameFile)(NSString *pcPath),bool gameReadable,bool *needsGame,NSArray<NSString *> **skip);
// A package the game uses this launch (GTA-153, NativeAssets.m).
void pg_mod_path_used(const char *path);
