# STEINS;GATE Phone Patcher

Very epic program to add custom wallpapers or ringtones to the phone.

## Install

1. Install the .NET 8 Desktop Runtime if it is not already installed.
2. Put your OGG Vorbis ringtone files in `assets\ringtones`.
3. Put your PNG, JPEG, BMP, GIF, or TIFF wallpaper files in `assets\wallpapers`.
4. Edit `Config.json`.
5. Run `Install.ps1` from PowerShell. Pass `-GamePath` to avoid the prompt.

For a private setup, copy `Config.json` to `Config.local.json` and edit the local copy. The installer uses `Config.local.json` when it exists, and Git ignores it. Like if you were doing a pull request and are testing stuff please use Config.local.json. 

Example configuration:

```json
{
  "GamePath": "D:\\SteamLibrary\\steamapps\\common\\STEINS;GATE",
  "ForceUnlockWallpapers": true,
  "Ringtones": [
    {
      "Name": "My Ringtone",
      "Audio": "assets\\ringtones\\my-ringtone.ogg",
      "Preview": "assets\\ringtones\\my-ringtone.ogg"
    }
  ],
  "Wallpapers": [
    {
      "Name": "My Wallpaper",
      "Image": "assets\\wallpapers\\my-wallpaper.png",
      "Fit": "Stretch"
    }
  ]
}
```

`Preview` is optional. If it is empty, the same OGG file is used for the phone preview. Audio is stored as supplied; use an already-loopable file if you want a seamless loop. The phone menu uses the name from `Name`.

`Fit` is optional. `Stretch` fills the phone and keeps the whole image, `Cover` fills it by cropping the edges, and `Contain` keeps the original proportions with black space when needed. The default is `Stretch`.

Set `ForceUnlockWallpapers` to `false` to leave the game's built-in wallpaper conditions unchanged. Otherwise, `true` makes it so you have all the wallpapers at the start. User wallpapers are always added as available entries.

## Uninstall

Close the game and run `Uninstall.ps1`. The patcher keeps backups in the folder which will be restored. Use `Uninstall.ps1 -RemoveBackup` only after confirming that you no longer need that recovery copy.

## Notes

The installer rebuilds only the archives needed by the selected options. The package is intended for the current Steam PC release and should be reapplied after Steam replaces a patched archive. I tested with the committee of zero patch installed so I don't know if this works without that, but I don't see why it wouldn't.
