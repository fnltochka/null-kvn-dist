{
  lib,
  stdenvNoCC,
  fetchurl,
  coreutils,
  jq,
  openssl,
  release ? import ./release.nix,
}:

let
  hashOrFake = value: if value == null then lib.fakeHash else value;
  manifest = fetchurl {
    name = "null-kvn-release-manifest.json";
    url = "${release.baseUrl}/${release.releaseId}/RELEASE-MANIFEST.json";
    hash = hashOrFake release.manifestSha256;
  };
  signature = fetchurl {
    name = "null-kvn-release-manifest.json.sig";
    url = "${release.baseUrl}/${release.releaseId}/RELEASE-MANIFEST.json.sig";
    hash = hashOrFake release.signatureSha256;
  };
  artifact = fetchurl {
    name = "null-kvn-client";
    url = "${release.baseUrl}/${release.releaseId}/null-kvn-client";
    hash = hashOrFake release.artifactSha256;
  };
in
stdenvNoCC.mkDerivation {
  pname = "null-kvn-client";
  version = release.version;
  src = artifact;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    coreutils
    jq
    openssl
  ];

  installPhase = ''
    runHook preInstall
    set -euo pipefail

    manifest=${manifest}
    signature=${signature}
    artifact=$src
    public_key=${./distribution-ed25519-public.pem}
    transcript="$TMPDIR/null-kvn-distribution-transcript"
    canonical="$TMPDIR/null-kvn-release-manifest.canonical"

    test -f "$manifest" && test ! -L "$manifest"
    test -f "$signature" && test ! -L "$signature"
    test -f "$artifact" && test ! -L "$artifact"
    test "$(stat -c %s "$signature")" -eq 64

    # The signature covers the exact manifest bytes, including its final LF.
    printf 'null-kvn-distribution-v1\0' > "$transcript"
    cat "$manifest" >> "$transcript"
    openssl pkeyutl -verify -pubin -inkey "$public_key" -rawin \
      -in "$transcript" -sigfile "$signature"

    # jq's sorted compact form matches the producer's canonical JSON form.
    jq -cS . "$manifest" > "$canonical"
    cmp -s "$manifest" "$canonical"

    jq -e --arg release_id "${release.releaseId}" \
      --arg version "${release.version}" \
      --arg target "x86_64-unknown-linux-musl" '
      (type == "object") and
      ((keys | sort) == [
        "artifacts", "channel", "createdUtc", "releaseId", "schema",
        "sequence", "sourceCommit", "sourceTree", "target", "version"
      ]) and
      .schema == "null-kvn-distribution-v1" and
      .channel == "internal-beta" and
      .target == $target and
      .releaseId == $release_id and
      (.releaseId | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,126}[A-Za-z0-9]$")) and
      (.createdUtc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      (.sourceCommit | test("^[0-9a-f]{40}$")) and
      (.sourceTree | test("^[0-9a-f]{40}$")) and
      (.releaseId | split("-") | last) == (.sourceTree[0:8]) and
      (.version == $version) and
      (.version | test("^20[0-9]{2}\\.(?:[1-9]|1[0-2])\\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?$")) and
      (.sequence | numbers | floor == . and . >= 1) and
      (.artifacts | (type == "object" and (keys == ["client"]))) and
      (.artifacts.client | (type == "object" and
        (keys | sort) == ["bytes", "name", "sha256"] and
        .name == "null-kvn-client" and
        (.sha256 | test("^[0-9a-f]{64}$")) and
        (.bytes | numbers | floor == . and . >= 1 and . <= 134217728)))
    ' "$manifest"

    actual_sha256="$(sha256sum "$artifact" | cut -d ' ' -f 1)"
    expected_sha256="$(jq -er '.artifacts.client.sha256' "$manifest")"
    test "$actual_sha256" = "$expected_sha256"
    actual_bytes="$(stat -c %s "$artifact")"
    expected_bytes="$(jq -er '.artifacts.client.bytes' "$manifest")"
    test "$actual_bytes" = "$expected_bytes"

    install -Dm555 "$artifact" "$out/bin/null-kvn-client"
    test "$(find "$out" -type f -printf '%P\n')" = "bin/null-kvn-client"
    runHook postInstall
  '';

  meta = {
    description = "NULL KVN source-free Linux client";
    homepage = "https://github.com/fnltochka/null-kvn-dist";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "null-kvn-client";
  };
}
