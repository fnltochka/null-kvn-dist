# NULL KVN source-free NixOS client

This flake packages the signed, source-free Linux `null-kvn-client` binary.
The public distribution contains one client artifact only. The detached
Ed25519 key is kept in `distribution-ed25519-public.pem` and is used during the
Nix build; the derivation also checks the canonical manifest, release identity,
artifact SHA-256, and byte size before installation.

## Current release

`release.nix` pins one immutable release ID, version, origin URL, and the SRI
hashes of its manifest, signature, and client artifact. There is no mutable
channel URL or latest-version lookup.

Install the package from a NixOS configuration:

```nix
{
  inputs.null-kvn-dist.url = "path:/path/to/null-kvn-dist";
  imports = [ inputs.null-kvn-dist.nixosModules.default ];
  programs.null-kvn-client.enable = true;
}
```

The daemon service is deliberately unavailable in this first distribution.
The option exists so consumers can state the disabled policy explicitly, but
enabling it fails evaluation until the complete client configuration, routing,
DNS, firewall, and teardown contract is published:

```nix
{
  services.null-kvn-client.enable = false;
}
```

## Explicit update workflow

There is no auto-update or “latest” lookup. For each owner-approved release,
update the fixed values in `release.nix`, then run `nix flake check` and build
the exact package with `nix build .#null-kvn-client`. Review the resulting
closure and manifest verification output before changing the consumer input
revision.
