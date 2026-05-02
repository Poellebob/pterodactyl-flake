{
  description = "NixOS flake for Pterodactyl panel + Wings on a single machine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    agenix = {
      url = "github:ryantm/agenix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, agenix, ... }: {
    nixosModules = {
      pterodactyl = import ./modules/pterodactyl.nix;
      wings       = import ./modules/wings.nix;
    };
  };
}
