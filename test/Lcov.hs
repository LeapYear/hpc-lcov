{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Lcov where

import Control.Arrow ((&&&))
import Data.Aeson (encode)
import qualified Data.IntMap as IntMap
import Data.List (sortOn)
import Data.Text (Text)
import Test.Tasty (TestTree)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (testCase, (@?=))
import Trace.Hpc.Mix (BoxLabel(..), CondBox(..))
import Trace.Hpc.Tix (TixModule(..))
import Trace.Hpc.Util (toHpcPos)

import Trace.Hpc.Lcov
import Trace.Hpc.Lcov.Report (LcovReport(..), FileReport(..), Hit(..))

test_generate_lcov :: TestTree
test_generate_lcov =
  goldenVsString "generateLcovFromTix" "test/golden/generate_lcov.golden" $
    pure $ encode $ generateLcovFromTixMix
      [ TixMix "MyModule.Foo" "src/MyModule/Foo.hs"
          [ TixMixEntry (1, 1) (1, 20) 0
          , TixMixEntry (2, 1) (2, 20) 1
          , TixMixEntry (3, 1) (3, 20) 2
          ]
      , TixMix "MyModule.Bar" "src/MyModule/Bar.hs"
          [ TixMixEntry (1, 1) (1, 20) 10
          ]
      , TixMix "MyModule.Bar.Baz" "src/MyModule/Bar/Baz.hs"
          [ TixMixEntry (1, 1) (1, 20) 20
          ]
      ]

test_generate_lcov_resolve_hits :: TestTree
test_generate_lcov_resolve_hits = testCase "generateLcovFromTix resolve hits" $
  let report = generateLcovFromTixMix
        [ TixMix "WithPartial" "WithPartial.hs"
            [ TixMixEntry (1, 1) (1, 5) 10
            , TixMixEntry (1, 10) (1, 20) 0
            ]
        , TixMix "WithMissing" "WithMissing.hs"
            [ TixMixEntry (1, 1) (1, 5) 0
            , TixMixEntry (1, 10) (1, 20) 0
            ]
        , TixMix "WithDisjoint" "WithDisjoint.hs"
            [ TixMixEntry (1, 1) (1, 5) 10
            , TixMixEntry (1, 10) (1, 20) 20
            ]
        , TixMix "WithNonDisjoint" "WithNonDisjoint.hs"
            [ TixMixEntry (1, 1) (5, 20) 20 -- contains all below
            , TixMixEntry (1, 1) (1, 5) 10
            , TixMixEntry (3, 1) (3, 5) 0
            , TixMixEntry (4, 1) (4, 5) 20
            , TixMixEntry (4, 6) (4, 20) 0
            , TixMixEntry (5, 1) (5, 5) 10
            , TixMixEntry (5, 6) (5, 10) 20
            , TixMixEntry (5, 1) (5, 20) 10 -- contains the two above
            ]
        ]
  in fromReport report @?=
    [ ("WithDisjoint.hs", [(1, Hit 20)])
    , ("WithMissing.hs", [(1, Hit 0)])
    , ("WithNonDisjoint.hs", [(1, Hit 10), (2, Hit 20), (3, Hit 0), (4, Partial), (5, Hit 20)])
    , ("WithPartial.hs", [(1, Partial)])
    ]

test_generate_lcov_merge_tixs :: TestTree
test_generate_lcov_merge_tixs = testCase "generateLcovFromTix merge .tix files" $
  let report = generateLcovFromTix
        [ mkModuleToMix "Test" "Test.hs"
            [ MixEntry (1, 1) (1, 10) (ExpBox True)
            , MixEntry (2, 1) (2, 10) (ExpBox True)
            , MixEntry (3, 1) (3, 10) (ExpBox True)
            , MixEntry (4, 1) (4, 10) (ExpBox True)
            ]
        ]
        [ mkTix "Test" [0, 0, 1, 1]
        , mkTix "Test" [0, 1, 0, 1]
        ]
  in fromReport report @?=
    [ ("Test.hs", [(1, Hit 0), (2, Hit 1), (3, Hit 1), (4, Hit 2)])
    ]

test_generate_lcov_non_expbox :: TestTree
test_generate_lcov_non_expbox = testCase "generateLcovFromTix non-ExpBox" $
  let report = generateLcovFromTix
        [ mkModuleToMix "WithBinBox" "WithBinBox.hs"
            -- if [x > 0] then ... else ...
            --    ^ evaluates to True 10 times, False 0 times
            --      should show in the report as "10 hits", not
            --      as "partial"
            [ MixEntry (1, 1) (1, 10) (ExpBox True)
            , MixEntry (1, 1) (1, 10) (BinBox CondBinBox True)
            , MixEntry (1, 1) (1, 10) (BinBox CondBinBox False)
            ]
        , mkModuleToMix "WithTopLevelBox" "WithTopLevelBox.hs"
            -- foo x = ...
            -- ^
            [ MixEntry (1, 1) (2, 10) (TopLevelBox ["foo"])
            , MixEntry (1, 1) (1, 5) (ExpBox True)
            , MixEntry (2, 6) (2, 10) (ExpBox True)
            ]
        , mkModuleToMix "WithLocalBox" "WithLocalBox.hs"
            -- foo x = ...
            --   where bar = ...
            --         ^
            [ MixEntry (1, 1) (1, 10) (LocalBox ["foo", "bar"])
            , MixEntry (1, 1) (1, 5) (ExpBox True)
            , MixEntry (1, 6) (1, 10) (ExpBox True)
            ]
        ]
        [ mkTix "WithBinBox" [10, 10, 0]
        , mkTix "WithTopLevelBox" [1, 0, 1]
        , mkTix "WithLocalBox" [1, 1, 1]
        ]
  in fromReport report @?=
    [ ("WithBinBox.hs", [(1, Hit 10)])
    , ("WithLocalBox.hs", [(1, Hit 1)])
    , ("WithTopLevelBox.hs", [(1, Hit 0), (2, Hit 1)])
    ]

{- Helpers -}

mkTix :: String -> [Integer] -> TixModule
mkTix moduleName ticks = TixModule moduleName 0 (length ticks) ticks

data MixEntry = MixEntry
  { mixEntryStartPos :: (Int, Int)
  , mixEntryEndPos   :: (Int, Int)
  , mixEntryBoxLabel :: BoxLabel
  }

mkModuleToMix :: String -> FilePath -> [MixEntry] -> (String, FileInfo)
mkModuleToMix moduleName filePath mixEntries = (moduleName, (filePath, mixs))
  where
    mixs = flip map mixEntries $ \MixEntry{..} ->
      let (startLine, startCol) = mixEntryStartPos
          (endLine, endCol) = mixEntryEndPos
      in (toHpcPos (startLine, startCol, endLine, endCol), mixEntryBoxLabel)

data TixMix = TixMix
  { tixMixModule   :: String
  , tixMixFilePath :: FilePath
  , tixMixEntries  :: [TixMixEntry]
  }

data TixMixEntry = TixMixEntry
  { tixMixEntryStartPos :: (Int, Int)
  , tixMixEntryEndPos   :: (Int, Int)
  , tixMixEntryTicks    :: Integer
  }

generateLcovFromTixMix :: [TixMix] -> LcovReport
generateLcovFromTixMix = uncurry generateLcovFromTix . unzip . map fromTixMix
  where
    fromTixMix TixMix{..} =
      let toMixEntry (TixMixEntry start end _) = MixEntry start end (ExpBox True)
          moduleToMix = mkModuleToMix tixMixModule tixMixFilePath $ map toMixEntry tixMixEntries
          tix = mkTix tixMixModule $ map tixMixEntryTicks tixMixEntries
      in (moduleToMix, tix)

fromReport :: LcovReport -> [(Text, [(Int, Hit)])]
fromReport (LcovReport fileReports) = sortOn fst $ map (fileName &&& getHits) fileReports
  where
    getHits = IntMap.toList . lineHits