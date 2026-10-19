{
  description = "RVSC 2026 tutorial workspace — dev environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    ecos-studio.url = "github:openecos-projects/ecos-studio";
    ecos-studio.inputs.ecc.follows = "ecc";
    ecc.url = "git+https://github.com/openecos-projects/ecc.git?submodules=1";
    ecc-sizer.url = "git+https://github.com/openecos-projects/ecc-sizer.git?submodules=1";
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      # Ecc is only supported on Linux, so we only build for Linux.
      systems = [ "x86_64-linux" ];

      perSystem =
        {
          pkgs,
          inputs',
          self',
          config,
          ...
        }:
        let
          # Use latest yosys from nixpkgs-unstable, and wrap it to set the environment variables for ecc.
          hostLibs = pkgs.lib.makeLibraryPath [
            pkgs.libxcb
            pkgs.fontconfig.lib
            pkgs.libxcrypt-legacy
          ];
          eccLatestYosys = inputs'.ecc.packages.default.overrideAttrs (_: {
            postFixup = ''
              for bin in ecc ecc-agent-rpc; do
                wrapProgram "$out/bin/$bin" \
                  --set CHIPCOMPILER_OSS_CAD_DIR "${pkgs.yosys}" \
                  --set CHIPCOMPILER_KEPLER_FORMAL_ROOT "${inputs'.ecc.packages.keplerFormal}" \
                  --prefix PATH : "${pkgs.yosys}/bin"
              done
            '';
          });
        in
        {
          devShells = {
            default = pkgs.mkShell {
              packages = with pkgs; [
                nodejs_22
                pnpm
                appimage-run
                yosys # the nightly bundle ships no OSS CAD Suite; ECC's doctor needs yosys + slang
              ];

              # Prebuilt bundles (ECC nightly PyInstaller bundle, nightly kepler-formal)
              # expect these from the host; NixOS does not provide them on the default path.
              # - libxcb, fontconfig: DreamPlace's cairo drawer (placement: libxcb.so.1 / cairo-2)
              # - libxcrypt-legacy: kepler-formal (postRouteLec: libcrypt.so.1)
              LD_LIBRARY_PATH = hostLibs;

              # ECC strips LD_LIBRARY_PATH before launching kepler-formal, so the
              # variable above never reaches it. nix-ld reads NIX_LD_LIBRARY_PATH,
              # which ECC leaves alone; prepend the same libraries there too.
              shellHook = ''
                export NIX_LD_LIBRARY_PATH="${hostLibs}''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
                export CHIPCOMPILER_OSS_CAD_DIR="${pkgs.yosys}"
                echo "🛝  Dev shell ready (node + pnpm)"
                echo "    cd slides"
                echo "    pnpm install"
                echo "    pnpm dev"
                echo "    pnpm build"
              '';
            };
            ecos = pkgs.mkShell {
              packages = with pkgs; [
                yosys
                inputs'.ecos-studio.packages.default
                eccLatestYosys
                inputs'.ecc-sizer.packages.default
                # inputs'.kepler-formal.packages.default
              ];
            };
          };

          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
            programs.prettier.enable = true;
            programs.prettier.excludes = [
              "flake.lock"
              "**/pnpm-lock.yaml"
              "**/dist/**"
              "**/components.d.ts"
              # prettier will insert a blank line between Slidev page separator ---
              # and frontmatter, which breaks the parsing
              "slides/slides.md"
            ];
            programs.autocorrect.enable = true;
            programs.autocorrect.includes = [ "*.md" ];
          };

          # For buildbot ci
          checks = {
            devShell = self'.devShells.default;
            formatting = config.treefmt.build.check inputs.self;
            ecos-studio = inputs'.ecos-studio.packages.default;
            ecc = eccLatestYosys;
            ecc-sizer = inputs'.ecc-sizer.packages.default;
          };
        };
    };
}
