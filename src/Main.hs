{-# LANGUAGE
    OverloadedStrings
  , RecordWildCards
#-}


import Conduit
  ( ConduitT (..)
  , ConduitM (..)
  , Void (..)
  , SealedConduitT (..)
  , (.|)
  , ($$+)
  , ($$+-)
  , fuseUpstream
  , mapC
  , liftIO
  , yield
  , awaitForever
  , linesUnboundedAsciiC
  , runConduit
  )

import Data.Conduit.Network
  ( AppData (..)
  , appSink
  , appSockAddr
  , appSource
  , runTCPServer
  , serverSettings
  )

import qualified Data.ByteString.Char8 as BS
  ( ByteString (..)
  , append
  , words
  )

import Data.Conduit.TMChan

import Text.Printf
  ( printf
  )

import Control.Concurrent.STM
  ( TVar (..)
  , STM (..)
  , writeTVar
  , readTVar
  , atomically
  , modifyTVar'
  , newTVarIO
  )

import qualified Data.Map as Map
  ( Map (..)
  , empty
  , elems
  , insert
  , delete
  , filterWithKey
  )

import Data.Word8
  ( _cr
  )

import Control.Monad
  ( void
  )

import Control.Concurrent.Async
  ( concurrently
  )

import Control.Exception
  ( finally
  )



type ClientId = Integer


data Server =
  Server
    { next_client_id :: TVar ClientId
    , clients        :: TVar (Map.Map ClientId Client)
    }


data Client =
  Client
    { client_id      :: ClientId
    , client_chan    :: TMChan Message
    , client_app     :: AppData
    }


instance Show Client
  where
    show = show . appSockAddr . client_app


data Message = Broadcast BS.ByteString
             | Message BS.ByteString
  deriving Show


-- Create a new server
--
newServer :: IO Server
newServer = do
  new_next_client_id <- newTVarIO 0
  new_clients_map    <- newTVarIO Map.empty
  return Server { next_client_id = new_next_client_id
                , clients = new_clients_map
                }


-- Create a new client
--
newClient :: ClientId -> AppData -> STM Client
newClient new_client_id app = do
  new_client_chan <- newTMChan
  return Client { client_id   = new_client_id
                , client_chan = new_client_chan
                , client_app  = app
                }


-- Broadcast a message
--
broadcastMessage :: Server -> ClientId -> Message -> STM ()
broadcastMessage Server{..} client_id msg = do
    clients_map <- readTVar clients
    mapM_ (\client -> sendMessage client msg) (Map.elems (Map.filterWithKey (\ cur_client_id _ -> client_id /= cur_client_id ) clients_map))


-- Send a message
--
sendMessage :: Client -> Message -> STM ()
sendMessage Client{..} msg = writeTMChan client_chan msg


-- Manage a message
--
handleMessage :: Server -> Client -> ConduitT Message BS.ByteString IO ()
handleMessage server client@Client{..} = awaitForever $ \ act ->
  case act of
    Broadcast msg      -> output $ msg
    Message msg        ->
      case BS.words msg of
        [""]           -> return ()
        []             -> return ()
        _              -> liftIO $ atomically $ broadcastMessage server client_id $ Broadcast msg

  where
    output s = yield (BS.append s "\n")


-- Add a client to the server
--
addClient :: Server -> AppData -> ConduitM BS.ByteString BS.ByteString IO Client
addClient server app = go
  where
    go = do
      client <- liftIO $ addClient' server app
      return client

    addClient' :: Server -> AppData -> IO (Client)
    addClient' server@Server{..} app = atomically $ do
        clientmap     <- readTVar clients
        new_client_id <- readTVar next_client_id
        new_client    <- newClient new_client_id app
        writeTVar clients $ Map.insert new_client_id new_client clientmap
        writeTVar next_client_id (new_client_id + 1)
        return new_client


-- Consume a message from a client
--
clientSink :: Client -> ConduitT BS.ByteString Void IO ()
clientSink Client{..} = mapC Message .| sinkTMChan client_chan


runClient :: SealedConduitT () BS.ByteString IO () -> Server -> Client -> IO ()
runClient clientSource server client@Client{..} =
    void $ concurrently
        (clientSource $$+- linesUnboundedAsciiC .| clientSink client)
        (runConduit (sourceTMChan client_chan
            .| handleMessage server client
            .| appSink client_app))


main :: IO ()
main = do
  server <- newServer
  runTCPServer (serverSettings 10000 "*") $ \ app -> do
    (fromClient, client) <- appSource app $$+ (addClient server app)
                              `fuseUpstream` appSink app
    print client
    (runClient fromClient server client)

