{
  description = "NixOS flake for Pterodactyl panel + Wings on a single machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }: {
    nixosModules = {
      pterodactyl = import ./modules/pterodactyl.nix;
      wings       = import ./modules/wings.nix;
    };
  };
}
