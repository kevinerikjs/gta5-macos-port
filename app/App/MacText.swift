import Foundation

/// The Mac app's own wording for text written for the iPhone (On My iPhone, Tap, iOS). AppLanguage.choose
/// swaps the key on Mac; the catalog has each Mac text with its translations (GTA-9).
enum MacText {
    static let replacements: [String: String] = [
        "The game files are already on this iPhone (folder \"{arg0}\"), so nothing needs downloading.":
            "The game files are already on this Mac (folder \"{arg0}\"), so nothing needs downloading.",
        "Paused because this iPhone is almost out of storage.":
            "Paused because this Mac is almost out of storage.",
        "The app was not allowed to open that folder. Move your game folder to Files › On My iPhone › GTA V Port instead; the app finds it there by itself.":
            "The app was not allowed to open that folder. Choose it again, or choose a folder above it.",
        "There is no game in \"{arg0}\". Pick the folder that has your game in it (any folder above it works, even On My iPhone itself).\n\nEasiest: move your game folder into Files › On My iPhone › GTA V Port. The app finds it there by itself.":
            "There is no game in \"{arg0}\". Choose the folder that has your game in it. Any folder above it works too: the app searches everything inside.",
        "For iPhones with little memory: lower detail and draw distance, so the world keeps loading":
            "For Macs with little memory: lower detail and draw distance, so the world keeps loading",
        "Today's tested setup for 6 GB iPhones":
            "A light setup for Macs with 8 GB",
        "Sends this run's game log and the previous one: your iPhone model, iOS version, app settings and what the game printed. No personal data, photos or contacts.":
            "Sends this run's game log and the previous one: your Mac model, macOS version, app settings and what the game printed. No personal data, photos or contacts.",
        "not needed on iPhone":
            "not needed on Mac",
        "Already on this iPhone":
            "Already on this Mac",
        "Easiest: in the Files app, move your unpacked game folder into On My iPhone › GTA V Port. The app finds it there by itself, however deep it is.":
            "Choose your unpacked game folder below. Any folder above it works too: the app searches everything inside, however deep the game is.",
        "Somewhere else? Choose any folder above it, even On My iPhone itself, and the app searches everything inside.":
            "The app remembers the folder, so you only choose it once.",
        "Can't pick it? A cloud icon next to the file means it's still in iCloud Drive: move it to On My iPhone first. In LiveContainer, turn on Fix File Picker and Use LiveContainer's Bundle ID in GTA V Port's settings (under Fixes).":
            "Can't pick it? A cloud icon next to the folder means it's still in iCloud Drive: in Finder, Control-click it and choose Download Now first.",
        "\"{arg0}\" on this iPhone: all {arg1} game files checked ({arg2}).":
            "\"{arg0}\" on this Mac: all {arg1} game files checked ({arg2}).",
        "\"{arg0}\" on this iPhone.":
            "\"{arg0}\" on this Mac.",
        "The app looked through every folder in On My iPhone › GTA V Port and found no game. If your game is somewhere else (another folder, or another app's folder), tap Choose a folder… below and pick it, or pick On My iPhone itself to search everything. iOS only lets an app into other folders once you pick them.":
            "No game folder chosen yet. Click Choose a folder… below and pick the folder your game is in. macOS only lets the app into a folder once you choose it.",
        "Tap Continue the download and pick the same archive: files already unpacked aren't unpacked again.":
            "Click Continue the download and choose the same archive: files already unpacked aren't unpacked again.",
        "Tap Continue the download: it picks up where it stopped instead of starting again.":
            "Click Continue the download: it picks up where it stopped instead of starting again.",
        "{arg0} isn't unpacked yet. Tap Unpack below and the app does it for you.":
            "{arg0} isn't unpacked yet. Click Unpack below and the app does it for you.",
        "To fit on this iPhone, the archive is used up while it unpacks: once it's done, only the unpacked game is left. If unpacking stops half way, you'll need the archive again.":
            "To save space on this Mac, the archive is used up while it unpacks: once it's done, only the unpacked game is left. If unpacking stops half way, you'll need the archive again.",
        "1 file is only in iCloud, not on this iPhone (for example {arg0}). The game can't read them from there: move the game folder to Files › On My iPhone › GTA V Port.":
            "1 file is only in iCloud, not on this Mac (for example {arg0}). The game can't read it from there: in Finder, Control-click the game folder and choose Download Now.",
        "{arg0} files are only in iCloud, not on this iPhone (for example {arg1}). The game can't read them from there: move the game folder to Files › On My iPhone › GTA V Port.":
            "{arg0} files are only in iCloud, not on this Mac (for example {arg1}). The game can't read them from there: in Finder, Control-click the game folder and choose Download Now.",
        " Unpacking or copying probably stopped before the end, most often because the iPhone ran out of storage. Free up space, delete this folder and unpack the game again.":
            " Unpacking or copying probably stopped before the end, most often because the Mac ran out of storage. Free up space, delete this folder and unpack the game again.",
        "Not enough memory on this iPhone":
            "Not enough memory on this Mac",
        "iOS can't give the game the memory it needs on this iPhone. iPhone 8, 8 Plus and X usually can't run it with a free Apple ID; a paid developer account or TrollStore may help. Send the log if your iPhone is newer.":
            "This Mac can't give the game the memory it needs right now. Quit other apps and try again, or choose a lower preset in Settings. Send the log if it keeps happening.",
        "The game folder was moved or deleted. Put it back in Files › On My iPhone › GTA V Port, or pick it again.":
            "The game folder was moved or deleted. Put it back, or choose it again.",
        "Tap to see the progress.":
            "Click to see the progress.",
        "On this iPhone":
            "On this Mac",
        "Found your game folder, but it can't be used yet. Tap to see why and how to fix it.":
            "Found your game folder, but it can't be used yet. Click to see why and how to fix it.",
        "Tap to change it.":
            "Click to change it.",
        "Tap to find them on this iPhone, or get them from a link or an archive.":
            "Click to choose your game folder, or get the files from a link or an archive.",
        "Found a game archive. Tap to unpack it.":
            "Found a game archive. Click to unpack it.",
        ". That usually means this setting needs more memory than iOS gives the app on this iPhone (about {arg0} MB).":
            ". That usually means this setting needs more memory than the game gets on this Mac (about {arg0} MB).",
        "Tap the page's download button. The app takes the download over by itself and unpacks it.":
            "Click the page's download button. The app takes the download over by itself and unpacks it.",
        "Ad blocking is off for this site. Tap the page's download button again.":
            "Ad blocking is off for this site. Click the page's download button again.",
        "Fewer stutters and steadier play: lowers the frame rate while the iPhone is hot, and raises it again once it cools down":
            "Fewer stutters and steadier play: lowers the frame rate while the Mac is hot, and raises it again once it cools down",
        "Higher uses more power and heat; 30 FPS is steadiest. Unlocked goes up to 120 on ProMotion iPhones.":
            "Higher uses more power and heat; 30 FPS is steadiest. Unlocked runs as fast as your Mac and display allow.",
        "Experimental. Keeps the game on the fast processor cores for steadier FPS. Turn off if your iPhone gets too hot.":
            "Experimental. Keeps the game on the fast processor cores for steadier FPS. Turn off if your Mac gets too hot.",
        "Experimental, off by default. Gives the game about 270 MB more room inside its 4 GB, for fewer stops after long play on 6-8 GB iPhones. Turn off if the game stops more often.":
            "Experimental, off by default. Gives the game about 270 MB more room inside its 4 GB, for fewer stops after long play. Turn off if the game stops more often.",
        "Pick a mod as you downloaded it (zip, rar, oiv, asi or loose files). The app finds where each file goes. Car, skin and add-on mods need the game files on this iPhone.":
            "Pick a mod as you downloaded it (zip, rar, oiv, asi or loose files). The app finds where each file goes. Car, skin and add-on mods need the game files on this Mac.",
        "This mod can't run on iPhone":
            "This mod can't run on Mac",
        "Experimental. The largest textures use a quarter of the memory on iPhones before the 15 Pro, so more of the world stays sharp. Turn off for the sharpest close-ups.":
            "Experimental. For iPhones before the 15 Pro; a Mac reads these textures directly, so this changes nothing here.",
        "Experimental. On iPhones before the 15 Pro, leaves, fences, smoke and decals use a quarter of the memory, so more of the world stays sharp. Turn off if soft see-through edges show steps.":
            "Experimental. For iPhones before the 15 Pro; a Mac reads leaves, fences and smoke directly, so this changes nothing here.",
        "Show the Self Radio folder in Files":
            "Show the Self Radio folder in Finder",
        "Pick songs from Files (MP3, M4A, AAC, WAV, AIFF or FLAC), or copy them into Files › On My iPhone › GTA V Port › Self Radio. Songs from Apple Music or Spotify can't be added: they're protected.":
            "Click Add songs… (MP3, M4A, AAC, WAV, AIFF or FLAC), or copy songs into the Self Radio folder in Finder. Songs from Apple Music or Spotify can't be added: they're protected.",
        "Without it there are no game files to play. Check the address, or use one of the ways below to put the files on this iPhone.":
            "Without it there are no game files to play. Check the address, or use one of the ways below to put the files on this Mac.",
    ]
}
