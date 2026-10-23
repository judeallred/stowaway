#!/bin/sh
# Creates "Stowaway Review" in the home folder: a web project with node_modules and a Rust
# project with build files, for App Review to try Stowaway on (nothing in it runs). The same
# commands are in review-notes.md for the reviewer to paste into Terminal; a core test runs this
# copy, so keep the two the same.
cd ~ && mkdir "Stowaway Review" && cd "Stowaway Review" &&
mkdir -p web-app rust-tool/src rust-tool/target/debug &&
printf '{ "name": "web-app", "private": true }\n' > web-app/package.json &&
for i in $(seq 1 40); do
  p=web-app/node_modules/package-$i && mkdir -p "$p/lib" &&
  printf '{ "name": "package-%s", "version": "1.0.0" }\n' "$i" > "$p/package.json" &&
  for f in $(seq 1 12); do head -c 24000 /dev/urandom | base64 > "$p/lib/module-$f.js"; done
done &&
printf '[package]\nname = "rust-tool"\nversion = "0.1.0"\nedition = "2021"\n' > rust-tool/Cargo.toml &&
echo 'fn main() {}' > rust-tool/src/main.rs &&
echo 'Signature: 8a477f597d28d172789f06886806bc55' > rust-tool/target/CACHEDIR.TAG &&
for d in deps incremental build; do
  mkdir -p "rust-tool/target/debug/$d" &&
  for f in $(seq 1 10); do head -c 300000 /dev/urandom > "rust-tool/target/debug/$d/file-$f.rlib"; done
done &&
echo 'Created "Stowaway Review" in your home folder.'
