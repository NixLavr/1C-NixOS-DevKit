{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  copyDesktopItems,
  makeDesktopItem,
  makeWrapper,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  cairo,
  cups,
  dbus,
  expat,
  fontconfig,
  freetype,
  glib,
  gtk3,
  libdrm,
  libgbm,
  libGL,
  libnotify,
  libsecret,
  libice,
  libsm,
  libx11,
  libxcrypt-legacy,
  libxscrnsaver,
  libxcomposite,
  libxcursor,
  libxdamage,
  libxext,
  libxfixes,
  libxi,
  libxrandr,
  libxrender,
  libxtst,
  libxcb,
  libxxf86vm,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,
  wayland,
  xdg-utils,
  xkeyboard_config,
}:

let
  runtimeLibs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    cairo
    cups
    dbus
    expat
    fontconfig
    freetype
    glib
    gtk3
    libdrm
    libgbm
    libGL
    libnotify
    libsecret
    libice
    libsm
    libx11
    libxcrypt-legacy
    libxscrnsaver
    libxcomposite
    libxcursor
    libxdamage
    libxext
    libxfixes
    libxi
    libxrandr
    libxrender
    libxtst
    libxcb
    libxxf86vm
    nspr
    nss
    pango
    pipewire
    stdenv.cc.cc.lib
    systemd
    wayland
  ];
in
stdenv.mkDerivation rec {
  pname = "onec-connect";
  version = "5.5.2";

  src = fetchurl {
    url = "https://updates.1c-connect.com/desktop/distribs/1C-Connect-Linux-x64.tar.gz";
    hash = "sha256-3Jz/rthHDglG99ptAHPUrlCzPt7EENuWCEIpa7Wko5o=";
  };

  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    copyDesktopItems
    makeWrapper
  ];

  buildInputs = runtimeLibs;

  desktopItems = [
    (makeDesktopItem {
      name = "onec-connect";
      desktopName = "1C-Connect";
      exec = "onec-connect";
      icon = "onec-connect";
      categories = [
        "Network"
        "InstantMessaging"
        "RemoteAccess"
      ];
    })
  ];

  installPhase = ''
    runHook preInstall

    appRoot="$PWD"
    if [ -d "$appRoot/1c-connect" ]; then
      appRoot="$appRoot/1c-connect"
    fi

    install -d "$out/bin" "$out/share/1c-connect"
    cp -r "$appRoot"/. "$out/share/1c-connect/"

    makeWrapper "$out/share/1c-connect/app/bin/connect" "$out/bin/onec-connect" \
      --chdir "$out/share/1c-connect/app/bin" \
      --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}" \
      --set QT_XKB_CONFIG_ROOT "${xkeyboard_config}/share/X11/xkb" \
      --prefix PATH : "${lib.makeBinPath [ xdg-utils ]}"

    install -Dm644 "$out/share/1c-connect/app/bin/ico-app.png" \
      "$out/share/pixmaps/onec-connect.png"

    runHook postInstall
  '';

  meta = {
    description = "1C-Connect desktop client for Linux";
    homepage = "https://1c-connect.com/";
    license = lib.licenses.unfreeRedistributable;
    mainProgram = "onec-connect";
    platforms = [ "x86_64-linux" ];
  };
}
