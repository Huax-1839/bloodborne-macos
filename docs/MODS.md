# File mods and external patches

## File mods

The launcher's **Mods** page adds a mod folder or a ZIP file (or one dropped onto the page),
switches mods on per profile and sets their load order. Changes apply at the next start. The mod
at the bottom of the list loads last and wins where two mods have the same file; the page lists
the overlapping files and which mod wins.

The launcher keeps mods in `~/Library/Application Support/HuntersLantern/mods/`; `macos/run.sh`
uses `macos/mods/` (or `BB_MODS_DIR`). A mod is laid out like this:

```text
mods/
  Mod name/
    dvdroot_ps4/
      chr/...
      param/...
      menu/...
```

Also accepted:

- `Mod name/app0/dvdroot_ps4/...` and `Mod name/CUSA03173/dvdroot_ps4/...`;
- one extra wrapper folder, as left by unpacking an archive into a folder of its name:
  `Mod name/Mod name v1.2/dvdroot_ps4/...` (readme files and pictures may sit beside it);
- a mod without `dvdroot_ps4` that holds the game's folders directly: `Mod name/chr/...`,
  `Mod name/parts/...` (`chr`, `parts`, `map`, `menu`, `msg`, `param`, `sfx`, `sound`, `font`
  and the other `dvdroot_ps4` folders).

Case in a mod's names does not matter: `DVDROOT_PS4/Chr/C0000.chrbnd.dcx` from a mod packed on
Windows replaces the game's `dvdroot_ps4/chr/c0000.chrbnd.dcx`. The start log says how many game
files the mods replaced and added: `Mods: 12 game files replaced, 0 added`. A mod that should
replace files but reports `0 game files replaced` has the wrong paths inside. Archives other than
ZIP (7z, RAR) have to be unpacked first. Supported are ready-made replacements of `dvdroot_ps4`
files: textures, models, parameters, interface, sound and fonts. Two mods' versions of the same
`.dcx`/`.bnd` file are not merged: the last one wins as a whole.

A shadPS4-style folder `CUSA03173-mods/dvdroot_ps4/...` next to the game folder `CUSA03173/` is
picked up automatically, before the mods of the list; the global switch turns it off too. A folder
that holds `dvdroot_ps4` directly can also be chosen as the mods folder: it is used as a whole,
without a list of mods. The `-mods` convention follows
[shadPS4's sources](https://github.com/shadps4-emu/shadPS4/blob/main/src/core/file_sys/fs.cpp).

The game's own files are never overwritten. Each start builds a merged tree of links in the data
directory's `out/mod-game-*`; reads, `stat` and directory listings see the chosen replacements and
the original files otherwise. The game's `/app0` and `/hostapp` are read-only; saves stay where
they are and writable. The temporary tree is removed when the game ends normally or the launcher
stops it; after a force quit it may be left behind and is not reused.

Not supported: mods that replace `eboot.bin`, `sce_module` or `sce_sys`, DLL injectors and script
plugins. Patches to the executable go through the patch system below. Symbolic links inside a mod
are refused. Whether a mod works with CUSA03173 1.09 is up to its author.

From the terminal:

```sh
BB_GAME_DIR=/path/to/CUSA03173 BB_MODS_DIR=/path/to/mods bash macos/run.sh
BB_GAME_DIR=/path/to/CUSA03173 BB_MODS_ENABLED=0 bash macos/run.sh
```

Order and switched-off mods are kept in the data directory's `mods.json`:

```json
{"order": ["First", "Second"], "disabled": ["First"]}
```

New folders are switched on and appended in alphabetical order. `BB_MODS_CONFIG` changes the
file's path. `BB_MOD_TRACE=1` together with `BB_MODS_DIR` logs the first reads of mod files, for
diagnosis.

## External patches (shadPS4 XML)

The data directory's `patches/` folder (launcher: the **Patches** page, "External patches";
`macos/run.sh`: `macos/patches/`). It takes patch XML files in the shadPS4/GoldHEN format: the
`Metadata` entries for `AppVer="01.09"` and `eboot.bin` are used, files with another game's
`TitleID` are skipped. A patch is on by default when its file says `isEnabled`; the choices are
saved in the data directory's `patches.json`:

```json
{"enabled": ["file.xml/Patch name"], "disabled": ["file.xml/Other patch"]}
```

Supported lines: `bytes`, `bytes16/32/64`, `float32/64`, `utf8`, `utf16`. A patch with `mask`
lines (pattern search) or an address outside the eboot is skipped as a whole, with a message in
the log. External patches apply after the built-in ones (`patches/Bloodborne.xml`); where they
overlap the external one wins. From the terminal:
`BB_PATCHES_DIR=/path BB_PATCHES_CONFIG=/path/patches.json bash macos/run.sh`.

Patches that replace pointers in tables (such as `60 FPS++` and `90 FPS++`) are moved to the
image's real address by the loader.

## TAA sharpening

`sharpen` and `sharpness` also apply to TAA, in the launcher and in the game's menu. The range is
**0…1**; at 0, or with the switch off, there is no extra pass. RCAS runs on the finished scene
before the HUD. TAA's history keeps the color from before sharpening, so it does not build up
over frames. Flat areas keep their color, HDR included; no extra buffer is needed.
