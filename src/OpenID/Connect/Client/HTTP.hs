{-|

Copyright:

  This file is part of the package openid-connect.  It is subject to
  the license terms in the LICENSE file found in the top-level
  directory of this distribution and at:

    https://code.devalot.com/open/openid-connect

  No part of this package, including this file, may be copied,
  modified, propagated, or distributed except according to the terms
  contained in the LICENSE file.

License: BSD-2-Clause

Helpers for HTTPS.

-}
module OpenID.Connect.Client.HTTP
  ( HTTPS
  , uriToText
  , forceHTTPS
  , requestFromURI
  , addRequestHeader
  , jsonPostRequest
  , cacheUntil
  , parseResponse
  ) where

--------------------------------------------------------------------------------
-- Imports:
import Control.Applicative
import Data.Aeson (ToJSON, FromJSON, eitherDecode)
import qualified Data.Aeson as Aeson
import Data.Bifunctor (bimap)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LByteString
import qualified Data.ByteString.Lazy.Char8 as LChar8
import Data.CaseInsensitive (CI)
import Data.Char (isDigit)
import Data.Function ((&))
import Data.Functor ((<&>))
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Time.Format (parseTimeM, defaultTimeLocale)
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Types.Header as HTTP
import qualified Network.HTTP.Types.Status as HTTP
import Network.URI (URI(..), parseURI, uriToString)
import OpenID.Connect.JSON (ErrorResponse(..))

--------------------------------------------------------------------------------
-- | A function that can make HTTPS requests.
--
-- Make sure you are using a @Manager@ value from the
-- @http-client-tls@ package.  It's imperative that the requests
-- flowing through this function are encrypted.
--
-- All requests are set to throw an exception if the response status
-- code is not in the 2xx range.  Therefore, functions that take this
-- 'HTTPS' type should be called in an exception-safe way and any
-- exception should be treated as an authentication failure.
--
-- @since 0.1.0.0
type HTTPS m = HTTP.Request -> m (HTTP.Response LByteString.ByteString)

--------------------------------------------------------------------------------
-- | Helper for rendering a URI as Text.
uriToText :: URI -> Text
uriToText uri = Text.pack (uriToString id uri [])

--------------------------------------------------------------------------------
-- | Force the given URI to use HTTPS.
forceHTTPS :: URI -> URI
forceHTTPS uri = uri { uriScheme = "https:" }

--------------------------------------------------------------------------------
-- | Convert a URI or Text value into a pre-configured request object.
requestFromURI :: Either Text URI -> Maybe HTTP.Request
requestFromURI (Left t) = parseURI (Text.unpack t) >>= requestFromURI . Right
requestFromURI (Right uri) =
  HTTP.requestFromURI (forceHTTPS uri)
    <&> addRequestHeader ("Accept", "application/json")

--------------------------------------------------------------------------------
-- | Add a JSON body to a request.
jsonPostRequest :: ToJSON a => a -> HTTP.Request -> HTTP.Request
jsonPostRequest json req = addRequestHeader ("Content-Type", "application/json") $
  req { HTTP.method = "POST"
      , HTTP.requestBody = HTTP.RequestBodyLBS (Aeson.encode json)
      }

--------------------------------------------------------------------------------
-- | Add a header to the request.
addRequestHeader :: (CI ByteString, ByteString) -> HTTP.Request -> HTTP.Request
addRequestHeader header req =
  req { HTTP.requestHeaders =
          header : filter ((/= fst header) . fst) (HTTP.requestHeaders req)
      }

--------------------------------------------------------------------------------
-- | Given a response, calculate how long it can be cached.
cacheUntil :: HTTP.Response a -> Maybe UTCTime
cacheUntil res = maxAge <|> expires
  where
    parseTime :: ByteString -> Maybe UTCTime
    parseTime = parseTimeM True defaultTimeLocale rfc1123 . Char8.unpack

    rfc1123 :: String
    rfc1123 = "%a, %d %b %Y %X %Z"

    date :: Maybe UTCTime
    date = lookup HTTP.hDate (HTTP.responseHeaders res) >>= parseTime

    expires :: Maybe UTCTime
    expires = lookup HTTP.hExpires (HTTP.responseHeaders res) >>= parseTime

    maxAge :: Maybe UTCTime
    maxAge = do
      dt <- date
      bs <- lookup HTTP.hCacheControl (HTTP.responseHeaders res)
      ma <- nullM (snd (Char8.breakSubstring "max-age" bs))
      bn <- nullM (snd (Char8.break isDigit ma))
      addUTCTime . fromIntegral . fst
        <$> Char8.readInt (Char8.take 6 bn) -- Limit input to readInt
        <*> pure dt

    nullM :: ByteString -> Maybe ByteString
    nullM bs = if Char8.null bs then Nothing else Just bs

--------------------------------------------------------------------------------
-- | Decode the JSON body of a request and calculate how long it can
-- be cached.
parseResponse
  :: FromJSON a
  => HTTP.Response LByteString.ByteString
  -> Either ErrorResponse (a, Maybe UTCTime)
parseResponse response =
  if HTTP.statusIsSuccessful (HTTP.responseStatus response)
    then eitherDecode (HTTP.responseBody response) &
         bimap asError (,cacheUntil response)
    else Left (asError "invalid response from server")
  where
    asError :: String -> ErrorResponse
    asError s = case eitherDecode (HTTP.responseBody response) of
      Left _  -> ErrorResponse (Text.pack s) (Just bodyError)
      Right e -> e

    bodyError :: Text
    bodyError = response
              & HTTP.responseBody
              & LChar8.take 1024
              & LChar8.toStrict
              & Text.decodeUtf8
