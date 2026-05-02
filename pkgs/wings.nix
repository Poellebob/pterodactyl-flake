{ lib, stdenvNoCC, fetchurl, ... }:

# To update: change `version`, then replace `hash` with lib.fakeHash,
# run `nix build .#wingsPackage` and copy the real hash from the error.
let
  version = "1.11.13";
in
stdenvNoCC.mkDerivation {
  pname = "wings";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_amd64";
    # Run: nix-prefetch-url https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_amd64
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    install -Dm755 $src $out/bin/wings
  '';

  meta = {
    description = "Pterodactyl Wings — the server-side daemon for game server management";
    homepage    = "https://pterodactyl.io";
    license     = lib.licenses.mit;
    platforms   = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "wings";
  };
}
