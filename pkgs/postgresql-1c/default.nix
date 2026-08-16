{
  lib,
  stdenv,
  autoPatchelfHook,
  binutils,
  zstd,
  makeWrapper,
  glibc,
  icu74,
  libkrb5,
  libselinux,
  liburing,
  libuuid,
  libxml2_13,
  libxslt,
  linux-pam,
  lz4,
  numactl,
  openldap,
  openssl,
  readline,
  systemdLibs,
  zlib,
}:

{
  archiveFile,
  version ? "18.1-2.1C",
  pname ? "postgresql-1c",
  meta ? { },
}:

stdenv.mkDerivation (finalAttrs: {
  inherit pname version;

  src = if builtins.isPath archiveFile then archiveFile else /. + toString archiveFile;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [
    autoPatchelfHook
    binutils
    makeWrapper
    zstd
  ];

  buildInputs = [
    glibc
    icu74
    libkrb5
    libselinux
    liburing
    libuuid
    libxml2_13
    libxslt
    linux-pam
    lz4
    numactl
    openldap
    openssl
    readline
    systemdLibs
    zlib
    zstd
  ];

  installPhase = ''
    runHook preInstall

    archiveDir="$PWD/archive"
    rootDir="$PWD/root"
    mkdir -p "$archiveDir" "$rootDir"

    tar -xjf "$src" -C "$archiveDir"

    shopt -s nullglob
    debs=("$archiveDir"/*.deb)
    if [ "''${#debs[@]}" -eq 0 ]; then
      echo "В архиве не найдены Debian-пакеты (*.deb)" >&2
      exit 1
    fi

    for deb in "''${debs[@]}"; do
      dataMember="$(${binutils}/bin/ar t "$deb" | grep '^data\.tar\.' | head -n1)"
      if [ -z "$dataMember" ]; then
        echo "В пакете $(basename "$deb") не найден data.tar.*" >&2
        exit 1
      fi

      case "$dataMember" in
        data.tar.zst)
          ${binutils}/bin/ar p "$deb" "$dataMember" | ${zstd}/bin/zstd -dc | tar -x -C "$rootDir"
          ;;
        data.tar.xz|data.tar.gz|data.tar.bz2|data.tar)
          ${binutils}/bin/ar p "$deb" "$dataMember" | tar -x -C "$rootDir" -a
          ;;
        *)
          echo "Неподдерживаемый формат $dataMember в $(basename "$deb")" >&2
          exit 1
          ;;
      esac
    done

    pgRoot="$rootDir/usr/lib/postgresql/18"
    if [ ! -x "$pgRoot/bin/postgres" ]; then
      echo "В архиве не найден usr/lib/postgresql/18/bin/postgres" >&2
      exit 1
    fi

    mkdir -p "$out"
    cp -a "$rootDir/usr" "$out/"
    chmod -R u+w "$out"

    rm -rf \
      "$out/usr/lib/systemd" \
      "$out/usr/lib/tmpfiles.d" \
      "$out/usr/share/lintian" \
      "$out/usr/share/postgresql-common"
    rm -f "$out/usr/bin"/* "$out/usr/sbin"/* 2>/dev/null || true

    mkdir -p "$out/bin"
    for b in "$out"/usr/lib/postgresql/18/bin/*; do
      if [ -x "$b" ]; then
        name="$(basename "$b")"
        ln -s "../usr/lib/postgresql/18/bin/$name" "$out/bin/$name"
      fi
    done

    # Nixpkgs packages expose libpq/libecpg in $out/lib. Keep the Debian
    # location too, because PostgreSQL itself was built with that libdir.
    mkdir -p "$out/lib"
    for l in "$out"/usr/lib/x86_64-linux-gnu/lib*.so*; do
      if [ -e "$l" ]; then
        ln -s "../usr/lib/x86_64-linux-gnu/$(basename "$l")" "$out/lib/$(basename "$l")"
      fi
    done

    # Compatibility with nixpkgs' postgresql.withPackages link layout.
    mkdir -p "$out/share/postgresql"
    ln -s "../../usr/share/postgresql/18" "$out/share/postgresql/18"
    for d in extension timezonesets tsearch_data; do
      if [ -d "$out/usr/share/postgresql/18/$d" ]; then
        ln -s "../../usr/share/postgresql/18/$d" "$out/share/postgresql/$d"
      fi
    done

    if [ -d "$out/usr/share/postgresql/18/man" ]; then
      mkdir -p "$out/share"
      ln -s "../usr/share/postgresql/18/man" "$out/share/man"
    fi

    # pg_config from the Ubuntu binary package reports /usr paths. Keep the
    # original in the versioned bindir, but expose a Nix-aware wrapper in PATH.
    mv "$out/bin/pg_config" "$out/bin/pg_config-ubuntu"
    makeWrapper "$out/usr/lib/postgresql/18/bin/pg_config" "$out/bin/pg_config" \
      --run '
        case " $* " in
          *" --bindir "*) echo "'"$out"'/bin"; exit 0 ;;
          *" --pkglibdir "*) echo "'"$out"'/usr/lib/postgresql/18/lib"; exit 0 ;;
          *" --sharedir "*) echo "'"$out"'/usr/share/postgresql/18"; exit 0 ;;
          *" --libdir "*) echo "'"$out"'/lib"; exit 0 ;;
        esac
      '

    runHook postInstall
  '';

  preFixup = ''
    addAutoPatchelfSearchPath "$out/usr/lib/x86_64-linux-gnu"
    addAutoPatchelfSearchPath "$out/usr/lib/postgresql/18/lib"
  '';

  passthru = {
    psqlSchema = "18";
    dlSuffix = ".so";
    installedExtensions = [ ];
    pkgs = { };
    pg_config = finalAttrs.finalPackage;
    withJIT = finalAttrs.finalPackage;
    withoutJIT = finalAttrs.finalPackage;
    withPackages =
      f:
      let
        extensions = f { };
      in
      if extensions == [ ] then
        finalAttrs.finalPackage
      else
        throw "postgresql-1c: external PostgreSQL extensions through withPackages are not supported for the binary 1C build";
  };

  meta = {
    description = "PostgreSQL 18.1-2.1C binary package for 1C";
    homepage = "https://www.postgresql.org/";
    license = lib.licenses.postgresql;
    platforms = [ "x86_64-linux" ];
  }
  // meta;
})
