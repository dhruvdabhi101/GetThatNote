# Landing page

Deploy **this directory** (`docs/`) as the publish/output directory on any
static host. No install command, build command, server, API key, or environment
variables are needed. Keep `index.html`, `style.css`, and `assets/` together.
Relative asset paths also support deployment under a subdirectory.

Local preview from the repository root:

```bash
python3 -m http.server 8080 --directory docs
```

Then open http://localhost:8080.

Both download buttons link to GitHub's latest release page. This avoids pointing
at a nonexistent DMG until a new release includes one. To host a DMG directly,
upload the output of `./build.sh dmg` to your host and update both download links
in `index.html`. A file built locally is not automatically published to GitHub.

The product images are captures of the actual web editor with sample notes,
not redesigned mockups. Fonts are local OS fonts; no third-party requests,
analytics, JavaScript, cookies, or font services are required by the page.
