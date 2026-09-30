# Ship Glass Rail to TestFlight

GitHub's Mac build servers build Glass Rail, sign it with Apple's cloud signing and upload it to
TestFlight. No Mac, certificates or provisioning profiles are involved.

| What | Value |
|---|---|
| App ID | `com.lasmith1689.GlassRail` |
| Widget App ID | `com.lasmith1689.GlassRail.Widgets` |
| App Group (on both IDs) | `group.com.lasmith1689.GlassRail` |
| Team ID | `U3CTV4FLKM` |
| TestFlight group | `Me` (internal, automatic distribution) |

The App IDs, the App Group, the App Store Connect app record and the `Me` group already exist.

## What GitHub needs

Four repository secrets under **Settings** ▸ **Secrets and variables** ▸ **Actions**:

| Secret | Value |
|---|---|
| `APPLE_TEAM_ID` | `U3CTV4FLKM` |
| `ASC_KEY_ID` | Key ID of the App Store Connect API key (Admin access) |
| `ASC_ISSUER_ID` | Issuer ID shown above the key list |
| `ASC_KEY_P8` | The whole text of `AuthKey_XXXXXXXXXX.p8`, including the `BEGIN` and `END` lines |

The same key that uploads Ai Sky works here. Never paste the key into a chat, an issue or a commit.

## Ship a build

Either:

- On GitHub, open **Actions** ▸ **TestFlight** ▸ **Run workflow** (branch `main`), or
- Push a commit to `main` whose message starts with `[ship]` (for example `[ship] Faster widget`). Only the start counts, so a message that merely mentions it doesn't upload.

Nothing else uploads. Ordinary pushes run CI only, which builds the App Store version as a check and
ends with "Nothing was uploaded".

Building and uploading takes about 10 to 15 minutes. Apple then processes the build, usually within
5 to 30 minutes, and TestFlight on the iPhone offers it as an update. Each build number is
`<run number>.<attempt>`, so re-running a workflow always produces a new one.

## After installing

Add the widget: long-press the Home Screen ▸ **Edit** ▸ **Add Widget** ▸ **Glass Rail**, then pick
small or medium. For the Lock Screen, long-press the Lock Screen ▸ **Customize** ▸ **Lock Screen** ▸
the widget area, and pick the rectangular or inline Glass Rail widget. The widget follows the
Hoboken / Penn choice and the look you pick in the app.

## If a build fails

The failed run ends with a one-line explanation:

| Message | Fix |
|---|---|
| "The App Store Connect app record for com.lasmith1689.GlassRail was not found" | The app record's bundle ID must match exactly. |
| "Turn on the App Group…" | Tick `group.com.lasmith1689.GlassRail` under App Groups on both App IDs. |
| "Check the API key…" | The key needs **Admin** access, and all three values must come from the same key. |
| "That build number was already used" | Click **Re-run all jobs**. |
| "The App Store build failed" | A compile error; the run's annotations list each one with file and line. |
