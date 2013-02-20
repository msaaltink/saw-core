{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Verifier.SAW.SharedTerm
  ( TermF(..)
  , Ident, mkIdent
  , SharedTerm(..)
  , TermIndex
  , unwrapSharedTerm
    -- * Low-level AppCache interface for building shared terms
  , AppCacheRef
  , getTerm
    -- ** Utility functions using AppCache
  , instantiateVarList
    -- * High-level SharedContext interface for building shared terms
  , SharedContext
  , mkSharedContext
    -- ** Implicit versions of functions.
  , scDefTerm
  , scFreshGlobal
  , scModule
  , scTermF
  , scApply
  , scApplyAll
  , scMkRecord
  , scRecordSelect
  , scApplyCtor
  , scFun
  , scNat
  , scBitvector
  , scFunAll
  , scLiteral
  , scLookupDef
  , scTuple
  , scTupleType
  , scTypeOf
  , scPrettyTerm
  , scViewAsBool
  , scViewAsNum
    -- ** Utilities
--  , scTrue
--  , scFalse
  ) where

import Control.Applicative ((<$>), pure, (<*>))
import Control.Concurrent.MVar
import qualified Control.Monad.State as State
import Control.Monad.Trans (lift)
import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Word
import Data.Foldable hiding (sum)
import Data.Traversable
import Prelude hiding (mapM, maximum)
import Text.PrettyPrint.HughesPJ

import Verifier.SAW.Cache
import Verifier.SAW.Change
import Verifier.SAW.TypedAST hiding (instantiateVarList)

type TermIndex = Word64
type VarIndex = Word64

data SharedTerm s
  = STVar !VarIndex !Ident !(SharedTerm s)
  | STApp !TermIndex !(TermF (SharedTerm s))

instance Eq (SharedTerm s) where
  STVar x _ _ == STVar y _ _ = x == y
  STApp x _ == STApp y _ = x == y
  _ == _ = False

instance Ord (SharedTerm s) where
  compare (STVar x _ _) (STVar y _ _) = compare x y
  compare STVar{} _ = LT
  compare _ STVar{} = GT
  compare (STApp x _) (STApp y _) = compare x y

unwrapSharedTerm :: SharedTerm s -> TermF (SharedTerm s)
unwrapSharedTerm (STApp _ tf) = tf

data AppCache s = AC { acBindings :: !(Map (TermF (SharedTerm s)) (SharedTerm s))
                     , acNextIdx :: !Word64
                     }

newtype AppCacheRef s = ACR (MVar (AppCache s))

emptyAppCache :: AppCache s
emptyAppCache = AC Map.empty 0

newAppCacheRef :: IO (AppCacheRef s)
newAppCacheRef = ACR <$> newMVar emptyAppCache

-- | Return term for application using existing term in cache if it is avaiable.
getTerm :: AppCacheRef s -> TermF (SharedTerm s) -> IO (SharedTerm s)
getTerm (ACR r) a =
  modifyMVar r $ \s -> do
    case Map.lookup a (acBindings s) of
      Just t -> return (s,t)
      Nothing -> seq s' $ return (s',t)
        where t = STApp (acNextIdx s) a
              s' = s { acBindings = Map.insert a t (acBindings s)
                     , acNextIdx = acNextIdx s + 1
                     }

getFlatTerm :: AppCacheRef s -> FlatTermF (SharedTerm s) -> IO (SharedTerm s)
getFlatTerm ac = getTerm ac . FTermF




{-
data LocalVarTypeMap s = LVTM { lvtmMap :: Map Integer (SharedTerm s) }

consLocalVarType :: LocalVarTypeMap s -> Ident -> SharedTerm s -> LocalVarTypeMap s
consLocalVarType = undefined

localVarType :: DeBruijnIndex -> LocalVarTypeMap s -> SharedTerm s
localVarType = undefined
-}

-- | Substitute var 0 in first term for second term, and shift all variable
-- references down.
subst0 :: AppCacheRef s -> SharedTerm s -> SharedTerm s -> IO (SharedTerm s)
subst0 = undefined

sortOfTerm :: AppCacheRef s -> (Ident -> IO (SharedTerm s)) -> SharedTerm s -> IO Sort
sortOfTerm ac typeOfGlobal t = do
  STApp _ (FTermF (Sort s)) <- typeOf ac typeOfGlobal t
  return s

mkSharedSort :: AppCacheRef s -> Sort -> IO (SharedTerm s)
mkSharedSort ac s = getFlatTerm ac (Sort s)


typeOfFTermF :: AppCacheRef s
             -> (Ident -> IO (SharedTerm s))
             -> FlatTermF (SharedTerm s)
             -> IO (SharedTerm s)
typeOfFTermF ac typeOfGlobal tf =
  case tf of
    GlobalDef d -> typeOfGlobal d
    App x y -> do
      STApp _ (Pi _ _ rhs) <- typeOf ac typeOfGlobal x
      subst0 ac rhs y
    TupleValue l -> getFlatTerm ac . TupleType =<< mapM (typeOf ac typeOfGlobal) l
    TupleType l -> mkSharedSort ac . maximum =<< mapM (sortOfTerm ac typeOfGlobal) l
    RecordValue m -> getFlatTerm ac . RecordType =<< mapM (typeOf ac typeOfGlobal) m
    RecordSelector t f -> do
      STApp _ (FTermF (RecordType m)) <- typeOf ac typeOfGlobal t
      let Just tp = Map.lookup f m
      return tp
    RecordType m -> mkSharedSort ac . maximum =<< mapM (sortOfTerm ac typeOfGlobal) m
    CtorApp c args -> undefined c args
    DataTypeApp dt args -> undefined dt args
    Sort s -> mkSharedSort ac (sortOf s)
    NatLit i -> undefined i
    ArrayValue tp _ -> undefined tp

typeOf :: AppCacheRef s
       -> (Ident -> IO (SharedTerm s))
       -> SharedTerm s
       -> IO (SharedTerm s)
typeOf ac _ (STVar _ _ tp) = return tp
typeOf ac typeOfGlobal (STApp _ tf) =
  case tf of
    FTermF ftf -> typeOfFTermF ac typeOfGlobal ftf
    Lambda (PVar i _ _) tp rhs -> do
      rtp <- typeOf ac typeOfGlobal rhs
      getTerm ac (Pi i tp rtp)
    Pi _ tp rhs -> do
      ltp <- sortOfTerm ac typeOfGlobal tp
      rtp <- sortOfTerm ac typeOfGlobal rhs
      mkSharedSort ac (max ltp rtp)
    Let defs rhs -> undefined defs rhs
    LocalVar _ tp -> return tp
--    EqType{} -> undefined 
--    Oracle{} -> undefined

{-
-- | Monadic fold with memoization
foldSharedTermM :: forall s b m . Monad m 
                => (VarIndex -> Ident -> SharedTerm s -> m b)
                -> (TermF b -> m b) -> SharedTerm s -> m b
foldSharedTermM g f = \t -> State.evalStateT (go t) Map.empty
  where
    go :: SharedTerm s -> State.StateT (Map TermIndex b) m b
    go (STVar i sym tp) = lift $ g i sym tp
    go (STApp i t) = do
      memo <- State.get
      case Map.lookup i memo of
        Just x  -> return x
        Nothing -> do
          t' <- Traversable.mapM go t
          x <- lift (f t')
          State.modify (Map.insert i x)
          return x
-}

-- | The inverse function to @sharedTerm@.
unshare :: forall s. SharedTerm s -> Term
unshare t = State.evalState (go t) Map.empty
  where
    go :: SharedTerm s -> State.State (Map TermIndex Term) Term
    go (STVar i sym tp) = error "unshare STVar"
    go (STApp i t) = do
      memo <- State.get
      case Map.lookup i memo of
        Just x  -> return x
        Nothing -> do
          x <- Term <$> traverse go t
          State.modify (Map.insert i x)
          return x

instance Show (SharedTerm s) where
  show = show . unshare

sharedTerm :: AppCacheRef s -> Term -> IO (SharedTerm s)
sharedTerm mvar = go
    where go (Term termf) = getTerm mvar =<< traverse go termf

instantiateVars :: forall s. AppCacheRef s
                -> (DeBruijnIndex -> DeBruijnIndex -> ChangeT IO (SharedTerm s)
                                  -> ChangeT IO (IO (SharedTerm s)))
                -> DeBruijnIndex -> SharedTerm s -> ChangeT IO (SharedTerm s)
instantiateVars ac f initialLevel t =
    do cache <- newCache
       let ?cache = cache in go initialLevel t
  where
    go :: (?cache :: Cache (ChangeT IO) (TermIndex, DeBruijnIndex) (SharedTerm s)) =>
          DeBruijnIndex -> SharedTerm s -> ChangeT IO (SharedTerm s)
    go l t@(STVar {}) = pure t
    go l t@(STApp tidx tf) =
        useCache ?cache (tidx, l) (preserveChangeT t $ go' l tf)

    go' :: (?cache :: Cache (ChangeT IO) (TermIndex, DeBruijnIndex) (SharedTerm s)) =>
           DeBruijnIndex -> TermF (SharedTerm s) -> ChangeT IO (IO (SharedTerm s))
    go' l (FTermF tf) = getFlatTerm ac <$> (traverse (go l) tf)
    go' l (Lambda i tp rhs) = getTerm ac <$> (Lambda i <$> go l tp <*> go (l+1) rhs)
    go' l (Pi i lhs rhs)    = getTerm ac <$> (Pi i <$> go l lhs <*> go (l+1) rhs)
    go' l (Let defs r) = getTerm ac <$> (Let <$> changeList procDef defs <*> go l' r)
      where l' = l + length defs
            procDef :: LocalDef (SharedTerm s) -> ChangeT IO (LocalDef (SharedTerm s))
            procDef (LocalFnDef sym tp eqs) =
              LocalFnDef sym <$> go l tp <*> changeList procEq eqs
            procEq :: DefEqn (SharedTerm s) -> ChangeT IO (DefEqn (SharedTerm s))
            procEq (DefEqn pats rhs) = DefEqn pats <$> go eql rhs
              where eql = l' + sum (patBoundVarCount <$> pats)
    go' l (LocalVar i tp)
      | i < l     = getTerm ac <$> (LocalVar i <$> go (l-(i+1)) tp)
      | otherwise = f l i (go (l-(i+1)) tp)
--    go' l (EqType lhs rhs) = getTerm ac <$> (EqType <$> go l lhs <*> go l rhs)
--    go' l (Oracle s prop) = getTerm ac <$> (Oracle s <$> go l prop)

-- | @incVars j k t@ increments free variables at least @j@ by @k@.
-- e.g., incVars 1 2 (C ?0 ?1) = C ?0 ?3
incVarsChangeT :: AppCacheRef s
               -> DeBruijnIndex -> DeBruijnIndex -> SharedTerm s -> ChangeT IO (SharedTerm s)
incVarsChangeT ac initialLevel j
    | j == 0 = return
    | j >  0 = instantiateVars ac fn initialLevel
    where
      fn _ i t = taint $ getTerm ac <$> (LocalVar (i+j) <$> t)

incVars :: AppCacheRef s
        -> DeBruijnIndex -> DeBruijnIndex -> SharedTerm s -> IO (SharedTerm s)
incVars ac i j t = commitChangeT (incVarsChangeT ac i j t)

-- | Substitute @t0@ for variable @k@ in @t@ and decrement all higher
-- dangling variables.
instantiateVarChangeT :: forall s. AppCacheRef s
                      -> DeBruijnIndex -> SharedTerm s -> SharedTerm s
                      -> ChangeT IO (SharedTerm s)
instantiateVarChangeT ac k t0 t =
    do cache <- newCache
       let ?cache = cache in instantiateVars ac fn 0 t
  where -- Use map reference to memoize instantiated versions of t.
        term :: (?cache :: Cache (ChangeT IO) DeBruijnIndex (SharedTerm s)) =>
                DeBruijnIndex -> ChangeT IO (SharedTerm s)
        term i = useCache ?cache i (incVarsChangeT ac 0 i t0)
        -- Instantiate variable 0.
        fn :: (?cache :: Cache (ChangeT IO) DeBruijnIndex (SharedTerm s)) =>
              DeBruijnIndex -> DeBruijnIndex -> ChangeT IO (SharedTerm s)
                            -> ChangeT IO (IO (SharedTerm s))
        fn i j t | j  > i + k = taint $ getTerm ac <$> (LocalVar (j - 1) <$> t)
                 | j == i + k = taint $ return <$> term i
                 | otherwise  = getTerm ac <$> (LocalVar j <$> t)

instantiateVar :: AppCacheRef s
               -> DeBruijnIndex -> SharedTerm s -> SharedTerm s -> IO (SharedTerm s)
instantiateVar ac k t0 t = commitChangeT (instantiateVarChangeT ac k t0 t)

-- | Substitute @ts@ for variables @[k .. k + length ts - 1]@ and
-- decrement all higher loose variables by @length ts@.
instantiateVarListChangeT :: forall s. AppCacheRef s
                          -> DeBruijnIndex -> [SharedTerm s]
                          -> SharedTerm s -> ChangeT IO (SharedTerm s)
instantiateVarListChangeT _ _ [] t = return t
instantiateVarListChangeT ac k ts t =
    do caches <- mapM (const newCache) ts
       instantiateVars ac (fn (zip caches ts)) 0 t
  where
    l = length ts
    -- Memoize instantiated versions of ts.
    term :: (Cache (ChangeT IO) DeBruijnIndex (SharedTerm s), SharedTerm s)
         -> DeBruijnIndex -> ChangeT IO (SharedTerm s)
    term (cache, t) i = useCache cache i (incVarsChangeT ac 0 i t)
    -- Instantiate variables [k .. k+l-1].
    fn :: [(Cache (ChangeT IO) DeBruijnIndex (SharedTerm s), SharedTerm s)]
       -> DeBruijnIndex -> DeBruijnIndex -> ChangeT IO (SharedTerm s)
       -> ChangeT IO (IO (SharedTerm s))
    fn = undefined
--    fn rs i j t | j >= i + k + l = taint $ getTerm ac <$> (LocalVar (j - l) <$> t)
--                | j >= i + k     = taint $ return <$> term (rs !! (j - i - k)) i
--                | otherwise      = getTerm ac <$> (LocalVar j <$> t)

instantiateVarList :: AppCacheRef s
                   -> DeBruijnIndex -> [SharedTerm s] -> SharedTerm s -> IO (SharedTerm s)
instantiateVarList ac k ts t = commitChangeT (instantiateVarListChangeT ac k ts t)

----------------------------------------------------------------------
-- SharedContext: a high-level interface for building SharedTerms.

-- | Operations that are defined, but not 
data SharedContext s = SharedContext
  { -- | Returns the current module for the underlying global theory.
    scModule :: IO Module
  , scTermF         :: TermF (SharedTerm s) -> IO (SharedTerm s)
  -- | Create a global variable with the given identifier (which may be "_") and type.
  , scFreshGlobal   :: Ident -> SharedTerm s -> IO (SharedTerm s)
  -- | Returns the defined constant with the given name. Fails if no such
  -- constant exists in the module.
  , scLookupDef     :: String -> IO (SharedTerm s)
  , scDefTerm       :: TypedDef -> IO (SharedTerm s)
  , scApply         :: SharedTerm s -> SharedTerm s -> IO (SharedTerm s)
  , scMkRecord      :: Map FieldName (SharedTerm s) -> IO (SharedTerm s)
  , scRecordSelect  :: SharedTerm s -> FieldName -> IO (SharedTerm s)
  , scApplyCtor     :: TypedCtor -> [SharedTerm s] -> IO (SharedTerm s)
  , scFun           :: SharedTerm s -> SharedTerm s -> IO (SharedTerm s)
  , scLiteral       :: Integer -> IO (SharedTerm s)
  , scTuple         :: [SharedTerm s] -> IO (SharedTerm s)
  , scTupleType     :: [SharedTerm s] -> IO (SharedTerm s)
  , scTypeOf        :: SharedTerm s -> IO (SharedTerm s)
  , scPrettyTermDoc :: SharedTerm s -> Doc
  -- | Returns term as a constant Boolean if it can be evaluated as one.
  , scViewAsBool    :: SharedTerm s -> Maybe Bool
  -- | Returns term as an integer if it is an integer, signed
  -- bitvector, or unsigned bitvector.
  , scViewAsNum     :: SharedTerm s -> Maybe Integer
  , scInstVarList   :: DeBruijnIndex -> [SharedTerm s] -> SharedTerm s -> IO (SharedTerm s)
  }

scApplyAll :: SharedContext s -> SharedTerm s -> [SharedTerm s] -> IO (SharedTerm s)
scApplyAll sc = foldlM (scApply sc)

scNat :: SharedContext s -> Integer -> IO (SharedTerm s)
scNat = error "scNat unimplemented"

-- | Obtain term representation a bitvector with a given width and known
-- value.
scBitvector :: SharedContext s
            -> (SharedTerm s)
            -> Integer
            -> IO (SharedTerm s)
scBitvector = error "scBitvector unimplemented"

scPrettyTerm :: SharedContext s -> SharedTerm s -> String
scPrettyTerm sc t = show (scPrettyTermDoc sc t)

scFunAll :: SharedContext s -> [SharedTerm s] -> SharedTerm s -> IO (SharedTerm s)
scFunAll sc argTypes resultType = foldrM (scFun sc) resultType argTypes

------------------------------------------------------------
-- | The default instance of the SharedContext operations.
mkSharedContext :: Module -> IO (SharedContext s)
mkSharedContext m = do
  vr <- newMVar  0 -- ^ Reference for getting variables.
  cr <- newAppCacheRef
--  let shareDef d = do
--        t <- sharedTerm cr $ Term (FTermF (GlobalDef (defIdent d)))
--        return (defIdent d, t)
--  sharedDefMap <- Map.fromList <$> traverse shareDef (moduleDefs m)
--  let getDef sym =
--        case Map.lookup (mkIdent (moduleName m) sym) sharedDefMap of
--          Nothing -> fail $ "Failed to find " ++ show sym ++ " in module."
--          Just d -> return d
  let typeOfGlobal ident =
        case findDef m ident of
          Nothing -> fail $ "Failed to find " ++ show ident ++ " in module."
          Just d -> sharedTerm cr (defType d)
  let freshGlobal sym tp = do
        i <- modifyMVar vr (\i -> return (i,i+1))
        return (STVar i sym tp)
  let viewAsNum (asNatLit -> Just i) = Just i
      viewAsNum _ = Nothing
  return SharedContext {
             scModule = return m
           , scTermF = getTerm cr
           , scFreshGlobal = freshGlobal
           , scLookupDef = getFlatTerm cr . GlobalDef . mkIdent (moduleName m)
           , scDefTerm = undefined
           , scApply = \f x -> getFlatTerm cr (App f x)
           , scMkRecord = undefined
           , scRecordSelect = undefined
           , scApplyCtor = undefined
           , scFun = \a b -> do b' <- Verifier.SAW.SharedTerm.incVars cr 0 1 b
                                getTerm cr (Pi "_" a b')
           , scLiteral = getFlatTerm cr . NatLit
           , scTuple = getFlatTerm cr . TupleValue
           , scTupleType = getFlatTerm cr . TupleType
           , scTypeOf = typeOf cr typeOfGlobal
           , scPrettyTermDoc = undefined
           , scViewAsBool = undefined
           , scViewAsNum = viewAsNum
           , scInstVarList = instantiateVarList cr
           }

asNatLit :: SharedTerm s -> Maybe Integer
asNatLit (STApp _ (FTermF (NatLit i))) = Just i
asNatLit _ = Nothing

asApp :: SharedTerm s -> Maybe (SharedTerm s, SharedTerm s)
asApp (STApp _ (FTermF (App t u))) = Just (t,u)
asApp _ = Nothing

asApp3Of :: SharedTerm s -> SharedTerm s -> Maybe (SharedTerm s, SharedTerm s, SharedTerm s)
asApp3Of op s3 = do
  (s2,a3) <- asApp s3
  (s1,a2) <- asApp s2
  (s0,a1) <- asApp s1
  if s0 == op then return (a1,a2,a3) else fail ""
