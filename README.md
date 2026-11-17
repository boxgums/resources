# Paper for Termux

Run your own Minecraft server on your Android phone. One installer, then one command to start playing.

```
mcstart
```

That's it. No folders to open, no Java commands to remember.

---

## Quick start

1. Install **Termux** from [F-Droid](https://f-droid.org/packages/com.termux/) or GitHub (not the Play Store version, it is outdated).
2. Open Termux, paste this and press Enter:

   ```
   curl -fsSL https://raw.githubusercontent.com/boxgums/resources/main/paper.sh | bash
   ```

3. Follow the questions on screen (every question has a sensible default, so you can mostly just press Enter).
4. From now on, to start your server, open Termux and type:

   ```
   mcstart
   ```

---

## What the installer asks you

| Step | Question | What to pick |
|------|----------|--------------|
| 1 | Minecraft version | The newest is at the top. Pick the version your friends use. |
| 2 | Build type | **Recommended** is the best choice for most people. |
| 3 | Java | Nothing to answer. The installer finds out which Java that version needs and installs it. |
| 4 | Download | Nothing to answer. The file is checked (SHA-256) so a broken download is thrown away. |
| 5 | RAM | Press Enter for the recommended amount (see [RAM](#ram-in-plain-words)). |
| 5 | Whitelist | Press Enter for **yes** (see [Whitelist](#whitelist-who-can-join)). |
| 5 | EULA | You must accept the [Minecraft EULA](https://aka.ms/MinecraftEULA) to run a server. |

You can run the installer again at any time to add more Minecraft versions, view your servers, or change a server's RAM. Your worlds, plugins and settings are never deleted.

---

## The commands

### `mcstart`

Shows a menu of every server you have installed. Type a number and press Enter.

```
╭────────────────────────────────────╮
│           PaperMC Server           │
│                                    │
│          Select a server           │
├────────────────────────────────────┤
│                                    │
│  1. Minecraft 1.21.11              │
│  2. Minecraft 1.21.10              │
│  3. Minecraft 1.20.6               │
│                                    │
│  i. Install a new server           │
│  r. Remove a server                │
│  j. Install / remove Java          │
│  u. Update mcstart                 │
│                                    │
│  0. Exit                           │
│                                    │
╰────────────────────────────────────╯

Choose an option:
```

A number starts that server. The letters manage things (see [Managing servers and Java](#managing-servers-and-java)). The list is built from what is actually installed, so it always matches your servers. It works from any folder.

| Command | What it does |
|---------|--------------|
| `mcstart` | Pick a server from the menu and start it |
| `mcstart --list` | Show installed servers (version, Java, RAM, folder) without starting one |
| `mcstart --update` | Update `mcstart` (and `mcwhitelist`) to the newest version |
| `mcstart --help` | Short help |

What `mcstart` does for you when you pick a server:

- Uses the **Java version that server needs**, not whatever Java happens to be the default. Different servers can use different Javas.
- Uses that server's **own RAM setting**.
- Starts it with `--nogui` from inside its folder.
- Leaves your worlds, plugins and settings alone.

If something is wrong it tells you in simple words instead of failing:

- **Java is missing:** it explains and offers to install it (`Y/n`).
- **server.jar is missing:** it tells you to run the installer again for that version. Your world is kept.
- **EULA not accepted yet:** it asks you.
- **Wrong menu number:** it asks again. `0` exits without starting anything.

To stop a running server safely, type `stop` in the server console.

#### Managing servers and Java

Everything below is in the `mcstart` menu, so there is nothing else to remember.

| Key | What it does |
|-----|--------------|
| `i` | **Install a new server.** Runs the installer and takes you straight to choosing a version. Your existing servers are not touched. |
| `r` | **Remove a server.** Pick one, see its folder and size, then type its version number to confirm. This deletes its world, plugins and settings for good, so there is no undo. It refuses to delete a server that is running, and it only ever deletes a real server folder inside `~/minecraft`. |
| `j` | **Java menu.** Shows which Java versions are installed and which servers use each. Lets you install or remove a Java version. Removing one a server needs is allowed after a warning, and `mcstart` offers to reinstall it next time that server starts. |
| `u` | **Update `mcstart`** to the newest version, then reopens the menu. |

If no servers are installed yet, the menu says so and you can press `i` to install your first one.

### `mcwhitelist`

Appears when you say **yes** to the whitelist question. Opens a simple menu:

```
1. Add players
2. Remove a player
3. Show who is allowed
4. Turn whitelist on/off
0. Done
```

| Command | What it does |
|---------|--------------|
| `mcwhitelist` | Open the whitelist menu (asks which server if you have several) |
| `mcwhitelist --help` | Short help |

**Adding players:** type each player's exact Minecraft Java name and press Enter. Add as many as you like, then press Enter on an empty line. Names are 3-16 letters, numbers or underscores.

If the server is running while you change the list, type `whitelist reload` in the server console so it notices.

---

## Whitelist: who can join

A whitelist is a list of players who are allowed on your server. Everyone else is kept out, even if they find your address. It is the easiest way to keep a friends-only server private.

- The installer asks `Do you want a whitelist? (Y/n)`. Pressing Enter means **yes**.
- Choosing yes switches on `white-list` and `enforce-whitelist` for that server and creates the `mcwhitelist` command.
- Choosing no leaves the server open to anyone who knows its address. You can turn the whitelist on later from `mcwhitelist`.

Player IDs are looked up from Mojang, so you need an internet connection when adding names. If a server runs in offline mode (`online-mode=false`), IDs are worked out locally and no lookup is needed.

---

## RAM in plain words

RAM is the memory Minecraft is allowed to use.

- More RAM means smoother play and more players.
- Too much RAM and Android may close Termux, because your phone needs memory for itself too.
- The installer suggests about **half your phone's memory, at most 4 GB**, and warns you above 75%.
- Each server has its own RAM setting. Change it by running the installer and choosing **Change server RAM**.

Examples you can type: `1536`, `2048`, `2G`.

---

## Where things are

| What | Where |
|------|-------|
| Servers | `~/minecraft/<version>/` (for example `~/minecraft/1.21.11/`) |
| Per-server settings | `~/minecraft/<version>/server.conf` (Minecraft version, Java, RAM, build) |
| The commands | `$PREFIX/bin/mcstart` and `$PREFIX/bin/mcwhitelist` |

The commands live in a folder Termux already searches, so they keep working after you close and reopen Termux. You never need to edit `.bashrc`.

---

## Updating

Press `u` in `mcstart` (or run `mcstart --update`), or run the installer command again. It will:

- Compare the `mcstart` and `mcwhitelist` on your phone with the newest version. If they are **different** (older, damaged, edited, or missing the executable flag) they are replaced. If they are identical, nothing is rewritten.
- **Never overwrite** a different command that happens to have the same name. It warns and leaves it alone.
- Offer to replace `server.jar` only if you say yes. Worlds, plugins and settings are untouched either way.

---

## Troubleshooting

**`mcstart: command not found`**
Close Termux completely and open it again. If it still fails, run the installer again.

**"A different mcstart command already exists"**
Something that was not made by this installer is using that name, so it was left alone. If it is an old copy you do not need, delete it (the message shows the exact `rm` command) and run the installer again.

**"Java N is missing"**
Say `Y` when `mcstart` offers to install it. If Termux cannot install that Java, pick an older Minecraft version, or try again later when Termux adds the package. If the error mentions a conflict with another openjdk package, remove that one yourself with `pkg uninstall openjdk-XX`. Nothing is removed for you.

**The server closes by itself or Termux disappears**
Android is probably running out of memory. Lower the RAM with the installer's **Change server RAM** option.

**"There is no Minecraft Java player called ..." in `mcwhitelist`**
Check the spelling. Only Java Edition names work, and you need internet.

**Players cannot join**
If the whitelist is on, add them with `mcwhitelist` (and type `whitelist reload` if the server is running).

---

## For developers

- `mcstart` and `mcwhitelist` are stand-alone scripts embedded inside `paper.sh` and written to `$PREFIX/bin` by the installer.
- Each carries a marker line such as `# paper.sh-managed: mcstart v1`. The installer only replaces files that carry the marker, and only when the version number differs.
- The installer replaces a managed file whenever its contents differ from the embedded copy (`cmp`), so a change only needs editing the script inside `paper.sh`. Bump `CMD_VERSION` for the marker.
- Installer flags (after `bash -s --` when piped): `--install` goes straight to installing a server, `--update` only refreshes `mcstart` and `mcwhitelist`. `mcstart` uses these.
- `mcstart` downloads the installer to a temporary file, checks it looks right and parses, and only then runs it.
- Testing helpers: `PAPER_HOME` (servers folder), `PAPER_INPUT` (where answers are read from), `PAPER_INSTALLER_URL` (installer source for `mcstart`, URL or local path), `PAPER_ALLOW_NON_TERMUX=1`.

---

Licensed under GPL-3.0-or-later. Copyright (C) boxgums.
