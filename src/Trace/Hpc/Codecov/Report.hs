{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Trace.Hpc.Codecov.Report
  ( CodecovReport(..)
  , FileReport(..)
  , Hit(..)
  ) where

import Data.Aeson (ToJSON(..), object, (.=))
import Data.IntMap (IntMap)
import qualified Data.IntMap as IntMap
import Data.Text (Text)
import qualified Data.Text as Text

newtype CodecovReport = CodecovReport [FileReport]
  deriving (Show, Eq)

instance ToJSON CodecovReport where
  toJSON (CodecovReport fileReports) = object
    [ "coverage" .= objectWith fromReport fileReports
    ]
    where
      objectWith f = object . map f
      fromReport FileReport{..} = fileName .= objectWith fromHit (IntMap.toList lineHits)
      fromHit (lineNum, hit) = Text.pack (show lineNum) .= hit

data FileReport = FileReport
  { fileName :: Text
  , lineHits :: IntMap Hit
  } deriving (Show, Eq)

data Hit
  = Hit Int
  | Partial
      Int -- hit branches
      Int -- total branches
  deriving (Show, Eq)

instance ToJSON Hit where
  toJSON = \case
    Hit count -> toJSON count
    Partial count total -> toJSON $ show count ++ "/" ++ show total
