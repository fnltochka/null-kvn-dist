{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.null-kvn-client;
  service = config.services.null-kvn-client;
in
{
  options.programs.null-kvn-client = {
    enable = lib.mkEnableOption "the NULL KVN client package";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "Package to install for the NULL KVN client.";
    };
  };

  options.services.null-kvn-client = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Reserved switch for the NULL KVN client daemon. Activation is not part
        of this package-only release and must remain disabled.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];
    })
    {
      assertions = [
        {
          assertion = !service.enable;
          message = ''
            services.null-kvn-client activation is not published yet. Install
            the verified client with programs.null-kvn-client.enable only.
          '';
        }
      ];
    }
  ];
}
