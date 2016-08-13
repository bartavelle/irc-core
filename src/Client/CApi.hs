{-# Language RecordWildCards #-}
{-|
Module      : Client.CApi
Description : Dynamically loaded extension API
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

Foreign interface to the IRC client via a simple C API
and dynamically loaded modules.

-}

module Client.CApi
  ( ActiveExtension
  , extensionSymbol
  , activateExtension
  , deactivateExtension
  , notifyExtensions
  ) where

import           Client.CApi.Types
import           Client.ConnectionState
import           Control.Exception
import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import           Data.Foldable
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Foreign as Text
import           Foreign.C
import           Foreign.Marshal
import           Foreign.Ptr
import           Foreign.StablePtr
import           Foreign.Storable
import           Irc.RawIrcMsg
import           Irc.UserInfo
import           System.Posix.DynamicLinker

-- | The symbol that is loaded from an extension object.
--
-- Extensions are expected to export:
--
-- @
-- struct galua_extension extension;
-- @
extensionSymbol :: String
extensionSymbol = "extension"

-- | Information about a loaded extension including the handle
-- to the loaded shared object, and state value returned by
-- the startup callback, and the loaded extension record.
data ActiveExtension = ActiveExtension
  { aeFgn     :: FgnExtension -- ^ Struct of callback function pointers
  , aeDL      :: DL           -- ^ Handle of dynamically linked extension
  , aeSession :: Ptr ()       -- ^ State value generated by start callback
  }

-- | Load the extension from the given path and call the start
-- callback. The result of the start callback is saved to be
-- passed to any subsequent calls into the extension.
activateExtension ::
  FilePath {- ^ path to extension -} ->
  IO ActiveExtension
activateExtension path =
  do dl <- dlopen path [RTLD_LAZY, RTLD_LOCAL]
     p  <- dlsym dl extensionSymbol
     md <- peek (castFunPtrToPtr p)
     let f = fgnStart md
     s  <- if nullFunPtr == f
             then return nullPtr
             else runStartExtension f
     return ActiveExtension
       { aeFgn     = md
       , aeDL      = dl
       , aeSession = s
       }

-- | Call the stop callback of the extension if it is defined
-- and unload the shared object.
deactivateExtension :: ActiveExtension -> IO ()
deactivateExtension ae =
  do let f = fgnStop (aeFgn ae)
     unless (nullFunPtr == f)
        (runStopExtension f (aeSession ae))
     dlclose (aeDL ae)

-- | Call all of the process message callbacks in the list of extensions.
-- This operation marshals the IRC message once and shares that across
-- all of the callbacks.
notifyExtensions ::
  Text              {- ^ network              -} ->
  ConnectionState   {- ^ state for network    -} ->
  RawIrcMsg         {- ^ current message      -} ->
  [ActiveExtension] {- ^ extensions to notify -} ->
  IO ()
notifyExtensions network cs msg aes = evalContT $

  do let aes' = [ (f,s) | ae <- aes
                        , let f = fgnProcess (aeFgn ae)
                              s = aeSession ae
                        , f /= nullFunPtr ]

     contT0 $ unless $ null aes' -- optimization, avoid unecessary marshal
     msgPtr <- withRawIrcMsg network msg
     csPtr  <- withStablePtr cs
     (f,s)  <- ContT $ for_ aes'
     lift $ runProcessMessage f (castStablePtrToPtr csPtr) s msgPtr

-- | Create a 'StablePtr' which will be valid for the remainder
-- of the computation.
withStablePtr :: a -> ContT r IO (StablePtr a)
withStablePtr x = ContT $ bracket (newStablePtr x) freeStablePtr

-- | Marshal a 'RawIrcMsg' into a 'FgnMsg' which will be valid for
-- the remainder of the computation.
withRawIrcMsg ::
  Text                 {- ^ network      -} ->
  RawIrcMsg            {- ^ message      -} ->
  ContT a IO (Ptr FgnMsg)
withRawIrcMsg network RawIrcMsg{..} =
  do net     <- withText network
     pfx     <- withText $ maybe Text.empty renderUserInfo _msgPrefix
     cmd     <- withText _msgCommand
     prms    <- traverse withText _msgParams
     tags    <- traverse withTag  _msgTags
     let (keys,vals) = unzip tags
     (tagN,keysPtr) <- contT2 $ withArrayLen keys
     valsPtr        <- ContT  $ withArray vals
     (prmN,prmPtr)  <- contT2 $ withArrayLen prms
     ContT $ with $ FgnMsg net pfx cmd prmPtr (fromIntegral prmN)
                                       keysPtr valsPtr (fromIntegral tagN)

withTag :: TagEntry -> ContT a IO (FgnStringLen, FgnStringLen)
withTag (TagEntry k v) =
  do pk <- withText k
     pv <- withText v
     return (pk,pv)

withText :: Text -> ContT a IO FgnStringLen
withText txt =
  do (ptr,len) <- ContT $ Text.withCStringLen txt
     return $ FgnStringLen ptr $ fromIntegral len

contT0 :: (m a -> m a) -> ContT a m ()
contT0 f = ContT $ \g -> f $ g ()

contT2 :: ((a -> b -> m c) -> m c) -> ContT c m (a,b)
contT2 f = ContT $ \g -> f $ curry g

------------------------------------------------------------------------

-- | Import a 'FgnMsg' into an 'RawIrcMsg'
peekFgnMsg :: FgnMsg -> IO RawIrcMsg
peekFgnMsg FgnMsg{..} =
  do let strArray n p = traverse peekFgnStringLen =<<
                        peekArray (fromIntegral n) p
        
     tagKeys <- strArray fgnTagN fgnTagKeys
     tagVals <- strArray fgnTagN fgnTagVals
     prefix  <- peekFgnStringLen fgnPrefix
     command <- peekFgnStringLen fgnCommand
     params  <- strArray fgnParamN fgnParams

     return RawIrcMsg
       { _msgTags    = zipWith TagEntry tagKeys tagVals
       , _msgPrefix  = if Text.null prefix
                         then Nothing
                         else Just (parseUserInfo prefix)
       , _msgCommand = command
       , _msgParams  = params
       }

-- | Peek a 'FgnStringLen' as UTF-8 encoded bytes.
peekFgnStringLen :: FgnStringLen -> IO Text
peekFgnStringLen (FgnStringLen ptr len) =
  Text.peekCStringLen (ptr, fromIntegral len)

------------------------------------------------------------------------

type CApiSendMessage = Ptr () -> Ptr FgnMsg -> IO CInt

foreign export ccall "glirc_send_message" capiSendMessage :: CApiSendMessage

capiSendMessage :: CApiSendMessage
capiSendMessage csPtr msgPtr =
  do cs  <- deRefStablePtr (castPtrToStablePtr csPtr)
     msg <- peekFgnMsg =<< peek msgPtr
     sendMsg cs msg
     return 0
  `catch` \SomeException{} -> return 1