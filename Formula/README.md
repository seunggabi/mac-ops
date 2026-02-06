# Homebrew Formula

This directory contains the Homebrew formula for mac-ops, which will be used in the future `homebrew-mac-ops` tap repository.

## Formula: mac-ops.rb

The formula installs mac-ops to your system with the following:
- Installs all bin, lib, config, and launchd files
- Creates a symlink for the main executable
- Provides post-install information about Full Disk Access requirements

## Future Homebrew Tap Setup

To create a public Homebrew tap:

1. Create a new repository named `homebrew-mac-ops`
2. Copy this formula to `Formula/mac-ops.rb` in the tap repository
3. Update the `sha256` hash in the formula after the first release
4. Users can then install with: `brew install seunggabi/mac-ops/mac-ops`

## Testing the Formula Locally

Before publishing, test locally with:

```bash
brew install --build-from-source ./Formula/mac-ops.rb
mac-ops version
brew uninstall mac-ops
```

## Release Checklist

Before updating sha256:
- [ ] Tag release in git (e.g., v1.0.0)
- [ ] Build tarball from release
- [ ] Calculate sha256: `shasum -a 256 mac-ops-v1.0.0.tar.gz`
- [ ] Update formula with sha256
- [ ] Test formula installation
