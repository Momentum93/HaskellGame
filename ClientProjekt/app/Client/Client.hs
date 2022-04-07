{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
module Client.Client where

import Prelude hiding (getContents)


import Data.Binary
import GHC.Generics

import Control.Concurrent (forkFinally, forkIO, newMVar, MVar, swapMVar, readMVar, Chan, newChan)
import qualified Control.Exception as E
import Control.Monad (unless, forever, void)
import qualified Data.ByteString as S
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import qualified Network.Socket.ByteString.Lazy as LAZZY

import qualified Data.Map as MAP

start = do
    forkIO server
    print "server startet"
    getLine
    client


server :: IO ()
server = do

    socketList <- newMVar MAP.empty :: IO (MVar (MAP.Map Int Socket))
    messageQueue <- newChan :: IO (Chan Message)


    runTCPServer Nothing "3000" socketList $ \s -> forever $ do

        --msg <- (decode <$> LAZZY.getContents s) :: IO Message
        currentSocketList <- readMVar socketList

        let listOfSocket        = map snd $ MAP.toList currentSocketList
            destinationList     = [soc | soc <- listOfSocket, soc /= s]

        LAZZY.getContents s >>= \msg -> mapM_ (`LAZZY.sendAll` msg) destinationList


        -- print msg

-- from the "network-run" package.
runTCPServer :: Maybe HostName -> ServiceName -> MVar (MAP.Map Int Socket) -> (Socket -> IO ())  -> IO ()
runTCPServer mhost port socketList server = withSocketsDo $ do
    addr <- resolve
    E.bracket (open addr) close (`loop` 0)
    where
        resolve = do
            let hints = defaultHints {
                    addrFlags = [AI_PASSIVE]
                , addrSocketType = Stream
                }
            head <$> getAddrInfo (Just hints) mhost (Just port)
        open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
            setSocketOption sock ReuseAddr 1
            withFdSocket sock setCloseOnExecIfNeeded
            bind sock $ addrAddress addr
            listen sock 1024
            return sock
        loop :: Socket -> Int -> IO ()
        loop sock acc = do
            E.bracketOnError (accept sock) (close . fst)
                $ \(conn, _peer) -> void $ do
                    readMVar socketList >>= \mVar -> swapMVar socketList $ MAP.insert acc conn mVar
                    -- 'forkFinally' alone is unlikely to fail thus leaking @conn@,
                    -- but 'E.bracketOnError' above will be necessary if some
                    -- non-atomic setups (e.g. spawning a subprocess to handle
                    -- @conn@) before proper cleanup of @conn@ is your case
                    forkFinally (server conn) (const $ gracefulClose conn 5000)
                    loop sock (acc+1)


client :: IO ()
client = runTCPClient "127.0.0.1" "3000" $ \s -> do
    forever $ do
        print "getLine"
        msg <- getLine
        LAZZY.sendAll s $ encode $ List [1..1000000]

-- from the "network-run" package.
runTCPClient :: HostName -> ServiceName -> (Socket -> IO a) -> IO a
runTCPClient host port client = withSocketsDo $ do
    addr <- resolve
    E.bracket (open addr) close client
  where
    resolve = do
        let hints = defaultHints { addrSocketType = Stream }
        head <$> getAddrInfo (Just hints) (Just host) (Just port)
    open addr = E.bracketOnError (openSocket addr) close $ \sock -> do
        connect sock $ addrAddress addr
        return sock



data Message =
        List [Int]
    |   String String
    |   END
    deriving stock Generic
    deriving anyclass Binary
    deriving Show
    deriving Eq