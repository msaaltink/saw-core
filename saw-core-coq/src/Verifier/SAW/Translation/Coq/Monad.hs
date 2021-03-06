{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Verifier.SAW.Translation.Coq
Copyright   : Galois, Inc. 2018
License     : BSD3
Maintainer  : atomb@galois.com
Stability   : experimental
Portability : portable
-}

module Verifier.SAW.Translation.Coq.Monad
  ( TranslationConfiguration(..)
  , TranslationConfigurationMonad
  , TranslationMonad
  , TranslationError(..)
  , runTranslationMonad
  ) where

import qualified Control.Monad.Except as Except
import Control.Monad.Reader hiding (fail)
import Control.Monad.State hiding (fail, state)
import Prelude hiding (fail)

import Verifier.SAW.SharedTerm
-- import Verifier.SAW.Term.CtxTerm
--import Verifier.SAW.Term.Pretty
-- import qualified Verifier.SAW.UntypedAST as Un

data TranslationError a
  = NotSupported a
  | NotExpr a
  | NotType a
  | LocalVarOutOfBounds a
  | BadTerm a
  | CannotCreateDefaultValue a

instance {-# OVERLAPPING #-} Show (TranslationError Term) where
  show = showError showTerm

instance {-# OVERLAPPABLE #-} Show a => Show (TranslationError a) where
  show = showError show

showError :: (a -> String) -> TranslationError a -> String
showError printer err = case err of
  NotSupported a -> "Not supported: " ++ printer a
  NotExpr a      -> "Expecting an expression term: " ++ printer a
  NotType a      -> "Expecting a type term: " ++ printer a
  LocalVarOutOfBounds a -> "Local variable reference is out of bounds: " ++ printer a
  BadTerm a -> "Malformed term: " ++ printer a
  CannotCreateDefaultValue a -> "Unable to generate a default value of the given type: " ++ printer a

data TranslationConfiguration = TranslationConfiguration
  { notations          :: [(String, String)]
  -- ^ We currently don't have a nice way of mapping Cryptol notations to Coq
  -- notations.  Instead, we provide a mapping from the notation symbol to an
  -- identifier to use instead.
  , monadicTranslation :: Bool
  -- ^ Whether to wrap everything in a free monad construction.
  -- - Advantage: fixpoints can be readily represented
  -- - Disadvantage: pure computations look more gnarly
  , skipDefinitions    :: [String]
  , vectorModule       :: String
  -- ^ all vector operations will be prepended with this module name, i.e.
  -- "<VectorModule>.append", etc.  So that it can be retargeted easily.
  -- Current provided options are:
  -- - SAWCoreVectorsAsCoqLists
  -- - SAWCoreVectorsAsCoqVectors
  -- Currently considering adding:
  -- - SAWCoreVectorsAsSSReflectSeqs
  }

type TranslationConfigurationMonad m =
  ( MonadReader TranslationConfiguration m
  )

type TranslationMonad s m =
  ( Except.MonadError (TranslationError Term)  m
  , TranslationConfigurationMonad m
  , MonadState s m
  )

runTranslationMonad ::
  TranslationConfiguration ->
  s ->
  (forall m. TranslationMonad s m => m a) ->
  Either (TranslationError Term) (a, s)
runTranslationMonad configuration state m = runStateT (runReaderT m configuration) state
