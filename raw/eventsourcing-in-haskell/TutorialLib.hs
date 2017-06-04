{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE RankNTypes            #-}

module TutorialLib
  ( Aggregate(..)
  , AggregateAction
  , EventSourcingError(..)
  , AggInit
  , AggApply
  , mkAggregate
  , runAggregateAction
  , getAS
  , getsAS
  , raise
  , load
  , createSnapshot
  , loadSnapshot
  , clearRaisedEvents
  -- * re-exports
  , throwError
  ) where

import           Control.Monad.Except (ExceptT, MonadError, runExceptT,
                                       throwError)
import           Control.Monad.State  (StateT, execStateT, get, gets, modify',
                                       put)
import           Data.Text            (Text)

type AggInit err ev s
  = forall m. MonadError (EventSourcingError err) m => ev -> m s

type AggApply err ev s
  = forall m. MonadError (EventSourcingError err) m => s -> ev -> m s

data Aggregate err ev s = Aggregate
  { aggState        :: Maybe s
  , aggInit         :: AggInit err ev s
  , aggApply        :: AggApply err ev s
  , aggVersion      :: Int
  , aggRaisedEvents :: [ev]
  }

type AggregateAction err ev s m a
  = StateT (Aggregate err ev s) (ExceptT (EventSourcingError err) m) a

data EventSourcingError err
  = StateDerivingFailure Text
  | UnknownState
  | DomainError err
  deriving (Show)

mkAggregate
  :: AggInit err ev s
  -> AggApply err ev s
  -> Aggregate err ev s
mkAggregate initAgg apply = Aggregate Nothing initAgg apply 0 []

runAggregateAction
  :: Monad m
  => Aggregate err ev s -> AggregateAction err ev s m a -> m (Either (EventSourcingError err) (Aggregate err ev s))
runAggregateAction agg action = runExceptT $ execStateT action agg

raise :: Monad m => ev -> AggregateAction err ev s m ()
raise ev = do
  agg <- get
  st <- gets aggState
  st' <- maybe (aggInit agg) (aggApply agg) st ev

  put $ agg { aggState = Just st'
            , aggVersion = aggVersion agg + 1
            , aggRaisedEvents = aggRaisedEvents agg ++ [ev] }

getAS :: Monad m => AggregateAction err ev s m s
getAS = gets aggState >>= maybe (throwError UnknownState) return

getsAS :: Monad m => (s -> b) -> AggregateAction err ev s m b
getsAS f = fmap f getAS

load :: Monad m => [ev] -> AggregateAction err ev s m ()
load xs = mapM_ raise xs >> clearRaisedEvents

createSnapshot :: Monad m => AggregateAction err ev s m (Int, s)
createSnapshot = do
  version <- gets aggVersion
  st <- getAS
  return (version, st)

loadSnapshot :: Monad m => (Int, s) -> AggregateAction err ev s m ()
loadSnapshot (version, st) = modify' $ \agg ->
  agg { aggState  = Just st
      , aggVersion = version }

clearRaisedEvents :: Monad m => AggregateAction err ev s m ()
clearRaisedEvents = modify' $ \agg -> agg { aggRaisedEvents = [] }
