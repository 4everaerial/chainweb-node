{-# LANGUAGE BangPatterns #-}
-- |
-- Module: Chainweb.Pact.Utils
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: See LICENSE file
-- Maintainer: Mark Nichols <mark@kadena.io>
-- Stability: experimental
--
-- Pact service for Chainweb

module Chainweb.Pact.Utils
    ( -- * persistence
      toEnv'
    , toEnvPersist'
      -- * combinators
    , aeson
    -- * time-to-live related items
    , maxTTL
    , timingsCheck
    ) where

import Data.Aeson

import Control.Concurrent.MVar

import Pact.Interpreter as P
import Pact.Parse
import Pact.Types.Command
import Pact.Types.ChainMeta

import Chainweb.BlockHeader
import Chainweb.Pact.Backend.Types
import Chainweb.Time
import Chainweb.Transaction

toEnv' :: EnvPersist' -> IO Env'
toEnv' (EnvPersist' ep') = do
    let thePactDb = _pdepPactDb $! ep'
    let theDbEnv = _pdepEnv $! ep'
    env <- mkPactDbEnv thePactDb theDbEnv
    return $! Env' env

toEnvPersist' :: Env' -> IO EnvPersist'
toEnvPersist' (Env' pactDbEnv) = do
    let mVar = pdPactDbVar $! pactDbEnv -- :: MVar (P.DbEnv a)
    !dbEnv <- readMVar $! mVar           -- :: P.DbEnv a
    let pDbEnvPersist = PactDbEnvPersist
          { _pdepPactDb = pdPactDb pactDbEnv -- :: P.PactDb (P.DbEnv a)
          , _pdepEnv = dbEnv
          }
    return $! EnvPersist' pDbEnvPersist

-- | This is the recursion principle of an 'Aeson' 'Result' of type 'a'.
-- Similar to 'either', 'maybe', or 'bool' combinators
--
aeson :: (String -> b) -> (a -> b) -> Result a -> b
aeson f _ (Error a) = f a
aeson _ g (Success a) = g a

-- | The maximum time-to-live (expressed in microseconds)
maxTTL :: ParsedInteger
maxTTL = ParsedInteger $ 2 * 24 * 60 * 60 * 1000000
-- This is probably going to be changed. Let us make it 2 days for now.

timingsCheck :: BlockCreationTime -> Command (Payload PublicMeta ParsedCode) -> Bool
timingsCheck (BlockCreationTime blockOriginationTime) tx =
  -- trace ("block-o-time: " ++ show blockOriginationTime ++ " tx-o-time: " ++ show txOriginationTime ++ " ttl " ++ show ttl) $
  and $
  -- zipWith
  -- (\x y -> trace (show x ++ ": " ++ show y) y)
  -- [1 :: Integer ..]
  [check1,check2,check3,check4,check5,check6]
  where
    (TTLSeconds ttl) = timeToLiveOf tx
    toMicrosFromSeconds = Time . TimeSpan . Micros . fromIntegral . (1000000 *)
    (TxCreationTime txOriginationTime) = creationTimeOf tx
    check1  = ttl > 0
    check2  = blockOriginationTime >= (toMicrosFromSeconds 0)
    check3  = txOriginationTime >= 0
    check4  = toMicrosFromSeconds txOriginationTime < blockOriginationTime
    check5  = toMicrosFromSeconds (txOriginationTime + ttl) >= blockOriginationTime
    check6  = ttl <= maxTTL
