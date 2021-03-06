{-# LANGUAGE ScopedTypeVariables, StandaloneDeriving, UndecidableInstances, NoMonomorphismRestriction, MultiParamTypeClasses, TemplateHaskell, FunctionalDependencies #-}

-------------------------------------------------------------------------------------------
--- CHR solver
-------------------------------------------------------------------------------------------

{-|
Under development (as of 20160218).

Solver is:
- Monomorphic, i.e. the solver is polymorph but therefore can only work on 1 type of constraints, rules, etc.
- Knows about variables for which substitutions can be found, substitutions are part of found solutions.
- Backtracking (on variable bindings/substitutions), multiple solution alternatives are explored.
- Found rules are applied in an order described by priorities associated with rules. Priorities can be dynamic, i.e. depend on terms in rules.

See

"A Flexible Search Framework for CHR", Leslie De Koninck, Tom Schrijvers, and Bart Demoen.
http://link.springer.com/10.1007/978-3-540-92243-8_2
-}

module UHC.Util.CHR.Solve.TreeTrie.MonoBacktrackPrio
  ( Verbosity(..)

  , CHRGlobState(..)
  , emptyCHRGlobState
  , chrgstVarToNmMp
  
  , CHRBackState(..)
  , emptyCHRBackState
  
  , emptyCHRStore
  
  , CHRMonoBacktrackPrioT
  , MonoBacktrackPrio
  , runCHRMonoBacktrackPrioT
  
  , addRule
  -- , addRule2
  
  , addConstraintAsWork
  
  , SolverResult(..)
  , ppSolverResult
  
  , CHRSolveOpts(..)
  , defaultCHRSolveOpts
  
  , StoredCHR
  , storedChrRule'
  
  , chrSolve
  
  , slvFreshSubst
  
  , getSolveTrace
  
{-
  ( CHRStore
  , emptyCHRStore
  
  , chrStoreFromElems
  , chrStoreUnion
  , chrStoreUnions
  , chrStoreSingletonElem
  , chrStoreToList
  , chrStoreElems
  
  , ppCHRStore
  , ppCHRStore'
  
  , SolveStep'(..)
  , SolveStep
  , SolveTrace
  , ppSolveTrace
  
  , SolveState
  , emptySolveState
  , solveStateResetDone
  , chrSolveStateDoneConstraints
  , chrSolveStateTrace
-}
  
  , IsCHRSolvable(..)
{-
  , chrSolve'
  , chrSolve''
  , chrSolveM
  )
-}
  )
  where

import           UHC.Util.CHR.Base
-- import           UHC.Util.CHR.Key
import           UHC.Util.CHR.Rule
import           UHC.Util.CHR.Solve.TreeTrie.Internal.Shared
import           UHC.Util.Substitutable
import           UHC.Util.VarLookup
import           UHC.Util.Lookup                                (Lookup, LookupApply, Scoped)
import qualified UHC.Util.Lookup                                as Lk
import           UHC.Util.VarMp
import           UHC.Util.AssocL
import           UHC.Util.Lens
import           UHC.Util.Fresh
-- import           UHC.Util.TreeTrie                              as TreeTrie
import qualified UHC.Util.TreeTrie2                             as TT2
import qualified Data.Set                                       as Set
import qualified Data.PQueue.Prio.Min                           as Que
import qualified Data.Map                                       as Map
import qualified Data.IntMap.Strict                             as IntMap
import qualified Data.IntSet                                    as IntSet
import qualified Data.Sequence                                  as Seq
import           Data.List                                      as List
import           Data.Typeable
import           Data.Maybe
import           UHC.Util.Pretty                                as Pretty
import           UHC.Util.Serialize
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           UHC.Util.Utils
import           UHC.Util.Lens
import           Control.Monad.LogicState

import           UHC.Util.Debug

-------------------------------------------------------------------------------------------
--- Verbosity
-------------------------------------------------------------------------------------------

data Verbosity
  = Verbosity_Quiet         -- default
  | Verbosity_Normal
  | Verbosity_ALot
  deriving (Eq, Ord, Show, Enum, Typeable)

-------------------------------------------------------------------------------------------
--- A CHR as stored
-------------------------------------------------------------------------------------------

-- | Index into table of CHR's, allowing for indirection required for sharing of rules by search for different constraints in the head
type CHRInx = Int

-- | Index into rule and head constraint
data CHRConstraintInx =
  CHRConstraintInx -- {-# UNPACK #-}
    { chrciInx :: !CHRInx
    , chrciAt  :: !Int
    }
  deriving (Eq, Ord, Show)

instance PP CHRConstraintInx where
  pp (CHRConstraintInx i j) = i >|< "." >|< j

-- | A CHR as stored in a CHRStore, requiring additional info for efficiency
data StoredCHR c g bp p
  = StoredCHR
      { _storedHeadKeys  :: ![CHRKey2 c]                        -- ^ the keys corresponding to the head of the rule
      , _storedChrRule   :: !(Rule c g bp p)                          -- ^ the rule
      , _storedChrInx    :: !CHRInx                                -- ^ index of constraint for which is keyed into store
      -- , storedKeys      :: ![Maybe (CHRKey c)]                  -- ^ keys of all constraints; at storedChrInx: Nothing
      -- , storedIdent     :: !(UsedByKey c)                       -- ^ the identification of a CHR, used for propagation rules (see remark at begin)
      }
  deriving (Typeable)
  
storedChrRule' :: StoredCHR c g bp p -> Rule c g bp p
storedChrRule' = _storedChrRule

-- type instance TTKey (StoredCHR c g bp p) = TTKey c

{-
instance (TTKeyable (Rule c g bp p)) => TTKeyable (StoredCHR c g bp p) where
  toTTKey' o schr = toTTKey' o $ storedChrRule schr

-- | The size of the simplification part of a CHR
storedSimpSz :: StoredCHR c g bp p -> Int
storedSimpSz = ruleSimpSz . storedChrRule
{-# INLINE storedSimpSz #-}
-}

-- | A CHR store is a trie structure
data CHRStore cnstr guard bprio prio
  = CHRStore
      { _chrstoreTrie    :: TT2.TreeTrie (TT2.TrTrKey cnstr) [CHRConstraintInx]                       -- ^ map from the search key of a rule to the index into tabl
      , _chrstoreTable   :: IntMap.IntMap (StoredCHR cnstr guard bprio prio)      -- ^ (possibly multiple) rules for a key
      }
  deriving (Typeable)

emptyCHRStore :: CHRStore cnstr guard bprio prio
emptyCHRStore = CHRStore TT2.empty IntMap.empty

-------------------------------------------------------------------------------------------
--- Store holding work, split up in global and backtrackable part
-------------------------------------------------------------------------------------------

type WorkInx = WorkTime

type WorkInxSet = IntSet.IntSet

data WorkStore cnstr
  = WorkStore
      { _wkstoreTrie     :: TT2.TreeTrie (TT2.TrTrKey cnstr) [WorkInx]                -- ^ map from the search key of a constraint to index in table
      , _wkstoreTable    :: IntMap.IntMap (Work2 cnstr)      -- ^ all the work ever entered
      }
  deriving (Typeable)

emptyWorkStore :: WorkStore cnstr
emptyWorkStore = WorkStore TT2.empty IntMap.empty

data WorkQueue
  = WorkQueue
      { _wkqueueActive          :: !WorkInxSet                  -- ^ active queue, work will be taken off from this one
      , _wkqueueRedo            :: !WorkInxSet                  -- ^ redo queue, holding work which could not immediately be reduced, but later on might be
      , _wkqueueDidSomething    :: !Bool                        -- ^ flag indicating some work was done; if False and active queue is empty we stop solving
      }
  deriving (Typeable)

emptyWorkQueue :: WorkQueue
emptyWorkQueue = WorkQueue IntSet.empty IntSet.empty True

-------------------------------------------------------------------------------------------
--- A matched combi of chr and work
-------------------------------------------------------------------------------------------

-- | Already matched combi of chr and work
data MatchedCombi' c w =
  MatchedCombi
    { mcCHR      :: !c              -- ^ the CHR
    , mcWork     :: ![w]            -- ^ the work matched for this CHR
    }
  deriving (Eq, Ord)

instance Show (MatchedCombi' c w) where
  show _ = "MatchedCombi"

instance (PP c, PP w) => PP (MatchedCombi' c w) where
  pp (MatchedCombi c ws) = ppParensCommas [pp c, ppBracketsCommas ws]

type MatchedCombi = MatchedCombi' CHRInx WorkInx

-------------------------------------------------------------------------------------------
--- Solver reduction step
-------------------------------------------------------------------------------------------

-- | Description of 1 chr reduction step taken by the solver
data SolverReductionStep' c w
  = SolverReductionStep
      { slvredMatchedCombi        :: !(MatchedCombi' c w)
      , slvredChosenBodyAltInx    :: !Int
      , slvredNewWork             :: !(Map.Map ConstraintSolvesVia [w])
      }
  | SolverReductionDBG PP_Doc

type SolverReductionStep = SolverReductionStep' CHRInx WorkInx

instance Show (SolverReductionStep' c w) where
  show _ = "SolverReductionStep"

instance {-# OVERLAPPABLE #-} (PP c, PP w) => PP (SolverReductionStep' c w) where
  pp (SolverReductionStep (MatchedCombi ci ws) a wns) = "STEP" >#< ci >|< "." >|< a >-< indent 2 ("+" >#< ppBracketsCommas ws >-< "-> (new)" >#< (ppAssocL $ Map.toList $ Map.map ppBracketsCommas wns)) -- (ppBracketsCommas wns >-< ppBracketsCommas wnbs)
  pp (SolverReductionDBG p) = "DBG" >#< p

instance (PP w) => PP (SolverReductionStep' Int w) where
  pp (SolverReductionStep (MatchedCombi ci ws) a wns) = ci >|< "." >|< a >#< "+" >#< ppBracketsCommas ws >#< "-> (new)" >#< (ppAssocL $ Map.toList $ Map.map ppBracketsCommas wns) -- (ppBracketsCommas wns >-< ppBracketsCommas wnbs)
  pp (SolverReductionDBG p) = "DBG" >#< p

-------------------------------------------------------------------------------------------
--- Waiting (for var resolution) work
-------------------------------------------------------------------------------------------

-- | Admin for waiting work
data WaitForVar s
  = WaitForVar
      { _waitForVarVars      :: CHRWaitForVarSet s
      , _waitForVarWorkInx   :: WorkInx
      }
  deriving (Typeable)

-- | Index into collection of 'WaitForVar'
type WaitInx = Int

-------------------------------------------------------------------------------------------
--- The CHR monad, state, etc. Used to interact with store and solver
-------------------------------------------------------------------------------------------

-- | Global state
data CHRGlobState cnstr guard bprio prio subst env m
  = CHRGlobState
      { _chrgstStore                 :: !(CHRStore cnstr guard bprio prio)                     -- ^ Actual database of rules, to be searched
      , _chrgstNextFreeRuleInx       :: !CHRInx                                          -- ^ Next free rule identification, used by solving to identify whether a rule has been used for a constraint.
                                                                                         --   The numbering is applied to constraints inside a rule which can be matched.
      , _chrgstWorkStore             :: !(WorkStore cnstr)                               -- ^ Actual database of solvable constraints
      , _chrgstNextFreeWorkInx       :: !WorkTime                                        -- ^ Next free work/constraint identification, used by solving to identify whether a rule has been used for a constraint.
      , _chrgstScheduleQueue         :: !(Que.MinPQueue (CHRPrioEvaluatableVal bprio) (CHRMonoBacktrackPrioT cnstr guard bprio prio subst env m (SolverResult subst)))
      , _chrgstTrace                 :: SolveTrace' cnstr (StoredCHR cnstr guard bprio prio) subst
      , _chrgstStatNrSolveSteps      :: !Int
      , _chrgstVarToNmMp             :: VarToNmMp
      }
  deriving (Typeable)

emptyCHRGlobState :: CHRGlobState c g b p s e m
emptyCHRGlobState = CHRGlobState emptyCHRStore 0 emptyWorkStore initWorkTime Que.empty emptySolveTrace 0 emptyVarToNmMp

-- | Backtrackable state
data CHRBackState cnstr bprio subst env
  = CHRBackState
      { _chrbstBacktrackPrio         :: !(CHRPrioEvaluatableVal bprio)                          -- ^ the current backtrack prio the solver runs on
      
      , _chrbstRuleWorkQueue         :: !WorkQueue                                              -- ^ work queue for rule matching
      , _chrbstSolveQueue            :: !WorkQueue                                              -- ^ solve queue, constraints which are not solved by rule matching but with some domain specific solver, yielding variable subst constributing to backtrackable bindings
      , _chrbstResidualQueue         :: [WorkInx]                                               -- ^ residual queue, constraints which are residual, no need to solve, etc
      
      , _chrbstMatchedCombis         :: !(Set.Set MatchedCombi)                                 -- ^ all combis of chr + work which were reduced, to prevent this from happening a second time (when propagating)
      
      , _chrbstFreshVar              :: !Int                                                    -- ^ for fresh var
      , _chrbstSolveSubst            :: !subst                                                  -- ^ subst for variable bindings found during solving, not for the ones binding rule metavars during matching but for the user ones (in to be solved constraints)
      , _chrbstWaitForVar            :: !(Map.Map (VarLookupKey subst) [WaitForVar subst])       -- ^ work waiting for a var to be bound
      
      , _chrbstReductionSteps        :: [SolverReductionStep]                                   -- ^ trace of reduction steps taken (excluding solve steps)
      }
  deriving (Typeable)

emptyCHRBackState :: (CHREmptySubstitution s, Bounded (CHRPrioEvaluatableVal bp)) => CHRBackState c bp s e
emptyCHRBackState = CHRBackState minBound emptyWorkQueue emptyWorkQueue [] Set.empty 0 chrEmptySubst Map.empty []

-- | Monad for CHR, taking from 'LogicStateT' the state and backtracking behavior
type CHRMonoBacktrackPrioT cnstr guard bprio prio subst env m
  = LogicStateT (CHRGlobState cnstr guard bprio prio subst env m) (CHRBackState cnstr bprio subst env) m

-- | All required behavior, as class alias
class ( IsCHRSolvable env cnstr guard bprio prio subst
      , Monad m
      -- , Ord (TTKey cnstr)
      -- , Ord prio
      -- , Ord (VarLookupKey subst)
      -- , VarLookup subst -- (VarLookupKey subst) (VarLookupVal subst)
      , Lookup subst (VarLookupKey subst) (VarLookupVal subst)
      , LookupApply subst subst
      -- , Scoped subst
      -- , TTKeyable cnstr
      -- , MonadIO m -- for debugging
      , Fresh Int (ExtrValVarKey (VarLookupVal subst))
      -- , VarLookupKey subst ~ ExtrValVarKey cnstr
      , ExtrValVarKey (VarLookupVal subst) ~ VarLookupKey subst
      , VarTerm (VarLookupVal subst)
      ) => MonoBacktrackPrio cnstr guard bprio prio subst env m

-------------------------------------------------------------------------------------------
--- Solver result
-------------------------------------------------------------------------------------------

-- | Solver solution
data SolverResult subst =
  SolverResult
    { slvresSubst                 :: subst                            -- ^ global found variable bindings
    , slvresResidualCnstr         :: [WorkInx]                        -- ^ constraints which are residual, no need to solve, etc, leftover when ready, taken from backtrack state
    , slvresWorkCnstr             :: [WorkInx]                        -- ^ constraints which are still unsolved, taken from backtrack state
    , slvresWaitVarCnstr          :: [WorkInx]                        -- ^ constraints which are still unsolved, waiting for variable resolution
    , slvresReductionSteps        :: [SolverReductionStep]            -- ^ how did we get to the result (taken from the backtrack state when a result is given back)
    }

-------------------------------------------------------------------------------------------
--- Solver: required instances
-------------------------------------------------------------------------------------------

-- | (Class alias) API for solving requirements
class ( IsCHRConstraint env c s
      , IsCHRGuard env g s
      , IsCHRBacktrackPrio env bp s
      , IsCHRPrio env p s
      , PP (VarLookupKey s)
      ) => IsCHRSolvable env c g bp p s

-------------------------------------------------------------------------------------------
--- Lens construction
-------------------------------------------------------------------------------------------

mkLabel ''WaitForVar
mkLabel ''StoredCHR
mkLabel ''CHRStore
mkLabel ''WorkStore
mkLabel ''WorkQueue
mkLabel ''CHRGlobState
mkLabel ''CHRBackState

-------------------------------------------------------------------------------------------
--- Misc utils
-------------------------------------------------------------------------------------------

getSolveTrace :: (PP c, PP g, PP bp, MonoBacktrackPrio c g bp p s e m) => CHRMonoBacktrackPrioT c g bp p s e m PP_Doc
getSolveTrace = fmap (ppSolveTrace . reverse) $ getl $ fstl ^* chrgstTrace

-------------------------------------------------------------------------------------------
--- CHR store, API for adding rules
-------------------------------------------------------------------------------------------

{-
-- | Combine lists of stored CHRs by concat, adapting their identification nr to be unique
cmbStoredCHRs :: [StoredCHR c g bp p] -> [StoredCHR c g bp p] -> [StoredCHR c g bp p]
cmbStoredCHRs s1 s2
  = map (\s@(StoredCHR {storedIdent=(k,nr)}) -> s {storedIdent = (k,nr+l)}) s1 ++ s2
  where l = length s2
-}

instance Show (StoredCHR c g bp p) where
  show _ = "StoredCHR"

ppStoredCHR :: (PP (TT2.TrTrKey c), PP c, PP g, PP bp, PP p) => StoredCHR c g bp p -> PP_Doc
ppStoredCHR c@(StoredCHR {})
  = ppParensCommas (_storedHeadKeys c)
    >-< _storedChrRule c
    >-< indent 2
          (ppParensCommas
            [ pp $ _storedChrInx c
            -- , pp $ storedSimpSz c
            -- , "keys" >#< (ppBracketsCommas $ map (maybe (pp "?") ppTreeTrieKey) $ storedKeys c)
            -- , "ident" >#< ppParensCommas [ppTreeTrieKey idKey,pp idSeqNr]
            ])

instance (PP (TT2.TrTrKey c), PP c, PP g, PP bp, PP p) => PP (StoredCHR c g bp p) where
  pp = ppStoredCHR

{-
-- | Convert from list to store
chrStoreFromElems :: (TTKeyable c, Ord (TTKey c), TTKey c ~ TrTrKey c) => [Rule c g bp p] -> CHRStore c g b p
chrStoreFromElems chrs
  = mkCHRStore
    $ chrTrieFromListByKeyWith cmbStoredCHRs
        [ (k,[StoredCHR chr i ks' (concat ks,0)])
        | chr <- chrs
        , let cs = ruleHead chr
              simpSz = ruleSimpSz chr
              ks = map chrToKey cs
        , (c,k,i) <- zip3 cs ks [0..]
        , let (ks1,(_:ks2)) = splitAt i ks
              ks' = map Just ks1 ++ [Nothing] ++ map Just ks2
        ]
-}

-- | Add a rule as a CHR
addRule :: MonoBacktrackPrio c g bp p s e m => Rule c g bp p -> CHRMonoBacktrackPrioT c g bp p s e m ()
addRule chr = do
    i <- modifyAndGet (fstl ^* chrgstNextFreeRuleInx) $ \i -> (i, i + 1)
    {-
    let ks  = map chrToKey $ ruleHead chr
    fstl ^* chrgstStore ^* chrstoreTable =$: IntMap.insert i (StoredCHR ks [] chr i)
    fstl ^* chrgstStore ^* chrstoreTrie =$: \t ->
      foldr (TreeTrie.unionWith (++)) t [ TreeTrie.singleton k [CHRConstraintInx i j] | (k,c,j) <- zip3 ks (ruleHead chr) [0..] ]
    -}
    let ks = map TT2.toTreeTrieKey $ ruleHead chr
    fstl ^* chrgstStore ^* chrstoreTable =$: IntMap.insert i (StoredCHR ks chr i)
    fstl ^* chrgstStore ^* chrstoreTrie =$: \t ->
      foldr (TT2.unionWith (++)) t [ TT2.singleton k [CHRConstraintInx i j] | (k,c,j) <- zip3 ks (ruleHead chr) [0..] ]
    return ()

{-
-- | Add a rule as a CHR
addRule2 :: MonoBacktrackPrio c g bp p s e m => Rule c g bp p -> CHRMonoBacktrackPrioT c g bp p s e m ()
addRule2 chr = do
    i <- modifyAndGet (fstl ^* chrgstNextFreeRuleInx) $ \i -> (i, i + 1)
    let ks = map TT2.toTreeTrieKey $ ruleHead chr
    fstl ^* chrgstStore ^* chrstoreTable =$: IntMap.insert i (StoredCHR [] ks chr i)
    fstl ^* chrgstStore ^* chrstoreTrie2 =$: \t ->
      foldr (TT2.unionWith (++)) t [ TT2.singleton k [CHRConstraintInx i j] | (k,c,j) <- zip3 ks (ruleHead chr) [0..] ]
    return ()
-}

-- | Add work to the rule work queue
addToWorkQueue :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addToWorkQueue i = do
    sndl ^* chrbstRuleWorkQueue ^* wkqueueActive =$: (IntSet.insert i)
    sndl ^* chrbstRuleWorkQueue ^* wkqueueDidSomething =: True
{-# INLINE addToWorkQueue #-}

-- | Add redo work to the rule work queue
addRedoToWorkQueue :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addRedoToWorkQueue i = do
    sndl ^* chrbstRuleWorkQueue ^* wkqueueRedo =$: (IntSet.insert i)
{-# INLINE addRedoToWorkQueue #-}

-- | Add work to the wait for var queue
addWorkToWaitForVarQueue :: (MonoBacktrackPrio c g bp p s e m, Ord (VarLookupKey s)) => CHRWaitForVarSet s -> WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addWorkToWaitForVarQueue wfvs wi = do
    let w = WaitForVar wfvs wi
    sndl ^* chrbstWaitForVar =$: Map.unionWith (++) (Map.fromList [(v,[w]) | v <- Set.toList wfvs])

-- | For (new) found subst split off work waiting for it
splitOffResolvedWaitForVarWork :: (MonoBacktrackPrio c g bp p s e m, Ord (VarLookupKey s)) => CHRWaitForVarSet s -> CHRMonoBacktrackPrioT c g bp p s e m [WorkInx]
splitOffResolvedWaitForVarWork vars = do
    -- wait admin
    wm <- getl $ sndl ^* chrbstWaitForVar
    let -- split off the part which can be released
        (wmRelease,wmRemain) = Map.partitionWithKey (\v _ -> Set.member v vars) wm
        wfvs = concat $ Map.elems wmRelease
        -- get all influenced vars and released work
        (wvars, winxs) = (\(vss,wis) -> (Set.unions vss, IntSet.fromList wis)) $ unzip [ (vs,wi) | (WaitForVar {_waitForVarVars=vs, _waitForVarWorkInx=wi}) <- wfvs ]
    -- remove released work from remaining admin for influenced vars
    sndl ^* chrbstWaitForVar =:
      foldr (Map.alter $ maybe Nothing $ \wfvs -> case filter (\i -> _waitForVarWorkInx i `IntSet.notMember` winxs) wfvs of
                [] -> Nothing
                wfvs' -> Just wfvs'
            )
            wmRemain
            (Set.toList wvars)

    -- released work
    return $ IntSet.toList winxs


-- | Add work to the solve queue
addWorkToSolveQueue :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m ()
addWorkToSolveQueue i = do
    sndl ^* chrbstSolveQueue ^* wkqueueActive =$: (IntSet.insert i)

-- | Split off work from the solve work queue, possible none left
splitWorkFromSolveQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Maybe (WorkInx))
splitWorkFromSolveQueue = do
    wq <- getl $ sndl ^* chrbstSolveQueue ^* wkqueueActive
    case IntSet.minView wq of
      Nothing ->
          return Nothing
      Just (workInx, wq') -> do
          sndl ^* chrbstSolveQueue ^* wkqueueActive =: wq'
          return $ Just (workInx)

-- | Remove work from the work queue
deleteFromWorkQueue :: MonoBacktrackPrio c g bp p s e m => WorkInxSet -> CHRMonoBacktrackPrioT c g bp p s e m ()
deleteFromWorkQueue is = do
    -- sndl ^* chrbstRuleWorkQueue ^* wkqueueActive =$: (\s -> foldr (IntSet.delete) s is)
    sndl ^* chrbstRuleWorkQueue ^* wkqueueActive =$: flip IntSet.difference is
    sndl ^* chrbstRuleWorkQueue ^* wkqueueRedo =$: flip IntSet.difference is

-- | Extract the active work in the queue
waitingInWorkQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m WorkInxSet
waitingInWorkQueue = do
    a <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueActive
    r <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueRedo
    return $ IntSet.union a r

-- | Split off work from the work queue, possible none left
splitFromWorkQueue :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Maybe WorkInx)
splitFromWorkQueue = do
    wq <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueActive
    case IntSet.minView wq of
      -- If no more work, ready if nothing was done anymore
      Nothing -> do
          did <- modifyAndGet (sndl ^* chrbstRuleWorkQueue ^* wkqueueDidSomething) $ \d -> (d, False)
          if did -- && not (IntSet.null wr)
            then do
              wr  <- modifyAndGet (sndl ^* chrbstRuleWorkQueue ^* wkqueueRedo) $ \r -> (r, IntSet.empty)
              sndl ^* chrbstRuleWorkQueue ^* wkqueueActive =: wr
              splitFromWorkQueue
            else
              return Nothing
      
      -- There is work in the queue
      Just (workInx, wq') -> do
          sndl ^* chrbstRuleWorkQueue ^* wkqueueActive =: wq'
          return $ Just workInx

-- | Add a constraint to be solved or residualised
addConstraintAsWork :: MonoBacktrackPrio c g bp p s e m => c -> CHRMonoBacktrackPrioT c g bp p s e m (ConstraintSolvesVia, WorkInx)
addConstraintAsWork c = do
    let via = cnstrSolvesVia c
        addw i w = do
          fstl ^* chrgstWorkStore ^* wkstoreTable =$: IntMap.insert i w
          return (via,i)
    i <- fresh
    w <- case via of
        -- a plain rule is added to the work store
        ConstraintSolvesVia_Rule -> do
            fstl ^* chrgstWorkStore ^* wkstoreTrie =$: TT2.insertByKeyWith (++) k [i]
            addToWorkQueue i
            return $ Work k c i
          where k = TT2.toTreeTrieKey c -- chrToKey c -- chrToWorkKey c
        -- work for the solver is added to its own queue
        ConstraintSolvesVia_Solve -> do
            addWorkToSolveQueue i
            return $ Work_Solve c
        -- residue is just remembered
        ConstraintSolvesVia_Residual -> do
            sndl ^* chrbstResidualQueue =$: (i :)
            return $ Work_Residue c
        -- fail right away if this constraint is a fail constraint
        ConstraintSolvesVia_Fail -> do
            addWorkToSolveQueue i
            return Work_Fail
    addw i w
{-
        -- succeed right away if this constraint is a succes constraint
        -- TBD, different return value of slvSucces...
        ConstraintSolvesVia_Succeed -> do
            slvSucces
-}
  where
    fresh = modifyAndGet (fstl ^* chrgstNextFreeWorkInx) $ \i -> (i, i + 1)
{-

chrStoreSingletonElem :: (TTKeyable c, Ord (TTKey c), TTKey c ~ TrTrKey c) => Rule c g bp p -> CHRStore c g b p
chrStoreSingletonElem x = chrStoreFromElems [x]

chrStoreUnion :: (Ord (TTKey c)) => CHRStore c g b p -> CHRStore c g b p -> CHRStore c g b p
chrStoreUnion cs1 cs2 = mkCHRStore $ chrTrieUnionWith cmbStoredCHRs (chrstoreTrie cs1) (chrstoreTrie cs2)
{-# INLINE chrStoreUnion #-}

chrStoreUnions :: (Ord (TTKey c)) => [CHRStore c g b p] -> CHRStore c g b p
chrStoreUnions []  = emptyCHRStore
chrStoreUnions [s] = s
chrStoreUnions ss  = foldr1 chrStoreUnion ss
{-# INLINE chrStoreUnions #-}

chrStoreToList :: (Ord (TTKey c)) => CHRStore c g b p -> [(CHRKey c,[Rule c g bp p])]
chrStoreToList cs
  = [ (k,chrs)
    | (k,e) <- chrTrieToListByKey $ chrstoreTrie cs
    , let chrs = [chr | (StoredCHR {storedChrRule = chr, storedChrInx = 0}) <- e]
    , not $ Prelude.null chrs
    ]

chrStoreElems :: (Ord (TTKey c)) => CHRStore c g b p -> [Rule c g bp p]
chrStoreElems = concatMap snd . chrStoreToList

ppCHRStore :: (PP c, PP g, PP p, Ord (TTKey c), PP (TTKey c)) => CHRStore c g b p -> PP_Doc
ppCHRStore = ppCurlysCommasBlock . map (\(k,v) -> ppTreeTrieKey k >-< indent 2 (":" >#< ppBracketsCommasBlock v)) . chrStoreToList

ppCHRStore' :: (PP c, PP g, PP p, Ord (TTKey c), PP (TTKey c)) => CHRStore c g b p -> PP_Doc
ppCHRStore' = ppCurlysCommasBlock . map (\(k,v) -> ppTreeTrieKey k >-< indent 2 (":" >#< ppBracketsCommasBlock v)) . chrTrieToListByKey . chrstoreTrie

-}

-------------------------------------------------------------------------------------------
--- Solver combinators
-------------------------------------------------------------------------------------------

-- | Succesful return, solution is found
slvSucces :: MonoBacktrackPrio c g bp p s e m => [WorkInx] -> CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
slvSucces leftoverWork = do
    bst <- getl $ sndl
    let ret = return $ SolverResult
          { slvresSubst = bst ^. chrbstSolveSubst
          , slvresResidualCnstr = reverse $ bst ^. chrbstResidualQueue
          , slvresWorkCnstr = leftoverWork
          , slvresWaitVarCnstr = [ wfv ^. waitForVarWorkInx | wfvs <- Map.elems $ bst ^. chrbstWaitForVar, wfv <- wfvs ]
          , slvresReductionSteps = reverse $ bst ^. chrbstReductionSteps
          }
    -- when ready, just return and backtrack into the scheduler
    ret `mplus` slvScheduleRun

-- | Failure return, no solution is found
slvFail :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
slvFail = do
    -- failing just terminates this slv, scheduling to another, if any
    slvScheduleRun
{-# INLINE slvFail #-}

-- | Schedule a solver with the current backtrack prio, assuming this is the same as 'slv' has administered itself in its backtracking state
slvSchedule :: MonoBacktrackPrio c g bp p s e m => CHRPrioEvaluatableVal bp -> CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s) -> CHRMonoBacktrackPrioT c g bp p s e m ()
slvSchedule bprio slv = do
    -- bprio <- getl $ sndl ^* chrbstBacktrackPrio
    fstl ^* chrgstScheduleQueue =$: Que.insert bprio slv
{-# INLINE slvSchedule #-}

-- | Schedule a solver with the current backtrack prio, assuming this is the same as 'slv' has administered itself in its backtracking state
slvSchedule' :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s) -> CHRMonoBacktrackPrioT c g bp p s e m ()
slvSchedule' slv = do
    bprio <- getl $ sndl ^* chrbstBacktrackPrio
    slvSchedule bprio slv
{-# INLINE slvSchedule' #-}

-- | Rechedule a solver, switching context/prio
slvReschedule :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s) -> CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
slvReschedule slv = do
    slvSchedule' slv
    slvScheduleRun
{-# INLINE slvReschedule #-}

-- | Retrieve solver with the highest prio from the schedule queue
slvSplitFromSchedule :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (Maybe (CHRPrioEvaluatableVal bp, CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)))
slvSplitFromSchedule = modifyAndGet (fstl ^* chrgstScheduleQueue) $ \q -> (Que.getMin q, Que.deleteMin q)
{-# INLINE slvSplitFromSchedule #-}

-- | Run from the schedule que, fail if nothing left to be done
slvScheduleRun :: MonoBacktrackPrio c g bp p s e m => CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
slvScheduleRun = slvSplitFromSchedule >>= maybe mzero snd
{-# INLINE slvScheduleRun #-}

-------------------------------------------------------------------------------------------
--- Solver utils
-------------------------------------------------------------------------------------------

{-
lkupWork :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m (Work c)
lkupWork i = fmap (IntMap.findWithDefault (panic "MBP.wkstoreTable.lookup") i) $ getl $ fstl ^* chrgstWorkStore ^* wkstoreTable
-}

lkupWork :: MonoBacktrackPrio c g bp p s e m => WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m (Work2 c)
lkupWork i = fmap (IntMap.findWithDefault (panic "MBP.wkstoreTable.lookup") i) $ getl $ fstl ^* chrgstWorkStore ^* wkstoreTable

lkupChr :: MonoBacktrackPrio c g bp p s e m => CHRInx -> CHRMonoBacktrackPrioT c g bp p s e m (StoredCHR c g bp p)
lkupChr  i = fmap (IntMap.findWithDefault (panic "MBP.chrSolve.chrstoreTable.lookup") i) $ getl $ fstl ^* chrgstStore ^* chrstoreTable

-- | Convert
cvtSolverReductionStep :: MonoBacktrackPrio c g bp p s e m => SolverReductionStep' CHRInx WorkInx -> CHRMonoBacktrackPrioT c g bp p s e m (SolverReductionStep' (StoredCHR c g bp p) (Work2 c))
cvtSolverReductionStep (SolverReductionStep mc ai nw) = do
    mc  <- cvtMC mc
    nw  <- fmap Map.fromList $ forM (Map.toList nw) $ \(via,i) -> do
             i <- forM i lkupWork
             return (via, i)
    return $ SolverReductionStep mc ai nw
  where
    cvtMC (MatchedCombi {mcCHR = c, mcWork = ws}) = do
      c'  <- lkupChr c
      ws' <- forM ws lkupWork
      return $ MatchedCombi c' ws'
cvtSolverReductionStep (SolverReductionDBG pp) = return (SolverReductionDBG pp)

-- | PP result
ppSolverResult
  :: ( MonoBacktrackPrio c g bp p s e m
     , VarUpdatable s s
     , PP s
     ) => Verbosity
       -> SolverResult s
       -> CHRMonoBacktrackPrioT c g bp p s e m PP_Doc
ppSolverResult verbosity (SolverResult {slvresSubst = s, slvresResidualCnstr = ris, slvresWorkCnstr = wis, slvresWaitVarCnstr = wvis, slvresReductionSteps = steps}) = do
    rs  <- forM ris  $ \i -> lkupWork i >>= return . pp . workCnstr
    ws  <- forM wis  $ \i -> lkupWork i >>= return . pp . workCnstr
    wvs <- forM wvis $ \i -> lkupWork i >>= return . pp . workCnstr
    ss  <- if verbosity >= Verbosity_ALot
      then forM steps $ \step -> cvtSolverReductionStep step >>= (return . pp)
      else return [pp $ "Only included with enough verbosity turned on"]
    nrsteps <- getl $ fstl ^* chrgstStatNrSolveSteps
    let pextra | verbosity >= Verbosity_Normal = 
                      "Residue" >-< indent 2 (vlist rs)
                  >-< "Wait"    >-< indent 2 (vlist wvs)
                  >-< "Stats"   >-< indent 2 (ppAssocLV [ ("Count of overall solve steps", pp nrsteps) ])
                  >-< "Steps"   >-< indent 2 (vlist ss)
               | otherwise = Pretty.empty
    return $ 
          "Subst"   >-< indent 2 (s `varUpd` s)
      >-< "Work"    >-< indent 2 (vlist ws)
      >-< pextra

-------------------------------------------------------------------------------------------
--- Solver: running it
-------------------------------------------------------------------------------------------

-- | Run and observe results
runCHRMonoBacktrackPrioT
  :: MonoBacktrackPrio cnstr guard bprio prio subst env m
     => CHRGlobState cnstr guard bprio prio subst env m
     -> CHRBackState cnstr bprio subst env
     -- -> CHRPrioEvaluatableVal bprio
     -> CHRMonoBacktrackPrioT cnstr guard bprio prio subst env m (SolverResult subst)
     -> m [SolverResult subst]
runCHRMonoBacktrackPrioT gs bs {- bp -} m = observeAllT (gs, bs {- _chrbstBacktrackPrio=bp -}) m

-------------------------------------------------------------------------------------------
--- Solver: Intermediate structures
-------------------------------------------------------------------------------------------

-- | Intermediate Solver structure
data FoundChr c g bp p
  = FoundChr
      { foundChrInx             :: !CHRInx
      , foundChrChr             :: !(StoredCHR c g bp p)
      , foundChrCnstr           :: ![WorkInx]
      }

-- | Intermediate Solver structure
data FoundWorkInx c g bp p
  = FoundWorkInx
      { foundWorkInxInx         :: !CHRConstraintInx
      , foundWorkInxChr         :: !(StoredCHR c g bp p)
      , foundWorkInxWorkInxs    :: ![[WorkInx]]
      }

-- | Intermediate Solver structure: sorting key for matches
data FoundMatchSortKey bp p s
  = FoundMatchSortKey
      { {- foundMatchSortKeyBacktrackPrio  :: !(CHRPrioEvaluatableVal bp)
      , -} foundMatchSortKeyPrio           :: !(Maybe (s,p))
      , foundMatchSortKeyWaitSize       :: !Int
      , foundMatchSortKeyTextOrder      :: !CHRInx
      }

instance Show (FoundMatchSortKey bp p s) where
  show _ = "FoundMatchSortKey"

instance (PP p, PP s) => PP (FoundMatchSortKey bp p s) where
  pp (FoundMatchSortKey {foundMatchSortKeyPrio=p, foundMatchSortKeyWaitSize=w, foundMatchSortKeyTextOrder=o}) = ppParensCommas [pp p, pp w, pp o]

compareFoundMatchSortKey :: {- (Ord (CHRPrioEvaluatableVal bp)) => -} ((s,p) -> (s,p) -> Ordering) -> FoundMatchSortKey bp p s -> FoundMatchSortKey bp p s -> Ordering
compareFoundMatchSortKey cmp_rp (FoundMatchSortKey {- bp1 -} rp1 ws1 to1) (FoundMatchSortKey {- bp2 -} rp2 ws2 to2) =
    {- orderingLexic (bp1 `compare` bp2) $ -} orderingLexic (rp1 `cmp_mbrp` rp2) $ orderingLexic (ws1 `compare` ws2) $ to1 `compare` to2
  where
    cmp_mbrp (Just rp1) (Just rp2) = cmp_rp rp1 rp2
    cmp_mbrp (Just _  ) _          = GT
    cmp_mbrp _          (Just _  ) = LT
    cmp_mbrp _          _          = EQ

-- | Intermediate Solver structure: body alternative, together with index position
data FoundBodyAlt c bp
  = FoundBodyAlt
      { foundBodyAltInx             :: !Int
      , foundBodyAltBacktrackPrio   :: !(CHRPrioEvaluatableVal bp)
      , foundBodyAltAlt             :: !(RuleBodyAlt c bp)
      }

instance Show (FoundBodyAlt c bp) where
  show _ = "FoundBodyAlt"

instance (PP c, PP bp, PP (CHRPrioEvaluatableVal bp)) => PP (FoundBodyAlt c bp) where
  pp (FoundBodyAlt {foundBodyAltInx=i, foundBodyAltBacktrackPrio=bp, foundBodyAltAlt=a}) = i >|< ":" >|< ppParens bp >#< a

-- | Intermediate Solver structure: all matched combis with their body alternatives + backtrack priorities
data FoundSlvMatch c g bp p s
  = FoundSlvMatch
      { foundSlvMatchSubst          :: !s                                   -- ^ the subst of rule meta vars making this a rule + work combi match
      , foundSlvMatchFreeVars       :: !(CHRWaitForVarSet s)                -- ^ free meta vars of head
      , foundSlvMatchWaitForVars    :: !(CHRWaitForVarSet s)                -- ^ for the work we try to solve the (global) vars on which we have to wait to continue
      , foundSlvMatchSortKey        :: !(FoundMatchSortKey bp p s)          -- ^ key to sort found matches
      , foundSlvMatchBodyAlts       :: ![FoundBodyAlt c bp]                 -- ^ the body alternatives of the rule which matches
      }

instance Show (FoundSlvMatch c g bp p s) where
  show _ = "FoundSlvMatch"

instance (PP s, PP p, PP c, PP bp, PP (VarLookupKey s), PP (CHRPrioEvaluatableVal bp)) => PP (FoundSlvMatch c g bp p s) where
  pp (FoundSlvMatch {foundSlvMatchSubst=s, foundSlvMatchWaitForVars=ws, foundSlvMatchBodyAlts=as}) = ws >#< s >-< vlist as

-- | Intermediate Solver structure: all matched combis with their backtrack prioritized body alternatives
data FoundWorkMatch c g bp p s
  = FoundWorkMatch
      { foundWorkMatchInx       :: !CHRConstraintInx
      , foundWorkMatchChr       :: !(StoredCHR c g bp p)
      , foundWorkMatchWorkInx   :: ![WorkInx]
      , foundWorkMatchSlvMatch  :: !(Maybe (FoundSlvMatch c g bp p s))
      }

instance Show (FoundWorkMatch c g bp p s) where
  show _ = "FoundWorkMatch"

instance (PP c, PP bp, PP p, PP s, PP (VarLookupKey s), PP (CHRPrioEvaluatableVal bp)) => PP (FoundWorkMatch c g bp p s) where
  pp (FoundWorkMatch {foundWorkMatchSlvMatch=sm}) = pp sm

-- | Intermediate Solver structure: all matched combis with their backtrack prioritized body alternatives
data FoundWorkSortedMatch c g bp p s
  = FoundWorkSortedMatch
      { foundWorkSortedMatchInx             :: !CHRConstraintInx
      , foundWorkSortedMatchChr             :: !(StoredCHR c g bp p)
      , foundWorkSortedMatchBodyAlts        :: ![FoundBodyAlt c bp]
      , foundWorkSortedMatchWorkInx         :: ![WorkInx]
      , foundWorkSortedMatchSubst           :: !s
      , foundWorkSortedMatchFreeVars        :: !(CHRWaitForVarSet s)
      , foundWorkSortedMatchWaitForVars     :: !(CHRWaitForVarSet s)
      }

instance Show (FoundWorkSortedMatch c g bp p s) where
  show _ = "FoundWorkSortedMatch"

instance (PP c, PP bp, PP p, PP s, PP g, PP (VarLookupKey s), PP (CHRPrioEvaluatableVal bp)) => PP (FoundWorkSortedMatch c g bp p s) where
  pp (FoundWorkSortedMatch {foundWorkSortedMatchBodyAlts=as, foundWorkSortedMatchWorkInx=wis, foundWorkSortedMatchSubst=s, foundWorkSortedMatchWaitForVars=wvs})
    = wis >-< s >#< ppParens wvs >-< vlist as

-------------------------------------------------------------------------------------------
--- Solver options
-------------------------------------------------------------------------------------------

-- | Solve specific options
data CHRSolveOpts
  = CHRSolveOpts
      { chrslvOptSucceedOnLeftoverWork  :: !Bool        -- ^ left over unresolvable (non residue) work is also a successful result
      , chrslvOptSucceedOnFailedSolve   :: !Bool        -- ^ failed solve is considered also a successful result, with the failed constraint as a residue
      }

defaultCHRSolveOpts :: CHRSolveOpts
defaultCHRSolveOpts
  = CHRSolveOpts
      { chrslvOptSucceedOnLeftoverWork  = False
      , chrslvOptSucceedOnFailedSolve   = False
      }

-------------------------------------------------------------------------------------------
--- Solver
-------------------------------------------------------------------------------------------

-- | (Under dev) solve
chrSolve
  :: forall c g bp p s e m .
     ( MonoBacktrackPrio c g bp p s e m
     , PP s
     ) => CHRSolveOpts
       -> e
       -> CHRMonoBacktrackPrioT c g bp p s e m (SolverResult s)
chrSolve opts env = slv
  where
    -- solve
    slv = do
        fstl ^* chrgstStatNrSolveSteps =$: (+1)
        mbSlvWk <- splitWorkFromSolveQueue
        case mbSlvWk of
          -- There is work in the solve work queue
          Just (workInx) -> do
              work <- lkupWork workInx
              case work of
                Work_Fail -> slvFail
                _ -> do
                  subst <- getl $ sndl ^* chrbstSolveSubst
                  let mbSlv = chrmatcherRun (chrBuiltinSolveM env $ workCnstr work) emptyCHRMatchEnv subst
                  
                  -- debug info
                  sndl ^* chrbstReductionSteps =$: (SolverReductionDBG
                    (    "solve wk" >#< work
                     >-< "match" >#< mbSlv
                    ) :)

                  case mbSlv of
                    Just (s,_) -> do
                          -- the newfound subst may reactivate waiting work
                          splitOffResolvedWaitForVarWork (Lk.keysSet s) >>= mapM_ addToWorkQueue
                          sndl ^* chrbstSolveSubst =$: (s `Lk.apply`)
                          -- just continue with next work
                          slv
                    _ | chrslvOptSucceedOnFailedSolve opts -> do
                          sndl ^* chrbstResidualQueue =$: (workInx :)
                          -- just continue with next work
                          slv
                      | otherwise -> do
                          slvFail


          -- If no more solve work, continue with normal work
          Nothing -> do
              waitingWk <- waitingInWorkQueue
              visitedChrWkCombis <- getl $ sndl ^* chrbstMatchedCombis
              mbWk <- splitFromWorkQueue
              case mbWk of
                -- If no more work, ready or cannot proceed
                Nothing -> do
                    wr <- getl $ sndl ^* chrbstRuleWorkQueue ^* wkqueueRedo
                    if chrslvOptSucceedOnLeftoverWork opts || IntSet.null wr
                      then slvSucces $ IntSet.toList wr
                      else slvFail
      
                -- There is work in the queue
                Just workInx -> do
                    -- lookup the work
                    work  <- lkupWork  workInx
                    -- work2 <- lkupWork2 workInx
          
                    -- find all matching chrs for the work
                    foundChrInxs  <- slvLookup  (workKey work ) (chrgstStore ^* chrstoreTrie )
                    -- foundChrInxs2 <- slvLookup2 (workKey work2) (chrgstStore ^* chrstoreTrie2)
                    -- remove duplicates, regroup
                    let foundChrGroupedInxs = Map.unionsWith Set.union $ map (\(CHRConstraintInx i j) -> Map.singleton i (Set.singleton j)) foundChrInxs
                    foundChrs <- forM (Map.toList foundChrGroupedInxs) $ \(chrInx,rlInxs) -> lkupChr chrInx >>= \chr -> return $ FoundChr chrInx chr $ Set.toList rlInxs

                    -- found chrs for the work correspond to 1 single position in the head, find all combinations with work in the queue
                    foundWorkInxs <- sequence
                      [ fmap (FoundWorkInx (CHRConstraintInx ci i) c) $ slvCandidate waitingWk visitedChrWkCombis workInx c i
                      | FoundChr ci c is <- foundChrs, i <- is
                      ]
          
                    -- each found combi has to match
                    foundWorkMatches <- fmap concat $
                      forM foundWorkInxs $ \(FoundWorkInx ci c wis) -> do
                        forM wis $ \wi -> do
                          w <- forM wi lkupWork
                          fmap (FoundWorkMatch ci c wi) $ slvMatch env c (map workCnstr w) (chrciAt ci)

                    -- split off the work which has to wait for variable bindings (as indicated by matching)
                    -- let () = partition () foundWorkMatches
                    -- sort over priorities
                    let foundWorkSortedMatches = sortByOn (compareFoundMatchSortKey $ chrPrioCompare env) fst
                          [ (k, FoundWorkSortedMatch (foundWorkMatchInx fwm) (foundWorkMatchChr fwm) (foundSlvMatchBodyAlts sm)
                                                     (foundWorkMatchWorkInx fwm) (foundSlvMatchSubst sm) (foundSlvMatchFreeVars sm) (foundSlvMatchWaitForVars sm))
                          | fwm@(FoundWorkMatch {foundWorkMatchSlvMatch = Just sm@(FoundSlvMatch {foundSlvMatchSortKey=k})}) <- foundWorkMatches
                          -- , (k,a) <- foundSlvMatchBodyAlts sm
                          ]

                    bprio <- getl $ sndl ^* chrbstBacktrackPrio
                    subst <- getl $ sndl ^* chrbstSolveSubst
                    dbgWaitInfo <- getl $ sndl ^* chrbstWaitForVar
                    -- sque <- getl $ fstl ^* chrgstScheduleQueue
                    -- debug info
                    let dbg =      "bprio" >#< bprio
                               >-< "wk" >#< (work >-< subst `varUpd` workCnstr work)
                               >-< "que" >#< ppBracketsCommas (IntSet.toList waitingWk)
                               >-< "subst" >#< subst
                               >-< "wait" >#< ppAssocL (assocLMapElt (ppAssocL . map (\i -> (_waitForVarWorkInx i, ppCommas $ Set.toList $ _waitForVarVars i))) $ Map.toList dbgWaitInfo)
                               >-< "visited" >#< ppBracketsCommas (Set.toList visitedChrWkCombis)
                               >-< "chrs" >#< vlist [ ci >|< ppParensCommas is >|< ":" >#< c | FoundChr ci c is <- foundChrs ]
                               >-< "works" >#< vlist [ ci >|< ":" >#< vlist (map ppBracketsCommas ws) | FoundWorkInx ci c ws <- foundWorkInxs ]
                               >-< "matches" >#< vlist [ ci >|< ":" >#< ppBracketsCommas wi >#< ":" >#< mbm | FoundWorkMatch ci _ wi mbm <- foundWorkMatches ]
                               -- >-< "prio'd" >#< (vlist $ zipWith (\g ms -> g >|< ":" >#< vlist [ ci >|< ":" >#< ppBracketsCommas wi >#< ":" >#< s | (ci,_,wi,s) <- ms ]) [0::Int ..] foundWorkMatchesFilteredPriod)
                               -- >-< "prio'd" >#< ppAssocL (zip [0::Int ..] $ map ppAssocL foundWorkSortedMatches)
                    sndl ^* chrbstReductionSteps =$: (SolverReductionDBG dbg :)

                    -- pick the first and highest rule prio solution
                    case foundWorkSortedMatches of
                      ((_,fwsm@(FoundWorkSortedMatch {foundWorkSortedMatchWaitForVars = waitForVars})):_)
                        | Set.null waitForVars -> do
                            -- addRedoToWorkQueue workInx
                            addToWorkQueue workInx
                            slv1 bprio fwsm
                        | otherwise -> do
                            -- put on wait queue if there are unresolved variables
                            addWorkToWaitForVarQueue waitForVars workInx
                            -- continue without reschedule
                            slv
                      _ -> do
                            addRedoToWorkQueue workInx
                            slv
{-
                      _ | chrslvOptSucceedOnLeftoverWork opts -> do
                            -- no chr applies for this work, so consider it to be residual
                            sndl ^* chrbstLeftWorkQueue =$: (workInx :)
                            -- continue without reschedule
                            slv
                        | otherwise -> do
                            -- no chr applies for this work, can never be resolved, consider this a failure unless prevented by option
                            slvFail
-}

    -- solve one step further, allowing a backtrack point here
    slv1 curbprio
         (FoundWorkSortedMatch
            { foundWorkSortedMatchInx = CHRConstraintInx {chrciInx = ci}
            , foundWorkSortedMatchChr = chr@StoredCHR {_storedChrRule = Rule {ruleSimpSz = simpSz}}
            , foundWorkSortedMatchBodyAlts = alts
            , foundWorkSortedMatchWorkInx = workInxs
            , foundWorkSortedMatchSubst = matchSubst
            , foundWorkSortedMatchFreeVars = freeHeadVars
            }) = do
        -- remove the simplification part from the work queue
        deleteFromWorkQueue $ IntSet.fromList $ take simpSz workInxs
        -- depending on nr of alts continue slightly different
        case alts of
          -- just continue if no alts 
          [] -> do
            log Nothing
            slv
          -- just reschedule
          [alt@(FoundBodyAlt {foundBodyAltBacktrackPrio=bprio})]
            | curbprio == bprio -> do
                log (Just alt)
                nextwork bprio alt
            | otherwise -> do
                log (Just alt)
                slvSchedule bprio $ nextwork bprio alt
                slvScheduleRun
          -- otherwise backtrack and schedule all and then reschedule
          alts -> do
                forM alts $ \alt@(FoundBodyAlt {foundBodyAltBacktrackPrio=bprio}) -> do
                  log (Just alt)
                  (backtrack $ nextwork bprio alt) >>= slvSchedule bprio
                slvScheduleRun

      where
        log alt = do
          let a = (fmap (rbodyaltBody . foundBodyAltAlt) alt)
          let step = SolveStep chr matchSubst a [] [] -- TODO: Set stepNewTodo, stepNewDone (last two arguments)
          fstl ^* chrgstTrace =$: (step:)
        nextwork bprio alt@(FoundBodyAlt {foundBodyAltAlt=(RuleBodyAlt {rbodyaltBody=body})}) = do
          -- set prio for this alt
          sndl ^* chrbstBacktrackPrio =: bprio
          -- fresh vars for unbound body metavars
          freshSubst <- slvFreshSubst freeHeadVars body
          -- add each constraint from the body, applying the meta var subst
          newWkInxs <- forM body $ addConstraintAsWork . ((freshSubst `Lk.apply` matchSubst) `varUpd`)
          -- mark this combi of chr and work as visited
          let matchedCombi = MatchedCombi ci workInxs
          sndl ^* chrbstMatchedCombis =$: Set.insert matchedCombi
          -- add this reduction step as being taken
          sndl ^* chrbstReductionSteps =$: (SolverReductionStep matchedCombi (foundBodyAltInx alt) (Map.unionsWith (++) $ map (\(k,v) -> Map.singleton k [v]) $ newWkInxs) :)
          -- take next step
          slv

    -- misc utils

-- | Fresh variables in the form of a subst
slvFreshSubst
  :: forall c g bp p s e m x .
     ( MonoBacktrackPrio c g bp p s e m
     , ExtrValVarKey x ~ ExtrValVarKey (VarLookupVal s)
     , VarExtractable x
     ) => Set.Set (ExtrValVarKey x)
       -> x
       -> CHRMonoBacktrackPrioT c g bp p s e m s
slvFreshSubst except x = 
    fmap (foldr Lk.apply Lk.empty) $
      forM (Set.toList $ varFreeSet x `Set.difference` except) $ \v ->
        modifyAndGet (sndl ^* chrbstFreshVar) (freshWith $ Just v) >>= \v' -> return $ (Lk.singleton v (varTermMkKey v') :: s)

{-
-- | Lookup work in a store part of the global state
slvLookup
  :: ( MonoBacktrackPrio c g bp p s e m
     , Ord x
     ) => CHRKey c                                   -- ^ work key
       -> Lens (CHRGlobState c g bp p s e m) (CHRTrie' c [x])
       -> CHRMonoBacktrackPrioT c g bp p s e m [x]
slvLookup key t =
    (getl $ fstl ^* t) >>= \t -> do
      let lkup how = concat $ TreeTrie.lookupResultToList $ TreeTrie.lookupPartialByKey how key t
      return $ Set.toList $ Set.fromList $ lkup TTL_WildInTrie ++ lkup TTL_WildInKey
-}

-- | Lookup work in a store part of the global state
slvLookup
  :: ( MonoBacktrackPrio c g bp p s e m
     , Ord (TT2.TrTrKey c)
     ) => CHRKey2 c                                   -- ^ work key
       -> Lens (CHRGlobState c g bp p s e m) (TT2.TreeTrie (TT2.TrTrKey c) [x])
       -> CHRMonoBacktrackPrioT c g bp p s e m [x]
slvLookup key t =
    (getl $ fstl ^* t) >>= \t -> do
      {-
      let lkup how = concat $ TreeTrie.lookupResultToList $ TreeTrie.lookupPartialByKey how key t
      return $ Set.toList $ Set.fromList $ lkup TTL_WildInTrie ++ lkup TTL_WildInKey
      -}
      return $ concat $ TT2.lookupResultToList $ TT2.lookup key t

{-
-- | Extract candidates matching a CHRKey.
--   Return a list of CHR matches,
--     each match expressed as the list of constraints (in the form of Work + Key) found in the workList wlTrie, thus giving all combis with constraints as part of a CHR,
--     partititioned on before or after last query time (to avoid work duplication later)
slvCandidate
  :: ( MonoBacktrackPrio c g bp p s e m
     -- , Ord (TTKey c), PP (TTKey c)
     ) => WorkInxSet                           -- ^ active in queue
       -> Set.Set MatchedCombi                      -- ^ already matched combis
       -> WorkInx                                   -- ^ work inx
       -> StoredCHR c g bp p                        -- ^ found chr for the work
       -> Int                                       -- ^ position in the head where work was found
       -> CHRMonoBacktrackPrioT c g bp p s e m
            ( [[WorkInx]]                           -- All matches of the head, unfiltered w.r.t. deleted work
            )
slvCandidate waitingWk alreadyMatchedCombis wi (StoredCHR {_storedHeadKeys = ks, _storedChrInx = ci}) headInx = do
    let [ks1,_,ks2] = splitPlaces [headInx, headInx+1] ks
    ws1 <- forM ks1 lkup
    ws2 <- forM ks2 lkup
    return $ filter (\wi ->    all (`IntSet.member` waitingWk) wi
                            && Set.notMember (MatchedCombi ci wi) alreadyMatchedCombis)
           $ combineToDistinguishedEltsBy (==) $ ws1 ++ [[wi]] ++ ws2
  where
    lkup k = slvLookup k (chrgstWorkStore ^* wkstoreTrie)
-}

-- | Extract candidates matching a CHRKey.
--   Return a list of CHR matches,
--     each match expressed as the list of constraints (in the form of Work + Key) found in the workList wlTrie, thus giving all combis with constraints as part of a CHR,
--     partititioned on before or after last query time (to avoid work duplication later)
slvCandidate
  :: ( MonoBacktrackPrio c g bp p s e m
     -- , Ord (TTKey c), PP (TTKey c)
     ) => WorkInxSet                           -- ^ active in queue
       -> Set.Set MatchedCombi                      -- ^ already matched combis
       -> WorkInx                                   -- ^ work inx
       -> StoredCHR c g bp p                        -- ^ found chr for the work
       -> Int                                       -- ^ position in the head where work was found
       -> CHRMonoBacktrackPrioT c g bp p s e m
            ( [[WorkInx]]                           -- All matches of the head, unfiltered w.r.t. deleted work
            )
slvCandidate waitingWk alreadyMatchedCombis wi (StoredCHR {_storedHeadKeys = ks, _storedChrInx = ci}) headInx = do
    let [ks1,_,ks2] = splitPlaces [headInx, headInx+1] ks
    ws1 <- forM ks1 lkup
    ws2 <- forM ks2 lkup
    return $ filter (\wi ->    all (`IntSet.member` waitingWk) wi
                            && Set.notMember (MatchedCombi ci wi) alreadyMatchedCombis)
           $ combineToDistinguishedEltsBy (==) $ ws1 ++ [[wi]] ++ ws2
  where
    lkup k = slvLookup k (chrgstWorkStore ^* wkstoreTrie)

-- | Match the stored CHR with a set of possible constraints, giving a substitution on success
slvMatch
  :: ( MonoBacktrackPrio c g bp p s env m
     -- these below should not be necessary as they are implied (via superclasses) by MonoBacktrackPrio, but deeper nested superclasses seem not to be picked up...
     , CHRMatchable env c s
     , CHRCheckable env g s
     , CHRMatchable env bp s
     -- , CHRPrioEvaluatable env p s
     , CHRPrioEvaluatable env bp s
     -- , CHRBuiltinSolvable env b s
     -- , PP s
     ) => env
       -> StoredCHR c g bp p
       -> [c]
       -> Int                                       -- ^ position in the head where work was found, on that work specifically we might have to wait
       -> CHRMonoBacktrackPrioT c g bp p s env m (Maybe (FoundSlvMatch c g bp p s))
slvMatch env chr@(StoredCHR {_storedChrRule = Rule {rulePrio = mbpr, ruleHead = hc, ruleGuard = gd, ruleBacktrackPrio = mbbpr, ruleBodyAlts = alts}}) cnstrs headInx = do
    subst <- getl $ sndl ^* chrbstSolveSubst
    curbprio <- fmap chrPrioLift $ getl $ sndl ^* chrbstBacktrackPrio
    return $ fmap (\(s,ws) -> FoundSlvMatch s freevars ws (FoundMatchSortKey (fmap ((,) s) mbpr) (Set.size ws) (_storedChrInx chr))
                    [ FoundBodyAlt i bp a | (i,a) <- zip [0..] alts, let bp = maybe minBound (chrPrioEval env s) $ rbodyaltBacktrackPrio a
                    ])
           $ (\m -> chrmatcherRun m (emptyCHRMatchEnv {chrmatchenvMetaMayBind = (`Set.member` freevars)}) subst)
           $ sequence_
           $ prio curbprio ++ matches ++ checks
  where
    prio curbprio = maybe [] (\bpr -> [chrMatchToM env bpr curbprio]) mbbpr
    matches = zipWith3 (\i h c -> chrMatchAndWaitToM (i == headInx) env h c) [0::Int ..] hc cnstrs
    -- ignoreWait 
    checks  = map (chrCheckM env) gd
    freevars = Set.unions [varFreeSet hc, maybe Set.empty varFreeSet mbbpr]

-------------------------------------------------------------------------------------------
--- Instances: Serialize
-------------------------------------------------------------------------------------------

{-
instance (Ord (TTKey c), Serialize (TTKey c), Serialize c, Serialize g, Serialize b, Serialize p) => Serialize (CHRStore c g b p) where
  sput (CHRStore a) = sput a
  sget = liftM CHRStore sget
  
instance (Serialize c, Serialize g, Serialize b, Serialize p, Serialize (TTKey c)) => Serialize (StoredCHR c g bp p) where
  sput (StoredCHR a b c d) = sput a >> sput b >> sput c >> sput d
  sget = liftM4 StoredCHR sget sget sget sget

-}
