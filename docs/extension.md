# Apple extension build input

Apple's iCloud Passwords extension is a required build input. Its source is not in this repository. Before building from a fresh checkout, run:

```sh
python3 scripts/prepare-extension.py
```

The script downloads version **3.3.0** from the pinned Google Chrome Web Store blob, checks its SHA256, reads the CRX3 header, and extracts the ZIP payload into `Resources/AppleExtension`. It omits Chrome's `_metadata` directory for unpacked loading. It does not change Apple's JavaScript, manifest, icons, or translations.

The pinned archive SHA256 is:

```text
3fefff3058e77877345d5d5c6ef6f1fb8c085ed2c1e4ecf76d16bf2fb64667b0
```

An existing directory must match the pinned version and file contents. Setup does not overwrite a changed directory. Move that directory aside, then run setup again to get the pinned files.

To check the files without network access:

```sh
python3 scripts/prepare-extension.py --check
```

The Xcode resource phase runs this check and stops if the extension is missing, incomplete, or changed. Downloading is a separate setup step; Xcode does not download the extension during its resource phase. CI must run the setup command before building. `--destination <directory>` supports an isolated setup check.

The upstream extension is [iCloud Passwords on the Chrome Web Store](https://chromewebstore.google.com/detail/icloud-passwords/pejdijmoenmkgeppbflobdenhhabjlaj). Its version, immutable blob URL, archive hash, and extracted-file hash are fixed in [prepare-extension.py](../scripts/prepare-extension.py).
