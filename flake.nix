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
                test -f ${./README.md}
                grep -F 'null-kvn-distribution-v1\0' ${./package.nix}
                grep -F 'null-kvn-client' ${./package.nix}
                grep -F 'license = lib.licenses.unfree' ${./package.nix}
                grep -F 'default = false' ${./nixos-module.nix}
                mkdir -p "$out"
              '';
        }
      );
    };
}
