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

The NixOS module also installs the client-only system-D-Bus and polkit assets
and the root daemon. By default activation is soft: enabling the service does
not create or require the early-boot protection guard. Set
`services.null-kvn-client.earlyProtection = true` to install the finite guard
before `network-pre.target`; the daemon then requires and starts after that
guard. The daemon still performs its own finite protection reconciliation when
it starts. Activation is deliberately host-only: it does not enable forwarding,
LAN gateway mode, L2TP, or any server, control-plane, or node-agent component.
The daemon receives both TOML files as systemd credentials; durable state is
created only under the `state_directory` declared by the client TOML.

```nix
{
  programs.null-kvn-client = {
    enable = true;
    # Optional: pin another approved binary package.
    # package = inputs.null-kvn-dist.packages.${pkgs.system}.null-kvn-client;
  };

  services.null-kvn-client = {
    enable = true;
    alwaysOn = true;
    # Optional: install and require the finite early-boot protection guard.
    # earlyProtection = true;
    configFile = ./client.toml;
    # productConfigFile defaults to the immutable file in the pinned package.
  };
}
```

`configFile` must be evaluation-readable and must declare a normalized absolute
state path below `/var/lib`; the module derives every parent `StateDirectory`
component from it. Enrollment and other mutable owner-only state are not
embedded in this public repository.

The public flake does not enroll a device. Provision a one-use owner-issued
bundle into the configured state directory before enabling the daemon. Never
put an enrollment bundle, device key, or mutable catalog in the Nix store.

## Explicit update workflow

There is no auto-update or “latest” lookup. For each owner-approved release,
update the fixed values in `release.nix`, then run `nix flake check` and build
the exact package with `nix build .#null-kvn-client`. Review the resulting
closure and manifest verification output before changing the consumer input
revision.
