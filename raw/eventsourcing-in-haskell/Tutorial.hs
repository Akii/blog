{-# LANGUAGE OverloadedStrings #-}

module Tutorial where

import           Control.Monad.Except
import           Control.Monad.State
import           Data.List            (foldl')
import           Data.Map             (Map, adjust, delete, elems, insert,
                                       member)
import           Data.String

--------------------------------------------------------
-- Part 1: Projections
--------------------------------------------------------

newtype UserName = UserName String
  deriving (Eq, Ord, Show)

newtype EmailAddress = EmailAddress String
  deriving (Eq, Ord, Show)

instance IsString UserName where
  fromString = UserName

instance IsString EmailAddress where
  fromString = EmailAddress

data UserEvent
  = UserRegistered UserName EmailAddress
  | UserEmailAddressChanged UserName EmailAddress
  | UserArchived UserName
  deriving (Show)

type UserList = Map UserName User

data User = User
  { userName     :: UserName
  , emailAddress :: EmailAddress
  } deriving (Eq, Show)

projectActiveUsers :: [UserEvent] -> UserList
projectActiveUsers = foldl' apply mempty

apply :: UserList -> UserEvent -> UserList
apply list ev =
  case ev of
    (UserRegistered username email) ->
      insert username (User username email) list
    (UserEmailAddressChanged username email) ->
      adjust (\u -> u {emailAddress = email}) username list
    (UserArchived username) ->
      delete username list

main :: IO ()
main = do
  let events = [UserRegistered "user1" "user@example.com",
                UserRegistered "user2" "user2@example.com",
                UserEmailAddressChanged "user1" "new@example.com",
                UserRegistered "user3" "user3@example.com",
                UserArchived "user2"]
  print (projectActiveUsers events)

--------------------------------------------------------
-- Part 2: Eventsourced Aggregates
--------------------------------------------------------

data UserError
  = UserAlreadyRegistered
  | EmailAddressExists
  deriving (Show)

registerUser :: [UserEvent] -> UserName -> EmailAddress -> Either UserError [UserEvent]
registerUser evs uname email
  | userExists  = Left UserAlreadyRegistered
  | emailExists = Left EmailAddressExists
  | otherwise   = Right [UserRegistered uname email]

  where
    users = projectActiveUsers evs
    userExists = member uname users
    emailExists = email `elem` fmap emailAddress (elems users)

data Aggregate event state = Aggregate
  { aggState        :: Maybe state
  , aggInit         :: event -> state
  , aggApply        :: state -> event -> state
  , aggVersion      :: Int
  , aggRaisedEvents :: [event]
  }

type AggregateAction error event state a
  = StateT (Aggregate event state) (Except error) a

raise :: event -> AggregateAction error event state ()
raise ev = do
  -- Fetch the current aggregate from the State Monad
  agg <- get

  -- The aggregates state, `Maybe state`
  st <- gets aggState

  -- If there is no state yet `aggInit` will create it,
  -- otherwise `aggApply` is used to apply the event to the existing state
  let st' = maybe (aggInit agg) (aggApply agg) st ev

  -- and then we just put the new state
  put $ agg { aggState = Just st'
            , aggVersion = aggVersion agg + 1
            , aggRaisedEvents = aggRaisedEvents agg ++ [ev] }

runAggregateAction
  :: Aggregate event state
  -> AggregateAction error event state a
  -> Either error (Aggregate event state)
runAggregateAction agg action = runExcept (execStateT action agg)

type RegistrationAction a
  = AggregateAction UserError UserEvent UserList a

newRegisterUserAgg :: Aggregate UserEvent UserList
newRegisterUserAgg = Aggregate
  { aggState = Nothing
  , aggInit = apply mempty
  , aggApply = apply
  , aggVersion = 0
  , aggRaisedEvents = []
  }

registerUser' :: UserName -> EmailAddress -> RegistrationAction ()
registerUser' uname email = do
  mst <- gets aggState

  case mst of
    Nothing -> raise (UserRegistered uname email)
    Just st -> do
      when (userExists st) (throwError UserAlreadyRegistered)
      when (emailExists st) (throwError EmailAddressExists)
      raise (UserRegistered uname email)

  where
    userExists = member uname
    emailExists users = email `elem` fmap emailAddress (elems users)

main' :: IO ()
main' = do
  let result1 = runAggregateAction newRegisterUserAgg $ do
        registerUser' "user1" "user1@example.com"
        registerUser' "user2" "user2@example.com"

      result2 = runAggregateAction newRegisterUserAgg $ do
        registerUser' "user1" "user1@example.com"
        registerUser' "user2" "user1@example.com"

  putStrLn "Result of 1 is:"
  print (aggState <$> result1)
  print (aggRaisedEvents <$> result1)

  putStrLn "Result of 2 is:"
  print (aggState <$> result2)
