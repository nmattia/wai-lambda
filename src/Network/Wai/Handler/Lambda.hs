{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}
{-# OPTIONS_GHC -fno-warn-deprecations #-}

module Network.Wai.Handler.Lambda where

import Control.Concurrent (forkIO)
import Control.DeepSeq (NFData)
import Control.Monad
import Data.Aeson ((.:))
import Data.Bifunctor
import Data.Function (fix)
import Data.List (partition)
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import Network.Wai (Application)
import System.Directory (renameFile)
import System.IO.Unsafe
import UnliftIO
import Text.Read (readMaybe)
import qualified Data.Binary.Builder as Binary
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Internal as Aeson
import qualified Data.Aeson.Parser as Aeson
import qualified Data.Aeson.Parser.Internal as Aeson
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import qualified Data.HashMap.Strict as HMap
import qualified Data.IP as IP
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Vault.Lazy as Vault
import qualified Network.HTTP.Types as H
import qualified Network.Socket as Socket
import qualified Network.Wai as Wai
import qualified Network.Wai.Internal as Wai
import qualified System.IO.Temp as Temp

-- | The representation of the response sent back to API Gateway.
type RawResponse = (H.Status, H.ResponseHeaders, BS.ByteString)

-- | The settings for running an 'Application'.
--
-- See also:
--  * 'runSettings'
--
-- For simplicity use the following setters with 'defaultSettings':
--  * 'setTimeoutSeconds'
--  * 'setHandleTimeout'
--  * 'setHandleException'
--
data Settings = Settings
  { timeoutValue :: Int
    -- ^ How many microseconds before we declare a timeout
  , handleTimeout :: BS.ByteString -> IO RawResponse
    -- ^ How to handle a timeout
  , handleException :: BS.ByteString -> SomeException -> IO RawResponse
    -- ^ How to handle an exception thrown by the 'Application'
  }

-- | Run an 'Application'.
--
-- Continuously reads requests from @stdin@. Each line should be a a JSON
-- document as described in 'decodeInput'.
--
-- All requests will be timed out after 2 seconds. If any exception
-- is thrown while processing the request this will return an @HTTP 500
-- Internal Server Error@.
--
-- If you need more control use 'handleRequest' directly.
run :: Application -> IO ()
run = runSettings defaultSettings

runSettings :: Settings -> Application -> IO ()
runSettings settings app = xif BS.empty $ \loop leftover ->
    -- XXX: we don't use getLine because it errors out on EOF; here we deal
    -- with this explicitly
    BS.hGetSome stdin 4096 >>= \bs ->
      if BS.null bs
      then pure () -- EOF was reached
      else case second BS8.uncons $ BS8.break (== '\n') (leftover <> bs) of
        (_tmpLine, Nothing) -> loop (leftover <> bs)
        (line, Just ('\n', rest)) -> do
          void $ forkIO $ handleRequest settings app line
          loop rest
        -- This happens if 'break' found a newline character but 'uncons'
        -- returned something different
        (_tmpLine, Just{}) -> throwIO $ userError $
          "wai-lambda: The impossible happened: was expecting newline"

setTimeoutSeconds :: Int -> Settings -> Settings
setTimeoutSeconds tout settings = settings
    { timeoutValue = tout * 1000 * 1000 }

setHandleException
  :: (BS.ByteString -> SomeException -> IO RawResponse)
  -> Settings
  -> Settings
setHandleException handler settings = settings
    { handleException = handler}

setHandleTimeout
  :: (BS.ByteString -> IO RawResponse)
  -> Settings
  -> Settings
setHandleTimeout handler settings = settings
    { handleTimeout = handler}

defaultSettings :: Settings
defaultSettings = Settings
    { timeoutValue = defaultTimeoutValue
    , handleTimeout = defaultHandleTimeout
    , handleException = defaultHandleException
    }

defaultHandleException :: BS.ByteString -> SomeException -> IO RawResponse
defaultHandleException bs e = do
    putStrLn $
      "Could not process request: " <> show bs <>
      " error: " <> show e
    pure (H.status500, [], "Internal Server Error")

-- | Default request timeout. 2 seconds.
defaultTimeoutValue :: Int
defaultTimeoutValue = 2 * 1000 * 1000

defaultHandleTimeout :: BS.ByteString -> IO RawResponse
defaultHandleTimeout bs = do
    putStrLn $ "Timeout processing request: " <> show bs
    pure (H.status504, [], "Timeout")

-------------------------------------------------------------------------------
-- Request handling
-------------------------------------------------------------------------------

-- | Parse and handle the request.
--
-- * Returns 504 if no response is available after the specified timeout.
-- * Returns 500 if an exception occurs while processing the request.
-- * Throws an exception if the input cannot be parsed.
handleRequest
  :: Settings
  -> Application
  -> BS.ByteString -- ^ The request (see 'decodeInput')
  -> IO ()
handleRequest settings app bs = case decodeInput bs of
    Left err -> do
      -- The request couldn't be parsed. There isn't much we can do since we
      -- don't even know where to put the response.
      let msg = unlines
            [ "Cannot decode request " <> show err
            , "Request was: " <> show bs
            ]
      putStrLn msg
      throwIO $ userError msg
    Right (fp, mkReq) -> do
      req <- mkReq
      mresp <- timeout (timeoutValue settings) $ tryAny $ processRequest app req
      resp <- case mresp of
        Just (Right r) -> do
          (st, hdrs, body) <- readResponse r
          pure $ toJSONResponse st hdrs body
        Just (Left e) ->
          uncurry3 toJSONResponse <$> handleException settings bs e
        Nothing ->
          uncurry3 toJSONResponse <$> handleTimeout settings bs

      writeFileAtomic fp $ BL.toStrict $ Aeson.encode $ Aeson.Object resp

-- | Run the 'Request' through the 'Application'.
--
-- This function is completely dependent on the 'Application. Any exception
-- thrown by the 'Application' will be rethrown here. No timeout is
-- implemented: if the 'Application' never provides a 'Response' then
-- 'processRequest' won't return.
processRequest :: Application -> Wai.Request -> IO Wai.Response
processRequest app req = do
    mvar <- newEmptyMVar
    Wai.ResponseReceived <- app req $ \resp -> do
      putMVar mvar resp
      pure Wai.ResponseReceived
    takeMVar mvar

-------------------------------------------------------------------------------
-- WAI <-> API Gateway
-------------------------------------------------------------------------------

-- | Decode a 'ByteString' into (1) a Wai 'Request' and (2) a filepath where
-- the response should be written.
-- The argument is JSON document with two fields:
--  * @request@: the API Gateway request (see 'parseRequest')
--  * @reqsponseFile@: Where to write the API Gateway response (see
--      'toJSONResponse')
decodeInput :: BS.ByteString -> Either (Aeson.JSONPath, String) (FilePath, IO Wai.Request)
decodeInput = Aeson.eitherDecodeStrictWith Aeson.jsonEOF $ Aeson.iparse $
    Aeson.withObject "input" $ \obj ->
      (,) <$>
        obj .: "responseFile" <*>
        (obj .: "request" >>= parseRequest)

data ApiGatewayRequestV2 = ApiGatewayRequestV2
  { body :: !(Maybe T.Text)
  , headers :: !(HMap.HashMap T.Text T.Text)
  , rawQueryString :: !(Maybe T.Text)
  , requestContext :: !RequestContext
  , cookies :: !(Maybe [T.Text])
  , isBase64Encoded :: !Bool
  }
  deriving (Show, Generic, Aeson.ToJSON, Aeson.FromJSON, NFData)

data RequestContext = RequestContext
  { accountId :: !T.Text
  , apiId :: !T.Text
  , domainName :: !T.Text
  , http :: Http
  , requestId :: !T.Text
  }
  deriving (Show, Generic, Aeson.ToJSON, Aeson.FromJSON, NFData)

data Http = Http
  { method :: !T.Text
  , path :: !T.Text
  , protocol :: !T.Text
  , sourceIp :: !T.Text
  }
  deriving (Show, Generic, Aeson.ToJSON, Aeson.FromJSON, NFData)

-- | Parser for a 'Wai.Request'.
--
-- The input is an AWS API Gateway request event:
-- https://docs.aws.amazon.com/lambda/latest/dg/eventsources.html#eventsources-api-gateway-request
parseRequest :: Aeson.Object -> Aeson.Parser (IO Wai.Request)
parseRequest obj = do
  ApiGatewayRequestV2
    { body
    , headers
    , rawQueryString
    , cookies
    , requestContext = RequestContext
      { http = Http
        { method
        , protocol
        , path
        , sourceIp
        }
      }
    } <- Aeson.parseJSON (Aeson.Object obj)

  -- We don't get data about the version, just assume
  httpVersion <- case CI.mk protocol of
    "http/0.9" -> pure H.http09
    "http/1.0" -> pure H.http10
    "http/1.1" -> pure H.http11
    "http/2.0" -> pure H.http20
    _ -> fail $ "Unknown http protocol " <> T.unpack protocol

  --  "headers": {
  --    "Accept": "text/html,application/xhtml+xml,...",
  --    ...
  --    "X-Forwarded-Proto": "https"
  --  },
  let
    cookieHeaders = (\c -> (H.hCookie, T.encodeUtf8 c)) <$> fromMaybe [] cookies
    otherHeaders = (\(k,v) -> (CI.mk (T.encodeUtf8 k),T.encodeUtf8 v)) <$> HMap.toList headers
    requestHeaders = otherHeaders <> cookieHeaders

  isSecure <- pure $ case lookup "X-Forwarded-Proto" requestHeaders of
    Just "https" -> True
    _ -> False

  let rawPathInfo = T.encodeUtf8 path
  pathInfo <- pure $ H.decodePathSegments rawPathInfo

  remoteHost <- case readMaybe @IP.IP (T.unpack sourceIp) of
    Just (IP.IPv4 ip) -> pure $ Socket.SockAddrInet 0 (IP.toHostAddress ip)
    Just (IP.IPv6 ip) -> pure $ Socket.SockAddrInet6 0 0 (IP.toHostAddress6 ip) 0
    _ -> fail $ "Could not parse ip address: " <> T.unpack sourceIp

  let
    rawQueryStringBytes = maybe "" T.encodeUtf8 rawQueryString
    queryString = H.parseQuery (rawQueryStringBytes)

  -- XXX: default to empty body as Lambda doesn't always set one (e.g. GET
  -- requests)
  let requestBodyRaw = maybe "" T.encodeUtf8 body
  requestBodyLength <- pure $
    Wai.KnownLength $ fromIntegral $ BS.length requestBodyRaw

  vault <- pure $ Vault.insert originalRequestKey obj Vault.empty

  requestHeaderHost <- pure $ lookup "host" requestHeaders
  requestHeaderRange <- pure $ lookup "range" requestHeaders
  requestHeaderReferer <- pure $ lookup "referer" requestHeaders
  requestHeaderUserAgent <- pure $ lookup "User-Agent" requestHeaders

  pure $ do
    requestBodyMVar <- newMVar requestBodyRaw
    let requestBody = do
          tryTakeMVar requestBodyMVar >>= \case
            Just bs -> pure bs
            Nothing -> pure BS.empty

    pure $ Wai.Request
        { requestMethod = T.encodeUtf8 method
        , httpVersion
        , rawPathInfo
        , rawQueryString = rawQueryStringBytes
        , queryString
        , requestBodyLength
        , requestHeaderHost
        , requestHeaderUserAgent
        , requestHeaderRange
        , requestHeaderReferer
        , requestHeaders
        , isSecure
        , remoteHost
        , pathInfo
        , requestBody
        , vault
        }

originalRequestKey :: Vault.Key Aeson.Object
originalRequestKey = unsafePerformIO Vault.newKey
{-# NOINLINE originalRequestKey #-}

-- | Read the status, headers and body of a 'Wai.Response'.
readResponse :: Wai.Response -> IO RawResponse
readResponse (Wai.responseToStream -> (st, hdrs, mkBody)) = do
    body <- mkBody drainBody
    pure (st, hdrs, body)
  where
    drainBody :: Wai.StreamingBody -> IO BS.ByteString
    drainBody body = do
      ioref <- newIORef Binary.empty
      body
        (\b -> atomicModifyIORef ioref (\b' -> (b <> b', ())))
        (pure ())
      BL.toStrict . Binary.toLazyByteString <$> readIORef ioref

-- | Make an API Gateway response from status, headers and body.
-- https://docs.aws.amazon.com/lambda/latest/dg/eventsources.html#eventsources-api-gateway-response
toJSONResponse :: H.Status -> H.ResponseHeaders -> BS.ByteString -> Aeson.Object
toJSONResponse st hdrs body =
  let
    (setCookieHeaders, otherHeaders) = partition (\(k,_) -> k == "set-cookie") hdrs
    Aeson.Object obj =
      Aeson.object
        [ ("statusCode", Aeson.Number (fromIntegral (H.statusCode st)))
        , ("headers", Aeson.toJSON $ HMap.fromList $
            (bimap T.decodeUtf8 T.decodeUtf8 . first CI.original) <$> otherHeaders)
        , ("cookies", Aeson.toJSON (T.decodeUtf8 . snd <$> setCookieHeaders))
        , ("body", Aeson.String (T.decodeUtf8 body))
        ]
  in obj

-------------------------------------------------------------------------------
-- Auxiliary
-------------------------------------------------------------------------------

-- | Atomically write the 'ByteString' to the file.
--
-- Uses @rename(2)@.
writeFileAtomic :: FilePath -> BS.ByteString -> IO ()
writeFileAtomic fp bs =
    Temp.withSystemTempFile "temp-response" $ \tmpFp h -> do
      hClose h
      BS.writeFile tmpFp bs
      renameFile tmpFp fp

-- | @flip fix@
xif :: b -> ((b -> c) -> b -> c) -> c
xif = flip fix

{-# INLINE uncurry3 #-}
uncurry3 :: (a -> b -> c -> d) -> ((a, b, c) -> d)
uncurry3 f ~(a,b,c) = f a b c
