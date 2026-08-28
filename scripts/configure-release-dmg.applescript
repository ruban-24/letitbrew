on run argv
    if (count of argv) is not 1 then error "expected the mounted volume name"
    set volumeName to item 1 of argv

    tell application "Finder"
        set targetDisk to disk (volumeName as text)
        tell targetDisk
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {120, 120, 780, 560}

            set viewOptions to icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set text size of viewOptions to 13
            set shows icon preview of viewOptions to false
            set background picture of viewOptions to file ".background:dmg-background.png"

            set position of item "Let It Brew.app" of container window to {165, 225}
            set position of item "Applications" of container window to {495, 225}
            delay 1
            close
        end tell
    end tell
end run
