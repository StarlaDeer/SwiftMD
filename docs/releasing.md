# Releasing SwiftMD

Releases are unsigned for now: `VERSION=0.9.0 Tools/package-app.sh` makes an ad-hoc signed
`dist/SwiftMD-0.9.0.zip` for a GitHub release, and the README explains how to open it. To sign and
notarize instead, a Developer ID is needed:

## One-time setup (the Apple Developer account holder does this)

1. **Developer ID certificate.** In Xcode: Settings → Accounts → select the team →
   Manage Certificates… → **+** → **Developer ID Application**. Check it's there:

   ```bash
   security find-identity -v -p codesigning
   ```

   It's listed as `Developer ID Application: Your Name (TEAMID)`.

2. **App-specific password** for notarization: sign in at <https://account.apple.com>, then
   Sign-In and Security → App-Specific Passwords → **+**, and name it "SwiftMD notarization".

3. **Save it in the keychain** (it asks for the app-specific password; nobody else needs to see it):

   ```bash
   xcrun notarytool store-credentials swiftmd --apple-id "you@example.com" --team-id TEAMID
   ```

## Each release

```bash
VERSION=0.9.0 SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=swiftmd Tools/package-app.sh
```

This builds `dist/SwiftMD.app` for Apple silicon and Intel, signs it, sends it to Apple to be
notarized (a few minutes), staples the ticket and zips it as `dist/SwiftMD-0.9.0.zip`. Upload the
zip to a GitHub release.

Without `SIGN_ID` the script makes an ad-hoc signed build, which runs on the Mac that built it;
other Macs say it can't be opened unless they right-click it and choose Open.
