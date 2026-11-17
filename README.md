# PaperMC Termux Installer

A lightweight Bash installer for running PaperMC Minecraft servers directly on Android using Termux.

## Features

- Automatically fetches available Minecraft versions
- Stable, Beta and Alpha build selection
- Automatically detects and installs the required Java version
- Supports multiple Java installations
- SHA-256 download verification
- Separate server directories for each Minecraft version
- Interactive Minecraft EULA acceptance
- Minimal dependencies

## Installation

### 1. Install Termux

Download Termux from [F-Droid](https://f-droid.org/packages/com.termux/).

### 2. Run the installer

Open Termux and execute:

```bash
curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash
```

### 3. Choose your version

Select your desired Minecraft version and Paper build channel.

The installer handles Java installation and Paper downloading automatically.

## Server storage

Servers are stored in:

```text
~/minecraft/
├── 1.21.11/
│   ├── server.jar
│   ├── eula.txt
│   └── ...
└── 26.3/
    ├── server.jar
    ├── eula.txt
    └── ...
```

## Requirements

- Android device
- Termux
- Internet connection
- Available storage and RAM

## Notes

- Build availability depends on official PaperMC support.
- Experimental builds may be unstable.
- Performance depends on your device and cooling.
- Keep Termux running while hosting your server.

## Credits

- [PaperMC](https://papermc.io/)
- [Termux](https://termux.dev/)

## License

See [LICENSE](LICENSE).
