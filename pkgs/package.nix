{ lib
, stdenv
, autoPatchelfHook
, wrapGAppsHook3
, bubblewrap
, unzip
, glibc
, krb5
, keyutils
, e2fsprogs
, glib
, gdk-pixbuf
, cairo
, pango
, atk
, gtk3
, cups
, libGL
, libGLU
, libxxf86vm
  , webkitgtk_4_1
  , wayland
  , libxkbcommon
  , harfbuzz
  , fontconfig
  , freetype
  , patchelf
  , gcc
  , glibcLocales
}:

# Генератор пакетов 1С:Предприятие 8.3 из фирменного дистрибутива —
# zip-архива, скачанного с портала 1С (например server64_8_3_27_2130.zip).
# Внутри такого архива лежит самораспаковывающийся инсталлятор
# (setup-full-*.run, InstallBuilder) — Nix сам находит его внутри архива,
# распаковывает и устанавливает нужные компоненты.
#
# Сам архив — единственный обязательный аргумент (archiveFile). Список и
# набор допустимых компонентов не хранится в этом файле как константа: он
# считывается прямо из инсталлятора командой `setup.run --help` во время
# сборки, так что при обновлении дистрибутива ничего в Nix-выражении
# менять не нужно, если только 1С не переименует сами компоненты.
#
# Инсталлятор — бинарник InstallBuilder, который жёстко требует
# geteuid() == 0, всегда пишет служебный файл в /usr/local/bin в обход
# --prefix и запускается через интерпретатор /lib64/ld-linux-x86-64.so.2
# (обычный не-NixOS ELF). Ничего этого в песочнице `nix build` нет, и
# настоящий root не нужен: непривилегированный user namespace даёт ровно
# то, что требует проверка geteuid(), а недостающий кусок FHS собирается
# рядом, в отдельном пространстве монтирования.
#
# Раньше здесь хватало `unshare --user --map-root-user` плюс `mkdir -p
# /lib64 /usr/local/bin` прямо в корне песочницы. С Nix 2.34 так больше
# нельзя: корень песочницы принадлежит немаппящемуся наружу uid и имеет
# режим 0750, поэтому процесс сборки в него писать не может (root внутри
# user namespace тут не помогает — capabilities действуют только на
# маппленные uid). Поэтому FHS строится в собственном корне-tmpfs через
# bubblewrap: загрузчик glibc подставляется симлинком по нужному пути,
# /usr/local/bin создаётся как обычный каталог, а рабочий каталог сборки
# пробрасывается bind-mount'ом внутрь. Реальных привилегий процесс
# по-прежнему не получает, наружу это никак не просачивается — сборка
# остаётся обычной, воспроизводимой, в песочнице.
let
mkOnec =
  { archiveFile # строка — абсолютный путь к дистрибутиву-архиву (.zip)
  , components
  , language ? "ru"
  , version
  , pname
  , meta ? { }
  }:
  let
    isClient = lib.any (c: lib.hasPrefix "client_" c) components;

    # desktop_icons — штатный компонент инсталлятора: даёт готовые
    # .desktop-файлы и иконки (usr/share/applications,
    # usr/share/icons/hicolor) для клиентских бинарников, см. installPhase
    # ниже. Смысла делать его настраиваемым нет — подключаем всегда вместе
    # с любым client_*, если вызывающий ещё не указал его сам.
    desktopIconsComponent = lib.optional (isClient && !(lib.elem "desktop_icons" components)) "desktop_icons";
    allComponents = components ++ desktopIconsComponent;
  in
  stdenv.mkDerivation {
    inherit pname version;

    # toString+конкатенация вместо прямого пути-литерала: если абсолютный
    # путь (например, к самому этому файлу) содержит нелатинские символы
    # в имени каталога, парсер Nix ошибается на "path has a trailing
    # slash" при попытке разобрать его как обычный /foo/bar литерал.
    # Через toString + "/." эта граница лексера не участвует.
    src = /. + toString archiveFile;
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;

    # wrapGAppsHook3 (только для клиента) оборачивает бинарники в $out/bin
    # переменными окружения (GTK_PATH, GDK_PIXBUF_MODULE_FILE,
    # GIO_EXTRA_MODULES, XDG_DATA_DIRS и т.п.), которые указывают строго
    # внутрь замыкания пакета. Без этого процесс наследует те же
    # переменные из окружения ЗАПУСКА и подмешивает GTK/шрифтовые модули
    # хоста поверх модулей из nixpkgs — например, так одновременно
    # загружаются ДВЕ разные libharfbuzz.so.0 (nix'овая и хостовая) и
    # процесс падает по SIGSEGV прямо в рендеринге текста, что и
    # воспроизводилось до этого фикса.
    nativeBuildInputs = [ autoPatchelfHook bubblewrap patchelf unzip ]
      ++ lib.optionals isClient [ wrapGAppsHook3 gcc ];

    # GTK/WebKit-стек нужен только клиентским компонентам (client_thin,
    # client_full) — их GUI (mmui.so, uiproxywx.so, встроенный HTML/WebKit
    # движок и т.п.). Серверным сборкам (ragent/rmngr/rphost/ras/rac) он
    # не требуется вовсе, поэтому подключаем его только когда среди
    # выбранных компонентов реально есть клиент — иначе он просто
    # раздувает замыкание пакета впустую.
    buildInputs = [ glibc krb5 keyutils e2fsprogs ]
      ++ lib.optionals isClient [
        glib gdk-pixbuf cairo pango atk gtk3 cups libGL libGLU libxxf86vm
        webkitgtk_4_1
        wayland libxkbcommon
        harfbuzz fontconfig freetype
        glibcLocales
        # nixpkgs-unstable собирает webkitgtk современным gcc с более
        # новым libstdc++, чем тот, что несёт с собой 1С (см. ниже —
        # бандловский libstdc++.so.6/libgcc_s.so.1 для клиента удаляются
        # из дерева, чтобы все .so цепляли ровно эту, единую версию).
        stdenv.cc.cc.lib
      ];

    # Опциональные dlopen-плагины (внешние СУБД и т.п.), не нужные для
    # базовой работы и намеренно не включаемые в замыкание пакета. Плюс
    # (для клиентских компонентов) — устаревшая ветка webkitgtk 4.0 /
    # libsoup 2.4: 1С носит webkit2_extu-3.0.so под неё как fallback для
    # старых систем наряду с современным webkit2_extu-3.0.so.wk41 (webkit
    # 4.1, уже удовлетворён выше). webkitgtk_4_0/libsoup_2_4 в актуальном
    # nixpkgs удалены как EOL/небезопасные — используется исключительно
    # современный .wk41-путь, легаси намеренно не собирается.
    autoPatchelfIgnoreMissingDeps = [
      "libodbc.so.2"
      "libpq.so.5"
      "libmysqlclient.so.21"
    ] ++ lib.optionals isClient [
      "libwebkit2gtk-4.0.so.37"
      "libjavascriptcoregtk-4.0.so.18"
      "libsoup-2.4.so.1"
    ];

    # core83.so и другие .so загружают libharfbuzz.so.0 через dlopen().
    # На хосте за пределами NixOS dlopen находит системный harfbuzz —
    # мгновенный SIGSEGV из-за несовместимости двух копий (hb_buffer
    # создан одной, уничтожен другой). Причина, по которой LD_LIBRARY_PATH
    # не помогает: dlopen вызывается из .so с DT_RUNPATH, а по glibc при
    # DT_RUNPATH LD_LIBRARY_PATH не просматривается — ищется только
    # DT_RUNPATH вызывающего объекта → ld.so.cache → /lib, /usr/lib.
    #
    # appendRunpaths пробрасывается в auto-patchelf --append-rpaths:
    # утилита добавляет путь к nix'овому harfbuzz в DT_RUNPATH каждого
    # .so файла, не перезаписывая вычисленные ей самой пути. Это самый
    # надёжный способ: хук auto-patchelf работает в postFixupHooks
    # (ПОСЛЕ нашего postFixup), поэтому никакой затирания не происходит.
    # appendRunpaths идёт в auto-patchelf --append-rpaths и дописывается
    # в DT_RUNPATH каждого литерально присутствующего в пакете .so. Список
    # НЕ ограничивается harfbuzz: bundled libwx_gtk3u-3.0.so.0 1С напрямую
    # NEEDED на libcairo.so.2, а nix-cairo тянет (уже как NEEDED) nix
    # libfontconfig и nix libfreetype. Если эти пути не лежат в RUNPATH
    # того самого libwx_gtk3u, динамический загрузчик резолвит cairo из
    # ld.so.conf хоста (/lib/x86_64-linux-gnu/libcairo.so.2), а уже тот
    # cairo затаскивает системный fontconfig+harfbuzz — и в процессе снова
    # оказываются ДВЕ libharfbuzz.so.0. Поэтому подсовываем полный текст
    # всей системной зависимости: cairo+fontconfig+freetype (через них же
    # и системный harfbuzz приходит), поверх того, что уже собирали из run
    # самого пакета.
    # fontconfig.lib, а НЕ fontconfig: у fontconfig в nixpkgs дефолтный
    # выход — "bin" (в нём только bin/ и share/, каталога lib нет вовсе),
    # так что "${fontconfig}/lib" — несуществующий путь. В RUNPATH он
    # просто молча игнорируется, а вот в dlopen-шиме ниже такой путь
    # означал бы dlopen() == NULL (см. там же).
    appendRunpaths = lib.optionals isClient (map (p: "${p}/lib") [
      harfbuzz cairo fontconfig.lib freetype
    ]);

    installPhase = ''
      runHook preInstall

      # Дистрибутив 1С скачивается с портала как zip-архив (например
      # server64_8_3_27_2130.zip), а не голым .run — распаковываем его
      # сами и ищем внутри фирменный самораспаковывающийся инсталлятор.
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

      # Сам инсталлятор — обычный не-NixOS ELF с интерпретатором
      # /lib64/ld-linux-x86-64.so.2, которого в песочнице сборки нет (в
      # отличие от обычного FHS-хоста). Патчить сам .run нельзя — он сам
      # распаковывает и запускает вложенные бинарники с тем же
      # интерпретатором. Поэтому весь недостающий FHS собирается в
      # отдельном корне-tmpfs через bubblewrap (см. комментарий в шапке
      # файла): загрузчик glibc по нужному пути, писабельный /usr/local/bin
      # и uid 0 для проверки geteuid() внутри инсталлятора.
      #
      # TMPDIR намеренно уводится в проброшенный каталог сборки, а не в
      # /tmp: /tmp внутри bubblewrap — это tmpfs в оперативной памяти, а
      # InstallBuilder распаковывает туда весь дистрибутив (гигабайты).
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

      # Достаём из --help актуальный на момент сборки список всех
      # допустимых компонентов (строка "Разрешено: ..." сразу после
      # описания --enable-components).
      # Список компонентов достаём через --installer-language en: без
      # заданной в песочнице локали кириллица в выводе инсталлятора
      # превращается в "?????" (нечитаемо для awk), а англ. текст — чистый
      # ASCII и не зависит от локали. На выбранный пользователем язык
      # самой установки (см. ниже) это никак не влияет.
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

      # Мусор инсталлятора, оставшийся после установки и не нужный для
      # работы ни одного бинарника (проверено grep'ом по всему дереву —
      # ни один .so/бинарник на эти файлы не ссылается): сам деинсталлятор
      # и его файл данных, многоязычная HTML-читалка инсталлятора.
      rm -f "$dest"/uninstaller-full "$dest"/uninstallAsRoot "$dest"/uninstaller-full.dat
      rm -f "$dest"/readme.htm
      rm -rf "$dest"/readme

      # conf/conf.cfg — служебный файл штатной утилиты обновлений
      # (v8update), которую этот пакет не использует. Хуже того: он
      # буквально прописывает внутрь себя путь временной песочницы
      # сборки (ConfLocation=/build/install-root/opt/1cv8/conf) — путь,
      # которого после сборки уже не существует. Оставлять такой файл в
      # $out бессмысленно и вводит в заблуждение. (Ключ SystemLanguage
      # в этом файле проверялся отдельно как гипотетический способ
      # задать язык интерфейса лаунчера — экспериментально опровергнуто:
      # значение конфига не влияет на выбор языка вообще, в любую
      # сторону; язык интерфейса целиком определяется тем, какие
      # языковые компоненты установлены — см. module.nix.)
      rm -rf "$dest"/conf

      # Штатные systemd-юниты (srv1cv8-*.service, ras-*.service) из
      # дистрибутива прописывают FHS-пути (/opt/1cv8/..., /home/usr1cv8)
      # — нерабочие в Nix store и никогда не подключаются systemd'ом
      # напрямую из этого дерева. Модуль NixOS генерирует свои юниты с
      # правильными путями (см. module.nix) — эти шаблоны только
      # засоряют пакет и могут ввести в заблуждение.
      rm -f "$dest"/srv1cv8-*.service "$dest"/ras-*.service

      # Документацию и лицензии — в $out/share/doc, а не вперемешку с
      # бинарниками/библиотеками: они не участвуют в работе 1С (никакой
      # .so их не ищет рядом с собой), а share/doc — общепринятое в Nix
      # место для такого рода файлов.
      docDir="$out/share/doc/${pname}"
      mkdir -p "$docDir"
      for d in docs licenses; do
        if [ -d "$dest/$d" ]; then
          mv "$dest/$d" "$docDir/$d"
        fi
      done

      ${lib.optionalString isClient ''
        # Свой bundled libstdc++/libgcc_s у 1С собран старым тулчейном и
        # не даёт символьных версий (GLIBCXX_3.4.30 и т.п.), которые
        # требует webkitgtk из современного nixpkgs. RUNPATH=$ORIGIN
        # заставил бы динлинкер загрузить именно старую копию первой и
        # закрепить её на весь процесс (SONAME один и тот же для всех
        # потребителей) — удаляем её, чтобы autoPatchelf прописал везде
        # единую современную версию из stdenv.cc.cc.lib. Она полностью
        # обратно совместима с тем, что нужно самим бинарникам 1С.
        rm -f "$dest"/libstdc++.so.6 "$dest"/libgcc_s.so.1

        # core83/grphcs/frame загружают libharfbuzz.so.0 через dlopen().
        # Если dlopen найдёт системную копию (при DT_RUNPATH вызывающего
        # .so обход LD_LIBRARY_PATH идёт мимо) — в процессе появляются
        # ДВЕ разные libharfbuzz и SIGSEGV на hb_buffer_destroy.
        # Принудительно линкуем НАШУ (nix) копию harfbuzz в главный
        # бинарник 1cv8c: она загружается самой первой в глобальный
        # scope, и любой последующий dlopen("libharfbuzz.so.0") вернёт
        # уже загруженный handle, не открывая системную копию.
        patchelf --add-needed libharfbuzz.so.0 "$dest/1cv8c" || true

        # Полный (толстый) клиент 1cv8 — в отличие от тонкого — реально
        # использует встроенный WebKit-виджет: libwx_gtk3u-3.0.so.0
        # вызывает webkit_web_context_new и т.п. при старте GUI. Поставка
        # несёт две версии libwx: .0.1.0 (для webkit2gtk 4.0 / libsoup2,
        # вырезанной из nixpkgs как EOL) и .0.1.0.wk41 (для webkit2gtk
        # 4.1, которую nixpkgs собирает). default-симлинк ведёт на 4.0 и
        # без неё падает 'symbol lookup error'. Перенаправляем на .wk41,
        # который autoPatchelfHook уже привязал к webkitgtk_4_1 из пакета.
        if [ -e "$dest/libwx_gtk3u-3.0.so.0" ]; then
          rm -f "$dest/libwx_gtk3u-3.0.so.0"
          ln -s libwx_gtk3u-3.0.so.0.1.0.wk41 "$dest/libwx_gtk3u-3.0.so.0"
        fi
      ''}

      ${lib.optionalString isClient ''
        # сборка shim'а-перехватчика dlopen
        mkdir -p "$out/lib"
        cat > dlopen-remap.c <<'EOF'
        #include <dlfcn.h>
        #include <string.h>

        /* 1С в core83/grphcs интегрёт жёстко абсолютные пути
           /lib/x86_64-linux-gnu/lib{harfbuzz,cairo,fontconfig,freetype}.so
           через dlopen(). LD_LIBRARY_PATH и DT_RUNPATH на такие вызовы не
           влияют (абсолютный путь не проходит поиск). Подменяем их на nix
           копии. */
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
            /* grphcs.so догружает через dlopen СВОЙ бандловый
               libcairo-v8.so (без SONAME, никем не NEEDED) в глобальное
               пространство имён — при том, что gtk3/wx/webkit к этому
               моменту уже притащили nix'овый libcairo.so.2. Две разные
               реализации cairo в одном процессе экспортируют одни и те же
               cairo_*, и это фатально: cairo_t создаёт GTK (nix cairo,
               см. wxWindow::GTKSendPaintEvents), а рисует в него код 1С
               через бандловую копию с другим layout структур -> SIGSEGV
               в pixman на первой же отрисовке окна (стек: grphcs ->
               cairo_mask@libcairo-v8 -> _cairo_gstate_mask@libcairo.so.2
               -> pixman). RTLD_DEEPBIND тут НЕ решение: состояние всё
               равно делится между копиями, SIGSEGV лишь сменяется на
               "free(): invalid size".

               При этом libcairo-v8.so — не только cairo: в него слинкованы
               ещё fontconfig, freetype, harfbuzz, pixman, libpng и zlib, и
               grphcs.so достаёт оттуда через dlsym все четыре семейства
               (146 cairo_*, 28 Fc*, 23 FT_*, 17 hb_*). Поэтому отдать
               голый libcairo.so.2 нельзя — Fc*/FT_*/hb_* тогда
               резолвятся в NULL, 1С остаётся без подбора шрифтов и без
               загрузки глифов: окно рисуется вообще без текста, а метрики
               шрифта приходят нулевыми, и клиент падает по SIGFPE, деля
               на такую метрику. Отдаём заглушку, у которой все четыре
               nix-библиотеки прописаны в DT_NEEDED: dlsym() по handle
               ищет символы и в зависимостях объекта, так что находится
               всё сразу, а реализация cairo в процессе остаётся одна. */
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
        # Заглушка вместо бандлового libcairo-v8.so (см. подробный
        # комментарий в dlopen-remap.c выше). Своего кода в ней нет вовсе —
        # нужна ровно одна вещь: чтобы в DT_NEEDED лежали все четыре
        # nix-библиотеки, которые 1С ожидает найти в libcairo-v8.so.
        # --no-as-needed обязателен: без него линкер выкинет все четыре
        # зависимости, поскольку сама заглушка не использует из них ни
        # одного символа, и dlsym() по её handle не найдёт ничего.
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

      ${lib.optionalString isClient ''
        # Компонент desktop_icons (включён выше в allComponents) в
        # обычной, не-песочной установке пишет готовые .desktop-файлы и
        # полный набор иконок (usr/share/icons/hicolor/*, включая
        # scalable/*.svg) в $workroot/usr/share — при их наличии
        # переиспользуем их вместо ручной разметки. Внутри строгой
        # песочницы `nix build` этот конкретный пост-install шаг
        # инсталлятора эмпирически оказывается тихим no-op (ничего не
        # пишет и не жалуется на это) — судя по всему, часть его логики
        # (там же лежит и polkit-action для pk1cv8) рассчитывает на D-Bus/
        # systemd, которых в песочнице попросту нет. Поэтому ниже —
        # запасной путь: свой минимальный .desktop без иконки, чтобы
        # GUI-клиент в любом случае был виден в меню приложений.
        mkdir -p "$out/share/applications"
        if [ -d "$workroot/usr/share/applications" ]; then
          mkdir -p "$out/share/icons"
          keep=""
          for f in "$workroot"/usr/share/applications/*.desktop; do
            base="$(basename "$f" .desktop)"
            bin="$(sed -n 's|^Exec=/opt/1cv8/x86_64/[^/]*/||p' "$f" | head -n1)"
            # Только бинарники, реально попавшие в $out/bin: у
            # деинсталлятора (uninstallAsRoot) он уже удалён выше как
            # мусор, а у бинарников, не входящих в эту сборку (например
            # 1cv8 у тонкого клиента) — просто отсутствует.
            if [ -z "$bin" ] || [ ! -e "$out/bin/$bin" ]; then
              continue
            fi
            sed "s|^Exec=.*|Exec=$out/bin/$bin|" "$f" > "$out/share/applications/$base.desktop"
            keep="$keep $base"
          done
          # Иконки — только для оставленных .desktop-файлов (та же логика
          # фильтрации), иначе в замыкание пакета тянутся никем не
          # используемые иконки деинсталлятора/pk1cv8/отфильтрованных
          # бинарников.
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
DESKTOP
        fi
      ''}

      runHook postInstall
    '';

    # Толстый клиент тянет через uiproxywx.so -> libwx_gtk3u-3.0.so.0 ->
    # libwebkit2gtk-4.0.so.37 старую (4.0/libsoup2) ветку webkitgtk ЖЁСТКО,
    # не лениво: это прямая NEEDED-цепочка, процесс не стартует вообще без
    # неё, в отличие от опционального .wk41-плагина. nixpkgs эту ветку
    # убрал целиком как EOL — а даже если подсунуть системную (пробовали,
    # через LD_LIBRARY_PATH на хостовые /usr/lib и /lib): процесс тут же
    # падает с SIGSEGV прямо внутри ld-linux, ещё до main(). Причина —
    # у хостового webkitgtk 4.0 своя копия glib/gobject, а у уже
    # загруженного современного webkitgtk_4.1 из nixpkgs — своя; GLib не
    # рассчитан на два экземпляра в одном процессе (глобальные реестры
    # GType и т.п.), так что даже "рабочая" на вид легаси-ветка ломает всё
    # приложение целиком.
    #
    # Правильный выход — не пытаться удовлетворить эту NEEDED-запись
    # вообще, а вырезать её из libwx_gtk3u-3.0.so.0 патчелфом. Загрузка
    # символов из shared-библиотек в ELF ленивая (PLT), поэтому это не
    # трогает остальной функционал wx — незагруженный символ выстрелит
    # только если реально дернуть встроенный в wxWidgets webkit-виджет,
    # которым 1С, судя по всему, не пользуется (у него для HTML/форм есть
    # современный путь через .wk41, полностью покрытый из nixpkgs выше).
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
      # Толстый клиент (1cv8, с Конфигуратором — в отличие от тонкого
      # 1cv8c) инициализирует EGL для своего 3D/чартового рендера сам,
      # в обход GDK_BACKEND: если в окружении есть WAYLAND_DISPLAY, он
      # безусловно пытается получить EGL-дисплей под Wayland и падает в
      # цикл "Could not create default EGL display: EGL_BAD_PARAMETER"
      # ещё до создания окна — воспроизведено эмпирически на реальном
      # Wayland-сеансе (KDE/Wayland, mesa из nixpkgs через libglvnd).
      # GDK_BACKEND=x11 сам по себе не спасает — эта проверка внутри 1С
      # смотрит только на WAYLAND_DISPLAY, а не на выбор GTK-бэкенда.
      # Гасим переменную безусловно для всех клиентских бинарников:
      # тонкий клиент (1cv8c) при этом просто уходит на XWayland —
      # исправно работает, но без нативной Wayland-интеграции.
      gappsWrapperArgs+=("--unset" "WAYLAND_DISPLAY")
      gappsWrapperArgs+=("--set" "GDK_BACKEND" "x11")
      # Управляемые формы (в т.ч. виджеты вроде календаря/планировщика в
      # решениях на 1С) рендерятся embedded WebKitGTK. У её DMA-BUF
      # рендерера (аппаратное композитинг-ускорение) — тот же класс
      # проблемы, что и у EGL-инициализации самой платформы выше, но
      # это отдельный, независимый потребитель EGL внутри
      # libwebkit2gtk-*.so (подтверждено grep'ом по загруженным в
      # процесс библиотекам: именно в ней лежит строка "Could not
      # create default EGL display"), и одного unset WAYLAND_DISPLAY
      # ему недостаточно — падает даже без Wayland-дисплея. Официальный
      # переключатель WebKitGTK для принудительного software-рендеринга
      # — WEBKIT_DISABLE_DMABUF_RENDERER; без него виджеты, использующие
      # аппаратный композитинг, остаются пустыми (сама форма при этом
      # не падает, просто не рисует конкретный виджет).
      gappsWrapperArgs+=("--set" "WEBKIT_DISABLE_DMABUF_RENDERER" "1")
      gappsWrapperArgs+=("--prefix" "LD_LIBRARY_PATH" ":" "${harfbuzz}/lib")
      # 1С грузит системные графические библиотеки абсолютными путями
      # /lib/x86_64-linux-gnu/lib{harfbuzz,cairo,fontconfig,freetype}.so.
      # Подставляем shim, который перенаправляет эти вызовы dlopen на
      # nix-версии — см. installPhase.
      gappsWrapperArgs+=("--prefix" "LD_PRELOAD" ":" "$out/lib/dlopen-remap.so")
      # nix-glibc не содержит скомпилированных локалей вообще (ни
      # ru_RU, ни en_US) — без LOCALE_ARCHIVE с полным набором из
      # glibcLocales setlocale() тихо откатывается на "C"/"POSIX", что
      # ломает локale-зависимое поведение glibc/ICU (формат чисел, дат,
      # сортировку). LANG/LANGUAGE намеренно не переопределяем — язык
      # ТЕКСТА интерфейса 1С определяется не ими, а тем, какие языковые
      # компоненты были установлены (services.onec.language в
      # module.nix), так что подставлять сюда конкретный LANG незачем.
      gappsWrapperArgs+=("--set" "LOCALE_ARCHIVE" "${glibcLocales}/lib/locale/locale-archive")
    '';

    meta = {
      homepage = "https://1c.ru";
      license = lib.licenses.unfree;
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    } // meta;
  };
in
mkOnec
