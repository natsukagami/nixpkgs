{ lib
, fetchurl
, undmg
, stdenv
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "tableplus";
  version = "504";
  src = fetchurl {
    url = "https://download.tableplus.com/macos/${finalAttrs.version}/TablePlus.dmg";
    hash = "sha256-YFUquv71QFEnlmh93+HsFN6XtgoUx6CMOVqfdWAIWfo=";
  };

  sourceRoot = "TablePlus.app";

  nativeBuildInputs = [ undmg ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications/TablePlus.app"
    cp -R . "$out/Applications/TablePlus.app"
    mkdir "$out/bin"
    ln -s "$out/Applications/TablePlus.app/Contents/MacOS/TablePlus" "$out/bin/${finalAttrs.pname}"

    runHook postInstall
  '';

  meta = with lib; {
    description = "Database management made easy";
    homepage = "https://tableplus.com";
    license = licenses.unfree;
    maintainers = with maintainers; [ yamashitax ];
    platforms = platforms.darwin;
  };
})
