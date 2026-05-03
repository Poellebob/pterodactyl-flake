{ lib, stdenvNoCC, fetchurl, ... }:

let
  version = "1.11.13";
  hash = "sha256-06ppifap4pklcb6aldqwz6lkz2hdja5pbp8n5h4hzhgivm2zm9dc";
in
stdenvNoCC.mkDerivation {
  pname = "wings";
  inherit version;

  src = fetchurl {
    url = "https://github.com/pterodactyl/wings/releases/download/v${version}/wings_linux_amd64";
    hash = hash;
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
