---
title: Eventsourced aggregates in Haskell
author: Philipp Maier
summary:
  Introduction to projections and event sourcing aggregates in Haskell.
  First I'll give a brief implementation of projections using `foldl` along with an example.
  After that, I explain my approach of using a simple Monad transformer stack to implement aggregates and make actions composable.
tags: Event Sourcing, Haskell, Domain-Driven Design
discussId: post-1
---

## Introduction ##

First of all, welcome. This is boring Haskell, so if you're looking for exciting Haskell this might not be the right blog.
I consider myself a beginner Haskell programmer that has reached productivity level. I also do mostly "business" stuff, Domain-Driven Design and sending around domain events.

In this first post I'll be digging into eventsourced aggregates in Haskell. If you are unfamiliar with event sourcing, you might want to get a quick introduction [here](https://docs.microsoft.com/en-us/azure/architecture/patterns/event-sourcing).

It basically means that instead of persisting some state like "Johns account balance is 100 €" you keep track of the changes to Johns account "First he deposited 125 €, then withdrew 25 €". Aggregates protect invariants like "John can only withdraw 25 € if he actually has enough money on his account". There is obviously _a lot_ more to it, but for the purpose of this blog post this is all I care about.

At first I will introduce projections (aka folds) that are used to derive state from event streams. Then I will show one possible implementation of aggregates using a Monad transformer stack.

I will try to provide enough examples so that no previous knowledge is required. There is a comment section below in case of questions.

## Projections ##

The technical core of event sourcing is deriving state from a series of domain events. In event sourcing terms this is referred to as "projection" or "projecting state". Although one can argue that this term is heavily overloaded, I will use it as I think it's the most common term.

Projections are ubiquitous in all eventsourced applications. Some serve as read models where others serve as state for validating invariants.

They can be expressed as a fold. Here's the (simplified) type signature for `foldl`:

```haskell
foldl :: (state -> event -> state) -> state -> [event] -> state
```

There are three parts to this function:

1. `(state -> event -> state)` is a function that _applies_ an event to a state
2. `state` is the initial state
3. `[event]` are the events to be applied to the initial state

The outcome is the final state, after applying all the domain events. This is pretty basic and there is no magic. In "the real world", projections will write into databases, websockets and do all sorts of side-effects, but at the base it's just processing one event after the other.

## Example: List of registered users ##

In our fictional application we use event sourcing to keep track of our users.

A user consists of a `UserName` as well as an `EmailAddress`. A user is either registered or archived. Archived users should no longer be visible in the system.

Since we're using event sourcing, the first thing to do is define the appropriate domain events. This is the information we'll be saving:

```haskell
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
```

In order to, for instance, have a list of non archived users a projection is required. As I said in the introduction, this can be accomplished by simply folding over the past events:

```haskell
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
```

If we run this example you'll get the list of non archived users:

```haskell
main :: IO ()
main = do
  let events = [UserRegistered "user1" "user@example.com",
                UserRegistered "user2" "user2@example.com",
                UserEmailAddressChanged "user1" "new@example.com",
                UserRegistered "user3" "user3@example.com",
                UserArchived "user2"]
  print (projectActiveUsers events)
  
-- fromList [
--   ("user1",RegisteredUser {userName = "user1", emailAddress = "new@example.com"}),
--   ("user3",RegisteredUser {userName = "user3", emailAddress = "user3@example.com"})]
```

As expected, the user 2 is no longer in the list and user 1's email address has been changed.

It is noteworthy that the default Monoid for map (left leaning union) is not the correct one to use here:

```haskell
projectActiveUsers [UserRegistered "username" "email@address.com"]
  <> projectActiveUsers [UserArchived "username"]
```

The expected result should be an empty map, however through union the event `UserArchived` is simply ignored.
The correct Monoid to use would be right leaning union that keeps track of deletions.

This is intentionally handwavy formulated as I am still investigating those properties.
My current idea is having a morphism `ev -> s` and a (correct) Semigroup defined for `s` could give you stuff like projecting state in parallel. Should I make any noteworthy discoveries I will write them down later.

## Eventsourced aggregates ##

Now that we have a basic understanding of projections, I can introduce aggregates: Producer of domain events and guardians of business invariants.

The most basic example implementation of an aggregate is this:

```haskell
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
```

So given the past events this function decides whether the user can actually be registered with the given `UserName` and `EmailAddress`. Failures are encoded in the sum type `UserError`. The only possible result in case of success is a list of new events `[UserEvent]`.

In order to protect invariants, state needs to be derived. This is again a projection. I'm re-using the projection from earlier, but usually the states for guarding invariants are different ones than those that are used in the view.

There are a few problems when doing this:

* The projection happens inside the function, and each of your aggregate actions must project the whole list of events again.
* Composition is tedious because of the return type (yes, I'm sure you could work around that).

There is a bit more to aggregates. Each aggregate is versioned to prevent committing it to a stream that has been modified in the meantime. When committing an aggregate to a stream you have to also specify the version you loaded your aggregate with to prevent it from becoming inconsistent (see 1. for how an event store API might look like).

### The AggregateAction Monad transformer stack

All in all this screams Monad. More precisely: this screams `State` and `Except`. So I made this Monad stack and a data type for aggregates:

```haskell
     data Aggregate event state = Aggregate
[1]    { aggState        :: Maybe state
[1]    , aggInit         :: event -> state
[1]    , aggApply        :: state -> event -> state
[2]    , aggVersion      :: Int
[3]    , aggRaisedEvents :: [event]
       }

[4]  type AggregateAction error event state a
[4]    = StateT (Aggregate event state) (Except error) a
```

So let's get over this step by step:

1) I embodied the projection into the data type. This hardly looks like the projection I introduced earlier, but when looking closer it is actually just split up. First of all, the state for a new aggregate is undefined since no events have been raised yet. Because of this, the state is optional and represented as `Maybe state`. In order to produce the initial state the first event is required. This is done with the function `aggInit`. Secondly, the `aggApply` function can operate on existing state and apply newly raised events to the aggregate state. This way the aggregate's state is actually applied "on the fly" when composing!

2) This is the aggregates version. It is increased as events are raised and when committing to the stream the original version can be calculated by subtracting the number of raised events.

3) In case all our aggregate actions run through, this holds all newly raised events that will be committed to the event stream of the aggregate.

4) The Monad stack. When running an `AggregateAction` the return type will be `Either error (Aggregate event state)`. If you are unfamiliar with this: it's hardly of any relevance, following the code examples doesn't require knowledge of Monad transformers.

With this Monad stack and data type we can now implement the function `raise` in order to raise new domain events, as well as `runAggregateAction` to run the Monad stack:

```haskell
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
```

Let's look at this in action. First thing we can do is specialize the `AggregateAction` type:

```haskell
type RegistrationAction a
  = AggregateAction UserError UserEvent UserList a
```

After that we need to define an empty aggregate. This includes specifying the projection to be used.

In my library I've written a function that takes `aggInit` and `aggApply` as arguments and returns an empty aggregate:

```haskell
newRegisterUserAgg :: Aggregate UserEvent UserList
newRegisterUserAgg = Aggregate
  { aggState = Nothing
  , aggInit = apply mempty        -- `apply` was defined in part 1
  , aggApply = apply
  , aggVersion = 0
  , aggRaisedEvents = []
  }
```

Now it's time to implement the new `registerUser'` function:

```haskell
registerUser' :: UserName -> EmailAddress -> RegistrationAction ()
registerUser' uname email = do
  st <- gets (fromMaybe mempty . aggState)

  when (userExists st) (throwError UserAlreadyRegistered)
  when (emailExists st) (throwError EmailAddressExists)
  raise (UserRegistered uname email)

  where
    userExists = member uname
    emailExists users = email `elem` fmap emailAddress (elems users)
```

Now let's run that and see what happens:

```haskell
main' :: IO ()
main' = do
  let result1 = runAggregateAction newRegisterUserAgg $ do
        registerUser' "user1" "user1@example.com"
        registerUser' "user2" "user2@example.com"

      result2 = runAggregateAction newRegisterUserAgg $ do
        registerUser' "user1" "user1@example.com"
        registerUser' "user2" "user1@example.com"

  putStrLn "Result of 1 is:"
  print (aggState <$> result1)        -- outputs Right (map of users as seen previously)
  print (aggRaisedEvents <$> result1) -- outputs Right (list with 2 raised events)

  putStrLn "Result of 2 is:"
  print (aggState <$> result2)        -- outputs Left EmailAddressExists
```

Let's reflect on how this improved the original basic aggregate implementation:

#### Procedural code
Because of the `do` notation, the code becomes procedural. I guess one could argue about the readability - I personally think it makes "business code" more readable. First check this invariant then the other invariant and if that succeeds, raise an event.

#### The argument `[UserEvent]` has been factored out
The argument `[UserEvent]` is no longer required as it is part of the aggregate given when running the action. Compare the function signatures `registerUser` with `registerUser'`:

* `[UserEvent] -> UserName -> EmailAddress -> Either UserError [UserEvent]`
* `UserName -> EmailAddress -> RegistrationAction ()`

#### Actions are composable
Not only is the `AggregateAction` decoupled from the actual projection, it also projects state "on the go". This way you can compose multiple `AggregateAction`s and get a guarantee that your state is always up-to-date (this is actually used in "result2").

#### Automatic handling of the aggregate version
The aggregates version is also now part of the aggregate data type and automatically increased with each raised event.

#### Actions have a return type
`AggregateAction`s have a return type that is independent from raised events. With this you can write reusable functions that work for any `AggregateAction`. I've some examples in the module TutorialLib that accompanies this blog post (see footnotes).

#### Built in snapshotting
Snapshotting is practically built in: `createSnapshot :: Aggregate event state -> Maybe (Int, state)`.

## Summary

That's a lot of cool stuff I'd say. Please note that is just one of many possible solutions.
If you want to run the code you can download the file [Tutorial.hs](/raw/eventsourcing-in-haskell/Tutorial.hs) and just load it up wit GHCi.

At the end of the page is the comment section, should you have any questions. Please be kind as this is my first blog post in ages!

There is still one issue left I want to address. This requires some "advanced" Haskell knowledge and I won't be explaining what's going on too much. So if you're unable to follow along, just come back later!

## Appendix: Error detection and handling

Back when I started with Haskell and looked at some solutions one thing always bugged me: how those solutions handled errors.

So what happens if you have a corrupt stream for some reason? Or you have a bug in your projection? What about `aggInit` and it having to be a total function (right now this function must produce an initial value for every given event)?

One could use exceptions but we can do better than that.

Let's look at how we can detect some errors when projecting state:

```haskell
projectActiveUsers' :: [UserEvent] -> UserList
projectActiveUsers' = foldl' applySafe
  where
    applySafe list (UserRegistered uname email) =
      case lookup uname list of
        Nothing -> insert uname (User uname email) list
        Just u  -> -- Now what
```

That's an obvious contradiction. We're getting a `UserRegistered` event but the user is already registered!
So there must be an error in the stream then, or an bug in the projection. Usually errors like these are not handled in projections, however, when dealing with loading aggregates I think it would be better to detect this, rather than ignoring it.

Then how can we handle this? One obvious way is to throw an exception. Chicken, err, I mean `error` out. We can also incorporate failure into the aggregates projection type signature. So let's try that:

```haskell
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RankNTypes #-}

data EventSourcingError err
  = StateDerivingFailure Text
  | UnknownState
  | DomainError err
  deriving (Show)

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
```

The projection of the aggregate can fail now.

### Example: Failing if the first event is not UserRegistered

```haskell
newRegisterUserAgg :: Aggregate UserError UserEvent UserList
newRegisterUserAgg = Aggregate
  { aggState = Nothing
  , aggInit = insertFirstUser
  , aggApply = (return .) . apply
  , aggVersion = 0
  , aggRaisedEvents = []
  }

-- So the first event must always be UserRegistered
-- Both UserEmailAddressChanged and UserArchived make no sense
-- if no user was previously registered
insertFirstUser :: AggInit UserError UserEvent UserList
insertFirstUser ev =
  case ev of
    (UserRegistered uname email) -> return (M.insert uname (User uname email) mempty)
    _                            ->
      throwError (StateDerivingFailure "First event must be UserRegistered.")
```

Now `insertFirstUser` actually fails in case the first event isn't `UserRegistered`. Normally you'd now also add error detection to the `aggApply` function (I leave this as a task for the reader).

Let's run that and see what happens:

```haskell
main :: IO ()
main = do
  result1 <- runAggregateAction newRegisterUserAgg
               (load [UserRegistered "user1" "user1@example.com",
                      UserRegistered "user2" "user2@example.com"])

  result2 <- runAggregateAction newRegisterUserAgg
               (load [UserEmailAddressChanged "user1" "changed@example.com"])

  -- Right (Map with two users in it)
  print (aggState <$> result1)
  
  -- Left (StateDerivingFailure "First event must be UserRegistered.")
  print (aggState <$> result2)
```

In my opinion, this is a better way to deal with errors than simply ignoring them or throwing exceptions.

If you want to run that code download the files [TutorialError.hs](/raw/eventsourcing-in-haskell/TutorialError.hs) and [TutorialLib.hs](/raw/eventsourcing-in-haskell/TutorialLib.hs).

____________
1) [http://docs.geteventstore.com/dotnet-api/4.0.0/optimistic-concurrency-and-idempotence/](http://docs.geteventstore.com/dotnet-api/4.0.0/optimistic-concurrency-and-idempotence/)
2) [Tutorial.hs](/raw/eventsourcing-in-haskell/Tutorial.hs)
3) [TutorialError.hs](/raw/eventsourcing-in-haskell/TutorialError.hs)
4) [TutorialLib.hs](/raw/eventsourcing-in-haskell/TutorialLib.hs)
