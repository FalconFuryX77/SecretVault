# Releasing

How a release of Undertow is built, signed and published, and how people
move from the old app to it.

## The signing key

Android only installs an update signed with the same key as the installed
app. Undertow's key was created once and must sign every future release:

- `undertow-release.jks`, kept **outside** the repository, with a note on
  where its password lives.
- `android/key.properties` (git-ignored) points the build at it:

  ```
  storeFile=<path to undertow-release.jks>
  storePassword=…
  keyAlias=undertow
  keyPassword=…
  ```

- Certificate SHA-256, published so anyone can check a download:
  `120bc48910582d88bca8bd3068b726974672d2b678ee24d4fa252b64a0c51de1`

Back up the keystore and its password together, offline (an encrypted USB
drive, a password manager). If the key is lost, installed apps can never be
updated again: people would have to move their vault out and reinstall.
Never commit it, never send it.

Without `key.properties` a release build is signed with the debug key, so
it can't update a real install.

## Building

1. Set the version in `pubspec.yaml` (`version: x.y.z+n`; `n` must go up
   every release).
2. Run the tests (see the README) on the PC and on an emulator.
3. Build:

   ```bash
   flutter build apk --release --split-per-abi
   flutter build apk --release
   ```

   The first gives one APK per processor type (`arm64-v8a` is right for
   almost every phone from the last eight years), the second a universal
   one.
4. Check the signature and the package:

   ```bash
   apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
   aapt2 dump badging build/app/outputs/flutter-apk/app-release.apk | head -3
   ```

   The certificate's SHA-256 must be the one above, the package
   `com.videotrimmer.local`, the label "Video Trimmer".
5. Name the files `Undertow-vX.Y.Z-<abi>.apk` and write their SHA-256s to
   `SHA256SUMS.txt`.

An organisation that wants its own identity can build with
`-PappId=<its package>` and its own key. That app can't update ours or the
other way round.

## Publishing

Create a GitHub release for the tag `vX.Y.Z` with the APKs,
`SHA256SUMS.txt`, the certificate fingerprint and short notes: what's new,
what's known not to work, and anything people must do.

## Moving from the old app (SecretVault / "Files", up to v2.1.0)

The old app has a different package (`com.example.gesture_unlock`) and was
signed with a development key, so Undertow can't update it in place. A
vault moves across with the move tool instead. For that, one last update of
the old app is built from the same code, with the old identity and key:

```bash
flutter build apk --release --split-per-abi -P appId=com.example.gesture_unlock -P legacySigning=true
```

Pass the properties with `-P`: environment variables such as
`ORG_GRADLE_PROJECT_appId` can be missed by a Gradle daemon that's already
running, which then silently builds the new app instead. It must be built
on the machine whose debug key signed the old releases, and per processor
type: the old releases' per-ABI version codes (2004, 1004) are higher than
a universal build's. Check that the certificate is the old one
(`05e16563e0ac03b9835b8d4c2a0fcbac22fc14f6cdc0e482161479f37f41629c`) and the
package `com.example.gesture_unlock`, then publish them as
`Undertow-vX.Y.Z-move-from-old-app-<abi>.apk`.

What people do:

1. **Back up first** (Settings → Backup in the old app), or at least make
   sure the vault's contents exist somewhere else.
2. Install the update over the old app. Unlock once: the vault is upgraded
   to the new format (both vaults, if there's a decoy).
3. Settings → **Move to Another Phone or App**. Save the file and write down
   the transfer code it shows.
4. Install Undertow. On its first screen choose **Move a vault here from
   another phone or app**, pick the file, type the code, and set new PINs.
5. Check everything is there (open a few files, the decoy too), then
   uninstall the old app and delete the moved file.

The moved file and the code together open the vault without a PIN until the
move is finished: keep them apart, and delete the file afterwards.
