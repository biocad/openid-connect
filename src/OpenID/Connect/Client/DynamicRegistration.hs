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

OpenID Connect Dynamic Client Registration 1.0.

-}
module OpenID.Connect.Client.DynamicRegistration
  (
    -- * Registration
    registerClient

    -- * Errors that can occur
  , RegistrationError(..)

    -- * Re-exports
  , HTTPS
  , ErrorResponse(..)
  , module OpenID.Connect.Registration
  ) where

--------------------------------------------------------------------------------
-- Imports:
import Control.Exception (Exception)
import Control.Monad.Except
import Data.Bifunctor (bimap)
import Data.Functor ((<&>))
import OpenID.Connect.Client.HTTP
import OpenID.Connect.Discovery
import OpenID.Connect.JSON
import OpenID.Connect.Registration

--------------------------------------------------------------------------------
-- | Errors that can occur during dynamic client registration.
data RegistrationError
  = NoSupportForRegistrationError
  | RegistrationFailedError ErrorResponse
  deriving (Show, Exception)

--------------------------------------------------------------------------------
-- | Register a client with the provider described by the 'Discovery' document.
--
-- Example:
--
-- @
-- let reg = 'defaultRegistration' yourClientRedirURI
--     metadata = 'clientMetadata' reg 'BasicRegistration'
-- in registerClient http discoveryDoc metadata
-- @
registerClient
  :: (Monad m, ToJSON a, FromJSON a)
  => HTTPS m
  -> Discovery
  -> ClientMetadata a
  -> m (Either RegistrationError (ClientMetadataResponse a))
registerClient https disco meta = runExceptT $ do
  uri <- maybe (throwError NoSupportForRegistrationError) pure
               (registrationEndpoint disco)

  req <- maybe (throwError NoSupportForRegistrationError) pure
               (requestFromURI (Right (getURI uri)))

  ExceptT (https (jsonPostRequest meta req)
            <&> parseResponse
            <&> bimap RegistrationFailedError fst)
