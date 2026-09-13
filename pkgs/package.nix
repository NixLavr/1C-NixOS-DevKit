{
  lib,
  stdenv,
  autoPatchelfHook,
  wrapGAppsHook3,
  bubblewrap,
  unzip,
  glibc,
  krb5,
  keyutils,
  e2fsprogs,
  glib,
  gdk-pixbuf,
  cairo,
  pango,
  atk,
  gtk3,
  cups,
  libGL,
  libGLU,
  libxxf86vm,
  webkitgtk_4_1,
  wayland,
  libxkbcommon,
  harfbuzz,
  fontconfig,
  freetype,
  patchelf,
  gcc,
  gnused,
  glibcLocales,
  runCommand,
}:

# Собирает пакет 1С:Предприятие 8.3 из фирменного zip-архива дистрибутива:
# находит внутри него инсталлятор (setup-full-*.run) и ставит нужные
# компоненты через bubblewrap-песочницу (нужна для эмуляции root, который
# требует InstallBuilder).
let
  mkOnec =
    {
      archiveFile, # путь или строка с абсолютным путём к архиву дистрибутива (.zip)
      components,
      language ? "ru",
      version,
      pname,
      meta ? { },
      # Если задан, webinst пишет публикации в изменяемый файл, который
      # Apache подключает из NixOS-модуля. Это нужно только для работы
      # публикации из Конфигуратора на NixOS.
      webinstConfigPath ? null,
    }:
    let
      isClient = lib.any (c: lib.hasPrefix "client_" c) components;

      # desktop_icons даёт .desktop-файлы и иконки для клиентских бинарников —
      # подключаем всегда вместе с любым client_*.
      desktopIconsComponent = lib.optional (
        isClient && !(lib.elem "desktop_icons" components)
      ) "desktop_icons";
      allComponents = components ++ desktopIconsComponent;
    in
    stdenv.mkDerivation (finalAttrs: {
      inherit pname version;

      # toString + "/." вместо пути-литерала: иначе парсер Nix падает на
      # путях с нелатинскими символами в каталогах.
      src = if builtins.isPath archiveFile || lib.isDerivation archiveFile then
        archiveFile
      else
        /. + toString archiveFile;
      dontUnpack = true;
      dontConfigure = true;
      dontBuild = true;

      # wrapGAppsHook3 (только для клиента) задаёт GTK/GDK-переменные строго
      # внутрь замыкания пакета — без этого хостовые GTK/шрифтовые модули
      # подмешиваются к nix'овым и клиент падает по SIGSEGV.
      nativeBuildInputs = [
        autoPatchelfHook
        bubblewrap
        patchelf
        unzip
      ]
      ++ lib.optionals isClient [
        wrapGAppsHook3
        gcc
      ];

      # GTK/WebKit-стек нужен только клиентским компонентам (GUI); серверным
      # сборкам он не требуется и только раздувает замыкание пакета.
      buildInputs = [
        glibc
        krb5
        keyutils
        e2fsprogs
      ]
      ++ lib.optionals isClient [
        glib
        gdk-pixbuf
        cairo
        pango
        atk
        gtk3
        cups
        libGL
        libGLU
        libxxf86vm
        webkitgtk_4_1
        wayland
        libxkbcommon
        harfbuzz
        fontconfig
        freetype
        glibcLocales
        # nixpkgs-unstable собирает webkitgtk более новым libstdc++, чем
        # несёт с собой 1С — бандловские копии для клиента удаляются ниже,
        # чтобы все .so цепляли эту единую версию.
        stdenv.cc.cc.lib
      ];

      # Опциональные dlopen-плагины (внешние СУБД и др.), не нужные для базовой
      # работы. Для клиента сюда же попадает устаревшая ветка webkitgtk 4.0 /
      # libsoup 2.4, вырезанная из nixpkgs как EOL — используется только
      # современный .wk41-путь.
      autoPatchelfIgnoreMissingDeps = [
        "libodbc.so.2"
        "libpq.so.5"
        "libmysqlclient.so.21"
      ]
      ++ lib.optionals isClient [
        "libwebkit2gtk-4.0.so.37"
        "libjavascriptcoregtk-4.0.so.18"
        "libsoup-2.4.so.1"
      ];

      # .so-файлы 1С грузят libharfbuzz/cairo/fontconfig/freetype через
      # dlopen() без RUNPATH, поэтому без явного append-rpath резолвится
      # системная копия рядом с nix'овой — две копии harfbuzz в процессе
      # дают SIGSEGV. Дописываем nix-пути в DT_RUNPATH каждого .so через
      # auto-patchelf --append-rpaths (fontconfig.lib, а не fontconfig — у
      # fontconfig дефолтный выход "bin" без каталога lib).
      appendRunpaths = lib.optionals isClient (
        map (p: "${p}/lib") [
          harfbuzz
          cairo
          fontconfig.lib
          freetype
        ]
      );

      installPhase = ''
        runHook preInstall

        # Распаковываем скачанный zip и ищем внутри инсталлятор.
        archiveDir="$PWD/archive"
        mkdir -p "$archiveDir"
        unzip -q "$src" -d "$archiveDir"

        runFile="$(find "$archiveDir" -iname 'setup-full-*.run' -type f | head -n1)"
        if [ -z "$runFile" ]; then
          runFile="$(find "$archiveDir" -iname '*.run' -type f | head -n1)"
        fi
        if [ -z "$runFile" ]; then
          echo "В архиве не найден инсталлятор (*.run)" >&2
          exit 1
        fi

        installer="$PWD/setup.run"
        cp "$runFile" "$installer"
        chmod +x "$installer"

        # Инсталлятор — не-NixOS ELF, которого интерпретатора нет в песочнице,
        # и требует uid 0 — недостающий FHS собирается в отдельном
        # корне-tmpfs через bubblewrap. TMPDIR уводим в каталог сборки, а не
        # в tmpfs /tmp — инсталлятор распаковывает туда гигабайты данных.
        mkdir -p "$NIX_BUILD_TOP/fhs-tmp"
        runInFHS() {
          bwrap \
            --unshare-user --uid 0 --gid 0 \
            --ro-bind /nix /nix \
            --ro-bind /etc /etc \
            --ro-bind /bin /bin \
            --bind "$NIX_BUILD_TOP" "$NIX_BUILD_TOP" \
            --proc /proc --dev /dev \
            --tmpfs /tmp --tmpfs /var \
            --dir /usr/local/bin \
            --symlink ${glibc}/lib/ld-linux-x86-64.so.2 /lib64/ld-linux-x86-64.so.2 \
            --setenv TMPDIR "$NIX_BUILD_TOP/fhs-tmp" \
            --chdir "$PWD" \
            -- "$@"
        }

        # Список допустимых компонентов достаём из --help на английском —
        # без локали кириллица в выводе превращается в "?????".
        all_components=$(runInFHS "$installer" --help --installer-language en 2>&1 | awk '
          /--enable-components/ { armed=1 }
          armed && /Allowed:/   { sub(/^.*Allowed: */, ""); print; exit }
        ')
        if [ -z "$all_components" ]; then
          echo "Не удалось получить список компонентов из инсталлятора" >&2
          exit 1
        fi

        enabled="${lib.concatStringsSep "," allComponents}"
        for c in ''${enabled//,/ }; do
          case " $all_components " in
            *" $c "*) ;;
            *) echo "Компонент '$c' неизвестен этой версии инсталлятора. Доступны: $all_components" >&2; exit 1 ;;
          esac
        done

        disable=""
        for c in $all_components; do
          case ",$enabled," in
            *",$c,"*) ;;
            *) disable="''${disable:+$disable,}$c" ;;
          esac
        done

        workroot="$PWD/install-root"
        mkdir -p "$workroot"

        runInFHS \
          "$installer" \
            --mode unattended --unattendedmodeui minimal \
            --installer-language "${language}" \
            --enable-components "$enabled" \
            --disable-components "$disable" \
            --prefix "$workroot"

        versioned="$(find "$workroot/opt/1cv8/x86_64" -mindepth 1 -maxdepth 1 -type d | head -n1)"
        if [ -z "$versioned" ]; then
          echo "В результате установки не найден /opt/1cv8/x86_64/<версия>" >&2
          exit 1
        fi

        dest="$out/opt/1cv8/x86_64/${version}"
        mkdir -p "$dest"
        cp -a "$versioned/." "$dest/"
        chmod -R u+w "$dest"

        # Мусор инсталлятора, не нужный ни одному бинарнику: деинсталлятор и
        # многоязычная HTML-читалка.
        rm -f "$dest"/uninstaller-full "$dest"/uninstallAsRoot "$dest"/uninstaller-full.dat
        rm -f "$dest"/readme.htm
        rm -rf "$dest"/readme

        # conf/conf.cfg — служебный файл неиспользуемой утилиты обновлений,
        # к тому же ссылается на путь временной песочницы сборки.
        rm -rf "$dest"/conf

        # Штатные systemd-юниты прописывают FHS-пути и не используются —
        # NixOS-модуль генерирует свои юниты (см. module.nix).
        rm -f "$dest"/srv1cv8-*.service "$dest"/ras-*.service

        # Документацию и лицензии переносим в общепринятое для Nix место.
        docDir="$out/share/doc/${pname}"
        mkdir -p "$docDir"
        for d in docs licenses; do
          if [ -d "$dest/$d" ]; then
            mv "$dest/$d" "$docDir/$d"
          fi
        done

        ${lib.optionalString isClient ''
          # Бандловый libstdc++/libgcc_s собран старым тулчейном и не даёт
          # символьных версий, нужных webkitgtk — удаляем, чтобы autoPatchelf
          # подставил единую современную версию из stdenv.cc.cc.lib.
          rm -f "$dest"/libstdc++.so.6 "$dest"/libgcc_s.so.1

          # Явно линкуем nix'овую libharfbuzz в 1cv8c первой, чтобы
          # последующие dlopen() не подхватили системную копию (SIGSEGV).
          patchelf --add-needed libharfbuzz.so.0 "$dest/1cv8c" || true

          # Толстый клиент использует встроенный WebKit-виджет; поставка
          # несёт libwx под старый webkitgtk 4.0 (вырезан из nixpkgs) и под
          # 4.1 (.wk41) — переключаем дефолтный симлинк на .wk41.
          if [ -e "$dest/libwx_gtk3u-3.0.so.0" ]; then
            rm -f "$dest/libwx_gtk3u-3.0.so.0"
            ln -s libwx_gtk3u-3.0.so.0.1.0.wk41 "$dest/libwx_gtk3u-3.0.so.0"
          fi

          # Та же развилка 4.0/4.1 для веб-расширения WebKit (грузится по
          # имени файла, не NEEDED) — без него HTML-виджеты форм остаются
          # пустыми без явной ошибки. Кладём .wk41-вариант на дефолтное имя.
          if [ -e "$dest/webkit2_extu-3.0.so.wk41" ]; then
            cp -f "$dest/webkit2_extu-3.0.so.wk41" "$dest/webkit2_extu-3.0.so"
          fi
        ''}

        ${lib.optionalString isClient ''
          # сборка shim'а-перехватчика dlopen
          mkdir -p "$out/lib"
          cat > dlopen-remap.c <<'EOF'
          #include <dlfcn.h>
          #include <string.h>

          /* 1С грузит системные библиотеки по абсолютным путям через
             dlopen(), куда RUNPATH/LD_LIBRARY_PATH не достают — подменяем
             эти пути на nix-копии. */
          static void *(*real_dlopen)(const char *, int);

          void *dlopen(const char *file, int flags) {
            static char  map_hbz30[] = "@HARFBUZZ@";
            static char  map_cairo30[] = "@CAIRO@";
            static char  map_fcfg30[] = "@FONTCONFIG@";
            static char  map_frt30[] = "@FREETYPE@";
            static char  map_cairov8[] = "@CAIROV8@";
            if (!real_dlopen)
              real_dlopen = (void *(*)(const char *, int)) dlsym(RTLD_NEXT, "dlopen");
            if (file) {
              /* grphcs.so догружает свой бандловый libcairo-v8.so, который
                 конфликтует с уже загруженным nix'овым libcairo.so.2 (две
                 реализации cairo → SIGSEGV в pixman). libcairo-v8.so также
                 несёт fontconfig/freetype/harfbuzz, которые grphcs достаёт
                 через dlsym — поэтому вместо голого cairo подставляем
                 заглушку с этими четырьмя nix-библиотеками в DT_NEEDED. */
              if (strstr(file, "libcairo-v8.so"))
                return real_dlopen(map_cairov8, flags);
              if (strstr(file, "/lib/") && strstr(file, "libharfbuzz.so"))
                return real_dlopen(map_hbz30, flags);
              if (strstr(file, "/lib/") && strstr(file, "libcairo.so"))
                return real_dlopen(map_cairo30, flags);
              if (strstr(file, "/lib/") && strstr(file, "libfontconfig.so"))
                return real_dlopen(map_fcfg30, flags);
              if (strstr(file, "/lib/") && strstr(file, "libfreetype.so"))
                return real_dlopen(map_frt30, flags);
            }
            return real_dlopen(file, flags);
          }
          EOF
          # Пустая заглушка вместо libcairo-v8.so (см. dlopen-remap.c выше);
          # --no-as-needed обязателен, иначе линкер выкинет неиспользуемые
          # зависимости из DT_NEEDED.
          : > cairo-v8-stub.c
          ${gcc}/bin/gcc -shared -fPIC -o "$out/lib/libcairo-v8-stub.so" cairo-v8-stub.c \
            -Wl,--no-as-needed \
            -Wl,-rpath,${cairo}/lib -Wl,-rpath,${fontconfig.lib}/lib \
            -Wl,-rpath,${freetype}/lib -Wl,-rpath,${harfbuzz}/lib \
            ${cairo}/lib/libcairo.so.2 \
            ${fontconfig.lib}/lib/libfontconfig.so.1 \
            ${freetype}/lib/libfreetype.so.6 \
            ${harfbuzz}/lib/libharfbuzz.so.0

          sed -e "s|@HARFBUZZ@|${harfbuzz}/lib/libharfbuzz.so.0|" \
              -e "s|@CAIRO@|${cairo}/lib/libcairo.so.2|" \
              -e "s|@FONTCONFIG@|${fontconfig.lib}/lib/libfontconfig.so.1|" \
              -e "s|@FREETYPE@|${freetype}/lib/libfreetype.so.6|" \
              -e "s|@CAIROV8@|$out/lib/libcairo-v8-stub.so|" \
              dlopen-remap.c > dlopen-remap-real.c
          ${gcc}/bin/gcc -O2 -shared -fPIC -o "$out/lib/dlopen-remap.so" dlopen-remap-real.c -ldl
        ''}

        mkdir -p "$out/bin"
        for b in ragent rmngr rphost rac ras ibsrv ibcmd webinst dbeng8 1cv8 1cv8c thinclient ibcmd; do
          if [ -e "$dest/$b" ]; then
            ln -sf "$dest/$b" "$out/bin/$b"
          fi
        done

        ${lib.optionalString (webinstConfigPath != null) ''
          # В NixOS основной httpd.conf — симлинк в /nix/store. Конфигуратор
          # запускает webinst и передаёт ему этот неизменяемый файл, а webinst
          # затем пытается переписать его целиком. Подменяем только путь
          # конфигурации: изменяемые публикации остаются в /var/lib, который
          # подключён Apache через IncludeOptional (см. module.nix).
          #
          # Сам webinst при первой публикации добавляет LoadModule
          # _1cws_module. Модуль уже загружен декларативно, поэтому вырезаем
          # эту строку после успешного вызова, иначе Apache откажется
          # перезагружаться из-за повторной загрузки DSO.
          if [ -e "$out/bin/webinst" ]; then
            mkdir -p "$out/libexec"
            mv "$out/bin/webinst" "$out/libexec/webinst-real"
            cat > "$out/bin/webinst" <<'EOF'
          #!${stdenv.shell}
          set -u

          webinst_args=()
          while [ "$#" -gt 0 ]; do
            case "$1" in
              -confPath|-confpath)
                shift
                if [ "$#" -gt 0 ]; then
                  shift
                fi
                ;;
              *)
                webinst_args+=("$1")
                shift
                ;;
            esac
          done

          @webinst-real@ "''${webinst_args[@]}" -confPath ${lib.escapeShellArg (toString webinstConfigPath)}
          result=$?
          if [ "$result" -eq 0 ] && [ -e ${lib.escapeShellArg (toString webinstConfigPath)} ]; then
            ${gnused}/bin/sed -i '\|^LoadModule _1cws_module |d' ${lib.escapeShellArg (toString webinstConfigPath)}
          fi
          exit "$result"
          EOF
            substituteInPlace "$out/bin/webinst" \
              --replace-fail @webinst-real@ "$out/libexec/webinst-real"
            chmod +x "$out/bin/webinst"
          fi
        ''}

        ${lib.optionalString isClient ''
                  # desktop_icons пишет .desktop-файлы и иконки вне песочницы;
                  # внутри `nix build` этот шаг — тихий no-op (нужен D-Bus/systemd),
                  # поэтому переиспользуем файлы, если есть, иначе — запасной путь ниже.
                  mkdir -p "$out/share/applications"
                  if [ -d "$workroot/usr/share/applications" ]; then
                    mkdir -p "$out/share/icons"
                    keep=""
                    for f in "$workroot"/usr/share/applications/*.desktop; do
                      base="$(basename "$f" .desktop)"
                      bin="$(sed -n 's|^Exec=/opt/1cv8/x86_64/[^/]*/||p' "$f" | head -n1)"
                      # Только бинарники, реально попавшие в $out/bin.
                      if [ -z "$bin" ] || [ ! -e "$out/bin/$bin" ]; then
                        continue
                      fi
                      sed "s|^Exec=.*|Exec=$out/bin/$bin|" "$f" > "$out/share/applications/$base.desktop"
                      keep="$keep $base"
                    done
                    # Иконки — только для оставленных .desktop-файлов.
                    find "$workroot/usr/share/icons" -type f | while read -r iconFile; do
                      iconBase="$(basename "$iconFile")"
                      iconBase="''${iconBase%.*}"
                      case " $keep " in
                        *" $iconBase "*)
                          rel="''${iconFile#"$workroot"/usr/share/icons/}"
                          mkdir -p "$out/share/icons/$(dirname "$rel")"
                          cp "$iconFile" "$out/share/icons/$rel"
                          ;;
                      esac
                    done
                  fi
                  # Графика для запасного пути: инсталлятор хранит логотип
                  # как сырые PNG-байты внутри setup-full-*.run — вытаскиваем
                  # первый попавшийся 512×512 PNG по сигнатуре.
                  #
                  # Один PNG на оба .desktop: официальный 1cestart-*.desktop
                  # из штатной установки тоже ссылается одной и той же
                  # Icon= на обоих режимах клиента.
                  cat > extract-icon.c <<'EOF'
          #include <stdio.h>
          #include <stdlib.h>
          #include <string.h>
          #include <stdint.h>

          static const unsigned char PNG_SIG[8] = { 0x89,'P','N','G','\r','\n',0x1a,'\n' };
          static const unsigned char IEND_TAIL[12] = { 0,0,0,0,'I','E','N','D',0xae,0x42,0x60,0x82 };

          int main(int argc, char **argv) {
            if (argc != 4) { fprintf(stderr, "usage: %s <input> <output> <size>\n", argv[0]); return 2; }
            long want = atol(argv[3]);
            FILE *f = fopen(argv[1], "rb");
            if (!f) { perror("fopen"); return 1; }
            fseek(f, 0, SEEK_END);
            long sz = ftell(f);
            fseek(f, 0, SEEK_SET);
            unsigned char *buf = malloc(sz);
            if (!buf || fread(buf, 1, sz, f) != (size_t) sz) { fprintf(stderr, "read failed\n"); return 1; }
            fclose(f);

            for (long i = 0; i + 24 <= sz; i++) {
              unsigned char *hit = memchr(buf + i, PNG_SIG[0], sz - i - 24 + 1);
              if (!hit) break;
              i = hit - buf;
              if (memcmp(buf + i, PNG_SIG, 8) != 0) continue;
              uint32_t w = (buf[i+16]<<24)|(buf[i+17]<<16)|(buf[i+18]<<8)|buf[i+19];
              uint32_t h = (buf[i+20]<<24)|(buf[i+21]<<16)|(buf[i+22]<<8)|buf[i+23];
              if (w != (uint32_t) want || h != (uint32_t) want) continue;
              for (long j = i; j + 12 <= sz; j++) {
                if (memcmp(buf + j, IEND_TAIL, 12) == 0) {
                  FILE *out = fopen(argv[2], "wb");
                  if (!out) { perror("fopen out"); return 1; }
                  fwrite(buf + i, 1, j + 12 - i, out);
                  fclose(out);
                  return 0;
                }
              }
            }
            fprintf(stderr, "no %ldx%ld PNG found\n", want, want);
            return 1;
          }
          EOF
                  ${gcc}/bin/gcc -O2 -o extract-icon extract-icon.c
                  iconName="1c-enterprise"
                  if ./extract-icon "$installer" onec-icon.png 512; then
                    mkdir -p "$out/share/icons/hicolor/512x512/apps"
                    cp onec-icon.png "$out/share/icons/hicolor/512x512/apps/$iconName.png"
                  else
                    echo "предупреждение: не удалось извлечь иконку 1С из дистрибутива, .desktop-файлы будут без Icon=" >&2
                    iconName=""
                  fi

                  if [ -e "$out/bin/1cv8" ] && [ -z "$(find "$out/share/applications" -iname '1cv8-*.desktop' 2>/dev/null)" ]; then
                    cat > "$out/share/applications/1cv8.desktop" <<DESKTOP
          [Desktop Entry]
          Type=Application
          Version=1.0
          Terminal=false
          Categories=Office;Finance;
          Name=1C:Enterprise (${version}) — толстый клиент
          Name[en]=1C:Enterprise (${version}) — thick client
          Comment=Запуск в режиме 1С:Предприятия
          Comment[en]=Run in 1C:Enterprise mode
          Exec=$out/bin/1cv8
          ''${iconName:+Icon=$iconName}
          DESKTOP
                  fi
                  if [ -e "$out/bin/1cv8c" ] && [ -z "$(find "$out/share/applications" -iname '1cv8c-*.desktop' 2>/dev/null)" ]; then
                    cat > "$out/share/applications/1cv8c.desktop" <<DESKTOP
          [Desktop Entry]
          Type=Application
          Version=1.0
          Terminal=false
          Categories=Office;Finance;
          Name=1C:Enterprise (${version}) — тонкий клиент
          Name[en]=1C:Enterprise (${version}) — thin client
          Comment=Запуск в режиме 1С:Предприятия
          Comment[en]=Run in 1C:Enterprise mode
          Exec=$out/bin/1cv8c
          ''${iconName:+Icon=$iconName}
          DESKTOP
                  fi
        ''}

        runHook postInstall
      '';

      # libwx_gtk3u-3.0.so.0 жёстко NEEDED на старую ветку webkitgtk 4.0,
      # вырезанную из nixpkgs как EOL (подсовывать системную нельзя — две
      # копии glib/gobject в процессе дают SIGSEGV). Вырезаем эту
      # NEEDED-запись патчелфом: символ не используется, т.к. 1С работает
      # через современный .wk41-путь.
      postFixup = lib.optionalString isClient ''
        target="$out"/opt/1cv8/x86_64/${version}/libwx_gtk3u-3.0.so.0.1.0
        if [ -e "$target" ]; then
          patchelf \
            --remove-needed libwebkit2gtk-4.0.so.37 \
            --remove-needed libjavascriptcoregtk-4.0.so.18 \
            --remove-needed libsoup-2.4.so.1 \
            "$target"
        fi
      '';

      preFixup = lib.optionalString isClient ''
        # Толстый клиент безусловно пытается получить EGL под Wayland и
        # падает ещё до создания окна; GDK_BACKEND=x11 одного недостаточно.
        gappsWrapperArgs+=("--unset" "WAYLAND_DISPLAY")
        gappsWrapperArgs+=("--set" "GDK_BACKEND" "x11")
        # Та же EGL-проблема отдельно у DMA-BUF рендерера embedded WebKitGTK
        # (управляемые формы) — без этого флага виджеты остаются пустыми.
        gappsWrapperArgs+=("--set" "WEBKIT_DISABLE_DMABUF_RENDERER" "1")
        gappsWrapperArgs+=("--prefix" "LD_LIBRARY_PATH" ":" "${harfbuzz}/lib")
        # Перенаправляет dlopen() системных графических библиотек на nix-версии,
        # см. installPhase.
        gappsWrapperArgs+=("--prefix" "LD_PRELOAD" ":" "$out/lib/dlopen-remap.so")
        # nix-glibc не содержит скомпилированных локалей — без LOCALE_ARCHIVE
        # setlocale() откатывается на "C". LANG не переопределяем: язык
        # интерфейса 1С зависит от установленных компонентов, а не от LANG.
        gappsWrapperArgs+=("--set" "LOCALE_ARCHIVE" "${glibcLocales}/lib/locale/locale-archive")
      '';

      # Внешние инструменты (в первую очередь 1C:EDT) ищут платформу по
      # штатному пути /opt/1cv8/x86_64/<версия> и запускают бинарники прямо
      # оттуда, мимо обёрток из bin/ — а голый 1cv8/1cv8c без GTK-окружения
      # и dlopen-remap падает по SIGSEGV. optTree — дерево симлинков на
      # каталог версии, в котором исполняемые файлы подменены обёртками;
      # именно его NixOS-модуль публикует в /opt (services.onec.client.linkToOpt).
      passthru.optTree = runCommand "${pname}-opt-${version}" { } ''
        mkdir -p "$out"
        cp -as "${finalAttrs.finalPackage}/opt/1cv8/x86_64/${version}/." "$out/"
        find "$out" -type d -exec chmod u+w {} +
        for w in "${finalAttrs.finalPackage}"/bin/*; do
          name="$(basename "$w")"
          if [ -e "$out/$name" ]; then
            ln -sf "$w" "$out/$name"
          fi
        done
      '';

      meta = {
        homepage = "https://1c.ru";
        license = lib.licenses.unfree;
        platforms = [ "x86_64-linux" ];
        sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
      }
      // meta;
    });
in
mkOnec
