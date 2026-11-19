{
  description = "probz: probabilistic data structures for Gleam";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        inherit (pkgs) lib;
        inherit (pkgs.beamPackages) erlang rebar3;

        # Gleam dependencies, fetched from Hex by the checksums in
        # manifest.toml, so the build needs no network.
        manifest = builtins.fromTOML (builtins.readFile ./manifest.toml);
        hexPackages = builtins.filter (p: p.source == "hex") manifest.packages;
        fetchHex =
          p:
          pkgs.fetchurl {
            url = "https://repo.hex.pm/tarballs/${p.name}-${p.version}.tar";
            sha256 = lib.toLower p.outer_checksum;
          };
        unpackDeps = lib.concatMapStrings (p: ''
          mkdir -p build/packages/${p.name}
          tar -xOf ${fetchHex p} contents.tar.gz | tar -xzf - -C build/packages/${p.name}
        '') hexPackages;
        packagesToml = pkgs.writeText "packages.toml" (
          "[packages]\n" + lib.concatMapStrings (p: "${p.name} = \"${p.version}\"\n") hexPackages
        );

        # Source, deps and toolchain shared by the package and the checks.
        gleamArgs = {
          version = (builtins.fromTOML (builtins.readFile ./gleam.toml)).version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./gleam.toml
              ./manifest.toml
              ./src
              ./dev
              ./test
              ./testdata
            ];
          };
          nativeBuildInputs = [
            pkgs.gleam
            erlang
            rebar3
          ];
          configurePhase = ''
            runHook preConfigure
            export HOME=$TMPDIR
            ${unpackDeps}
            install -m 644 ${packagesToml} build/packages/packages.toml
            runHook postConfigure
          '';
        };
        gleamCheck =
          name: script:
          pkgs.stdenv.mkDerivation (
            gleamArgs
            // {
              pname = "probz-${name}";
              buildPhase = script;
              installPhase = "touch $out";
            }
          );

        # The library: compiled BEAM files and the HTML docs.
        probz = pkgs.stdenv.mkDerivation (
          gleamArgs
          // {
            pname = "probz";
            buildPhase = ''
              runHook preBuild
              gleam build --warnings-as-errors
              gleam docs build
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/share/doc
              cp -r build/dev/erlang/probz $out/lib/probz
              cp -r build/dev/docs/probz $out/share/doc/probz
              runHook postInstall
            '';
          }
        );
      in
      {
        packages.default = probz;

        checks = {
          inherit probz;
          fmt = gleamCheck "fmt" "gleam format --check src test dev";
          test = gleamCheck "test" "gleam test";
          examples = gleamCheck "examples" "sh dev/run_examples.sh";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            gleam
            erlang
            rebar3
            just
            watchexec
          ];
        };

        formatter = pkgs.nixfmt;
      }
    );
}
