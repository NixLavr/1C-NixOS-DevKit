# 1С:Предприятие 8.3 — пакет для Nix/NixOS

Генератор Nix-пакетов и модуль NixOS для официального дистрибутива
1С:Предприятие 8.3 (сервер и клиент), а также сопутствующих компонентов:
среда разработки 1C:EDT, PostgreSQL для 1С и клиент 1C-Connect.

## Использование пакета напрямую

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  mkOnec = pkgs.callPackage ./package.nix { };
in
mkOnec {
  archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX/server64_8_3_XX_XXXX.zip"; # строка!
  components = [ "server" "server_admin" "ws" "ru" ];   # или [ "client_thin" "ru" ], [ "client_full" "ru" ]...
  language = "ru";
  version = "8.3.XX.XXXX";
  pname = "1c-enterprise-server";
}
```

У собранного пакета есть `passthru.optTree` — дерево симлинков на
`opt/1cv8/x86_64/<версия>`, в котором исполняемые файлы заменены
обёртками из `bin/` (для клиента это принципиально: голый `1cv8` без
GTK-окружения падает). Его кладут в `/opt/1cv8/x86_64/<версия>`, чтобы
платформу нашли внешние инструменты — в первую очередь 1C:EDT.
NixOS-модуль делает это сам, см. `client.linkToOpt`.

`archiveFile` — путь к скачанному с портала 1С zip-архиву дистрибутива,
указывается строкой (не path-литералом). Язык интерфейса (`"ru"` и т.п.)
нужно включить в список `components` — без него в сборку не попадут файлы
перевода. `module.nix` (см. ниже) делает это автоматически из
`services.onec.language`.

## Подключение флейка

```nix
{
  inputs.onec-devkit.url = "github:NixLavr/1C-NixOS-DevKit";

  outputs = { self, nixpkgs, onec-devkit, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        onec-devkit.nixosModules.default   # или .onec — тот же модуль
        { nixpkgs.config.allowUnfree = true; }
        {
          services.onec = {
            enable = true;
            archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX.zip";
            # ...
          };
        }
      ];
    };
  };
}
```

Для 1C:EDT модуля нет — это просто пакет
(`onec-devkit.packages.${system}.onec-edt`) или генератор
`onec-devkit.lib.${system}.mkOnecEdt` под свою версию дистрибутива;
готовый пример конфигурации — [Установка через flake](#установка-через-flake).
Для PostgreSQL 1С аналогично: `onec-devkit.nixosModules.postgresql_1c`,
генератор пакета — `onec-devkit.lib.${system}.mkPostgresql1c`, подробности —
[PostgreSQL 1С](#postgresql-1с). Пакет 1C-Connect (без модуля, просто
бинарник) — `onec-devkit.packages.${system}.onec-connect`, см.
[1C-Connect](#1c-connect). Без флейков модуль можно импортировать и
напрямую по пути (`imports = [ ./modules/module.nix ];`), если репозиторий
склонирован локально.

## NixOS-модуль

```nix
{
  imports = [ onec-devkit.nixosModules.default ];

  services.onec = {
    enable = true;
    archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX/server64_8_3_XX_XXXX.zip";
    language = "ru";

    client = {
      enable = true;                        # добавить клиент в PATH всем пользователям
      components = [ "client_thin" ];       # или [ "client_full" ]
    };

    server.instances."main" = {
      enable = true;

      programs.ibcmd.enable = true;         # ibcmd-8.3.XX.XXXX в PATH

      services.full-server = {              # кластер: ragent/rmngr/rphost
        enable = true;
        openFirewall = true;
      };

      services.ras.enable = true;           # rac/ras — консоль администрирования кластера

      services.standalone-server = {        # автономный сервер (ibsrv)
        enable = true;
        openFirewall = true;
        settings.name = "main";
      };
    };
  };
}
```

`services.onec.version` можно не указывать — выводится из имени файла в
`archiveFile`. `services.onec.client.enable` просто кладёт клиентский пакет
в `environment.systemPackages`, это не сервис.

Вместе с ним включается `services.onec.client.linkToOpt` (по умолчанию
`true`): клиент публикуется по штатному для 1С пути
`/opt/1cv8/x86_64/<версия>` симлинком через systemd-tmpfiles. Это нужно
1C:EDT — версии платформы он ищет, перебирая подкаталоги `/opt/1cv8/i386`
и `/opt/1cv8/x86_64` (раскладка единого дистрибутива, 8.3.18+) и
`/opt/1C/v8.3/<арх>` (старая, по одной версии), а саму версию берёт из
имени каталога. Публикуется не каталог пакета напрямую, а `optTree` (см.
[Использование пакета напрямую](#использование-пакета-напрямую)) — в нём
`1cv8`/`1cv8c` подменены обёртками, потому что голые
бинарники из `/nix/store` падают без GTK-окружения. EDT запускает из
этого каталога `1cv8`, `1cv8c`, `dbgs` и `rphost`, так что толстый клиент
(`components = [ "client_full" ]`) обязателен: в `client_thin` нет ни
`1cv8`, ни конфигуратора.

### Публикация веб-клиента из Конфигуратора

Для публикации через «Администрирование → Публикация на веб-сервере» включите
веб-интеграцию и толстый клиент:

```nix
services.onec = {
  enable = true;
  archiveFile = "/home/user/Downloads/server64_8_3_XX_XXXX.zip";

  client = {
    enable = true;
    components = [ "client_full" ];
  };

  web.enable = true;
};
```

`web.enable` сам добавляет компонент 1С `ws`, включает Apache 2.4 и загружает
`wsap24.so` из той же версии платформы. Для Конфигуратора создаются совместимые
пути Apache для RPM и Debian (`httpd`/`apachectl` и `apache2`/`apache2ctl`),
а также конфигурации `/etc/httpd/conf/httpd.conf` и
`/etc/apache2/apache2.conf`. Оба файла ведут на изменяемый
`/var/lib/1c-web/httpd.conf`, а Apache подключает совместимый путь. Поэтому
публикация работает как при вызове `webinst` из
`/opt/1cv8/x86_64/<версия>`, так и при прямой записи Конфигуратора. Файл
сохраняется после `nixos-rebuild`, а Apache автоматически проверяется и
перезагружается после изменения. Первая строка файла — `LoadModule
_1cws_module …/wsap24.so`; не удаляйте её: по ней Конфигуратор обнаруживает
веб-сервер.

Публикацию нужно выполнять с правами root — это требование самой 1С для Linux.
Запускать вручную `webinst` с `-confPath /etc/httpd/httpd.conf` не нужно и
нельзя: основной файл NixOS неизменяем. Обёртка из `/opt` сама направляет
запись в изменяемый файл публикаций. Для файловой ИБ дайте пользователю Apache
(`services.httpd.user`, обычно `wwwrun`) права на каталог базы; каталог
публикации, выбранный в Конфигураторе, также должен быть ему доступен.

### Инстансы сервера

Серверная часть построена вокруг `services.onec.server.instances` — набора
именованных инстансов. Ключ атрибута попадает в имена юнитов:

| Что включено | Юнит |
| --- | --- |
| `services.full-server` | `1c-server-<метка>.service` |
| `services.standalone-server` | `1c-standalone-server-<метка>.service` |
| `services.ras` | `1c-ras-<метка>.service` |

Все три независимы. Модуль заводит системного пользователя
`usr1cv8`/`grp1cv8` (настраивается через `services.onec.server.user` /
`.group` / `.home`) и готовит каталоги данных перед стартом сервиса.

Инстансы могут быть разных версий — у каждого свои `archiveFile` и
`version`, по умолчанию берутся общие:

```nix
services.onec.server.instances = {
  main = {
    enable = true;
    services.standalone-server.enable = true;
    services.standalone-server.settings.name = "main";
  };
  testing = {
    enable = true;
    archiveFile = "/home/user/Downloads/server64_8_3_YY_YYYY.zip"; # другая версия
    services.standalone-server = {
      enable = true;
      settings = {
        name = "test";
        http.port = 8315;
        direct-regport = 1542;
        direct-range = "1610:1641";
        debug-port = 1555;
        data = "/var/lib/1cv8-testing";
        extraArgs = [ "--disable-extended-designer-features" ];
      };
    };
  };
};
```

Полный набор настроек — в `modules/module.nix`.

## PostgreSQL 1С

`pkgs/postgresql-1c` — пакет PostgreSQL, собранный из фирменного архива 1С
для Ubuntu.

### Использование пакета напрямую

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  mkPostgresql1c = pkgs.callPackage ./pkgs/postgresql-1c { };
in
mkPostgresql1c {
  archiveFile = "/home/user/Downloads/postgresql_18.1-2.1C_ubuntu_x86_64_package.tar.bz2";
  version = "18.1-2.1C"; # необязательно, это значение по умолчанию
}
```

### NixOS-модуль

```nix
{
  imports = [ onec-devkit.nixosModules.postgresql_1c ];

  services.postgresql_1c = {
    enable = true;
    archiveFile = "/home/user/Downloads/postgresql_18.1-2.1C_ubuntu_x86_64_package.tar.bz2";
    ensureDatabases = [ "mydb" ];
    ensureUsers = [
      {
        name = "usr1cv8";
        ensureDBOwnership = true;
      }
    ];
  };
}
```

`services.postgresql_1c.enable` включает штатный `services.postgresql` с
пакетом, собранным из `archiveFile`. Опции вроде `dataDir`, `settings`,
`ensureDatabases`, `ensureUsers`, `authentication`, `extensions` — это
алиасы на одноимённые опции `services.postgresql.*`, работают так же, как
в штатном модуле nixpkgs. `addToSystemPackages` (по умолчанию `true`)
кладёт клиентские утилиты (`psql`, `pg_dump` и т.п.) в
`environment.systemPackages`.

## 1C:EDT

`pkgs/onec-edt.nix` — пакет
[1C:Enterprise Development Tools](https://edt.1c.ru) из фирменного
offline-дистрибутива для Linux. NixOS-модуля у него нет — это обычный
пакет в `environment.systemPackages`.

### Установка через flake

Шаг 1. Скачать offline-дистрибутив с [releases.1c.ru](https://releases.1c.ru)
и положить архив в стор — один раз, руками:

```console
$ nix store add-file --name 1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz \
    ~/Downloads/1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz
/nix/store/8f26d03z...-1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz
```

Флейк не скачивает и не перевыкладывает дистрибутив: `pkgs.requireFile`
только ссылается на уже лежащий в сторе архив по имени и хешу. Хеш даёт
`nix hash file --type sha256 --base16 <архив>`.

Шаг 2. Подключить флейк. EDT бесполезен без самой платформы —
`services.onec` из того же флейка публикует её в `/opt/1cv8/x86_64/<версия>`,
где EDT её и ищет:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    onec-devkit.url = "github:NixLavr/1C-NixOS-DevKit";
  };

  outputs =
    { self, nixpkgs, onec-devkit, ... }:
    let
      system = "x86_64-linux";
    in
    {
      nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          onec-devkit.nixosModules.default
          { nixpkgs.config.allowUnfree = true; }
          (
            { pkgs, ... }:
            {
              # Сама среда разработки.
              environment.systemPackages = [
                (onec-devkit.lib.${pkgs.system}.mkOnecEdt {
                  archiveFile = pkgs.requireFile {
                    name = "1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz";
                    sha256 = "892ea80e7b9019a7a333804cbdcbc84a1a49df47de88d13469639bed4773ec53";
                    message = "nix store add-file --name 1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz /путь/к/архиву";
                  };
                })
              ];

              # Платформа, которую EDT найдёт в /opt/1cv8/x86_64/<версия>.
              services.onec = {
                enable = true;
                archiveFile = pkgs.requireFile {
                  name = "server64_8_3_27_2130.zip";
                  sha256 = "06e58d4a7a6ffbc2bb414141b5594bf49e4b134cc51e6cbc98bf47c57693b35e";
                  message = "nix store add-file --name server64_8_3_27_2130.zip /путь/к/архиву";
                };
                language = "ru";
                client = {
                  enable = true;
                  components = [ "client_full" ];  # EDT нужен именно толстый клиент
                  # linkToOpt = true;              # включено по умолчанию
                };
              };
            }
          )
        ];
      };
    };
}
```

`nixpkgs.config.allowUnfree = true` обязателен: у обоих пакетов лицензия
`unfree`.

Система в индексе `lib.${pkgs.system}` взята из `pkgs`, а не из `let` в
`outputs`, нарочно: если вынести этот модуль в отдельный файл
(`imports = [ ./modules/onec.nix ];`), переменная `system` из `outputs` в
него не попадёт и вычисление упадёт с `undefined variable 'system'`.
`pkgs.system` работает в обоих случаях; альтернатива — прокинуть систему
модулям через `specialArgs = { inherit system; }` и добавить `system` в
аргументы модуля.

Архив в сторе — обычный путь без корня сборщика мусора: `nix-collect-garbage`
его удаляет. Это не страшно, исходник нужен только когда деривация меняется
(например, после обновления nixpkgs), — тогда сборка остановится с текстом
из `message`, и архив нужно добавить в стор той же командой ещё раз.

Если версия EDT та же, что зашита в этом репозитории, вместо вызова
`mkOnecEdt` достаточно готового пакета —
`onec-devkit.packages.${system}.onec-edt` (имя и хеш архива прописаны в
`flake.nix`). Для любой другой версии нужен `mkOnecEdt` со своим
`requireFile`, как в примере выше.

### Сборка пакета напрямую

```nix
let
  pkgs = import <nixpkgs> { config.allowUnfree = true; };
  mkOnecEdt = pkgs.callPackage ./pkgs/onec-edt.nix { };
in
mkOnecEdt {
  archiveFile = "/home/user/Downloads/1c_edt_distr_offline_2026.1.2_2_linux_x86_64.tar.gz";
  # version = "2026.1.2+2";  # необязательно, выводится из имени архива
}
```

`archiveFile` принимает и строку с путём, и деривацию (`requireFile`).
Версия выводится из имени файла в обоих случаях — префикс-хеш store-пути
регулярке не мешает.

### Что получается

Пакет даёт три команды: `1cedt` (сама среда разработки), `1cedtcli` (её
консольный режим) и `1cedtstart` (стартер, он же обработчик ссылок
`e1cedt://`), плюс `.desktop`-файлы для первой и третьей.

Без платформы 1С:Предприятие в EDT нельзя ни запустить, ни отладить
конфигурацию: клиент должен быть опубликован в `/opt/1cv8/x86_64/<версия>`
— этим занимается `services.onec.client.linkToOpt` (по умолчанию включён),
см. [NixOS-модуль](#nixos-модуль). Поэтому в примере выше рядом с пакетом
EDT включён и `services.onec`.

Обратите внимание: `1cedtstart` рассчитан на то, что версии EDT ставятся
и обновляются штатным инсталлятором 1С и перечислены в его реестре
(`/etc/1C/1CE`), которого у сборки из `/nix/store` нет. Запускается он
нормально, но управлять этой установкой не сможет — рабочий способ
запуска среды здесь `1cedt`, а версии переключаются как обычно в Nix,
через `archiveFile`.

Штатный инсталлятор из архива (`1ce-installer-cli`) не запускается: ему
нужен uid 0 и глобальный реестр установленных продуктов в `/etc/1C/1CE`,
а полезной работы он не делает — компоненты дистрибутива (`*.e1c.car`)
это обычные zip-архивы, и каталог `data/` внутри них дословно совпадает с
тем, что инсталлятор раскладывает по `<products-home>/components/`.
Пакет распаковывает их напрямую.

Java берётся встроенная в дистрибутив (Axiom JDK Full) и кладётся в тот
же пакет: заменить её на `jdk17` из nixpkgs нельзя, `1cedtstart` написан
на JavaFX. Она же прописывается в `1cedt.ini` строкой `-vm` и в
`JAVA_HOME`/`PATH` обёрток.

Каталог установки в `/nix/store` доступен только на чтение, поэтому
область конфигурации Eclipse уводится в
`${XDG_DATA_HOME:-$HOME/.local/share}/1cedt/<версия>/configuration`.
Рабочая область (workspace) — на своём обычном месте, `~/workspace`.
Ставить плагины через «Install New Software» в такой сборке нельзя.

Пакет весит около 7,5 ГБ; на время сборки к нему добавляются копия архива
в `/nix/store` и распакованный tar в `TMPDIR`, так что свободного места
нужно порядка 16 ГБ.

## 1C-Connect

`pkgs/onec-connect.nix` — пакет для официального Linux-клиента
[1C-Connect](https://1c-connect.com/), сервиса удалённого доступа/
техподдержки от 1С. С самим 1С:Предприятием он никак не связан — общее
только происхождение от фирмы 1С, но экспортируется из этого же flake как
отдельный пакет: `packages.${system}.onec-connect`.

NixOS-модуля у него нет — подключается через `environment.systemPackages`
из flake-input (см. [Подключение флейка](#подключение-флейка)):

```nix
{
  environment.systemPackages = [ onec-devkit.packages.${system}.onec-connect ];
}
```

`nixpkgs.config.allowUnfree = true` обязателен — лицензия
`unfreeRedistributable`.

## Важно про лицензию

Дистрибутив 1С:Предприятие — проприетарное ПО. Пакет не переопубликовывает
и не скачивает его: он берёт уже скачанный вами (под вашей лицензией) архив
и превращает в воспроизводимую Nix-сборку. Публиковать архив дистрибутива
или собранный из него пакет в открытом доступе нельзя.
