{
  description = "1С:Предприятие 8.3 — генератор Nix-пакетов (сервер/клиент) и модуль NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      # Пакета "по умолчанию" нет: сборка требует локального архива
      # дистрибутива под лицензией пользователя, поэтому экспортируется
      # генератор — см. README.md.
      lib.${system} = {
        mkOnec = pkgs.callPackage ./pkgs/package.nix { };
        mkPostgresql1c = pkgs.callPackage ./pkgs/postgresql-1c { };
      };

      packages.${system}.postgresql_1c = self.lib.${system}.mkPostgresql1c {
        archiveFile = "/home/lavr/nixos-config-main/flakes/postgresql_18.1_2_ubuntu_24.04_x86_64_package.tar.bz2";
      };

      packages.${system}.onec-connect = pkgs.callPackage ./pkgs/onec-connect.nix { };

      nixosModules.default = import ./modules/module.nix;
      nixosModules.onec = self.nixosModules.default;
      nixosModules.postgresql_1c = import ./modules/postgresql-1c.nix;
    };
}
