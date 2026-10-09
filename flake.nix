{
  description = "Friend location collector";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" ];
      eachSystem = nixpkgs.lib.genAttrs systems;
    in {
      packages = eachSystem (system:
        let pkgs = import nixpkgs { inherit system; };
        in rec {
          friend-location-collector = pkgs.callPackage ./nix/package.nix { };
          default = friend-location-collector;
        });
      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/findmy";
        };
      });
      homeModules.default = import ./nix/home-module.nix;
      darwinModules.default = import ./nix/darwin-module.nix;
    };
}
