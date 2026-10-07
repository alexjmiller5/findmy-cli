{ lib, stdenv, swift }:
stdenv.mkDerivation {
  pname = "friend-location-collector";
  version = "unstable";
  src = ../findmy.swift;
  dontUnpack = true;
  nativeBuildInputs = [ swift ];
  buildPhase = ''
    runHook preBuild
    swiftc -Onone "$src" -o findmy
    runHook postBuild
  '';
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./findmy --selftest
    runHook postCheck
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 findmy "$out/bin/findmy"
    runHook postInstall
  '';
  meta = {
    description = "Read displayed Find My locations through macOS accessibility";
    platforms = lib.platforms.darwin;
    mainProgram = "findmy";
  };
}
