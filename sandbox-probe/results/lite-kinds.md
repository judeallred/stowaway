# Stowaway Lite: every folder kind, with real tools

Run 2026-10-16 by `scripts/lite-kinds-e2e.sh`: Lite (sandboxed) adopts each folder, the tool uses it from the drive offline, the drive is unplugged and the tool works locally, the drive returns and the merged data works offline, then the folder is released. Tools: cargo, Go 1.27, Gradle 9.8 on JDK 21, xcodebuild 26, huggingface_hub, Next.js 15, uv 0.13, npx.

| Kind | adopt | from drive | drive away | after replug | release |
|---|---|---|---|---|---|
| cargo-registry | PASS  | PASS  | PASS  | PASS  | PASS  |
| go | PASS  | PASS  | PASS  | PASS  | PASS  |
| gradle | PASS  | PASS  | PASS  | PASS  | PASS  |
| deriveddata | PASS  | PASS  | PASS  | PASS  | PASS  |
| huggingface | PASS  | PASS  | PASS  | PASS  | PASS  |
| next | PASS  | PASS  | PASS  | PASS  | PASS  |
| venv | PASS  | PASS  | PASS  | PASS  | PASS  |
| npx | PASS  | PASS  | PASS  | PASS  | PASS  |
