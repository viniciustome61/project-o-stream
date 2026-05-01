# CI

## Codemagic

The canonical Flutter project root is the repository root. `codemagic.yaml`
builds from this root and should be the preferred workflow.
Android's Gradle configuration also pins Flutter's `source` to the repository
root so `flutter build` and Gradle agree on the `build/` artifact directory.

Codemagic's older UI workflow for this project may still run from `mobile/`.
To keep that workflow buildable without duplicating source, `mobile/` contains
Git symlinks to the root Flutter project:

```text
mobile/pubspec.yaml -> ../pubspec.yaml
mobile/pubspec.lock -> ../pubspec.lock
mobile/lib          -> ../lib
mobile/android      -> ../android
mobile/ios          -> ../ios
```

On Windows checkouts without symlink support, these entries can appear as tiny
text files. Do not edit them as normal source files. On Codemagic they resolve
as symlinks.

## Android Build Hardening

The Android project intentionally does not use `dependencyResolutionManagement`
because Flutter injects a local engine Maven repository at project level.
Project-level repositories are required so Gradle can resolve both Flutter
engine artifacts and regular dependencies from Google/Maven Central.

Debug and release builds explicitly disable resource shrinking while
minification is disabled. Release signing is activated only when all Codemagic
`CM_KEYSTORE_*` variables are present, so debug builds do not fail on missing
keystore secrets.
