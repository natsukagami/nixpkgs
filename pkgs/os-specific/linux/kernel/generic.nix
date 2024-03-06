{ buildPackages
, callPackage
, perl
, bison ? null
, flex ? null
, gmp ? null
, libmpc ? null
, mpfr ? null
, pahole
, lib
, stdenv
, rustc
, rustPlatform
, rust-bindgen

, # The kernel source tarball.
  src

, # The kernel version.
  version

, # Allows overriding the default defconfig
  defconfig ? null

, # Legacy overrides to the intermediate kernel config, as string
  extraConfig ? ""

  # Additional make flags passed to kbuild
, extraMakeFlags ? []

, # enables the options in ./common-config.nix; if `false` then only
  # `structuredExtraConfig` is used
 enableCommonConfig ? true

, # kernel intermediate config overrides, as a set
 structuredExtraConfig ? {}

, # The version number used for the module directory
  # If unspecified, this is determined automatically from the version.
  modDirVersion ? null

, # An attribute set whose attributes express the availability of
  # certain features in this kernel.  E.g. `{ia32Emulation = true;}'
  # indicates a kernel that provides Intel wireless support.  Used in
  # NixOS to implement kernel-specific behaviour.
  features ? {}

, # Custom seed used for CONFIG_GCC_PLUGIN_RANDSTRUCT if enabled. This is
  # automatically extended with extra per-version and per-config values.
  randstructSeed ? ""

, # A list of patches to apply to the kernel.  Each element of this list
  # should be an attribute set {name, patch} where `name' is a
  # symbolic name and `patch' is the actual patch.  The patch may
  # optionally be compressed with gzip or bzip2.
  kernelPatches ? []
, ignoreConfigErrors ? stdenv.hostPlatform.linux-kernel.name != "pc"
, extraMeta ? {}

, isZen      ? false
, isLibre    ? false
, isHardened ? false

# easy overrides to stdenv.hostPlatform.linux-kernel members
, autoModules ? stdenv.hostPlatform.linux-kernel.autoModules
, preferBuiltin ? stdenv.hostPlatform.linux-kernel.preferBuiltin or false
, kernelArch ? stdenv.hostPlatform.linuxArch
, kernelTests ? []
, nixosTests
, ...
}@args:

# Note: this package is used for bootstrapping fetchurl, and thus
# cannot use fetchpatch! All mutable patches (generated by GitHub or
# cgit) that are needed here should be included directly in Nixpkgs as
# files.

assert stdenv.isLinux;

let
  # Dirty hack to make sure that `version` & `src` have
  # `<nixpkgs/pkgs/os-specific/linux/kernel/linux-x.y.nix>` as position
  # when using `builtins.unsafeGetAttrPos`.
  #
  # This is to make sure that ofborg actually detects changes in the kernel derivation
  # and pings all maintainers.
  #
  # For further context, see https://github.com/NixOS/nixpkgs/pull/143113#issuecomment-953319957
  basicArgs = builtins.removeAttrs
    args
    (lib.filter (x: ! (builtins.elem x [ "version" "src" ])) (lib.attrNames args));

  # Combine the `features' attribute sets of all the kernel patches.
  kernelFeatures = lib.foldr (x: y: (x.features or {}) // y) ({
    efiBootStub = true;
    netfilterRPFilter = true;
    ia32Emulation = true;
  } // features) kernelPatches;

  commonStructuredConfig = import ./common-config.nix {
    inherit lib stdenv version;

    features = kernelFeatures; # Ensure we know of all extra patches, etc.
  };

  intermediateNixConfig = configfile.moduleStructuredConfig.intermediateNixConfig
    # extra config in legacy string format
    + extraConfig
    + stdenv.hostPlatform.linux-kernel.extraConfig or "";

  structuredConfigFromPatches =
        map ({extraStructuredConfig ? {}, ...}: {settings=extraStructuredConfig;}) kernelPatches;

  # appends kernel patches extraConfig
  kernelConfigFun = baseConfigStr:
    let
      configFromPatches =
        map ({extraConfig ? "", ...}: extraConfig) kernelPatches;
    in lib.concatStringsSep "\n" ([baseConfigStr] ++ configFromPatches);

  withRust = ((configfile.moduleStructuredConfig.settings.RUST or {}).tristate or null) == "y";

  configfile = stdenv.mkDerivation {
    inherit ignoreConfigErrors autoModules preferBuiltin kernelArch extraMakeFlags;
    pname = "linux-config";
    inherit version;

    generateConfig = ./generate-config.pl;

    kernelConfig = kernelConfigFun intermediateNixConfig;
    passAsFile = [ "kernelConfig" ];

    depsBuildBuild = [ buildPackages.stdenv.cc ];
    nativeBuildInputs = [ perl gmp libmpc mpfr ]
      ++ lib.optionals (lib.versionAtLeast version "4.16") [ bison flex ]
      ++ lib.optional (lib.versionAtLeast version "5.2") pahole
      ++ lib.optionals withRust [ rust-bindgen rustc ]
    ;

    RUST_LIB_SRC = lib.optionalString withRust rustPlatform.rustLibSrc;

    platformName = stdenv.hostPlatform.linux-kernel.name;
    # e.g. "defconfig"
    kernelBaseConfig = if defconfig != null then defconfig else stdenv.hostPlatform.linux-kernel.baseConfig;

    makeFlags = lib.optionals (stdenv.hostPlatform.linux-kernel ? makeFlags) stdenv.hostPlatform.linux-kernel.makeFlags
      ++ extraMakeFlags;

    postPatch = kernel.postPatch + ''
      # Patch kconfig to print "###" after every question so that
      # generate-config.pl from the generic builder can answer them.
      sed -e '/fflush(stdout);/i\printf("###");' -i scripts/kconfig/conf.c
    '';

    preUnpack = kernel.preUnpack or "";

    inherit (kernel) src patches;

    buildPhase = ''
      export buildRoot="''${buildRoot:-build}"
      export HOSTCC=$CC_FOR_BUILD
      export HOSTCXX=$CXX_FOR_BUILD
      export HOSTAR=$AR_FOR_BUILD
      export HOSTLD=$LD_FOR_BUILD

      # Get a basic config file for later refinement with $generateConfig.
      make $makeFlags \
          -C . O="$buildRoot" $kernelBaseConfig \
          ARCH=$kernelArch \
          HOSTCC=$HOSTCC HOSTCXX=$HOSTCXX HOSTAR=$HOSTAR HOSTLD=$HOSTLD \
          CC=$CC OBJCOPY=$OBJCOPY OBJDUMP=$OBJDUMP READELF=$READELF \
          $makeFlags

      # Create the config file.
      echo "generating kernel configuration..."
      ln -s "$kernelConfigPath" "$buildRoot/kernel-config"
      DEBUG=1 ARCH=$kernelArch KERNEL_CONFIG="$buildRoot/kernel-config" AUTO_MODULES=$autoModules \
        PREFER_BUILTIN=$preferBuiltin BUILD_ROOT="$buildRoot" SRC=. MAKE_FLAGS="$makeFlags" \
        perl -w $generateConfig
    '';

    installPhase = "mv $buildRoot/.config $out";

    enableParallelBuilding = true;

    passthru = rec {
      module = import ../../../../nixos/modules/system/boot/kernel_config.nix;
      # used also in apache
      # { modules = [ { options = res.options; config = svc.config or svc; } ];
      #   check = false;
      # The result is a set of two attributes
      moduleStructuredConfig = (lib.evalModules {
        modules = [
          module
        ] ++ lib.optionals enableCommonConfig [
          { settings = commonStructuredConfig; _file = "pkgs/os-specific/linux/kernel/common-config.nix"; }
        ] ++ [
          { settings = structuredExtraConfig; _file = "structuredExtraConfig"; }
        ]
        ++  structuredConfigFromPatches
        ;
      }).config;

      structuredConfig = moduleStructuredConfig.settings;
    };
  }; # end of configfile derivation

  kernel = (callPackage ./manual-config.nix { inherit lib stdenv buildPackages; }) (basicArgs // {
    inherit kernelPatches randstructSeed extraMakeFlags extraMeta configfile;
    pos = builtins.unsafeGetAttrPos "version" args;

    config = { CONFIG_MODULES = "y"; CONFIG_FW_LOADER = "m"; } // lib.optionalAttrs withRust { CONFIG_RUST = "y"; };
  } // lib.optionalAttrs (modDirVersion != null) { inherit modDirVersion; });

in
kernel.overrideAttrs (finalAttrs: previousAttrs: {

  passthru = previousAttrs.passthru or { } // basicArgs // {
    features = kernelFeatures;
    inherit commonStructuredConfig structuredExtraConfig extraMakeFlags isZen isHardened isLibre;
    isXen = lib.warn "The isXen attribute is deprecated. All Nixpkgs kernels that support it now have Xen enabled." true;

    # Adds dependencies needed to edit the config:
    # nix-shell '<nixpkgs>' -A linux.configEnv --command 'make nconfig'
    configEnv = kernel.overrideAttrs (old: {
      nativeBuildInputs = old.nativeBuildInputs or [] ++ (with buildPackages; [
        pkg-config ncurses
      ]);
    });

    tests = let
      overridableKernel = finalAttrs.finalPackage // {
        override = args:
          lib.warn (
            "override is stubbed for NixOS kernel tests, not applying changes these arguments: "
            + toString (lib.attrNames (lib.toFunction args { }))
          ) overridableKernel;
      };
    in [ (nixosTests.kernel-generic.passthru.testsForKernel overridableKernel) ] ++ kernelTests;
  };

})
