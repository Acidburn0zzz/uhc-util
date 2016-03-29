{-# LANGUAGE UndecidableInstances, GeneralizedNewtypeDeriving, ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
#if __GLASGOW_HASKELL__ >= 710
#else
{-# LANGUAGE OverlappingInstances #-}
#endif

module UHC.Util.VarLookup
    ( VarLookup(..)
    , varlookupResolveVarWithMetaLev
    , varlookupResolveVar
    , varlookupResolveValWithMetaLev
    , varlookupResolveVal
    
    , varlookupMap
    
    , VarLookupFix, varlookupFix
    , varlookupFixDel
    
    , VarLookupCmb (..)
    
    , VarLookupBase (..)
    
    , VarLookupCmbFix, varlookupcmbFix
    
    , MetaLev
    , metaLevVal
    
    , StackedVarLookup(..)
    
    )
  where

import Control.Applicative
import Data.Maybe

-- | Level to lookup into
type MetaLev = Int

-- | Base level (of values, usually)
metaLevVal :: MetaLev
metaLevVal = 0

-- | Stacked VarLookup derived from a base one, to allow a use of multiple lookups but update on top only
newtype StackedVarLookup s = StackedVarLookup {unStackedVarLookup :: [s]}
  deriving Foldable

{- |
VarLookup abstracts from a Map.
The purpose is to be able to combine maps only for the purpose of searching without actually merging the maps.
This then avoids the later need to unmerge such mergings.
The class interface serves to hide this.
-}

class VarLookup m k v where
  varlookupWithMetaLev :: MetaLev -> k -> m -> Maybe v
  varlookup :: k -> m -> Maybe v
  -- varlookupValIsVar :: v -> Maybe k

  -- defaults
  varlookup = varlookupWithMetaLev metaLevVal
  -- varlookupValIsVar _ = Nothing

-- | Fully resolve lookup
varlookupResolveVarWithMetaLev :: VarLookup m k v => MetaLev -> (v -> Maybe k) -> k -> m -> Maybe v
varlookupResolveVarWithMetaLev l isVar k m =
  varlookupWithMetaLev l k m >>= \v -> varlookupResolveValWithMetaLev l isVar v m <|> return v

-- | Fully resolve lookup
varlookupResolveVar :: VarLookup m k v => (v -> Maybe k) -> k -> m -> Maybe v
varlookupResolveVar = varlookupResolveVarWithMetaLev metaLevVal
{-# INLINE varlookupResolveVar #-}

varlookupResolveValWithMetaLev :: VarLookup m k v => MetaLev -> (v -> Maybe k) -> v -> m -> Maybe v
varlookupResolveValWithMetaLev l isVar v m = isVar v >>= \k -> varlookupResolveVarWithMetaLev l isVar k m <|> return v

-- | Fully resolve lookup
varlookupResolveVal :: VarLookup m k v => (v -> Maybe k) -> v -> m -> Maybe v
varlookupResolveVal = varlookupResolveValWithMetaLev metaLevVal
{-# INLINE varlookupResolveVal #-}

instance (VarLookup m1 k v,VarLookup m2 k v) => VarLookup (m1,m2) k v where
  varlookupWithMetaLev l k (m1,m2)
    = case varlookupWithMetaLev l k m1 of
        r@(Just _) -> r
        _          -> varlookupWithMetaLev l k m2

{-
instance VarLookup m k v => VarLookup [m] k v where
  varlookupWithMetaLev l k ms = listToMaybe $ catMaybes $ map (varlookupWithMetaLev l k) ms
-}

instance VarLookup m k v => VarLookup (StackedVarLookup m) k v where
  varlookupWithMetaLev l k (StackedVarLookup ms) = listToMaybe $ catMaybes $ map (varlookupWithMetaLev l k) ms

varlookupMap :: VarLookup m k v => (v -> Maybe res) -> k -> m -> Maybe res
varlookupMap get k m
  = do { v <- varlookup k m
       ; get v
       }

type VarLookupFix k v = k -> Maybe v

-- | fix looking up to be for a certain var mapping
varlookupFix :: VarLookup m k v => m -> VarLookupFix k v
varlookupFix m = \k -> varlookup k m

-- | simulate deletion
varlookupFixDel :: Ord k => [k] -> VarLookupFix k v -> VarLookupFix k v
varlookupFixDel ks f = \k -> if k `elem` ks then Nothing else f k

{- |
VarLookupCmb abstracts the 'combining' of/from a substitution.
The interface goes along with VarLookup but is split off to avoid functional dependency restrictions.
The purpose is to be able to combine maps only for the purpose of searching without actually merging the maps.
This then avoids the later need to unmerge such mergings.
-}

infixr 7 |+>

class VarLookupCmb m1 m2 where
  (|+>) :: m1 -> m2 -> m2

{-
#if __GLASGOW_HASKELL__ >= 710
instance {-# OVERLAPPING #-}
#else
instance
#endif
  VarLookupCmb m1 m2 => VarLookupCmb m1 [m2] where
    m1 |+> (m2:m2s) = (m1 |+> m2) : m2s
-}

instance
  VarLookupCmb m1 m2 => VarLookupCmb m1 (StackedVarLookup m2) where
    m1 |+> StackedVarLookup (m2:m2s) = StackedVarLookup $ (m1 |+> m2) : m2s

{-
#if __GLASGOW_HASKELL__ >= 710
instance {-# OVERLAPPING #-}
#else
instance
#endif
  (VarLookupCmb m1 m1, VarLookupCmb m1 m2) => VarLookupCmb [m1] [m2] where
    m1 |+> (m2:m2s) = (foldr1 (|+>) m1 |+> m2) : m2s
-}

{-
instance
  (VarLookupCmb m1 m1, VarLookupCmb m1 m2) => VarLookupCmb (StackedVarLookup m1) (StackedVarLookup m2) where
    m1 |+> StackedVarLookup (m2:m2s) = StackedVarLookup $ (foldr1 (|+>) m1 |+> m2) : m2s
-}

class VarLookupBase m k v | m -> k v where
  varlookupEmpty :: m
  -- varlookupTyUnit :: k -> v -> m

instance VarLookupBase m k v => VarLookupBase (StackedVarLookup m) k v where
  varlookupEmpty = StackedVarLookup [varlookupEmpty]

type VarLookupCmbFix m1 m2 = m1 -> m2 -> m2

-- | fix combining up to be for a certain var mapping
varlookupcmbFix :: VarLookupCmb m1 m2 => VarLookupCmbFix m1 m2
varlookupcmbFix m1 m2 = m1 |+> m2

