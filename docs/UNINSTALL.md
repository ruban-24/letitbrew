# Uninstalling by hand

The supported way to uninstall is **Settings → About → Uninstall Let It Brew…**.
It needs no admin password and handles everything below in the right order.

Use this document only if the app will not launch.

## Order matters

The privileged background service must be unregistered **while the app that owns
it is still present**. Deleting the app first strands a registered service with
no owner, and your Mac may keep a modified sleep setting.

1. In **Settings → Agents**, use each connected agent's `…` menu to
   **Disconnect**. Do this for Claude Code, Codex, OpenCode, and GitHub
   Copilot CLI when connected. Disconnect removes only Let It Brew-owned JSON
   entries, or only the owned `letitbrew.js` OpenCode plugin; it does not remove
   any foreign hook entry, plugin, project, team, or enterprise configuration.
2. Turn off Launch at Login.
3. Turn off the closed-lid option, choose **Pause Let It Brew**, and confirm the
   popover reads **Let It Brew is paused**.
4. Quit Let It Brew.
5. Unregister the background service, and wait for it to confirm:

   ```sh
   '/Applications/Let It Brew.app/Contents/MacOS/LetItBrew' --unregister-daemon
   ```

6. Move `/Applications/Let It Brew.app` to the Trash.
7. Optionally remove `~/Library/Application Support/LetItBrew/`.

## Do not force the sleep setting

**Do not run `sudo pmset -a disablesleep 0`.**

Let It Brew restores the exact `SleepDisabled` value that existed before its
hold. Forcing `0` assumes your Mac started with sleep enabled, which may not be
true — another tool or your own configuration may have set it deliberately.

To check the current value:

```sh
pmset -g | grep SleepDisabled
```

If that value is not what you expect after uninstalling, please
[open an issue](https://github.com/ruban-24/letitbrew/issues) with the reading
rather than overwriting it. A wrong baseline is a bug worth fixing.

## Verifying the removal

```sh
sudo launchctl print system/com.ruban24.letitbrew.daemon
```

Should report no such service.

```sh
defaults read com.ruban24.letitbrew
```

Should report that the domain does not exist.

`/Library/Application Support/LetItBrew/` is deliberately left behind by the
manual path — it holds the background service's recovery state and is harmless.
Remove it only after confirming the service is unregistered.
