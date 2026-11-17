
# Paper installer for Termux
 
Set up a [Paper](https://papermc.io) Minecraft server on your Android phone with a few taps. No Linux or Java knowledge needed.
 
## Features
 
- Picks from the Minecraft versions PaperMC currently offers (nothing is hardcoded)
- Only offers build types that exist for your version (Recommended, Stable, Beta, Alpha)
- Finds the Java version your server needs from PaperMC's data, installs it, and checks that it runs
- Verifies the download's SHA-256 checksum before installing it
- One folder per Minecraft version; your worlds, plugins and settings are never deleted
- Asks you to accept the Minecraft EULA yourself; the server never starts without it
- Simple menu to start a server, install another version, list servers or change RAM
## Requirements
 
- Android with [Termux](https://f-droid.org/packages/com.termux/) (from F-Droid or GitHub, not the old Play Store build)
- An internet connection and a few GB of free storage
- Enough RAM: 3 GB or more on the phone is realistic for a small server
## Install
 
Open Termux and run:
 
```bash
curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash
```
 
Follow the numbered menus. Press Enter to accept the suggested choice shown in `[brackets]`.
 
## Use
 
Run the same command again any time to open the menu:
 
1. Start a server
2. Install another Minecraft version
3. View installed servers
4. Change server RAM
5. Exit
To start a server directly (replace the version with yours):
 
```bash
bash ~/minecraft/1.21.11/start.sh
```
 
Type `stop` in the server console to shut it down safely.
 
## Where things are
 
Each version lives in `~/minecraft/<version>/`, for example `~/minecraft/1.21.11/`.
It contains `server.jar`, your world, plugins and settings, plus two files made by the installer:
`start.sh` (the launcher) and `server.conf` (Java path and RAM).
 
## Troubleshooting
 
- **"Could not determine the Java version"**: The installer reads Java requirements from PaperMC and, if missing, from Mojang's version data. If both fail it prints PaperMC's response; please include it in an issue.
- **Java not available**: Termux may not offer the Java a newer Minecraft needs yet. Choose an older Minecraft version or try again later. The installer never removes other Java versions for you.
- **Server closes or Termux is killed**: Lower the RAM (menu option 4) and keep Termux open. In Android settings, disable battery optimisation for Termux.
- **Checksum mismatch / download failed**: Nothing was changed. Check your connection and run it again.
- **Colors look odd**: Set `NO_COLOR=1` before running to turn colors off.
## License
 
GNU General Public License v3.0 or later (GPL-3.0-or-later). See the `LICENSE` file in this repository.
 
