{ config, lib, pkgs, ... }:
let cfg = config.programs.friend-location-collector;
in {
  options.programs.friend-location-collector = {
    enable = lib.mkEnableOption "the Find My accessibility reader";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      description = "Installed reader package";
    };
  };
  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];
  };
}
