# CI

## GitHub Actions

`.github/workflows/mobile-build.yml` builds the Flutter app from the repository
root on push, pull request, and manual dispatch. 

### Android Job
- Runs on `ubuntu-latest`.
- Produces debug APK artifacts.
- Automatically uploaded as workflow artifacts.

### iOS Job
- Runs on `macos-15`.
- Produces an unsigned device `stream-unsigned.ipa`.
- The app uses camera/SRT native code, so CI builds the physical-device iOS target instead of the simulator target.
- **Note:** App Store/TestFlight distribution requires signing secrets (p12/provisioning profiles) and export options which are not currently configured in the GitHub workflow.

## Repository Structure for CI

The canonical Flutter project root is the repository root. All CI tasks should run from the root directory.

## Android Build Configuration

The Android project intentionally does not use `dependencyResolutionManagement` because Flutter injects a local engine Maven repository at project level. Project-level repositories are required so Gradle can resolve both Flutter engine artifacts and regular dependencies from Google/Maven Central.

Debug builds explicitly disable resource shrinking and minification for faster turnaround. Release signing is currently disabled in the main workflow until secrets are provisioned.
