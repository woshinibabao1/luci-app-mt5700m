#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="${RUNNER_TEMP:-/tmp}/mt5700m-sdk"
output_dir="${repo_dir}/dist-release"
base_url="https://downloads.immortalwrt.org/releases/23.05.4/targets/mediatek/filogic"
qmodem_commit="6f84b7935921cce6a215171af5e93cad62f8a5a5"

mkdir -p "${work_dir}" "${output_dir}"
find "${output_dir}" -mindepth 1 -maxdepth 1 -delete
cd "${work_dir}"
curl -fsSLO "${base_url}/sha256sums"
# ImmortalWrt 23.05 使用 .tar.xz 格式的 SDK
archive="$(awk '/immortalwrt-sdk-.*Linux-x86_64\.tar\.xz$/ { print $2; exit }' sha256sums | sed 's/^\*//')"
test -n "${archive}"
curl -fL --retry 5 "${base_url}/${archive}" -o "${archive}"
grep "[ *]${archive}$" sha256sums | sha256sum -c -
tar -Jxf "${archive}"
# ImmortalWrt 的 SDK 解压后目录名以 immortalwrt-sdk- 开头
sdk_dir="$(find "${work_dir}" -maxdepth 1 -type d -name 'immortalwrt-sdk-*' | head -n 1)"
test -n "${sdk_dir}"

cd "${sdk_dir}"
printf '\nsrc-git qmodem https://github.com/FUjr/QModem.git^%s\n' "${qmodem_commit}" >> feeds.conf.default
./scripts/feeds update -a
./scripts/feeds install luci-base
./scripts/feeds install -p qmodem ubus-at-daemon sms-tool_q

perl -0pi -e 's/(config ALL\n\s+bool "Select all userspace packages by default"\n\s+default )y/${1}n/' Config.in
perl -0pi -e 's/(config TARGET_MULTI_PROFILE\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_ALL_PROFILES\n\s+bool\n\s+default )y/${1}n/; s/(config TARGET_DEVICE_mediatek_filogic_DEVICE_[^\n]+\n\s+bool\n\s+default )y/${1}n/g' Config-build.in
sed -i 's/^[[:space:]]*default m$/\tdefault n/' Config-build.in

mkdir -p package/h5000m-custom
cp -a "${repo_dir}/luci-app-mt5700m" package/h5000m-custom/

# ---------------------------------------------------------------------------
# Build the Rust AT backend (v4.0). One std-only static binary serves BOTH
# frontends: "at-webserver" (WebSocket daemon for the WebUI) and
# "mt5700m-at" (LuCI shell contract via argv[0] dispatch; installed as a
# symlink by 93-mt5700m-webui). The aarch64-unknown-linux-musl target links
# with the bundled rust-lld, so no cross toolchain is needed on the runner.
# NOTE: linker config is MANDATORY. Without it rustc drives the HOST cc, and
# the aarch64-only workaround flag `-Wl,--fix-cortex-a53-843419` (injected by
# rustc for this target) is rejected by the x86_64 GNU ld:
#   /usr/bin/ld: unrecognized option '--fix-cortex-a53-843419'
# rust-lld understands it and links self-contained (bundled musl crt + libc).
# ---------------------------------------------------------------------------
rust_dir="${repo_dir}/mt5700webui-openwrt-server/at-webserver"
rust_target="aarch64-unknown-linux-musl"
rust_bin=""
if command -v cargo >/dev/null 2>&1; then
	rustup target add "${rust_target}" >/dev/null 2>&1 || true
	(cd "${rust_dir}" && \
	 RUSTFLAGS="-C link-self-contained=yes -C linker=rust-lld" \
	 cargo build --release --locked --target "${rust_target}")
	rust_bin="${rust_dir}/target/${rust_target}/release/at-webserver"
fi
if [ ! -f "${rust_bin}" ]; then
	echo "ERROR: Rust backend binary not built (cargo missing or compile error)." >&2
	exit 1
fi
echo "INFO: built Rust at-webserver backend (${rust_target})"

# Fold the standalone WebUI (mt5700webui 4.0: React/Semi frontend + Rust
# AT backend) into the package source, so one ipk ships frontend + backend +
# LuCI manager.  The LuCI app itself no longer carries the old umi WebUI
# (htdocs/5700, at-server.py were removed from the repo).
pkg_src="package/h5000m-custom/luci-app-mt5700m"
mkdir -p "${pkg_src}/htdocs" "${pkg_src}/root/usr/bin" "${pkg_src}/root/etc/init.d"
cp -a "${repo_dir}/mt5700webui-openwrt-server/at-webserver/files/www/5700" "${pkg_src}/htdocs/5700"
cp -f "${rust_bin}" "${pkg_src}/root/usr/bin/at-webserver"
chmod 0755 "${pkg_src}/root/usr/bin/at-webserver"
cp -f "${repo_dir}/mt5700webui-openwrt-server/at-webserver/files/etc/init.d/at-webserver" "${pkg_src}/root/etc/init.d/at-webserver"
echo "INFO: folded mt5700webui 4.0 frontend + Rust backend into package source"
cat > .config <<'EOF'
CONFIG_TARGET_mediatek=y
CONFIG_TARGET_mediatek_filogic=y
# CONFIG_ALL is not set
# CONFIG_ALL_KMODS is not set
# CONFIG_ALL_NONSHARED is not set
CONFIG_PACKAGE_luci-app-mt5700m=m
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_ubus-at-daemon=m
CONFIG_PACKAGE_sms-tool_q=m
# CONFIG_PACKAGE_luci-app-qmodem is not set
# CONFIG_PACKAGE_luci-app-qmodem-next is not set
# CONFIG_PACKAGE_qmodem is not set
# CONFIG_PACKAGE_modem_scan is not set
# CONFIG_PACKAGE_tom_modem is not set
EOF
make defconfig
make package/feeds/qmodem/ubus_at_daemon/compile package/feeds/qmodem/sms-tool_q/compile -j"$(nproc)" V=s
# Force a clean rebuild so the SDK re-copies the updated htdocs (network.js/status.js)
# instead of reusing a cached build_dir / staging copy from the previous version.
make package/h5000m-custom/luci-app-mt5700m/clean >/dev/null 2>&1 || true
rm -rf build_dir/target-*/luci-app-mt5700m \
       staging_dir/target-*/root-*/www/luci-static/resources/view/mt5700m \
       staging_dir/target-*/root-*/www/5700 \
       bin/packages/*/custom/luci-app-mt5700m*.apk bin/packages/*/custom/luci-app-mt5700m_*.ipk 2>/dev/null || true
# CRLF prevention: .gitattributes mandates eol=lf for www/5700 text files.
# A pre-compile `sed -i 's/\r$//'` was empirically proven to corrupt large
# single-line JS bundles on CI runners, so it stays removed.  The post-compile
# `cp -a` of pristine repo files into staging_dir is the safety net for any
# SDK copy/tar artifacts, and `node --check` validates the result.

make package/h5000m-custom/luci-app-mt5700m/compile -j"$(nproc)" V=s

# Re-copy the PRISTINE www/5700 frontend (mt5700webui 4.0) from the repo
# source into the freshly staged www tree, AFTER `make compile` and BEFORE
# the node --check guard below.
#
# This is the step that fixes SDK truncation of huge minified JS bundles
# (34000+ char lines; the SDK copy/tar mangles CRLF/long-line files).
# The .ipk is assembled FROM staging_dir, so overwriting staging_dir here
# DOES reach the package.
cp -a "${repo_dir}/mt5700webui-openwrt-server/at-webserver/files/www/5700/." staging_dir/target-*/root-*/www/5700/.
echo "INFO: re-copied pristine www/5700 (mt5700webui 4.0) into staging_dir after compile"

# Sanity check: the freshly staged www tree must contain the WebUI integration.
# If this fails, the SDK reused a cached htdocs copy and the package would be broken.
if ! grep -rq "mt5700m-webui-cta" staging_dir/target-*/root-*/www/luci-static/resources/view/mt5700m/ 2>/dev/null; then
  echo "ERROR: built www tree is missing the WebUI entry button (SDK caching?)" >&2
  exit 1
fi
if ! ls staging_dir/target-*/root-*/www/5700/index.html >/dev/null 2>&1; then
  echo "ERROR: built www tree is missing the WebUI SPA at /www/5700/index.html" >&2
  exit 1
fi
# Guard rail: catch truncated/garbled JS bundles (e.g. broken regex) before packaging.
while IFS= read -r js; do
  [ -f "$js" ] || continue
  if ! node --check "$js" 2>/dev/null; then
    echo "ERROR: $js has syntax errors (likely truncated by SDK build)" >&2
    exit 1
  fi
done < <(find staging_dir/target-*/root-*/www/5700 -name '*.js' -type f 2>/dev/null)

# ImmortalWrt 23.05 使用 opkg，产出 .ipk 格式
find bin -type f \( -name 'luci-app-mt5700m_*.ipk' -o -name 'luci-i18n-mt5700m-zh-cn_*.ipk' -o -name 'ubus-at-daemon_*.ipk' -o -name 'sms-tool_q_*.ipk' \) -exec cp -f {} "${output_dir}/" \;
test "$(find "${output_dir}" -type f -name '*.ipk' | wc -l)" -ge 4
cp -f public-key.pem "${output_dir}/openwrt-sdk-build.pem" 2>/dev/null || true
(cd "${output_dir}" && find . -maxdepth 1 -type f \( -name '*.ipk' -o -name 'openwrt-sdk-build.pem' \) -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
