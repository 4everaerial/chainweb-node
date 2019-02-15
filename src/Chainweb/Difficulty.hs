{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}

{-# OPTIONS_GHC -fno-warn-redundant-constraints #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}

-- |
-- Module: Chainweb.Difficulty
-- Copyright: Copyright © 2018 Kadena LLC
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Difficulty
(
-- * PowHashNat
  PowHashNat(..)
, powHashNat
, encodePowHashNat
, decodePowHashNat

-- * HashTarget
, HashTarget(..)
, showTargetBits
, checkTarget
, maxTarget
, maxTargetWord
, difficultyToTarget
, targetToDifficulty
, encodeHashTarget
, decodeHashTarget

-- * HashDifficulty
, HashDifficulty(..)
, encodeHashDifficulty
, decodeHashDifficulty

-- * Difficulty Adjustment
, BlockRate(..)
, WindowWidth(..)
, adjust

-- * Test Properties
, properties
, prop_littleEndian
) where

import Control.DeepSeq
import Control.Monad

import Data.Int (Int64)
import Data.Ratio ((%))
import Data.Aeson
import Data.Aeson.Types (toJSONKeyText)
import Data.Bits
import Data.Bool (bool)
import Data.Bytes.Get
import Data.Bytes.Put
import qualified Data.ByteString as B
import qualified Data.ByteString.Short as SB
import Data.Coerce
import Data.DoubleWord
import Data.Hashable
import qualified Data.Text as T

import GHC.Generics
import GHC.TypeNats

import Numeric.Natural (Natural)

import Test.QuickCheck (Property, property)

import Text.Printf (printf)

-- internal imports

import Chainweb.Crypto.MerkleLog
import Chainweb.MerkleUniverse
import Chainweb.PowHash
import Chainweb.Time (TimeSpan(..))
import Chainweb.Utils
import Chainweb.Version (ChainwebVersion, usePOW)

import Data.Word.Encoding hiding (properties)

import Numeric.Additive

-- DEBUGGING ---
-- import Control.Monad (when)
-- import Chainweb.ChainId (testChainId)
-- import System.IO (hFlush, stdout)
-- import Text.Printf (printf)

-- -------------------------------------------------------------------------- --
-- Large Word Orphans

instance NFData Word128
instance NFData Word256

-- -------------------------------------------------------------------------- --
-- PowHashNat

-- | A type that maps block hashes to unsigned 256 bit integers by
-- projecting onto the first 8 bytes (least significant in little
-- endian encoding) and interpreting them as little endian encoded
-- unsigned integer value.
--
-- Arithmetic is defined as unsigned bounded integer arithmetic.
-- Overflows result in an exception and may result in program abort.
--
newtype PowHashNat = PowHashNat Word256
    deriving (Show, Generic)
    deriving anyclass (Hashable, NFData)
    deriving newtype (Eq, Ord, Bounded, Enum)
    deriving newtype (Num, Integral, Real, Bits, FiniteBits)
        -- FIXME implement checked arithmetic
        -- FIXME avoid usage of Num and co
    deriving newtype (AdditiveSemigroup, AdditiveAbelianSemigroup)
    -- deriving newtype (MultiplicativeSemigroup, MultiplicativeAbelianSemigroup, MultiplicativeGroup)
        -- FIXME use checked arithmetic instead

powHashNat :: PowHash -> PowHashNat
powHashNat = PowHashNat . powHashToWord256
{-# INLINE powHashNat #-}

powHashToWord256 :: 32 <= PowHashBytesCount => PowHash -> Word256
powHashToWord256 = either error id . runGetS decodeWordLe . SB.fromShort . powHashBytes
{-# INLINE powHashToWord256 #-}

encodePowHashNat :: MonadPut m => PowHashNat -> m ()
encodePowHashNat (PowHashNat n) = encodeWordLe n
{-# INLINE encodePowHashNat #-}

decodePowHashNat :: MonadGet m => m PowHashNat
decodePowHashNat = PowHashNat <$> decodeWordLe
{-# INLINE decodePowHashNat #-}

instance ToJSON PowHashNat where
    toJSON = toJSON . encodeB64UrlNoPaddingText . runPutS . encodePowHashNat
    {-# INLINE toJSON #-}

instance FromJSON PowHashNat where
    parseJSON = withText "PowHashNat" $ either (fail . show) return
        . (runGet decodePowHashNat <=< decodeB64UrlNoPaddingText)
    {-# INLINE parseJSON #-}

instance ToJSONKey PowHashNat where
    toJSONKey = toJSONKeyText
        $ encodeB64UrlNoPaddingText . runPutS . encodePowHashNat
    {-# INLINE toJSONKey #-}

instance FromJSONKey PowHashNat where
    fromJSONKey = FromJSONKeyTextParser $ either (fail . show) return
        . (runGet decodePowHashNat <=< decodeB64UrlNoPaddingText)
    {-# INLINE fromJSONKey #-}

-- -------------------------------------------------------------------------- --
-- HashDifficulty

-- | Hash Difficulty
--
-- difficulty = maxBound / target
--            = network hash rate * block time
--
newtype HashDifficulty = HashDifficulty PowHashNat
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)
    deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey, Hashable, Bounded, Enum)
    deriving newtype (AdditiveSemigroup, AdditiveAbelianSemigroup)
    deriving newtype (Num, Integral, Real)

encodeHashDifficulty :: MonadPut m => HashDifficulty -> m ()
encodeHashDifficulty (HashDifficulty x) = encodePowHashNat x
{-# INLINE encodeHashDifficulty #-}

decodeHashDifficulty :: MonadGet m => m HashDifficulty
decodeHashDifficulty = HashDifficulty <$> decodePowHashNat
{-# INLINE decodeHashDifficulty #-}

-- -------------------------------------------------------------------------- --
-- HashTarget

-- | HashTarget
--
-- target = maxBound / (network hash rate * block time)
--        = maxBound / difficulty
--
-- network hash rate is interpolated from observered past block times.
--
newtype HashTarget = HashTarget PowHashNat
    deriving (Show, Eq, Ord, Generic)
    deriving anyclass (NFData)
    deriving newtype (ToJSON, FromJSON, Hashable, Bounded)

-- | A visualization of a `HashTarget` as binary.
showTargetBits :: HashTarget -> T.Text
showTargetBits (HashTarget (PowHashNat n)) = T.pack . printf "%0256b" $ (int n :: Integer)

-- | By maximum, we mean "easiest". For POW-based chainwebs, this is reduced
-- down from `maxBound` so that the mining of initial blocks doesn't occur too
-- quickly, stressing the system, or otherwise negatively affecting difficulty
-- adjustment with very brief time deltas between blocks.
--
-- Otherwise, chainwebs with "trivial targets" expect this to be `maxBound` and
-- never change. See also `Chainweb.Version.usePOW`.
--
maxTarget :: ChainwebVersion -> HashTarget
maxTarget = HashTarget . PowHashNat . maxTargetWord

-- | A pre-reduction of 9 bits has experimentally been shown to be an
-- equilibrium point for the hash power provided by a single, reasonably
-- performant laptop in early 2019. It is further reduced from 9 to be merciful
-- to CI machines.
--
maxTargetWord :: ChainwebVersion -> Word256
maxTargetWord v = maxBound `div` (2 ^ prereduction v)

-- TODO This should probably dispatch on different values for `TestWithPow` and
-- `TestNet*` specifically.
prereduction :: ChainwebVersion -> Int
prereduction v = bool 0 7 $ usePOW v

instance IsMerkleLogEntry ChainwebHashTag HashTarget where
    type Tag HashTarget = 'HashTargetTag
    toMerkleNode = encodeMerkleInputNode encodeHashTarget
    fromMerkleNode = decodeMerkleInputNode decodeHashTarget
    {-# INLINE toMerkleNode #-}
    {-# INLINE fromMerkleNode #-}

-- | Given the same `ChainwebVersion`, forms an isomorphism with
-- `targetToDifficulty`.
difficultyToTarget :: ChainwebVersion -> HashDifficulty -> HashTarget
difficultyToTarget v (HashDifficulty (PowHashNat difficulty)) =
    HashTarget . PowHashNat $ maxTargetWord v `div` difficulty
{-# INLINE difficultyToTarget #-}

-- | Like `difficultyToTarget`, but accepts a `Rational` that would have been
-- produced by `targetToDifficultyR` and then further manipulated during
-- Difficulty Adjustment.
difficultyToTargetR :: ChainwebVersion -> Rational -> HashTarget
difficultyToTargetR v difficulty =
    HashTarget . PowHashNat $ maxTargetWord v `div` floor difficulty
{-# INLINE difficultyToTargetR #-}

-- | Given the same `ChainwebVersion`, forms an isomorphism with
-- `difficultyToTarget`.
targetToDifficulty :: ChainwebVersion -> HashTarget -> HashDifficulty
targetToDifficulty v (HashTarget (PowHashNat target)) =
    HashDifficulty . PowHashNat $ maxTargetWord v `div` target
{-# INLINE targetToDifficulty #-}

-- | Like `targetToDifficulty`, but yields a `Rational` for lossless
-- calculations in Difficulty Adjustment.
targetToDifficultyR :: ChainwebVersion -> HashTarget -> Rational
targetToDifficultyR v (HashTarget (PowHashNat target)) =
    int (maxTargetWord v) % int target
{-# INLINE targetToDifficultyR #-}

-- | The critical check in Proof-of-Work mining: did the generated hash match
-- the target?
checkTarget :: HashTarget -> PowHash -> Bool
checkTarget (HashTarget target) h = powHashNat h <= target
{-# INLINE checkTarget #-}

encodeHashTarget :: MonadPut m => HashTarget -> m ()
encodeHashTarget = encodePowHashNat . coerce
{-# INLINE encodeHashTarget #-}

decodeHashTarget :: MonadGet m => m HashTarget
decodeHashTarget = HashTarget <$> decodePowHashNat
{-# INLINE decodeHashTarget #-}

-- -------------------------------------------------------------------------- --
-- Difficulty Adjustment

-- | The gap in SECONDS that we desire between the Creation Time of subsequent
-- blocks in some chain.
--
newtype BlockRate = BlockRate Natural

-- | The number of blocks to be mined after a difficulty adjustment, before
-- considering a further adjustment. Critical for the "epoch-based" adjustment
-- algorithm seen in `hashTarget`.
--
newtype WindowWidth = WindowWidth Natural

-- | A new `HashTarget`, based on the rate of mining success over the previous N
-- blocks.
--
-- == Epoch-based Difficulty Adjustment
--
-- This function represents a Bitcoin-inspired, "epoch-based" adjustment
-- algorithm. For every N blocks (as defined by `WindowWidth`), we perform an
-- adjustment.
--
-- === Terminology
--
-- `BlockHeader` stores a 256-bit measure of difficulty: `HashTarget`. More
-- precisely, `HashTarget` is a derivation (seen below) of the `HashDifficulty`.
-- `HashDifficulty` in itself is roughly a measure of the number of hashes
-- necessary to "solve" a block. For non-POW testing scenarios that use trivial
-- targets (i.e. `maxBound`), then difficulty is exactly the number of necessary
-- hashes. For POW mining, this is offset. See `maxTarget`.
--
-- A `HashDifficulty` of 1 is considered the "easiest" difficulty, and
-- represents a `HashTarget` of `maxTarget`. There must never be a difficulty of
-- 0.
--
-- Given the same `Chainweb.Version.ChainwebVersion`, the functions
-- `targetToDifficulty` and `difficultyToTarget` form an isomorphism between the
-- above mentioned types.
--
-- === Justification
--
-- We define the maximum possible hash target (the "easiest" target) as follows:
--
-- \[
-- \begin{align*}
--   \text{MaxBound} &= 2^{256} - 1 \\
--   \text{MaxTarget} &= \frac{\text{MaxBound}}{2^{\text{offset}}}
-- \end{align*}
-- \]
--
-- where /offset/ is some number of bits, 0 for trivial scenarios and some
-- experimentally discovered \(N\) for real POW mining scenarios. For Bitcoin,
-- \(N = 32\).
--
-- Given some difficulty \(D\), its corresponding `HashTarget` can be found by:
--
-- \[
-- \text{Target} = \frac{\text{MaxTarget}}{D}
-- \]
--
-- During adjustment, we seek to solve for some new \(D\). From the above, it
-- follows that the expected number of hashes necessary to "solve" a block
-- becomes:
--
-- \[
-- \text{Expected} = \frac{D * \text{MaxBound}}{\text{MaxTarget}}
-- \]
--
-- If we expect a block to be solved every \(R\) seconds, we find our total
-- Network Hash Rate:
--
-- \[
-- \text{HashRate} = \frac{\text{Expected}}{R}
-- \]
--
-- But, as a block chain is a dynamic system, the real time it took to mine some
-- block would likely not be exactly \(R\). This implies:
--
-- \[
-- \begin{align*}
--   \frac{\text{Expected}}{R} &= \text{HashRate} = \frac{\text{Expected}'}{M} \\
--   \frac{D * \text{MaxBound}}{R * \text{MaxTarget}} &= \text{HashRate} = \frac{D' * \text{MaxBound}}{M * \text{MaxTarget}} \\
--   \frac{D}{R} &= \text{HashRate} = \frac{D'}{M}
-- \end{align*}
-- \]
--
-- where \(D'\) is the known difficulty from the previous block, \(M\) is the
-- average time in seconds it took to calculate the previous \(B\) blocks. The
-- value of \(B\) is assumed to be configurable.
--
-- Given this, our new \(D\) is a simple ratio:
--
-- \[
-- D = \frac{D' * R}{M}
-- \]
--
-- /HashRate/ will of course not stay fixed as the network grows. Luckily, the
-- difference in \(M\) values will naturally correct for this in the calculation
-- of a new \(D\).
--
-- === Precision
--
-- In real systems, the difference between \(M\) and \(R\) may be minute. To
-- ensure that:
--
--   * differences are not lost to integer-math rounding errors
--   * adjustment actually occurs
--   * small, incremental adjustments are allowed to build into greater change over time
--   * `Word256`-based overflows do not occur
--   * the algorithm is simple
--
-- we use the infinite-precision `Rational` type in the calculation of the new
-- \(D\). Only when being converted to a final `HashTarget` is the non-integer
-- precision discarded.
--
-- /Note/: Use of `Rational` is likely not our final solution, and complicates
-- any cross-language spec we would write regarding adjustment algorithm
-- expectations. For now, however, `Rational` is stable for a Haskell-only
-- environment.
--
-- === Adjustment Limits
--
-- Spikes in /HashRate/ may occur as the mining network grows. To ensure that
-- adjustment does not occur too quickly, we cap the total "significant bits of
-- change" as to no more than 3 bits in either the "harder" or "easier" direction
-- at one time. Experimentally, it has been shown than the maximum change should
-- be greater than \(e = 2.71828\cdots\) (/source needed/).
--
adjust :: ChainwebVersion -> WindowWidth -> BlockRate -> TimeSpan Int64 -> HashTarget -> HashTarget
adjust ver (WindowWidth ww) (BlockRate blockRate) (TimeSpan delta) oldTarget
    -- Intent: When increasing the difficulty (thereby lowering the target
    -- toward 0), the leading 1-bit must not move more than 3 bits at a time.
    | newTarget < oldTarget = max newTarget (HashTarget $! oldNat `div` 8)
    -- Intent: Cap the new target back down, if it somehow managed to go over
    -- the maximum. This is possible during POW, since we assume
    -- @maxTarget < maxBound@.
    | newTarget > maxTarget ver = maxTarget ver
    -- Intent: When decreasing the difficulty (thereby raising the target toward
    -- `maxTarget`), ensure that the new target does not increase by more than 3
    -- bits at a time. Using `countLeadingZeros` like this also helps avoid a
    -- `Word256` overflow.
    | countLeadingZeros oldNat - countLeadingZeros (nat newTarget) > 3 = HashTarget $! oldNat * 8
    | otherwise = newTarget

    -- DEBUGGING --
    -- Uncomment the following to get a live view of difficulty adjustment. You
    -- will have to readd a few imports, and also uncomment a few helper
    -- functions below.

    -- when (_blockChainId bh' == testChainId 0) $ do
    --     printf "\n=== CHAIN:%s\n=== HEIGHT:%s\n=== AVG:%f\n=== RATE:%d\n=== OLD DIFF:%f\n=== NEW DIFF:%f\n=== ORIGINAL:%s\n=== ADJUSTED:%s\n=== ACCEPTED:%s\n"
    --         (show $ _blockChainId bh')
    --         (show $ _blockHeight bh')
    --         (floating avg)
    --         blockRate
    --         (floating oldDiff)
    --         (floating newDiff)
    --         (targetBits $ _blockTarget bh')
    --         (targetBits newTarget)
    --         (targetBits actual)
    --     hFlush stdout
  where
    -- The average time in seconds that it took to mine each block in
    -- the given window.
    avg :: Rational
    avg | delta < 0 = error "hashTarget: Impossibly negative delta!"
        | otherwise = (int delta % int ww) / 1000000

    -- The mining difficulty of the previous block (the parent) as a
    -- function of its `HashTarget`.
    oldDiff :: Rational
    oldDiff = targetToDifficultyR ver oldTarget

    -- The adjusted difficulty, following the formula explained in the
    -- docstring of this function.
    newDiff :: Rational
    newDiff = oldDiff * int blockRate / avg

    newTarget :: HashTarget
    newTarget = difficultyToTargetR ver newDiff

    nat :: HashTarget -> PowHashNat
    nat (HashTarget n) = n

    oldNat :: PowHashNat
    oldNat = nat oldTarget

    -- floating :: Rational -> Double
    -- floating = realToFrac

-- -------------------------------------------------------------------------- --
-- Properties

prop_littleEndian :: Bool
prop_littleEndian = all run [1..31]
  where
    run i = (==) i
        $ length
        $ takeWhile (== 0x00)
        $ reverse
        $ B.unpack
        $ runPutS
        $ encodePowHashNat (maxBound `div` 2^(8*i))

properties :: [(String, Property)]
properties =
    [ ("BlockHashNat is encoded as little endian", property prop_littleEndian)
    ]
