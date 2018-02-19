---
title: Implementing an efficient GeoIP lookup using STM and Async (Part 1)
author: Philipp Maier
summary:
  One of my first private projects I wrote with Haskell involved fetching GeoIP information from a remote service.
  Now, roughly 1.5 years later, I want to come back to that implementation and reflect on it.
tags: Haskell, STM, Async, Aeson
discussId: post-2
---

## Introduction ##

One of my first private projects I wrote with Haskell involved fetching GeoIP information from a remote service. Now, roughly 1.5 years later, I want to come back to that implementation and reflect on it. Back then it really excited me, so I thought I should share this experience in a blog post.

Since this blog is explicitly targeted at beginners, I will not just simply refactor and abstract my original implementation. I will implement the lookup from scratch. This will give you insight into how to implement this and, more importantly, what the thought process looks like.

The goal is to implement a fast and efficient GeoIP lookup that can handle at least 50 lookups per second. The roadmap for that looks like this:

1. Implement quering the free REST GeoIP service <a href="http://freegeoip.net" target="_blank">freegeoip.net</a> to retrieve GeoIP information.
2. Make it so that multiple worker threads are quering the service concurrently for speed.
3. Introduce a cache to prevent quering the service for the same IPs multiple times.
4. Abstract the GeoIP lookup to work for arbitrary IO actions.

The following resources are accompanying this post:

* My original implementation: <a href="../raw/geoip-lookup/GeoIP.hs" target="_blank">GeoIP.hs</a>.
* A GitHub repository with the code to play around with: <a href="https://github.com/Akii/geoip-lookup" target="_blank">Akii/geoip-lookup</a>.

## 1. Looking up geo information for IPv4 addresses <br/><small>Code: src/Chapter1.hs <a href="https://github.com/Akii/geoip-lookup/blob/master/src/Chapter1.hs" target="_blank"><i class="fa fa-github"></i></a></small>

The first step is to implement querying the remote service. This is fairly straight forward with two libraries: <a href="https://hackage.haskell.org/package/aeson" target="_blank">aeson</a> and <a href="https://hackage.haskell.org/package/http-conduit" target="_blank">http-conduit</a>. First we define the data types. For convenience I simply derive the FromJSON instance.

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

import           ClassyPrelude
import           Data.Aeson
import           Network.HTTP.Simple

-- | Represents an IP address like 172.217.22.46
newtype IPAddress = IPAddress
  { getAddress :: String
  }

-- | Allows us to write ("172.217.22.46" :: IPAddress)
instance IsString IPAddress where
  fromString = IPAddress

-- | Result of a GeoIP lookup. Record names match payload for convenient
--   JSON decoding.
data LookupResult = LookupResult
  { country_code :: Text
  , country_name :: Text
  } deriving (Show, Generic, FromJSON)
```

The library http-conduit offers a very simple HTTP client as shown below.

```haskell
-- | Query the server and get a result. Throws an exception if anything fails.
fetchGeoIP :: IPAddress -> IO LookupResult
fetchGeoIP ipAddr = do
  req <- parseRequest ("http://freegeoip.net/json/" <> getAddress ipAddr)
  getResponseBody <$> httpJSON req
```

And with that, we're already done with the querying part! Pretty boring.
Now let's actually run it.

```haskell
lookupOne :: IO ()
lookupOne = fetchGeoIP "172.217.22.46" >>= print

-- let it run in ghci
> λ lookupOne
> LookupResult {country_code = "US", country_name = "United States"}
```

Neat! There is just a tiny problem: It's very slow. If we try to sequentially query a large amount of IP addresses things will naturally be very slow. And our goal is to make at least 50 lookups per second.

```haskell
-- That module holds a list of IP addresses as [String]
import IPs

lookupAll :: IO ()
lookupAll =
  forM_ manyIPs $ \ip -> fetchGeoIP (IPAddress ip) >>= print

-- let it run in ghci
> λ lookupAll
> LookupResult {country_code = "BR", country_name = "Brazil"}
> LookupResult {country_code = "DE", country_name = "Germany"}
> LookupResult {country_code = "ZM", country_name = "Zambia"}
> LookupResult {country_code = "AU", country_name = "Australia"}
> ...
```

Without actually measuring performance, it's a good estimation that this method can lookup around 4 IPs per second. It's about time to distribute the work between multiple threads.

## 2. Concurrently looking up IPs <br/><small>Code: src/Chapter2.hs <a href="https://github.com/Akii/geoip-lookup/blob/master/src/Chapter2.hs" target="_blank"><i class="fa fa-github"></i></a></small>

There are many ways of performing IO actions concurrently or in parallel. Choosing the right method heavily depends on the use-case. I can highly recommend Simon Marlow's book <a href="https://simonmar.github.io/pages/pcph.html" target="_blank">Parallel and Concurrent Programming in Haskell</a>, which is the de-facto standard literature on that subject.

In my private project I had an event stream of IP addresses to look up. That made it impossible to concurrently map a static list. Additionally, I wasn't sure how many IPs I would have to look up at a certain time and I didn't want to have an unlimited amount of concurrent requests going out. Because of that I decided to use TQueue, a queue from the STM library (<a href="https://hackage.haskell.org/package/stm-2.4.5.0/docs/Control-Concurrent-STM-TQueue.html" target="_blank">TQueue on Hackage</a>) and have a fixed number of workers process the queue. So let's start with the data types and API.

```haskell
[1] data GeoIPLookup
[2] type JobResult = Either SomeException LookupResult

[3] mkGeoIPLookup :: Int -> (IPAddress -> IO LookupResult) -> IO GeoIPLookup
[4] lookupIP :: GeoIPLookup -> IPAddress -> IO (Async JobResult)
[5] processQueue :: GeoIPLookup -> Int -> IO ()
[6] worker :: GeoIPLookup -> IO ()
```

1. We'll need some sort of data type holding the queue and lookup function.
2. You probably already noticed that the function `fetchGeoIP`, that we wrote in chapter 1, is throwing exceptions. This means looking up geo IP information can fail. At some point we will need to handle this. There is the possibility to make `LookupResult` a sum type and include a failure case. I chose to use this representation instead.
3. The idea behind this function is to have a way of creating a value of type `GeoIPLookup`. We already know we're going to have a number of worker threads, so that is one argument. We also need a way of looking up IP information, that's the second argument. Creating a new TQueue requires IO, thus the return type must be `IO GeoIPLookup`.
4. This function will serve as our new way of looking up IPs. It will take a `GeoIPLookup` and `IPAddress` as argument and produce a value that will eventually hold the `JobResult`. So this function will insert the IP address into the queue and then offer a way of "waiting" until the lookup has been processed. This is encoded as `Async` from the library <a href="https://hackage.haskell.org/package/async">async</a>.
5. By using the function `worker`, this function will create a number of worker threads.
6. The definition of what a single worker will do.

Let's implement the functions starting with `lookupIP`. From our function definitions above, we can derive what the data type `GeoIPLookup` must look like. There is yet one thing to figure out: What the type of the TQueue is. Since all we can do is write to and read from the queue, there is no direct way of returning the lookup result. Remember, the workers will be asynchronously reading from the queue. The "trick" is to use a TVar:

```haskell
import ClassyPrelude
import Chapter1

type JobResult = Either SomeException LookupResult

data GeoIPLookup = GeoIPLookup
  { ipLookup      :: IPAddress -> IO LookupResult
  , ipLookupQueue :: TQueue (IPAddress, TVar (Maybe JobResult))
  }

lookupIP :: GeoIPLookup -> IPAddress -> IO (Async JobResult)
lookupIP l ipAddr = async $ do
  var <- newTVarIO Nothing
  atomically $ writeTQueue (ipLookupQueue l) (ipAddr, var)

  atomically $ do
    done <- readTVar var
    case done of
      Nothing  -> retrySTM
      Just res -> return res
```

TVar and TQueue both come from the STM library. STM stands for software transactional memory and enables us to manipulate variables inside transactions (think: database transaction). Let me briefly explain the used functions. Consult Marlow's book for a more detailed and complete STM introduction.

```haskell
[1] atomically :: STM a -> IO a
[2] newTVarIO :: a -> IO (TVar a)
[3] writeTQueue :: TQueue a -> a -> STM ()
[4] readTVar :: TVar a -> STM a
[5] retrySTM :: STM a
```

1. Executes an STM transaction inside IO.
2. Creates a new TVar with the provided value as content. In the above code we create a new TVar with Nothing as value.
3. Appends a new value to the end of the queue. Note that this is inside the STM monad, and therefore inside a transaction.
4. Read the value of a TVar inside a transaction.
5. Retries the transaction. Calling this function will abort the transaction and discard any changes made (like writing TVars or into TQueues). This is more useful than it looks on first sight. STM is smart enough to not infinitely retry the transaction. Instead it waits until actual changes have been made to the used variables and can detect deadlocks in case a state is unreachable.

Let's come back to our implementation:

```haskell
lookupIP :: GeoIPLookup -> IPAddress -> IO (Async JobResult)
lookupIP l ipAddr = async $ do
  var <- newTVarIO Nothing
  atomically $ writeTQueue (ipLookupQueue l) (ipAddr, var)

  atomically $ do
    done <- readTVar var
    case done of
      Nothing  -> retrySTM
      Just res -> return res
```

There are two transactions going on here (three if you count newTVarIO). In the first transaction we write a tuple `(IPAddress, TVar)` to the queue. In the second we "watch" the value of the TVar. As long as the content of the variable is Nothing, we will retry the transaction. As soon as it has a value, we return. All of that happens inside a thread because of the `async` function in line 2. Eventually one of the workers will read from the queue, generate a `JobResult` and write it to the TVar. This will trigger STM and cause the transaction to be completed, fulfilling the Async.

With the writing side being done, let's implement the remaining functions.

```haskell
{-# LANGUAGE RecordWildCards #-}

mkGeoIPLookup :: Int -> (IPAddress -> IO LookupResult) -> IO GeoIPLookup
mkGeoIPLookup n f = do
  glookup <- GeoIPLookup <$> pure f <*> newTQueueIO
  processQueue glookup n
  return glookup

processQueue :: GeoIPLookup -> Int -> IO ()
processQueue l n = replicateM_ n (worker l)

worker :: GeoIPLookup -> IO ()
worker GeoIPLookup {..} = void . fork . forever $ do
  (ipAddr, var) <- atomically $ readTQueue ipLookupQueue
  res <- try (ipLookup ipAddr)
  atomically $ writeTVar var (Just res)
```

Implementing `mkGeoIPLookup` is pretty much straight forward: Create the value and start processing the queue. `processQueue` simply replicates workers. A worker will forever read from the queue (and block if there are no entries in it), perform the lookup while catching any exceptions thrown, and write the result to the TVar. Using the language extension `RecordWildCards` we bring all record fields into scope (ipLookupQueue and ipLookup).

With all that done we can now fetch geo IP information concurrently. In order to be able to properly see printed output, I use the package `concurrent-output`.

```haskell
import System.Console.Concurrent
import IPs

lookupAll :: IO ()
lookupAll = do
  glookup <- mkGeoIPLookup 10 fetchGeoIP
  withConcurrentOutput . forM_ manyIPs $ \ip -> do
    as <- lookupIP glookup (IPAddress ip)
    void . fork $ waitAsync as >>= outputConcurrent . mappend "\n" . tshow

-- let it run in ghci
> λ lookupAll
> Right (LookupResult {country_code = "ZM", country_name = "Zambia"})
> Right (LookupResult {country_code = "BR", country_name = "Brazil"})
> Right (LookupResult {country_code = "GB", country_name = "United Kingdom"})
> Right (LookupResult {country_code = "AU", country_name = "Australia"})
> Right (LookupResult {country_code = "US", country_name = "United States"})
> Right (LookupResult {country_code = "SG", country_name = "Singapore"})
> Right (LookupResult {country_code = "MU", country_name = "Mauritius"})
> Right (LookupResult {country_code = "US", country_name = "United States"})
> ... really fast this time, because concurrent!
```

## Summary ##

In part 1 of this series about implementing an efficient GeoIP lookup we implemented the HTTP client for the remote service. Then we made looking up IPs fast by using concurrency and STM. In the next part we will be implementing a cache and request collapsing so that each IP is looked up exactly once. Furthermore we will try to abstract this implementation to work with any IO action.

As a reminder, the GitHub repository containing the code can be found <a href="https://github.com/Akii/geoip-lookup" target="_blank">here</a>.
If you have questions or suggestions please feel free to leave them in the comment section below.
