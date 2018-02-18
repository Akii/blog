{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell     #-}

module GeoIP
  ( GeoIPLookup
  , LookupResult (..)
  , mkIPAddress
  , mkGeoIPLookup
  , mkFreeGeoIPLookup
  , loadCache
  , lookupGeoIP
  , lookupGeoIP_
  , lookupGeoIPCached
  , lookupGeoIPCache
  ) where

import           ClassyPrelude
import           Data.Aeson
import           Data.Aeson.TH
import qualified Data.ByteString.Lazy.Char8 as BS
import           Data.IP                    (IP)
import qualified Data.Map                   as M
import           Network.HTTP
import           Text.Read

newtype IPAddress =
  IPAddress Text
  deriving (Show, Ord, Eq)

type LookupCache = TVar (Map IPAddress LookupResult)

data GeoIPLookup = GeoIPLookup
  { ipLookup      :: IPAddress -> IO LookupResult
  , ipLookupCache :: LookupCache
  , ipLookupQueue :: TQueue (IPAddress, TVar (Maybe LookupResult))
  }

data LookupResult
  = LookupSuccess { ip           :: !IPAddress
                 ,  country_code :: !Text
                 ,  country_name :: !Text
                 ,  region_code  :: !Text
                 ,  region_name  :: !Text
                 ,  city         :: !Text
                 ,  zip_code     :: !Text
                 ,  time_zone    :: !Text
                 ,  latitude     :: !Float
                 ,  longitude    :: !Float}
  | LookupFailure { ip    :: !IPAddress
                 ,  error :: !Text}
  deriving (Show)

deriveJSON defaultOptions ''IPAddress
deriveJSON defaultOptions { sumEncoding = UntaggedValue } ''LookupResult

mkIPAddress :: Text -> Maybe IPAddress
mkIPAddress t =
  let
    mip = readMaybe (unpack t) :: Maybe IP
  in
    fmap (const (IPAddress t)) mip

mkGeoIPLookup :: (IPAddress -> IO LookupResult) -> Int -> IO GeoIPLookup
mkGeoIPLookup f n = do
  l <- GeoIPLookup <$> pure f <*> newTVarIO mempty <*> newTQueueIO
  processQueue l n
  return l

mkFreeGeoIPLookup :: Int -> IO GeoIPLookup
mkFreeGeoIPLookup n = do
  let url = "http://freegeoip.net/json/"
      f = \(IPAddress t) -> do
        x <- simpleHTTP (getRequest $ unpack $ url <> t) >>= getResponseBody
        case decode (BS.pack x) of
          Just x' -> return x'
          Nothing -> return $ LookupFailure (IPAddress t) "nope"

  mkGeoIPLookup f n

loadCache :: GeoIPLookup -> [LookupResult] -> IO ()
loadCache l xs =
  let
    cache = M.fromList $ fmap (liftA2 (,) ip id) xs
  in
    atomically $ writeTVar (ipLookupCache l) cache

lookupGeoIP :: GeoIPLookup -> IPAddress -> IO (Async LookupResult)
lookupGeoIP l ipAddr = async $ do
  var <- insertQueue l ipAddr

  atomically $ do
    done <- readTVar var
    case done of
      Nothing  -> retrySTM
      Just res -> return res

lookupGeoIP_ :: GeoIPLookup -> IPAddress -> IO (Async ())
lookupGeoIP_ l ipAddr = async $ void $ insertQueue l ipAddr

lookupGeoIPCached :: GeoIPLookup -> IPAddress -> IO (Maybe LookupResult)
lookupGeoIPCached l ipAddr = readTVarIO (ipLookupCache l) >>= (return . lookup ipAddr)

lookupGeoIPCache :: GeoIPLookup -> IO (Map IPAddress LookupResult)
lookupGeoIPCache = readTVarIO . ipLookupCache

insertQueue :: GeoIPLookup -> IPAddress -> IO (TVar (Maybe LookupResult))
insertQueue l ipAddr = do
  var <- newTVarIO Nothing
  atomically $ writeTQueue (ipLookupQueue l) (ipAddr, var)
  return var

processQueue :: GeoIPLookup -> Int -> IO ()
processQueue l n = replicateM_ n (worker l)

worker :: GeoIPLookup -> IO ()
worker GeoIPLookup {..} = void $ fork $ forever $ do
  (ipAddr, var) <- atomically $ readTQueue ipLookupQueue
  c <- readTVarIO ipLookupCache

  case lookup ipAddr c of
    Nothing                  -> performLookup ipAddr var
    Just (LookupFailure _ _) -> performLookup ipAddr var
    Just cached              -> atomically $ writeTVar var (Just cached)

  where
    performLookup ipAddr var = do
      res <- ipLookup ipAddr `catch` (\(e :: IOException) -> return $ LookupFailure ipAddr (tshow e))
      atomically $ do
        modifyTVar ipLookupCache (insertMap ipAddr res)
        writeTVar var (Just res)
