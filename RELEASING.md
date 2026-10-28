# Releasing DynamicWall

## First time: put it on GitHub

1. On github.com, create a new **empty** repository called `DynamicWall` (no README, no license — they're already here).
2. In Terminal, from this folder:
   ```sh
   git init
   git add .
   git commit -m "DynamicWall 1.2.0"
   git branch -M main
   git remote add origin https://github.com/ShantnuKhedar/DynamicWall.git
   git push -u origin main
   ```
   (Or use GitHub Desktop: File → Add Local Repository → Publish.)
3. Optional: in `DynamicWall/DynamicWall.swift`, set `Feedback.repoURL` to your repository's address. Settings will then show a **View on GitHub** button.

## Bump the version

In Xcode, select the project, then the **DynamicWall** target → **General** → **Identity**: raise **Version** (for example 1.2.1) and **Build** (by one). `scripts/build.sh` reads the same numbers.

## Option A — Free release (no Apple account)

```sh
git commit -am "DynamicWall 1.2.1"
git tag v1.2.1
git push origin main --tags
```

GitHub Actions builds the app and creates a release with `DynamicWall.zip` attached (watch it in the **Actions** tab). The app isn't notarized, so on first launch people need **System Settings → Privacy & Security → Open Anyway**.

## Option B — Signed and notarized (recommended; Apple Developer Program, $99/year)

People can open it with no warnings.

1. Xcode → **Settings → Accounts**: add your Apple ID. In the target's **Signing & Capabilities**, choose your **Team**.
2. **Product → Archive**.
3. In the Organizer: **Distribute App → Direct Distribution**. Xcode signs it with your Developer ID and notarizes it.
4. Export the app, zip it with `ditto -c -k --keepParent DynamicWall.app DynamicWall.zip`, and upload it to the GitHub release (drag it onto the release page, or `gh release upload v1.2.1 DynamicWall.zip --clobber`).

From Terminal instead: `scripts/build.sh release "Developer ID Application: Your Name (TEAMID)"` makes a notarized DMG in `build/`.

## Mac App Store

Possible, but likely to be rejected: Apple's guideline 5.2 requires permission to use third-party content, and the Bing and Spotlight feeds are unofficial. Options A and B avoid this.

## Before each release

- Try it on a fresh user account, so you see what a new user sees.
- Activity Monitor → **Energy**: DynamicWall should be close to 0 when idle.
- Update the README screenshots if the look changed.
