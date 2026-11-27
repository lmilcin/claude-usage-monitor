# Claude Usage Monitor

> [!WARNING]
> **NOT AFFILIATED WITH ANTHROPIC.** This is an unofficial, independent project. It is not made,
> endorsed or supported by Anthropic. It reads your usage through the same internal, undocumented
> endpoints that the claude.ai web page and Claude Code's `/usage` command use. They can change or
> stop working without notice, and using them this way may not be covered by Anthropic's terms.
> Use it at your own risk.

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

## Requirements

- macOS 13 (Ventura) or later, on Apple silicon or Intel
- A Claude subscription, and either a claude.ai login in your browser or the Claude Code CLI
  logged in on the same Mac (see [Data sources](#data-sources))

## Installing

Download `ClaudeUsageMonitor.zip` from the
[latest release](https://github.com/lmilcin/claude-usage-monitor/releases/latest).

The easiest way is the `gh` CLI. Files downloaded this way don't get the quarantine flag, so
Gatekeeper won't complain:

```sh
gh release download --repo lmilcin/claude-usage-monitor --pattern 'ClaudeUsageMonitor.zip*'
# verify it here, see below
unzip ClaudeUsageMonitor.zip && mv ClaudeUsageMonitor.app /Applications/
open /Applications/ClaudeUsageMonitor.app
```

The app is only **ad-hoc signed**: there's no Apple Developer ID and no notarization. If you
download it with a browser instead, macOS will refuse to open it. In that case, either run
`xattr -dr com.apple.quarantine /Applications/ClaudeUsageMonitor.app`, or try to open it once and
then go to *System Settings → Privacy & Security → Open Anyway*.

### Keychain prompts after installing or updating

The Keychain trusts an app by its code signature, and an ad-hoc signature changes with every
build. So after each update macOS asks whether the new build may read the session key (or Claude
Code's login). Enter your **login keychain password**, which is normally your Mac login password,
and click **Always Allow**. "Allow" works too, but then you'll be asked again on the next launch.
If you click **Deny**, the app won't ask again until you relaunch it or set the key again.

If the prompts won't go away, delete the old item and set the key again. The app then creates a
fresh item that this build already trusts:

1. Quit the app (or force-quit it from Activity Monitor).
2. Open **Keychain Access**, search for `ClaudeUsageMonitor`, and delete that item. Or run
   `security delete-generic-password -s ClaudeUsageMonitor -a sessionKey` in Terminal.
3. Start the app and choose **Settings → Set Session Key…**.

### Verify your download

This app handles a credential for your Claude account, so check that the zip you got is the one
this repository's CI built. Every release publishes two things for that:

**A build provenance attestation.** It is signed by GitHub Actions and proves the zip was built
by this repository's workflow from the tagged source. This is the stronger check:

```sh
gh attestation verify ClaudeUsageMonitor.zip --repo lmilcin/claude-usage-monitor
```

**A SHA-256 hash.** It is printed in the notes of each
[release](https://github.com/lmilcin/claude-usage-monitor/releases) and attached as
`ClaudeUsageMonitor.zip.sha256`. Compare it with your file:

```sh
shasum -a 256 ClaudeUsageMonitor.zip          # compare with the hash in the release notes
shasum -a 256 -c ClaudeUsageMonitor.zip.sha256   # or let shasum compare it
```

The hash is different for every release, which is why it lives with the release and not in this
file.

### Updates

The app doesn't update itself. Once a day it asks GitHub's public API whether a newer release
exists, and if so shows **Update Available** in the menu, which opens the release page. The
request carries no account data. You can turn it off under **Settings → Check for Updates
Automatically**, and check by hand with **Check for Updates…**.

## Settings

From the menu:

- **Data Source**: a claude.ai session key, or your Claude Code CLI login
- **Refresh Every**: 1–30 minutes (default 5)
- **Menu Bar Icon**: session and weekly bars, session only, or weekly only
- **Show Percentage in Menu Bar**: adds text like `63% · 48%` next to the icon
- **Launch at Login**
- **Check for Updates Automatically**: on by default
- **Organization**: only appears if your session key can see more than one claude.ai org

When the server pushes back, automatic refreshes slow down instead of retrying at the usual
pace:

- **Rate limited (HTTP 429), server errors (5xx) or a Cloudflare block:** the app waits twice
  the refresh interval, then doubles the wait after each further failure, up to an hour. It
  waits longer if the server's `Retry-After` header asks for it. The menu shows when the next
  try is, and the first successful refresh ends the backoff.
- **Session key or Claude Code login rejected:** the app stops sending that credential
  automatically. It resumes on its own once the credential changes, whether you set a new key
  or run `claude` to log in again.

**Refresh Now** always sends one request, even during a backoff or with a rejected credential.

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

### CI and releases

GitHub Actions builds the app on a macOS runner. Every push to `main` uploads a
`ClaudeUsageMonitor` artifact, which you can fetch with
`gh run download --repo lmilcin/claude-usage-monitor --name ClaudeUsageMonitor`. These builds are
versioned `0.0.0-<run>` and have no attestation.

Pushing a `v*` tag also publishes a GitHub Release with the zip, its SHA-256 and the build
provenance attestation.

## Layout

```
Sources/UsageCore/            # JSON parsing, org selection, formatting, version comparison (cross-platform, tested)
Sources/ClaudeUsageMonitor/   # AppKit app: status item, icon drawing, menu, Keychain, networking
Tests/UsageCoreTests/
packaging/Info.plist          # LSUIElement app bundle template
scripts/build-app.sh          # universal build → .app → ad-hoc codesign → zip
.github/workflows/build.yml
```

## License

[MIT](LICENSE)
