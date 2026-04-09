{
  description = "Zcash unanimity node — builds zebra and zcashd from vendored git subtrees";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

        # ---------------------------------------------------------------
        # Rust toolchains
        # ---------------------------------------------------------------

        # zebrad requires Rust >= 1.89 (zebra/zebrad/Cargo.toml rust-version)
        zebraRust = pkgs.rust-bin.stable."1.89.0".default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };

        zebraRustPlatform = pkgs.makeRustPlatform {
          cargo = zebraRust;
          rustc = zebraRust;
        };

        # zcashd Rust FFI requires 1.81.0 (zcashd/rust-toolchain.toml)
        zcashdRust = pkgs.rust-bin.stable."1.81.0".default.override {
          extensions = [ "rust-src" "clippy" "rustfmt" ];
        };

        # A rust platform built around the zcashd toolchain, used to vendor
        # Cargo dependencies so the zcashd make build can work in the Nix
        # pure sandbox (no network access).
        zcashdRustPlatform = pkgs.makeRustPlatform {
          cargo = zcashdRust;
          rustc = zcashdRust;
        };

        # ---------------------------------------------------------------
        # zebra — Rust Zcash full node (ZcashFoundation/zebra v4.3.0)
        # Source: https://github.com/ZcashFoundation/zebra
        # Branch: main  Commit: 92a4e55f9e702468dbb0d8ec57df3e0c3fdd4ea9
        # Tag:    v4.3.0
        # ---------------------------------------------------------------
        zebra = zebraRustPlatform.buildRustPackage {
          pname = "zebra";
          version = "4.3.0";
          src = ./zebra;

          cargoLock.lockFile = ./zebra/Cargo.lock;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.protobuf
            pkgs.clang
            pkgs.llvmPackages.libclang
          ];

          buildInputs = [
            pkgs.openssl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

          # Build only the node binary; skip the rest of the workspace
          cargoBuildFlags = [ "--package" "zebrad" ];
          # Skip tests — they require a running Zcash network
          doCheck = false;

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
        };

        # ---------------------------------------------------------------
        # zcashd — C++ Zcash full node (zcash/zcash v6.12.0)
        # Source: https://github.com/zcash/zcash
        # Branch: master  Commit: 5145b8543caecf3f2b705d150161dd06192cf4da
        # Tag:    v6.12.0
        #
        # zcashd is a hybrid C++/Rust project.  The C++ build system
        # (autoconf/make) invokes `cargo build` to compile the Rust FFI
        # library (librustzcash) and link it into zcashd.  In the Nix
        # pure sandbox there is no network access, so we pre-vendor all
        # Cargo dependencies using cargoSetupHook / importCargoLock and
        # point cargo at the local vendor directory via CARGO_HOME.
        # ---------------------------------------------------------------
        zcashd = pkgs.stdenv.mkDerivation {
          pname = "zcashd";
          version = "6.12.0";
          src = ./zcashd;

          # Pre-vendor all Rust crates referenced in zcashd/Cargo.lock so
          # the cargo invocation inside `make` can run without network access.
          cargoDeps = zcashdRustPlatform.importCargoLock {
            lockFile = ./zcashd/Cargo.lock;
          };

          nativeBuildInputs = [
            # Cargo vendoring hook — must come before zcashdRust so that the
            # hook's setup-hook script runs first and configures CARGO_HOME.
            zcashdRustPlatform.cargoSetupHook
            zcashdRust            # provides cargo + rustc for the FFI build
            pkgs.autoconf
            pkgs.automake
            pkgs.libtool
            pkgs.pkg-config
            pkgs.python3
            pkgs.git
            pkgs.clang
            pkgs.llvmPackages.libclang
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.util-linux       # provides hexdump on Linux; macOS ships /usr/bin/hexdump
          ];

          buildInputs = [
            pkgs.boost
            pkgs.libevent
            pkgs.openssl
            pkgs.libsodium
            pkgs.zeromq
            pkgs.db62             # Berkeley DB 6.2 (required for wallet)
            pkgs.zlib
            pkgs.curl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
          ];

          preConfigure = ''
            ./autogen.sh
          '';

          configureFlags = [
            "--disable-tests"
            "--disable-bench"
            "--disable-debug"
            "--with-boost=${pkgs.boost.dev}"
            "--with-boost-libdir=${pkgs.boost}/lib"
            "--with-incompatible-bdb"
          ];

          enableParallelBuilding = true;

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          meta = {
            description = "Zcash node and CLI wallet (zcashd) built from source";
            homepage = "https://github.com/zcash/zcash";
            license = pkgs.lib.licenses.mit;
            platforms = pkgs.lib.platforms.linux ++ pkgs.lib.platforms.darwin;
          };
        };

      in {
        # -------------------------------------------------------------------
        # Packages
        # -------------------------------------------------------------------
        packages = {
          inherit zebra zcashd;

          # `nix build` (default) builds both and merges them into one output
          default = pkgs.symlinkJoin {
            name = "zcash-unanimity-node-${zebra.version}-${zcashd.version}";
            paths = [ zebra zcashd ];
          };
        };

        # -------------------------------------------------------------------
        # Dev shell — `nix develop` gives an environment capable of building
        # both zebra and zcashd interactively on the CLI.
        # -------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          name = "zcash-unanimity-node-dev";

          nativeBuildInputs = [
            # Rust toolchain — 1.89.0 satisfies both zebra (>= 1.89) and
            # zcashd (1.81) so a single toolchain works for both projects.
            zebraRust
            pkgs.pkg-config
            pkgs.protobuf
            pkgs.clang
            pkgs.llvmPackages.libclang
            # zcashd autoconf build tools
            pkgs.autoconf
            pkgs.automake
            pkgs.libtool
            pkgs.python3
            pkgs.git
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.util-linux       # provides hexdump on Linux; macOS ships /usr/bin/hexdump
          ];

          buildInputs = [
            pkgs.openssl
            pkgs.boost
            pkgs.libevent
            pkgs.libsodium
            pkgs.zeromq
            pkgs.db62
            pkgs.zlib
            pkgs.curl
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            pkgs.darwin.apple_sdk.frameworks.Security
            pkgs.darwin.apple_sdk.frameworks.SystemConfiguration
          ];

          LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";

          shellHook = ''
            echo ""
            echo "╔══════════════════════════════════════════════════════════════╗"
            echo "║        Zcash unanimity-node development shell                ║"
            echo "╚══════════════════════════════════════════════════════════════╝"
            echo ""
            echo "  zebra  v4.3.0  — https://github.com/ZcashFoundation/zebra"
            echo "    Build:  cd zebra && cargo build --release -p zebrad"
            echo "    Run:    ./zebra/target/release/zebrad"
            echo ""
            echo "  zcashd v6.12.0 — https://github.com/zcash/zcash"
            echo "    Build:  cd zcashd && ./autogen.sh && ./configure && make -j\$(nproc)"
            echo "    Run:    ./zcashd/src/zcashd"
            echo ""
          '';
        };
      }
    );
}
