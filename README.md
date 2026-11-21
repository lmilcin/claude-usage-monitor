# Claude Usage Monitor

A small macOS menu bar app that shows how much of your Claude plan limits is left, so you
don't have to keep opening claude.ai → Settings → Usage.

The menu bar icon is two thin "battery" bars:

```
┌████████████░░░░┐  ← current 5-hour session: share still available
┌█████░░░░░░░░░░░┐  ← weekly limit (all models): share still available
```

The bars turn orange when 25% or less is left and red at 10% or less. Click the icon to see
every limit (including model-specific weekly ones, if your plan has them), with "% left /
% used" and when each one resets.

Settings (from the menu):

- **Data Source**: a claude.ai session key, or your Claude Code CLI login
- **Refresh Every**: 1–30 minutes (default 5)
- **Menu Bar Icon**: session and weekly bars, session only, or weekly only
- **Show Percentage in Menu Bar**: adds text like `63% · 48%` next to the icon
- **Launch at Login**
- **Organization**: only appears if your session key can see more than one claude.ai org

> Unofficial. It uses the same internal endpoints the claude.ai web page and Claude Code's
> `/usage` command use. These are undocumented and could change without notice.

## Data sources

| Source | Endpoint | Setup | Notes |
|---|---|---|---|
| **claude.ai session key** (default) | `GET claude.ai/api/organizations/{org}/usage` | Paste the `sessionKey` cookie once | Same numbers as the web page. The key expires when you log out of claude.ai, or after about a month. |
| **Claude Code login** | `GET api.anthropic.com/api/oauth/usage` | None, if you use the `claude` CLI on this Mac | Reads the token from the Keychain item `Claude Code-credentials`. The app never refreshes the token itself, because doing that would log Claude Code out. Run `claude` now and then to keep it fresh. |

The session key is stored in your login Keychain and is only ever sent to `claude.ai`.

### Getting the session key

1. Log in to <https://claude.ai> in your browser.
2. Open the developer tools with ⌥⌘I. In Safari, first turn on *Settings → Advanced → Show features for web developers*.
3. Go to **Storage** (Safari) or **Application** (Chrome) → **Cookies** → `https://claude.ai`.
4. Copy the value of `sessionKey` (it starts with `sk-ant-sid`). Then paste it into the app via
   **Settings → Set Session Key…**.

## Installing

The app is built by GitHub Actions on a macOS runner. Every push to `main` uploads a
`ClaudeUsageMonitor` artifact, and pushing a `v*` tag also publishes a GitHub Release with the zip.

The easiest way to get it onto your Mac is with the `gh` CLI. Files downloaded this way don't get
the quarantine flag, so Gatekeeper won't complain:

```sh
# latest release
gh release download --repo <owner>/claude-usage-monitor --pattern ClaudeUsageMonitor.zip
# …or the newest CI build
gh run download --repo <owner>/claude-usage-monitor --name ClaudeUsageMonitor

unzip ClaudeUsageMonitor.zip && mv ClaudeUsageMonitor.app /Applications/
open /Applications/ClaudeUsageMonitor.app
```

The app is only **ad-hoc signed**: there's no Apple Developer ID and no notarization. If you
download it with a browser instead, macOS will refuse to open it. In that case, either run
`xattr -dr com.apple.quarantine /Applications/ClaudeUsageMonitor.app`, or try to open it once and
then go to *System Settings → Privacy & Security → Open Anyway*.

Note: after installing a new build, macOS may ask again for Keychain access. The Keychain ties
access to the code signature, and an ad-hoc signature changes with every build.

## Building

On a Mac with Xcode 15+ (or the Command Line Tools):

```sh
swift test                # unit tests for the parsing/formatting core
./scripts/build-app.sh    # → build/ClaudeUsageMonitor.app + build/ClaudeUsageMonitor.zip
```

You can't build it on Linux. AppKit and the macOS SDK aren't available there, and cross-compiling
with osxcross needs a repackaged Xcode SDK. That's why the CI workflow exists.

The `UsageCore` target is plain Foundation, so its tests also run on Linux:

```sh
docker run --rm -v "$PWD":/pkg -w /pkg swift:6.1 swift test   # app target is skipped off-macOS
```

## Layout

```
Sources/UsageCore/            # JSON parsing, org selection, time formatting (cross-platform, tested)
Sources/ClaudeUsageMonitor/   # AppKit app: status item, icon drawing, menu, Keychain, networking
Tests/UsageCoreTests/
packaging/Info.plist          # LSUIElement app bundle template
scripts/build-app.sh          # universal build → .app → ad-hoc codesign → zip
.github/workflows/build.yml
```
