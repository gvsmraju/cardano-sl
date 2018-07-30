{ system
, compiler
, flags ? {}
, pkgs
, hsPkgs
, pkgconfPkgs }:
  let
    _flags = {} // flags;
  in {
    flags = _flags;
    package = {
      specVersion = "1.10";
      identifier = {
        name = "cardano-sl-infra-test";
        version = "1.3.0";
      };
      license = "MIT";
      copyright = "2018 IOHK";
      maintainer = "IOHK <support@iohk.io>";
      author = "IOHK";
      homepage = "";
      url = "";
      synopsis = "Cardano SL - generators for cardano-sl-infra";
      description = "This package contains generators for the infrastructural data types used in Cardano SL.";
      buildType = "Simple";
    };
    components = {
      "cardano-sl-infra-test" = {
        depends  = [
          (hsPkgs.QuickCheck)
          (hsPkgs.async)
          (hsPkgs.base)
          (hsPkgs.bytestring)
          (hsPkgs.cardano-sl-binary)
          (hsPkgs.cardano-sl-binary-test)
          (hsPkgs.cardano-sl-core)
          (hsPkgs.cardano-sl-core-test)
          (hsPkgs.cardano-sl-crypto)
          (hsPkgs.cardano-sl-crypto-test)
          (hsPkgs.cardano-sl-infra)
          (hsPkgs.cardano-sl-ssc)
          (hsPkgs.cardano-sl-ssc-test)
          (hsPkgs.cardano-sl-update-test)
          (hsPkgs.cardano-sl-util-test)
          (hsPkgs.containers)
          (hsPkgs.generic-arbitrary)
          (hsPkgs.hedgehog)
          (hsPkgs.hspec)
          (hsPkgs.kademlia)
          (hsPkgs.universum)
        ];
      };
    };
  } // rec {
    src = ../infra/test;
  }