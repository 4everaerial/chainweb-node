{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module: Chainweb.TreeDB.Sync
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Colin Woodbury <colin@kadena.io>
-- Stability: experimental
--
-- Sync a local `TreeDb` with that of some peer.
--

module Chainweb.TreeDB.Sync
  ( -- * Syncronizing a Chain
    PeerTree(..)
  , sync
    -- * Utils
  , Depth(..)
  , minHeight
  ) where

import Data.Semigroup (Min(..))

import Numeric.Natural (Natural)

import Streaming

-- internal modules

import Chainweb.BlockHeader (BlockHeader(..), BlockHeight(..))
import Chainweb.TreeDB

-- | Some Rank depth in the past, past which we wouldn't want to sync.
--
newtype Depth = Depth Natural

-- | A wrapper for things which have `TreeDb` instances.
--
newtype PeerTree t = PeerTree { _peerTree :: t } deriving newtype (TreeDb)

-- | Given a peer to connect to, fetch all `BlockHeader`s that exist
-- in the peer's chain but not our local given `TreeDb`, and sync them.
--
sync
    :: (TreeDb local, TreeDb peer, DbEntry local ~ BlockHeader, DbEntry peer ~ BlockHeader)
    => Depth
    -> local
    -> PeerTree peer
    -> IO ()
sync d local peer = do
    h <- maxHeader local
    let m = minHeight (_blockHeight h) d
    void . insertStream local $ entries peer Nothing Nothing (Just m) Nothing

-- | Given a `BlockHeight` that represents the highest rank of some `TreeDb`,
-- find the lowest entry rank such that it's at most only
-- (diameter * 2) in height away.
--
minHeight :: BlockHeight -> Depth -> MinRank
minHeight h (Depth d) = MinRank $ Min m
  where
    m :: Natural
    m = fromIntegral (max (high - low) 0)

    -- | Using `Integer` prevents underflow errors.
    --
    high :: Integer
    high = fromIntegral h

    low :: Integer
    low = fromIntegral $ 2 * d
