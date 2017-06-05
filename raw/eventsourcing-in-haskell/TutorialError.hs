{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes        #-}

module TutorialError where

import           Data.Map    (Map)
import qualified Data.Map    as M
import           Data.String

import           TutorialLib

--------------------------------------------------------
-- Part 2,5: Handling failures
--------------------------------------------------------

{--
projectActiveUsers' :: [UserEvent] -> UserList
projectActiveUsers' = foldl' applySafe mempty
  where
    applySafe :: UserList -> UserEvent -> UserList
    applySafe list (UserRegistered uname email) =
      case lookup uname list of
        Nothing -> insert uname (User uname email) list
        Just u -> -- Now what
--}

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

data UserError
  = UserAlreadyRegistered
  | EmailAddressExists
  deriving (Show)

type UserList = Map UserName User

data User = User
  { userName     :: UserName
  , emailAddress :: EmailAddress
  } deriving (Eq, Show)

newRegisterUserAgg :: Aggregate UserError UserEvent UserList
newRegisterUserAgg = Aggregate
  { aggState = Nothing
  , aggInit = insertFirstUser
  , aggApply = (return .) . apply
  , aggVersion = 0
  , aggRaisedEvents = []
  }

-- So the first event must always be UserRegistered
-- Both UserEmailAddressChanged and UserArchived make no sense if no user was previously registered
insertFirstUser :: AggInit UserError UserEvent UserList
insertFirstUser ev =
  case ev of
    (UserRegistered uname email) -> return (M.insert uname (User uname email) mempty)
    _                            -> throwError (StateDerivingFailure "Couldn't derive initial state for something other than UserRegistered event")

-- just copied over, you could add checks now
apply :: UserList -> UserEvent -> UserList
apply list ev =
  case ev of
    (UserRegistered username email) ->
      M.insert username (User username email) list
    (UserEmailAddressChanged username email) ->
      M.adjust (\u -> u {emailAddress = email}) username list
    (UserArchived username) ->
      M.delete username list

main :: IO ()
main = do
  result1 <- runAggregateAction newRegisterUserAgg
               (load [UserRegistered "user1" "user1@example.com",
                      UserRegistered "user2" "user2@example.com"])

  result2 <- runAggregateAction newRegisterUserAgg
               (load [UserEmailAddressChanged "user1" "changed@example.com"])

  print (aggState <$> result1)
  print (aggState <$> result2)
