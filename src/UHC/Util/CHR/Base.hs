{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, FunctionalDependencies, UndecidableInstances, ExistentialQuantification, ScopedTypeVariables, StandaloneDeriving, GeneralizedNewtypeDeriving, TemplateHaskell, NoMonomorphismRestriction #-}

-------------------------------------------------------------------------------------------
--- Constraint Handling Rules
-------------------------------------------------------------------------------------------

{- |
Derived from work by Gerrit vd Geest, but with searching structures for predicates
to avoid explosion of search space during resolution.
-}

module UHC.Util.CHR.Base
  ( IsConstraint(..)
  , ConstraintSolvesVia(..)

  , IsCHRConstraint(..)
  -- , CHRConstraint(..)
  
  , IsCHRGuard(..)
  -- , CHRGuard(..)
  
  -- , IsCHRBuiltin(..)
  -- , CHRBuiltin(..)
  
  , IsCHRPrio(..)
  -- , CHRPrio(..)
  
  , IsCHRBacktrackPrio(..)
  
  , CHREmptySubstitution(..)
  
  , CHRMatcherFailure(..)
  
  , CHRMatcher
  , chrmatcherRun'
  , chrmatcherRun
  -- , chrmatcherLift
  -- , chrmatcherUnlift
  
  , chrmatcherstateEnv
  , chrmatcherstateVarLookup
  
  , chrMatchSubst
  , chrMatchBind
  , chrMatchFail
  , chrMatchFailNoBinding
  , chrMatchSuccess
  , chrMatchWait
  , chrMatchSucces
  -- , chrMatchVarUpd
  
  , CHRMatchEnv(..)
  , emptyCHRMatchEnv
  
  , CHRMatchable(..)
  , CHRMatchableKey
  , CHRMatchHow(..)
  , chrMatchAndWaitToM
  
  , CHRWaitForVarSet
  
  , CHRCheckable(..)
  
  , Prio(..)
  , CHRPrioEvaluatable(..)
  , CHRPrioEvaluatableVal
  
  -- , CHRBuiltinSolvable(..)
  
  , CHRTrOpt(..)
  )
  where

-- import qualified UHC.Util.TreeTrie as TreeTrie
import           UHC.Util.VarMp
import           Data.Word
import           Data.Monoid
import           Data.Typeable
import           Data.Function
import           Unsafe.Coerce
import qualified Data.Set as Set
import           UHC.Util.Pretty
import           UHC.Util.CHR.Key
import           Control.Monad
import           Control.Monad.State.Strict
import           Control.Monad.Except
import           Control.Monad.Identity
import           UHC.Util.Lens
import           UHC.Util.Utils
import           UHC.Util.Binary
import           UHC.Util.Serialize
import           UHC.Util.Substitutable

import           UHC.Util.Debug

-------------------------------------------------------------------------------------------
--- CHRCheckable
-------------------------------------------------------------------------------------------

-- | A Checkable participates in the reduction process as a guard, to be checked.
-- Checking is allowed to find/return substitutions for meta variables (not for global variables).
class (CHREmptySubstitution subst, VarLookupCmb subst subst) => CHRCheckable env x subst where
  chrCheck :: env -> subst -> x -> Maybe subst
  chrCheck e s x = chrmatcherUnlift (chrCheckM e x) emptyCHRMatchEnv s

  chrCheckM :: env -> x -> CHRMatcher subst ()
  chrCheckM e x = chrmatcherLift $ \sg -> chrCheck e sg x

-------------------------------------------------------------------------------------------
--- CHRPrioEvaluatable
-------------------------------------------------------------------------------------------

-- | The type of value a prio representation evaluates to, must be Ord instance
type family CHRPrioEvaluatableVal p :: *

-- | A PrioEvaluatable participates in the reduction process to indicate the rule priority, higher prio takes precedence
class (Ord (CHRPrioEvaluatableVal x), Bounded (CHRPrioEvaluatableVal x)) => CHRPrioEvaluatable env x subst | x -> env subst where
  -- | Reduce to a prio representation
  chrPrioEval :: env -> subst -> x -> CHRPrioEvaluatableVal x
  chrPrioEval _ _ _ = minBound

  -- | Compare priorities
  chrPrioCompare :: env -> (subst,x) -> (subst,x) -> Ordering
  chrPrioCompare e (s1,x1) (s2,x2) = chrPrioEval e s1 x1 `compare` chrPrioEval e s2 x2
  
  -- | Lift prio val into prio
  chrPrioLift :: CHRPrioEvaluatableVal x -> x

-------------------------------------------------------------------------------------------
--- Prio
-------------------------------------------------------------------------------------------

-- | Separate priority type, where minBound represents lowest prio, and compare sorts from high to low prio (i.e. high `compare` low == LT)
newtype Prio = Prio {unPrio :: Word32}
  deriving (Eq, Bounded, Num, Enum, Integral, Real)

instance Ord Prio where
  compare = flip compare `on` unPrio
  {-# INLINE compare #-}
  
-------------------------------------------------------------------------------------------
--- Constraint, Guard, & Prio API
-------------------------------------------------------------------------------------------

-- | (Class alias) API for constraint requirements
class ( CHRMatchable env c subst
      -- , CHRBuiltinSolvable env c subst
      , VarExtractable c
      , VarUpdatable c subst
      , Typeable c
      , Serialize c
      , TTKeyable c
      , IsConstraint c
      , Ord c, Ord (TTKey c)
      , PP c, PP (TTKey c)
      ) => IsCHRConstraint env c subst

-- | (Class alias) API for guard requirements
class ( CHRCheckable env g subst
      , VarExtractable g
      , VarUpdatable g subst
      , Typeable g
      , Serialize g
      , PP g
      ) => IsCHRGuard env g subst

{-
-- | (Class alias) API for builtin solvable requirements
class ( CHRBuiltinSolvable env b subst
      , Typeable b
      , Serialize b
      , PP b
      ) => IsCHRBuiltin env b subst

instance {-# OVERLAPPABLE #-} (CHREmptySubstitution subst, VarLookupCmb subst subst) => IsCHRBuiltin env () subst
-}

-- | (Class alias) API for priority requirements
class ( CHRPrioEvaluatable env p subst
      , Typeable p
      , Serialize p
      , PP p
      ) => IsCHRPrio env p subst

-- instance {-# OVERLAPPABLE #-} IsCHRPrio env () subst

-- | (Class alias) API for backtrack priority requirements
class ( IsCHRPrio env bp subst
      , CHRMatchable env bp subst
      , PP (CHRPrioEvaluatableVal bp)
      -- , Num (CHRPrioEvaluatableVal bp)
      ) => IsCHRBacktrackPrio env bp subst

-- instance {-# OVERLAPPABLE #-} (CHREmptySubstitution subst, VarLookupCmb subst subst) => IsCHRBacktrackPrio env () subst

-------------------------------------------------------------------------------------------
--- What a constraint must be capable of
-------------------------------------------------------------------------------------------

-- | Different ways of solving
data ConstraintSolvesVia
  = ConstraintSolvesVia_Rule        -- ^ rewrite/CHR rules apply
  | ConstraintSolvesVia_Solve       -- ^ solving involving finding of variable bindings (e.g. unification)
  | ConstraintSolvesVia_Residual    -- ^ a leftover, residue
  | ConstraintSolvesVia_Fail        -- ^ triggers explicit fail
  | ConstraintSolvesVia_Succeed     -- ^ triggers explicit succes
  deriving (Show, Enum, Eq, Ord)

instance PP ConstraintSolvesVia where
  pp = pp . show

-- | The things a constraints needs to be capable of in order to participate in solving
class IsConstraint c where
  -- | Requires solving? Or is just a residue...
  cnstrRequiresSolve :: c -> Bool
  cnstrRequiresSolve c = case cnstrSolvesVia c of
    ConstraintSolvesVia_Residual -> False
    _                            -> True
  
  cnstrSolvesVia :: c -> ConstraintSolvesVia
  cnstrSolvesVia c | cnstrRequiresSolve c = ConstraintSolvesVia_Rule
                   | otherwise            = ConstraintSolvesVia_Residual

-------------------------------------------------------------------------------------------
--- Tracing options, specific for CHR solvers
-------------------------------------------------------------------------------------------

data CHRTrOpt
  = CHRTrOpt_Lookup     -- ^ trie query
  | CHRTrOpt_Stats      -- ^ various stats
  deriving (Eq, Ord, Show)
-------------------------------------------------------------------------------------------
--- CHREmptySubstitution
-------------------------------------------------------------------------------------------

-- | Capability to yield an empty substitution.
class CHREmptySubstitution subst where
  chrEmptySubst :: subst

-------------------------------------------------------------------------------------------
--- CHRMatchEnv
-------------------------------------------------------------------------------------------

-- | How to match, increasingly more binding is allowed
data CHRMatchHow
  = CHRMatchHow_Check               -- ^ equality check only
  | CHRMatchHow_Match               -- ^ also allow one-directional (left to right) matching/binding of (meta)vars
  | CHRMatchHow_MatchAndWait        -- ^ also allow giving back of global vars on which we wait
  | CHRMatchHow_Unify               -- ^ also allow bi-directional matching, i.e. unification
  deriving (Ord, Eq)

-- | Context/environment required for matching itself
data CHRMatchEnv k
  = CHRMatchEnv
      { {- chrmatchenvHow          :: !CHRMatchHow
      , -} 
        chrmatchenvMetaMayBind  :: !(k -> Bool)
      }

emptyCHRMatchEnv :: CHRMatchEnv x
emptyCHRMatchEnv = CHRMatchEnv {- CHRMatchHow_Check -} (const True)

-------------------------------------------------------------------------------------------
--- Wait for var
-------------------------------------------------------------------------------------------

type CHRWaitForVarSet s = Set.Set (SubstVarKey s)

-------------------------------------------------------------------------------------------
--- CHRMatcher, call back API used during matching
-------------------------------------------------------------------------------------------

{-
data CHRMatcherState subst k
  = CHRMatcherState
      { _chrmatcherstateVarLookup       :: !(StackedVarLookup subst)
      , _chrmatcherstateWaitForVarSet   :: !(CHRWaitForVarSet subst)
      , _chrmatcherstateEnv             :: !(CHRMatchEnv k)
      }
  deriving Typeable
-}
type CHRMatcherState subst k = (StackedVarLookup subst, CHRWaitForVarSet subst, CHRMatchEnv k)

mkCHRMatcherState :: StackedVarLookup subst -> CHRWaitForVarSet subst -> CHRMatchEnv k -> CHRMatcherState subst k
mkCHRMatcherState s w e = (s, w, e)
{-# INLINE mkCHRMatcherState #-}

unCHRMatcherState :: CHRMatcherState subst k -> (StackedVarLookup subst, CHRWaitForVarSet subst, CHRMatchEnv k)
unCHRMatcherState = id
{-# INLINE unCHRMatcherState #-}

-- | Failure of CHRMatcher
data CHRMatcherFailure
  = CHRMatcherFailure
  | CHRMatcherFailure_NoBinding         -- ^ absence of binding

-- | Matching monad, keeping a stacked (pair) of subst (local + global), and a set of global variables upon which the solver has to wait in order to (possibly) match further/again
-- type CHRMatcher subst = StateT (StackedVarLookup subst, CHRWaitForVarSet subst) (Either ())
type CHRMatcher subst = StateT (CHRMatcherState subst (SubstVarKey subst)) (Either CHRMatcherFailure)

chrmatcherstateVarLookup     = fst3l
chrmatcherstateWaitForVarSet = snd3l
chrmatcherstateEnv           = trd3l

-------------------------------------------------------------------------------------------
--- CHRMatchable
-------------------------------------------------------------------------------------------

-- | The key of a substitution
type family CHRMatchableKey subst :: *

type instance CHRMatchableKey (StackedVarLookup subst) = CHRMatchableKey subst

-- | A Matchable participates in the reduction process as a reducable constraint.
-- Unification may be incorporated as well, allowing matching to be expressed in terms of unification.
-- This facilitates implementations of 'CHRBuiltinSolvable'.
class (CHREmptySubstitution subst, VarLookupCmb subst subst, VarExtractable x, SubstVarKey subst ~ ExtrValVarKey x) => CHRMatchable env x subst where
  -- | One-directional (1st to 2nd 'x') unify
  chrMatchTo :: env -> subst -> x -> x -> Maybe subst
  chrMatchTo env s x1 x2 = chrUnify CHRMatchHow_Match (emptyCHRMatchEnv {chrmatchenvMetaMayBind = (`Set.member` varFreeSet x1)}) env s x1 x2
    -- where free = varFreeSet x1
  
  -- | One-directional (1st to 2nd 'x') unify
  chrUnify :: CHRMatchHow -> CHRMatchEnv (SubstVarKey subst) -> env -> subst -> x -> x -> Maybe subst
  chrUnify how menv e s x1 x2 = chrmatcherUnlift (chrUnifyM how e x1 x2) menv s
  
  -- | Match one-directional (from 1st to 2nd arg), under a subst, yielding a subst for the metavars in the 1st arg, waiting for those in the 2nd
  chrMatchToM :: env -> x -> x -> CHRMatcher subst ()
  chrMatchToM e x1 x2 = chrUnifyM CHRMatchHow_Match e x1 x2

  -- | Unify bi-directional or match one-directional (from 1st to 2nd arg), under a subst, yielding a subst for the metavars in the 1st arg, waiting for those in the 2nd
  chrUnifyM :: CHRMatchHow -> env -> x -> x -> CHRMatcher subst ()
  chrUnifyM how e x1 x2 = getl chrmatcherstateEnv >>= \menv -> chrmatcherLift $ \sg -> chrUnify how menv e sg x1 x2

{-
  -- | Solve a constraint which is categorized as 'ConstraintSolvesVia_Solve'
  chrBuiltinSolve :: env -> subst -> x -> Maybe subst
  chrBuiltinSolve e s x = getl chrmatcherstateEnv >>= \menv -> chrmatcherUnlift (chrBuiltinSolveM e x) menv s
-}

  -- | Solve a constraint which is categorized as 'ConstraintSolvesVia_Solve'
  chrBuiltinSolveM :: env -> x -> CHRMatcher subst ()
  chrBuiltinSolveM e x = return () -- chrmatcherLift $ \sg -> chrBuiltinSolve e sg x

-------------------------------------------------------------------------------------------
--- CHRMatcher API, part I
-------------------------------------------------------------------------------------------

-- | Unlift/observe (or run) a CHRMatcher
chrmatcherUnlift :: (CHREmptySubstitution subst) => CHRMatcher subst () -> CHRMatchEnv (SubstVarKey subst) -> (subst -> Maybe subst)
chrmatcherUnlift mtch menv s = do
    (s,w) <- chrmatcherRun mtch menv s
    if Set.null w then Just s else Nothing

-- | Lift into CHRMatcher
chrmatcherLift :: (VarLookupCmb subst subst) => (subst -> Maybe subst) -> CHRMatcher subst ()
chrmatcherLift f = do
    [sl,sg] <- fmap unStackedVarLookup $ getl chrmatcherstateVarLookup -- gets (unStackedVarLookup . _chrmatcherstateVarLookup)
    maybe chrMatchFail (\snew -> chrmatcherstateVarLookup =$: (snew |+>)) $ f sg
    
{-
chrmatcherLift f = do
    -- [sl,sg] <- gets (unStackedVarLookup . _chrmatcherstateVarLookup)
    [sl,sg] <- undefined -- gets (unStackedVarLookup . _chrmatcherstateVarLookup)
    maybe (throwError ()) (undefined) $ f sg
    -- maybe (throwError ()) (\snew -> modify (\st -> st {_chrmatcherstateVarLookup = snew |+> _chrmatcherstateVarLookup st})) $ f sg
    -- maybe (throwError ()) (\snew -> modify (\(s,w) -> (snew |+> s,w))) $ f sg
-}

-- | Run a CHRMatcher
chrmatcherRun' :: (CHREmptySubstitution subst) => (CHRMatcherFailure -> r) -> (subst -> CHRWaitForVarSet subst -> x -> r) -> CHRMatcher subst x -> CHRMatchEnv (SubstVarKey subst) -> StackedVarLookup subst -> r
chrmatcherRun' fail succes mtch menv s = either
    fail
    ((\(x,ms) -> let (StackedVarLookup s, w, _) = unCHRMatcherState ms in succes (head s) w x))
      $ flip runStateT (mkCHRMatcherState s Set.empty menv)
      $ mtch

-- | Run a CHRMatcher
chrmatcherRun :: (CHREmptySubstitution subst) => CHRMatcher subst () -> CHRMatchEnv (SubstVarKey subst) -> subst -> Maybe (subst, CHRWaitForVarSet subst)
chrmatcherRun mtch menv s = chrmatcherRun' (const Nothing) (\s w _ -> Just (s,w)) mtch menv (StackedVarLookup [chrEmptySubst,s])

{-
  either
    (const Nothing)
    ((\(StackedVarLookup [s,_], w, _) -> Just (s,w)) . unCHRMatcherState)
    -- (\(CHRMatcherState {_chrmatcherstateVarLookup = StackedVarLookup [s,_], _chrmatcherstateWaitForVarSet = w}) -> Just (s,w))
      $ flip execStateT (mkCHRMatcherState (StackedVarLookup [chrEmptySubst,s]) Set.empty menv)
      $ mtch
-}

-------------------------------------------------------------------------------------------
--- Lens construction
-------------------------------------------------------------------------------------------

-- mkLabel ''CHRMatcherState


-------------------------------------------------------------------------------------------
--- CHRMatcher API, part II
-------------------------------------------------------------------------------------------

chrMatchSubst :: CHRMatcher subst (StackedVarLookup subst)
chrMatchSubst = getl chrmatcherstateVarLookup
{-# INLINE chrMatchSubst #-}

chrMatchBind :: forall subst k v . (VarLookupCmb subst subst, SubstMake subst, k ~ SubstVarKey subst, v ~ SubstVarVal subst) => CHRMatchEnv k -> k -> v -> CHRMatcher subst ()
chrMatchBind menv k v = chrmatcherstateVarLookup =$: ((substSingleton k v :: subst) |+>)
{-
chrMatchBind menv k v = do
    menv <- getl chrmatcherstateEnv
    if chrmatchenvMetaMayBind menv k
      then chrmatcherstateVarLookup =$: ((substSingleton k v :: subst) |+>) -- modify (\(s,w,e) -> ((substSingleton k v :: subst) |+> s,w,e))
      else return ()
-}
{-
chrMatchBind menv k v
  | chrmatchenvMetaMayBind menv k = modify (\(s,w,e) -> ((substSingleton k v :: subst) |+> s,w,e))
  | otherwise                     = return ()
-}

chrMatchWait :: (Ord k, k ~ SubstVarKey subst) => k -> CHRMatcher subst ()
chrMatchWait k = chrMatchModifyWait (Set.insert k)
{-# INLINE chrMatchWait #-}

chrMatchSuccess :: CHRMatcher subst ()
chrMatchSuccess = return ()
{-# INLINE chrMatchSuccess #-}

-- | Normal CHRMatcher failure
chrMatchFail :: CHRMatcher subst a
chrMatchFail = throwError CHRMatcherFailure
{-# INLINE chrMatchFail #-}

-- | CHRMatcher failure because a variable binding is missing
chrMatchFailNoBinding :: CHRMatcher subst a
chrMatchFailNoBinding = throwError CHRMatcherFailure_NoBinding
{-# INLINE chrMatchFailNoBinding #-}

chrMatchSucces :: CHRMatcher subst ()
chrMatchSucces = return ()
{-# INLINE chrMatchSucces #-}

chrMatchModifyWait :: (CHRWaitForVarSet subst -> CHRWaitForVarSet subst) -> CHRMatcher subst ()
chrMatchModifyWait f =
  -- modify (\st -> st {_chrmatcherstateWaitForVarSet = f $ _chrmatcherstateWaitForVarSet st})
  -- (chrmatcherstateWaitForVarSet =$:)
  modify (\(s,w,e) -> (s, f w, e))
{-# INLINE chrMatchModifyWait #-}

-- | Match one-directional (from 1st to 2nd arg), under a subst, yielding a subst for the metavars in the 1st arg, waiting for those in the 2nd
chrMatchAndWaitToM :: CHRMatchable env x subst => Bool -> env -> x -> x -> CHRMatcher subst ()
chrMatchAndWaitToM wait env x1 x2 = chrUnifyM (if wait then CHRMatchHow_MatchAndWait else CHRMatchHow_Match) env x1 x2

-------------------------------------------------------------------------------------------
--- CHRMatchable: instances
-------------------------------------------------------------------------------------------

-- TBD: move to other file...
instance {-# OVERLAPPABLE #-} Ord (ExtrValVarKey ()) => VarExtractable () where
  varFreeSet _ = Set.empty

instance {-# OVERLAPPABLE #-} (Ord (ExtrValVarKey ()), CHREmptySubstitution subst, VarLookupCmb subst subst, SubstVarKey subst ~ ExtrValVarKey ()) => CHRMatchable env () subst where
  chrUnifyM _ _ _ _ = chrMatchFail

-------------------------------------------------------------------------------------------
--- Prio: instances
-------------------------------------------------------------------------------------------

instance Show Prio where
  show = show . unPrio

instance PP Prio where
  pp = pp . unPrio

-------------------------------------------------------------------------------------------
--- CHRPrioEvaluatable: instances
-------------------------------------------------------------------------------------------

type instance CHRPrioEvaluatableVal () = Prio

{-
instance {-# OVERLAPPABLE #-} Ord x => CHRPrioEvaluatable env x subst where
  -- chrPrioEval _ _ _ = minBound
  chrPrioCompare _ (_,x) (_,y) = compare x y
-}

{-
instance {-# OVERLAPPABLE #-} CHRPrioEvaluatable env () subst where
  chrPrioLift _ = ()
  chrPrioEval _ _ _ = minBound
  chrPrioCompare _ _ _ = EQ
-}


