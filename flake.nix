{
  description = "The purely functional package manager";

  # TODO switch to nixos-23.11-small
  #      https://nixpk.gs/pr-tracker.html?pr=291954
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/release-24.05";
  inputs.nixpkgs-regression.url = "github:NixOS/nixpkgs/215d4d0fd80ca5163643b03a33fde804a29cc1e2";
  inputs.nixpkgs-23-11.url = "github:NixOS/nixpkgs/a62e6edd6d5e1fa0329b8653c801147986f8d446";
  inputs.flake-compat = { url = "github:edolstra/flake-compat"; flake = false; };
  inputs.libgit2 = { url = "github:libgit2/libgit2"; flake = false; };

  # dev tooling
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.pre-commit-hooks.url = "github:cachix/pre-commit-hooks.nix";
  # work around https://github.com/NixOS/nix/issues/7730
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  inputs.pre-commit-hooks.inputs.nixpkgs-stable.follows = "nixpkgs";
  # work around 7730 and https://github.com/NixOS/nix/issues/7807
  inputs.pre-commit-hooks.inputs.flake-compat.follows = "";
  inputs.pre-commit-hooks.inputs.gitignore.follows = "";

  outputs = inputs@{ self, nixpkgs, nixpkgs-regression, libgit2, ... }:


    let
      inherit (nixpkgs) lib;

      officialRelease = false;

      version = lib.fileContents ./.version + versionSuffix;
      versionSuffix =
        if officialRelease
        then ""
        else "pre${builtins.substring 0 8 (self.lastModifiedDate or self.lastModified or "19700101")}_${self.shortRev or "dirty"}";

      linux32BitSystems = [ "i686-linux" ];
      linux64BitSystems = [ "x86_64-linux" "aarch64-linux" ];
      linuxSystems = linux32BitSystems ++ linux64BitSystems;
      darwinSystems = [ "x86_64-darwin" "aarch64-darwin" ];
      systems = linuxSystems ++ darwinSystems;

      crossSystems = [
        "armv6l-unknown-linux-gnueabihf"
        "armv7l-unknown-linux-gnueabihf"
        "riscv64-unknown-linux-gnu"
        "x86_64-unknown-netbsd"
        "x86_64-unknown-freebsd"
        "x86_64-w64-mingw32"
      ];

      stdenvs = [
        "ccacheStdenv"
        "clangStdenv"
        "gccStdenv"
        "libcxxStdenv"
        "stdenv"
      ];

      /**
        `flatMapAttrs attrs f` applies `f` to each attribute in `attrs` and
        merges the results into a single attribute set.

        This can be nested to form a build matrix where all the attributes
        generated by the innermost `f` are returned as is.
        (Provided that the names are unique.)

        See https://nixos.org/manual/nixpkgs/stable/index.html#function-library-lib.attrsets.concatMapAttrs
       */
      flatMapAttrs = attrs: f: lib.concatMapAttrs f attrs;

      forAllSystems = lib.genAttrs systems;

      forAllCrossSystems = lib.genAttrs crossSystems;

      forAllStdenvs = f:
        lib.listToAttrs
          (map
            (stdenvName: {
              name = "${stdenvName}Packages";
              value = f stdenvName;
            })
            stdenvs);


      # We don't apply flake-parts to the whole flake so that non-development attributes
      # load without fetching any development inputs.
      devFlake = inputs.flake-parts.lib.mkFlake { inherit inputs; } {
        imports = [ ./maintainers/flake-module.nix ];
        systems = lib.subtractLists crossSystems systems;
        perSystem = { system, ... }: {
          _module.args.pkgs = nixpkgsFor.${system}.native;
        };
      };

      # Memoize nixpkgs for different platforms for efficiency.
      nixpkgsFor = forAllSystems
        (system: let
          make-pkgs = crossSystem: stdenv: import nixpkgs {
            localSystem = {
              inherit system;
            };
            crossSystem = if crossSystem == null then null else {
              config = crossSystem;
            } // lib.optionalAttrs (crossSystem == "x86_64-unknown-freebsd13") {
              useLLVM = true;
            };
            overlays = [
              (overlayFor (p: p.${stdenv}))
            ];
          };
          stdenvs = forAllStdenvs (make-pkgs null);
          native = stdenvs.stdenvPackages;
        in {
          inherit stdenvs native;
          static = native.pkgsStatic;
          cross = forAllCrossSystems (crossSystem: make-pkgs crossSystem "stdenv");
        });

      binaryTarball = nix: pkgs: pkgs.callPackage ./scripts/binary-tarball.nix {
        inherit nix;
      };

      overlayFor = getStdenv: final: prev:
        let
          stdenv = getStdenv final;
        in
        {
          nixStable = prev.nix;

          # A new scope, so that we can use `callPackage` to inject our own interdependencies
          # without "polluting" the top level "`pkgs`" attrset.
          # This also has the benefit of providing us with a distinct set of packages
          # we can iterate over.
          nixComponents = lib.makeScope final.nixDependencies.newScope (import ./packaging/components.nix);

          # The dependencies are in their own scope, so that they don't have to be
          # in Nixpkgs top level `pkgs` or `nixComponents`.
          nixDependencies = lib.makeScope final.newScope (import ./packaging/dependencies.nix {
            inherit inputs stdenv versionSuffix;
            pkgs = final;
          });

          nix = final.nixComponents.nix;

          nix_noTests = final.nix.override {
            doInstallCheck = false;
          };

          # See https://github.com/NixOS/nixpkgs/pull/214409
          # Remove when fixed in this flake's nixpkgs
          pre-commit =
            if prev.stdenv.hostPlatform.system == "i686-linux"
            then (prev.pre-commit.override (o: { dotnet-sdk = ""; })).overridePythonAttrs (o: { doCheck = false; })
            else prev.pre-commit;

        };

    in {
      # A Nixpkgs overlay that overrides the 'nix' and
      # 'nix-perl-bindings' packages.
      overlays.default = overlayFor (p: p.stdenv);

      hydraJobs = import ./packaging/hydra.nix {
        inherit
          inputs
          binaryTarball
          forAllCrossSystems
          forAllSystems
          lib
          linux64BitSystems
          nixpkgsFor
          self
          ;
      };

      checks = forAllSystems (system: {
        binaryTarball = self.hydraJobs.binaryTarball.${system};
        installTests = self.hydraJobs.installTests.${system};
        nixpkgsLibTests = self.hydraJobs.tests.nixpkgsLibTests.${system};
        rl-next =
          let pkgs = nixpkgsFor.${system}.native;
          in pkgs.buildPackages.runCommand "test-rl-next-release-notes" { } ''
          LANG=C.UTF-8 ${pkgs.changelog-d}/bin/changelog-d ${./doc/manual/rl-next} >$out
        '';
        repl-completion = nixpkgsFor.${system}.native.callPackage ./tests/repl-completion.nix { };
      } // (lib.optionalAttrs (builtins.elem system linux64BitSystems)) {
        dockerImage = self.hydraJobs.dockerImage.${system};
      } // (lib.optionalAttrs (!(builtins.elem system linux32BitSystems))) {
        # Some perl dependencies are broken on i686-linux.
        # Since the support is only best-effort there, disable the perl
        # bindings

        # Temporarily disabled because GitHub Actions OOM issues. Once
        # the old build system is gone and we are back to one build
        # system, we should reenable this.
        #perlBindings = self.hydraJobs.perlBindings.${system};
      }
      # Add "passthru" tests
      // flatMapAttrs ({
          "" = nixpkgsFor.${system}.native;
        } // lib.optionalAttrs (! nixpkgsFor.${system}.native.stdenv.hostPlatform.isDarwin) {
          # TODO: enable static builds for darwin, blocked on:
          #       https://github.com/NixOS/nixpkgs/issues/320448
          "static-" = nixpkgsFor.${system}.static;
        })
        (nixpkgsPrefix: nixpkgs:
          flatMapAttrs nixpkgs.nixComponents
            (pkgName: pkg:
              flatMapAttrs pkg.tests or {}
              (testName: test: {
                "${nixpkgsPrefix}${pkgName}-${testName}" = test;
              })
            )
        )
      // devFlake.checks.${system} or {}
      );

      packages = forAllSystems (system:
        { # Here we put attributes that map 1:1 into packages.<system>, ie
          # for which we don't apply the full build matrix such as cross or static.
          inherit (nixpkgsFor.${system}.native)
            changelog-d;
          default = self.packages.${system}.nix;
          nix-internal-api-docs = nixpkgsFor.${system}.native.nixComponents.nix-internal-api-docs;
          nix-external-api-docs = nixpkgsFor.${system}.native.nixComponents.nix-external-api-docs;
        }
        # We need to flatten recursive attribute sets of derivations to pass `flake check`.
        // flatMapAttrs
          { # Components we'll iterate over in the upcoming lambda
            "nix" = { };
            # Temporarily disabled because GitHub Actions OOM issues. Once
            # the old build system is gone and we are back to one build
            # system, we should reenable these.
            #"nix-util" = { };
            #"nix-store" = { };
            #"nix-fetchers" = { };
          }
          (pkgName: {}: {
              # These attributes go right into `packages.<system>`.
              "${pkgName}" = nixpkgsFor.${system}.native.nixComponents.${pkgName};
              "${pkgName}-static" = nixpkgsFor.${system}.static.nixComponents.${pkgName};
            }
            // flatMapAttrs (lib.genAttrs crossSystems (_: { })) (crossSystem: {}: {
              # These attributes go right into `packages.<system>`.
              "${pkgName}-${crossSystem}" = nixpkgsFor.${system}.cross.${crossSystem}.nixComponents.${pkgName};
            })
            // flatMapAttrs (lib.genAttrs stdenvs (_: { })) (stdenvName: {}: {
              # These attributes go right into `packages.<system>`.
              "${pkgName}-${stdenvName}" = nixpkgsFor.${system}.stdenvs."${stdenvName}Packages".nixComponents.${pkgName};
            })
          )
        // lib.optionalAttrs (builtins.elem system linux64BitSystems) {
        dockerImage =
          let
            pkgs = nixpkgsFor.${system}.native;
            image = import ./docker.nix { inherit pkgs; tag = version; };
          in
          pkgs.runCommand
            "docker-image-tarball-${version}"
            { meta.description = "Docker image with Nix for ${system}"; }
            ''
              mkdir -p $out/nix-support
              image=$out/image.tar.gz
              ln -s ${image} $image
              echo "file binary-dist $image" >> $out/nix-support/hydra-build-products
            '';
      });

      devShells = let
        makeShell = pkgs: stdenv: (pkgs.nix.override { inherit stdenv; forDevShell = true; }).overrideAttrs (attrs:
        let
          modular = devFlake.getSystem stdenv.buildPlatform.system;
          transformFlag = prefix: flag:
            assert builtins.isString flag;
            let
              rest = builtins.substring 2 (builtins.stringLength flag) flag;
            in
              "-D${prefix}:${rest}";
          havePerl = stdenv.buildPlatform == stdenv.hostPlatform && stdenv.hostPlatform.isUnix;
        in {
          pname = "shell-for-" + attrs.pname;

          # Remove the version suffix to avoid unnecessary attempts to substitute in nix develop
          version = lib.fileContents ./.version;
          name = attrs.pname;

          installFlags = "sysconfdir=$(out)/etc";
          shellHook = ''
            PATH=$prefix/bin:$PATH
            unset PYTHONPATH
            export MANPATH=$out/share/man:$MANPATH

            # Make bash completion work.
            XDG_DATA_DIRS+=:$out/share
          '';

          # We use this shell with the local checkout, not unpackPhase.
          src = null;

          env = {
            # Needed for Meson to find Boost.
            # https://github.com/NixOS/nixpkgs/issues/86131.
            BOOST_INCLUDEDIR = "${lib.getDev pkgs.nixDependencies.boost}/include";
            BOOST_LIBRARYDIR = "${lib.getLib pkgs.nixDependencies.boost}/lib";
            # For `make format`, to work without installing pre-commit
            _NIX_PRE_COMMIT_HOOKS_CONFIG =
              "${(pkgs.formats.yaml { }).generate "pre-commit-config.yaml" modular.pre-commit.settings.rawConfig}";
          };

          mesonFlags =
            map (transformFlag "libutil") pkgs.nixComponents.nix-util.mesonFlags
            ++ map (transformFlag "libstore") pkgs.nixComponents.nix-store.mesonFlags
            ++ map (transformFlag "libfetchers") pkgs.nixComponents.nix-fetchers.mesonFlags
            ++ lib.optionals havePerl (map (transformFlag "perl") pkgs.nixComponents.nix-perl-bindings.mesonFlags)
            ;

          nativeBuildInputs = attrs.nativeBuildInputs or []
            ++ pkgs.nixComponents.nix-util.nativeBuildInputs
            ++ pkgs.nixComponents.nix-store.nativeBuildInputs
            ++ pkgs.nixComponents.nix-fetchers.nativeBuildInputs
            ++ lib.optionals havePerl pkgs.nixComponents.nix-perl-bindings.nativeBuildInputs
            ++ pkgs.nixComponents.nix-internal-api-docs.nativeBuildInputs
            ++ pkgs.nixComponents.nix-external-api-docs.nativeBuildInputs
            ++ [
              pkgs.buildPackages.cmake
              pkgs.shellcheck
              modular.pre-commit.settings.package
              (pkgs.writeScriptBin "pre-commit-hooks-install"
                modular.pre-commit.settings.installationScript)
            ]
            # TODO: Remove the darwin check once
            # https://github.com/NixOS/nixpkgs/pull/291814 is available
            ++ lib.optional (stdenv.cc.isClang && !stdenv.buildPlatform.isDarwin) pkgs.buildPackages.bear
            ++ lib.optional (stdenv.cc.isClang && stdenv.hostPlatform == stdenv.buildPlatform) pkgs.buildPackages.clang-tools;

          buildInputs = attrs.buildInputs or []
            ++ [
              pkgs.gtest
              pkgs.rapidcheck
            ]
            ++ lib.optional havePerl pkgs.perl
            ;
        });
        in
        forAllSystems (system:
          let
            makeShells = prefix: pkgs:
              lib.mapAttrs'
              (k: v: lib.nameValuePair "${prefix}-${k}" v)
              (forAllStdenvs (stdenvName: makeShell pkgs pkgs.${stdenvName}));
          in
            (makeShells "native" nixpkgsFor.${system}.native) //
            (lib.optionalAttrs (!nixpkgsFor.${system}.native.stdenv.isDarwin)
              (makeShells "static" nixpkgsFor.${system}.static) //
              (forAllCrossSystems (crossSystem: let pkgs = nixpkgsFor.${system}.cross.${crossSystem}; in makeShell pkgs pkgs.stdenv))) //
            {
              default = self.devShells.${system}.native-stdenvPackages;
            }
        );
  };
}
