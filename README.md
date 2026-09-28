# GRTubeYou — release channel

This repo is **only** the update channel for the GRTubeYou Android TV app. It holds no
source code; the sources live in the SmartTube fork.

## What is in here

| File | Purpose |
|---|---|
| `version.json` | The update manifest. The app reads it over HTTPS on every start. |
| `publish.ps1` | Builds a new APK, publishes it as a GitHub release, rewrites `version.json`. |

## How an update reaches a TV

1. The app requests `https://raw.githubusercontent.com/<owner>/<repo>/main/version.json`
2. It compares `versionCode` from the manifest with its own
3. If the manifest is newer, it downloads the APK for the device's ABI
   (`downloadUrlList_arm64-v8a` and friends) and offers to install
4. Android itself refuses the install unless the APK carries the same signing key,
   so a tampered mirror cannot push anything

Nothing in the app knows about GitHub — it is just a static JSON file at a fixed URL.

## Releasing a new version

```powershell
$env:GITHUB_TOKEN = "ghp_..."      # PAT with 'repo' scope
.\publish.ps1 -Owner <your-github-login> -ChangeLog "Что изменилось", "Ещё пункт"
```

The script will:

1. bump `versionCode` / `versionName` in the app's `build.gradle`
2. run `assembleStstableRelease`
3. create release `v<versionName>` and upload the four APKs
4. regenerate `version.json`, keeping the changelog of older versions

Then commit and push `version.json`:

```powershell
git add version.json
git commit -m "release: <versionName>"
git push
```

**The update only becomes visible after `version.json` reaches the default branch.**
Pushing the APKs alone changes nothing for users.

## First-time setup

1. Create an empty GitHub repository (no README, no .gitignore)
2. Replace `OWNER` in `version.json` and in the app's
   `common/src/ststable/res/values/update_urls.xml` with your login
3. Run `publish.ps1` once to create the first release
