# 1С:Предприятие 8.3 — пакет для Nix/NixOS

Дистрибутив 1С скачивается с портала как zip-архив (например
`server64_8_3_XX_XXXX.zip`) с самораспаковывающимся инсталлятором внутри
(`setup-full-*.run`, InstallBuilder), который жёстко требует root.
`package.nix` распаковывает архив, находит инсталлятор и запускает его без
root внутри обычной песочницы `nix build`, используя bubblewrap для
эмуляции недостающего окружения — никаких внешних скриптов или ослабления
sandbox.

Список допустимых `--enable-components` не хранится в Nix-файле как
константа: `package.nix` считывает его прямо из инсталлятора во время
сборки, так что обновление дистрибутива не требует правок.

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

`archiveFile` — строка, а не путь-литерал: с path-литералом парсер Nix
ошибается на нелатинских символах в имени каталога (например, `~/Загрузки`).

Язык интерфейса — отдельный **устанавливаемый компонент** инсталлятора, а
не встроенная опция: без кода языка (`"ru"` и т.п.) в списке `components`
файлы перевода физически не попадают в сборку. `module.nix` добавляет его
сам из `services.onec.language`; при прямом использовании `package.nix` —
нужно руками.

Собранный пакет кладёт файлы в `$out/opt/1cv8/x86_64/<version>/` (1С сам
ищет свои ресурсы рядом со своими `.so`, поэтому путь менять нельзя) и
линкует основные бинарники в `$out/bin`. Мусор инсталлятора (деинсталлятор,
HTML-читалка, штатные systemd-юниты с FHS-путями) удаляется; документация и
лицензии переносятся в `$out/share/doc/<pname>/`.

### Толстый клиент (`client_full`) и Wayland

Толстый клиент (`1cv8`) падает при инициализации EGL под Wayland —
`package.nix` автоматически гасит `WAYLAND_DISPLAY` в обёртке клиентских
бинарников, тонкий клиент (`1cv8c`) при этом уходит на XWayland.

### Ярлыки в меню приложений (.desktop)

Штатный компонент `desktop_icons` пишет `.desktop`-файлы и иконки, но
внутри строгой песочницы `nix build` этот шаг инсталлятора — тихий no-op
(нужен D-Bus/systemd). На этот случай `package.nix` подставляет свой
минимальный `.desktop` без фирменной иконки для каждого собранного
клиентского бинарника.

## Зависимости

Почти всё (libstdc++, ICU, tcmalloc, libssh и т.д.) 1С приносит в
комплекте — `autoPatchelfHook` чинит интерпретатор и сшивает эти файлы
между собой. Из внешнего окружения нужны:

- **glibc, krb5, keyutils, e2fsprogs** — всегда.
- **glib, gdk-pixbuf, cairo, pango, atk, gtk3, cups, libGL, webkitgtk_4_1**
  — только для клиентских компонентов (`client_*`).

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

Для PostgreSQL 1С аналогично: `onec-devkit.nixosModules.postgresql_1c`,
генератор пакета — `onec-devkit.lib.${system}.mkPostgresql1c`. Без флейков
модуль можно импортировать и напрямую по пути (`imports = [
./modules/module.nix ];`), если репозиторий склонирован локально.

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

## 1C-Connect

`pkgs/onec-connect.nix` в корне репозитория (не в этом flake) — отдельный
пакет для официального Linux-клиента [1C-Connect](https://1c-connect.com/),
сервиса удалённого доступа/техподдержки от 1С. Дистрибутив скачивается с
`updates.1c-connect.com` и запускается как готовый `.tar.gz` без сборки из
исходников; пакет лишь патчит ELF-зависимости через `autoPatchelfHook` и
оборачивает бинарник нужным `LD_LIBRARY_PATH`. С самим 1С:Предприятием
(этим flake) он никак не связан — общее только происхождение от фирмы 1С.

## Важно про лицензию

Дистрибутив 1С:Предприятие — проприетарное ПО. Пакет не переопубликовывает
и не скачивает его: он берёт уже скачанный вами (под вашей лицензией) архив
и превращает в воспроизводимую Nix-сборку. Публиковать архив дистрибутива
или собранный из него пакет в открытом доступе нельзя.
