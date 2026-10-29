# Install

## Requirements

- macOS 14 or later.
- Xcode or the Command Line Tools with a Swift 6 toolchain. `swift test` needs
  Xcode's XCTest; the app itself builds with the Command Line Tools.

## Install

```sh
./install.sh
```

The script builds a release binary, packages it at
`~/Applications/meter.app`, and writes the LaunchAgent
`~/Library/LaunchAgents/app.meter.meter.plist`. The agent starts meter at
login and restarts it if it exits.

It also links `~/.local/bin/meter` to the bundle's executable, which is how
the `--print`, `--json`, and `--test-notify` modes are meant to be run. Make
sure `~/.local/bin` is on your `PATH`.

## Code signing

The first install creates a self-signed certificate named `meter codesign` and
signs the bundle with it. meter reads credentials that belong to other apps
(Claude Code, Zed), and macOS ties keychain grants to the app's signature. An
ad-hoc signature changes on every build and invalidates those grants, so each
read prompts again. With a stable signature you approve each credential once.

## First run

Open the menu bar item and let it refresh. The first read of Claude's or Zed's
keychain item triggers a system prompt; choose **Always Allow**. Later reads,
including background refreshes, are silent.

If you deny it, background refreshes fail with a message telling you to click
Refresh and allow access. You can also fix it later in Keychain Access.

Notifications need the app bundle, not a bare binary. `meter --test-notify`
asks for permission and sends a test. If you dismissed the prompt, enable
meter in System Settings → Notifications.

## After editing config

The app reloads `~/.config/meter/config.json` on every refresh, so most changes
apply within one interval. To apply them immediately:

```sh
launchctl kickstart -k gui/$(id -u)/app.meter.meter
```

## Uninstall

```sh
launchctl bootout gui/$(id -u)/app.meter.meter
rm -rf ~/Applications/meter.app
rm -f ~/Library/LaunchAgents/app.meter.meter.plist ~/.local/bin/meter
```

That leaves your data in place. To remove it as well:

```sh
rm -rf ~/.config/meter ~/.local/share/meter ~/.cache/meter
```

The `meter codesign` certificate can be deleted from Keychain Access if you
don't plan to reinstall.
