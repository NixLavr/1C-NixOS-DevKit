{
  lib,
  stdenv,
  autoPatchelfHook,
  wrapGAppsHook3,
  makeWrapper,
  unzip,
  alsa-lib,
  atk,
  cairo,
  cups,
  e2fsprogs,
  fontconfig,
  freetype,
  gdk-pixbuf,
  glib,
  glib-networking,
  glibcLocales,
  gsettings-desktop-schemas,
  gtk3,
  krb5,
  libGL,
  libGLU,
  libice,
  libsecret,
  libsm,
  libx11,
  libxcrypt-legacy,
  libxext,
  libxi,
  libxrender,
  libxtst,
  libxxf86vm,
  lz4,
  pango,
  webkitgtk_4_1,
  zlib,
}:

# Собирает пакет 1С:Enterprise Development Tools (EDT) из фирменного
# offline-дистрибутива (1c_edt_distr_offline_*.tar.gz).
#
# Штатный инсталлятор (1ce-installer-cli) здесь не запускается: он требует
# uid 0 и ведёт глобальный реестр установленных продуктов в /etc/1C/1CE —
# состояние, которому в /nix/store места нет. Полезной работы он при этом
# не делает: компоненты дистрибутива (*.e1c.car) — обычные zip-архивы, и
# каталог data/ внутри них дословно совпадает с тем, что инсталлятор
# раскладывает по <products-home>/components/. Поэтому пакет распаковывает
# компоненты напрямую и сам доводит их до рабочего вида: прибивает -vm к
# встроенной Java, уводит область конфигурации Eclipse в $HOME (каталог
# установки в /nix/store доступен только на чтение) и ставит .desktop.
let
  mkOnecEdt =
    {
      archiveFile, # путь или строка с абсолютным путём к архиву дистрибутива (.tar.gz)
      version ? null, # по умолчанию выводится из имени архива
      pname ? "onec-edt",
      meta ? { },
    }:
    let
      # 1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz -> "2026.1.2+2".
      # Регулярка не привязана к началу имени: у архива, добавленного в стор
      # (requireFile / nix store add-file), базовое имя начинается с хеша.
      archiveName = baseNameOf (toString archiveFile);
      versionFromName =
        let
          parts = builtins.match ".*1c_edt_distr_offline_([0-9.]+)_([0-9]+)_.*" archiveName;
        in
        if parts == null then
          throw "onec-edt: не удалось вывести версию из имени '${archiveName}', задайте version явно"
        else
          "${builtins.elemAt parts 0}+${builtins.elemAt parts 1}";

      edtVersion = if version != null then version else versionFromName;

      # Библиотеки, которые SWT, JavaFX и встроенные нативные библиотеки 1С
      # грузят через dlopen по soname — RUNPATH от autoPatchelf сюда не
      # достаёт, поэтому они же прописываются в LD_LIBRARY_PATH обёрток.
      runtimeLibs = [
        alsa-lib
        atk
        cairo
        cups
        e2fsprogs
        fontconfig
        freetype
        gdk-pixbuf
        glib
        gtk3
        krb5
        libGL
        libGLU
        libice
        libsecret
        libsm
        libx11
        libxcrypt-legacy
        libxext
        libxi
        libxrender
        libxtst
        libxxf86vm
        lz4
        pango
        stdenv.cc.cc.lib
        webkitgtk_4_1
        zlib
      ];
    in
    stdenv.mkDerivation {
      inherit pname;
      version = edtVersion;

      # toString + "/." вместо пути-литерала: иначе парсер Nix падает на
      # путях с нелатинскими символами в каталогах.
      src =
        if builtins.isPath archiveFile || lib.isDerivation archiveFile then
          archiveFile
        else
          /. + toString archiveFile;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;

      # Дерево EDT — почти 8 ГБ фирменных бинарников; strip их только
      # портит и стоит десятки минут.
      dontStrip = true;

      # Обёртки ставятся вручную в preFixup: GTK-переменные нужны трём
      # лаунчерам в bin/, а не пяти тысячам файлов внутри дерева Eclipse.
      dontWrapGApps = true;

      nativeBuildInputs = [
        autoPatchelfHook
        makeWrapper
        unzip
        wrapGAppsHook3
      ];

      buildInputs = runtimeLibs;

      # EDT несёт нативные библиотеки платформы 1С для всех версий начиная
      # с 8.3.8 — они тянут вырезанные из nixpkgs как EOL GTK2/WebKitGTK 4.0
      # и медиа-стек в нескольких несовместимых ABI сразу. Ни одна из этих
      # веток не используется, а libc.so.1/libc.so.7 приходят из случайно
      # попавших в поставку solaris/freebsd-бинарников.
      autoPatchelfIgnoreMissingDeps = [
        "coreui83.so"
        "libavcodec*.so.*"
        "libavformat*.so.*"
        "libc.so.1"
        "libc.so.7"
        "libgdk-x11-2.0.so.0"
        "libgtk-x11-2.0.so.0"
        "libjavascriptcoregtk-4.0.so.18"
        "libsoup-2.4.so.1"
        "libwebkit2gtk-4.0.so.37"
        "libwebkitgtk-3.0.so.0"
        "libwx_gtk2u-2.9.so.2"
      ];

      installPhase = ''
        runHook preInstall

        distDir="$PWD/dist"
        mkdir -p "$distDir"
        tar -xzf "$src" -C "$distDir"

        shopt -s nullglob
        edtCar=("$distDir"/1c-edt-[0-9]*-linux-*.e1c.car)
        startCar=("$distDir"/1c-edt-start-*-linux-*.e1c.car)
        jdkDir=("$distDir"/*-jdk-full-*-linux-*/data)

        if [ ''${#edtCar[@]} -eq 0 ]; then
          echo "В дистрибутиве не найден компонент 1c-edt-<версия>-linux-*.e1c.car" >&2
          exit 1
        fi
        if [ ''${#jdkDir[@]} -eq 0 ]; then
          echo "В дистрибутиве не найдена встроенная Java (*-jdk-full-*)" >&2
          exit 1
        fi

        base="$out/share/1c-edt"
        mkdir -p "$base"

        # .car собран Java-архиватором, а zip из Java не хранит unix-права:
        # какие файлы исполняемые, знает только component-manifest.xml
        # компонента. Штатный инсталлятор проставляет биты по нему —
        # делаем то же самое, иначе не запускается ни один лаунчер.
        applyExecBits() {
          local manifest="$1" root="$2"
          awk 'match($0, /categories="[^"]*"/) {
                 cat = substr($0, RSTART + 12, RLENGTH - 13)
                 if (cat ~ /(^|,)executable(,|$)/ && match($0, />[^<]*<\/file>/))
                   print substr($0, RSTART + 1, RLENGTH - 8)
               }' "$manifest" \
          | while IFS= read -r rel; do
              if [ -f "$root$rel" ]; then chmod +x "$root$rel"; fi
            done
        }

        # data/ внутри компонента — готовое дерево установки.
        unpackCar() {
          unzip -q "$1" 'data/*' 'component-manifest.xml' -d "$base/.unpack"
          mv "$base/.unpack/data" "$base/$2"
          applyExecBits "$base/.unpack/component-manifest.xml" "$base/$2"
          rm -rf "$base/.unpack"
        }
        unpackCar "''${edtCar[0]}" edt
        if [ ''${#startCar[@]} -gt 0 ]; then
          unpackCar "''${startCar[0]}" start
        fi

        # Встроенная Java лежит в дистрибутиве уже распакованной. Заменить
        # её на jdk17 из nixpkgs нельзя: 1cedtstart написан на JavaFX,
        # которого в сборках nixpkgs нет.
        cp -a "''${jdkDir[0]}" "$base/jdk"
        chmod -R u+w "$base"
        applyExecBits "$(dirname "''${jdkDir[0]}")/component-manifest.xml" "$base/jdk"

        # Без -vm лаунчер Eclipse ищет JVM в JAVA_HOME/PATH; прибиваем её к
        # встроенной. Строка -vm обязана стоять до -vmargs, иначе лаунчер
        # считает её аргументом JVM, а не своим.
        pinVm() {
          local ini="$1"
          [ -e "$ini" ] || return 0
          awk -v vm="$base/jdk/bin/java" '
            !seen && $0 == "-vmargs" { print "-vm"; print vm; seen = 1 }
            { print }
          ' "$ini" > "$ini.new"
          mv "$ini.new" "$ini"
        }
        pinVm "$base/edt/1cedt.ini"
        pinVm "$base/start/1cedtstart.ini"

        # -Dosgi.debug=.options ищется относительно текущего каталога:
        # штатный ярлык 1С запускает EDT из каталога установки, у нас же CWD
        # какой угодно, а без этого файла Equinox включает отладочную печать
        # целиком. Абсолютный путь сохраняет штатное поведение, не навязывая
        # рабочий каталог (иначе поехали бы относительные пути в аргументах).
        sed -i "s|^-Dosgi\.debug=\.options$|-Dosgi.debug=$base/edt/.options|" "$base/edt/1cedt.ini"

        # Лаунчер Eclipse ищет plugins/ рядом с argv[0], поэтому симлинк в
        # bin/ его ломает (молча, с кодом 1) — вызываем бинарники по их
        # настоящему пути.
        #
        # p2/OSGi пишут в configuration/ рядом с установкой, а она в
        # /nix/store только на чтение. Equinox для явно заданной области
        # конфигурации сам подставляет каталог установки родительской
        # (shared) областью, поэтому bundles.info и профиль p2 остаются
        # видны. У 1cedtstart osgi.configuration.area задан в его .ini.
        mkdir -p "$out/bin"
        cat > "$out/bin/1cedt" <<EOF
        #!${stdenv.shell}
        conf="\''${XDG_DATA_HOME:-\$HOME/.local/share}/1cedt/${edtVersion}/configuration"
        mkdir -p "\$conf"
        exec "$base/edt/1cedt" -configuration "\$conf" "\$@"
        EOF

        # 1cedtcli своего .ini не имеет и берёт JVM из PATH — её задают обёртки.
        for exe in "$base/edt/1cedtcli" "$base/start/1cedtstart"; do
          [ -e "$exe" ] || continue
          cat > "$out/bin/$(basename "$exe")" <<EOF
        #!${stdenv.shell}
        exec "$exe" "\$@"
        EOF
        done
        chmod +x "$out"/bin/*

        mkdir -p "$out/share/pixmaps" "$out/share/applications"
        ln -s "$base/edt/icon.xpm" "$out/share/pixmaps/1cedt.xpm"

        cat > "$out/share/applications/1cedt.desktop" <<EOF
        [Desktop Entry]
        Type=Application
        Version=1.0
        Terminal=false
        Categories=Development;IDE;
        Name=1C:EDT (${edtVersion})
        Comment=1C:Enterprise Development Tools
        Comment[ru]=Среда разработки 1С:Предприятие
        Exec=$out/bin/1cedt
        Icon=$out/share/pixmaps/1cedt.xpm
        EOF

        if [ -e "$out/bin/1cedtstart" ]; then
          ln -s "$base/start/icon.xpm" "$out/share/pixmaps/1cedtstart.xpm"
          # e1cedt:// — схема, по которой стартер открывает проекты из браузера.
          cat > "$out/share/applications/1cedtstart.desktop" <<EOF
        [Desktop Entry]
        Type=Application
        Version=1.0
        Terminal=false
        Categories=Development;IDE;
        Name=1C:EDT Start
        Comment=Launcher for 1C:Enterprise Development Tools
        Comment[ru]=Стартер 1С:Enterprise Development Tools
        Exec=$out/bin/1cedtstart %u
        Icon=$out/share/pixmaps/1cedtstart.xpm
        MimeType=x-scheme-handler/e1cedt;
        EOF
        fi

        # Лицензии — в общепринятое для Nix место.
        docDir="$out/share/doc/${pname}"
        mkdir -p "$docDir"
        for d in "$base/edt/licenses" "$base/jdk/legal"; do
          if [ -d "$d" ]; then cp -a "$d" "$docDir/$(basename "$d")"; fi
        done
        for f in "$base/edt/readme_ru.htm" "$base/edt/readme_en.htm" "$base/jdk/LICENSE"; do
          if [ -e "$f" ]; then cp "$f" "$docDir/"; fi
        done

        runHook postInstall
      '';

      preFixup = ''
        for exe in "$out"/bin/*; do
          wrapProgram "$exe" \
            "''${gappsWrapperArgs[@]}" \
            --set JAVA_HOME "$out/share/1c-edt/jdk" \
            --prefix PATH : "$out/share/1c-edt/jdk/bin" \
            --prefix LD_LIBRARY_PATH : "${lib.makeLibraryPath runtimeLibs}" \
            --prefix GIO_EXTRA_MODULES : "${glib-networking}/lib/gio/modules" \
            --prefix XDG_DATA_DIRS : "${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}" \
            --set-default LOCALE_ARCHIVE "${glibcLocales}/lib/locale/locale-archive" \
            --set-default WEBKIT_DISABLE_DMABUF_RENDERER 1
        done
      '';

      meta = {
        description = "1C:Enterprise Development Tools (EDT) — среда разработки для 1С:Предприятие 8";
        homepage = "https://edt.1c.ru";
        license = lib.licenses.unfree;
        mainProgram = "1cedt";
        platforms = [ "x86_64-linux" ];
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      }
      // meta;
    };
in
mkOnecEdt
