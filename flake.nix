{
  description = "NULL KVN source-free client distribution for NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forEachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          client = pkgs.callPackage ./package.nix { };
        in
        {
          default = client;
          null-kvn-client = client;
        }
      );

      nixosModules.default = import ./nixos-module.nix;

      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);

      checks = forEachSystem (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          moduleConfig =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  nixpkgs.config.allowUnfree = true;
                  programs.null-kvn-client.enable = true;
                  services.resolved.enable = true;
                  services.null-kvn-client = {
                    enable = true;
                    alwaysOn = true;
                    earlyProtection = true;
                    configFile = ./tests/client.toml;
                  };
                }
              ];
            }).config;
          softModuleConfig =
            (nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                self.nixosModules.default
                {
                  nixpkgs.config.allowUnfree = true;
                  programs.null-kvn-client.enable = true;
                  services.resolved.enable = true;
                  services.null-kvn-client = {
                    enable = true;
                    configFile = ./tests/client.toml;
                  };
                }
              ];
            }).config;
        in
        {
          source-free-contract =
            pkgs.runCommand "null-kvn-source-free-contract"
              {
                nativeBuildInputs = [
                  pkgs.coreutils
                  pkgs.gnugrep
                  pkgs.jq
                ];
              }
              ''
                test -f ${./distribution-ed25519-public.pem}
                test -f ${./release.nix}
                test -f ${./package.nix}
                test -f ${./nixos-module.nix}
                test -f ${./dbus/dev.nullkvn.Client1.conf}
                test -f ${./polkit/dev.nullkvn.policy}
                test -f ${./product-config.toml}
                test -f ${./tests/client.toml}
                test -f ${./README.md}
                grep -F 'null-kvn-distribution-v1\0' ${./package.nix}
                grep -F 'null-kvn-client' ${./package.nix}
                grep -F 'license = lib.licenses.unfree' ${./package.nix}
                grep -F 'default = false' ${./nixos-module.nix}
                grep -F 'earlyProtection' ${./nixos-module.nix}
                grep -F 'services.null-kvn-client' ${./nixos-module.nix}
                grep -F 'LoadCredential' ${./nixos-module.nix}
                grep -F 'StateDirectory' ${./nixos-module.nix}
                mkdir -p "$out"
              '';

          client-module =
            assert builtins.elem pkgs.coreutils moduleConfig.systemd.services.null-kvn-client.path;
            assert builtins.elem pkgs.coreutils moduleConfig.systemd.services.null-kvn-client-guard.path;
            assert builtins.elem pkgs.nftables moduleConfig.systemd.services.null-kvn-client.path;
            assert builtins.elem pkgs.nftables moduleConfig.systemd.services.null-kvn-client-guard.path;
            pkgs.runCommand "null-kvn-client-module"
              {
                nativeBuildInputs = [ pkgs.gnugrep ];
              }
              ''
                test ${
                  if builtins.hasAttr "null-kvn-client-guard" softModuleConfig.systemd.services then
                    "false"
                  else
                    "true"
                } = true
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON softModuleConfig.systemd.services.null-kvn-client.requires)} = '[]'
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON softModuleConfig.systemd.services.null-kvn-client.after)} = '["dbus.socket","network-pre.target","systemd-resolved.service"]'
                test ${
                  if builtins.hasAttr "null-kvn-client-guard" moduleConfig.systemd.services then "true" else "false"
                } = true
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON moduleConfig.systemd.services.null-kvn-client.requires)} = '["null-kvn-client-guard.service"]'
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON moduleConfig.systemd.services.null-kvn-client.after)} = '["dbus.socket","network-pre.target","null-kvn-client-guard.service","systemd-resolved.service"]'
                test ${nixpkgs.lib.escapeShellArg moduleConfig.systemd.services.null-kvn-client-guard.serviceConfig.Type} = oneshot
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON moduleConfig.systemd.services.null-kvn-client-guard.requiredBy)} = '["network-pre.target"]'
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON moduleConfig.systemd.services.null-kvn-client.serviceConfig.StateDirectory)} = \
                  '["null-kvn","null-kvn/client"]'
                grep -F -- '--always-on' <<'EOF'
                ${moduleConfig.systemd.services.null-kvn-client.serviceConfig.ExecStart}
                EOF
                test ${nixpkgs.lib.escapeShellArg (builtins.toJSON moduleConfig.systemd.services.null-kvn-client.wants)} = \
                  '["network-pre.target","null-kvn-client-always-on.service","systemd-resolved.service"]'
                test -x ${moduleConfig.programs.null-kvn-client.package}/bin/null-kvn-client
                test -f ${moduleConfig.services.null-kvn-client.productConfigFile}
                test -f ${moduleConfig.programs.null-kvn-client.package}/share/dbus-1/system.d/dev.nullkvn.Client1.conf
                test -f ${moduleConfig.programs.null-kvn-client.package}/share/polkit-1/actions/dev.nullkvn.policy
                mkdir -p "$out"
              '';
        }
      );
    };
}
