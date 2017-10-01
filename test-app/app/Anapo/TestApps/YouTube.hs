{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE JavaScriptFFI #-}
{-# LANGUAGE MultiWayIf #-}
module Anapo.TestApps.YouTube (YouTubeState, youTubeComponent, youTubeInit, youTubeSetup) where

import Control.Lens (makeLenses, (^.), set, (.=))
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import Control.Concurrent.MVar
import GHCJS.Foreign.Callback
import GHCJS.Types
import GHCJS.Marshal
import qualified Data.Aeson.TH as Aeson
import Control.Exception (bracket)
import Data.Foldable (for_)
import Data.JSString (JSString)
import Data.JSString.Text (textFromJSString)
import Data.Text (Text)

import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.Document as DOM

import Anapo
import Anapo.TestApps.Prelude

-- YT api bindings
-- --------------------------------------------------------------------

{-# NOINLINE youTubePlayerReady #-}
youTubePlayerReady :: MVar ()
youTubePlayerReady = unsafePerformIO newEmptyMVar

foreign import javascript unsafe
  "window.onYouTubeIframeAPIReady = $1"
  js_setupOnYouTubeIframeAPIReady :: Callback (IO ()) -> IO ()

youTubeEnsureReady :: JSM ()
youTubeEnsureReady = readMVar youTubePlayerReady

-- blocks until yt api is ready
youTubeSetup :: JSM ()
youTubeSetup = do
  bracket
    (asyncCallback $ do
      void (tryPutMVar youTubePlayerReady ()))
    releaseCallback
    (\cback -> do
      js_setupOnYouTubeIframeAPIReady cback
      youTubeEnsureReady)

type YouTubePlayer = JSVal

data YouTubeNew = YouTubeNew
  { ytnHeight :: Int
  , ytnWidth :: Int
  , ytnVideoId :: Text
  }
Aeson.deriveJSON (aesonRecord "ytn") ''YouTubeNew

foreign import javascript unsafe
  "new YT.Player($1, $2)"
  js_youTubeNew :: JSVal -> JSVal -> IO JSVal

foreign import javascript unsafe
  " $1.events = {};\
  \ $1.events.onReady = $2;"
  js_youTubeSetOnReady :: JSVal -> Callback (IO ()) -> IO ()

-- | blocks until the player is ready
youTubeNew ::
     (ToJSVal el)
  => el
  -> YouTubeNew
  -> IO YouTubePlayer
youTubeNew container ytn = do
  -- make sure we have the api
  youTubeEnsureReady
  -- set up things
  containerJS <- toJSVal container
  ytnJS <- toJSVal_aeson ytn
  isPlayerReady <- newEmptyMVar
  bracket
    (asyncCallback (void (tryPutMVar isPlayerReady ())))
    releaseCallback
    (\cback -> do
      js_youTubeSetOnReady ytnJS cback
      ytp <- js_youTubeNew containerJS ytnJS
      readMVar isPlayerReady
      return ytp)

foreign import javascript unsafe
  "$1.getCurrentTime()"
  youTubeGetCurrentTime :: YouTubePlayer -> IO Int

foreign import javascript unsafe
  "$1.seekTo($2)"
  youTubeSeekTo :: YouTubePlayer -> Int -> IO ()

foreign import javascript unsafe
  "$1.pauseVideo()"
  youTubePauseVideo :: YouTubePlayer -> IO ()

-- YT api
-- --------------------------------------------------------------------

type YouTubeLastPosition = Maybe Int -- ^ seconds elapsed

type VideoId = JSString

data YouTubeState = YouTubeState
  { _ytsVideoId :: VideoId
  , _ytsToken :: Int
  , _ytsLastPosition :: YouTubeLastPosition
  }
makeLenses ''YouTubeState

{-# NOINLINE youTubeCounter #-}
youTubeCounter :: IORef Int
youTubeCounter = unsafePerformIO (newIORef 0)

newYouTubeToken :: JSM Int
newYouTubeToken = liftIO (atomicModifyIORef' youTubeCounter (\c -> (c+1, c)))

youTubeInit :: VideoId -> JSM YouTubeState
youTubeInit videoId = do
  tok <- newYouTubeToken
  return YouTubeState
    { _ytsVideoId = videoId
    , _ytsToken = tok
    , _ytsLastPosition = Nothing
    }

-- it's important to have this as a generic element since we'll replace it
-- with a iframe
youTubeNode :: Node' DOM.Element YouTubeState
youTubeNode = do
  st <- askState
  dispatch <- askDispatch
  mbYtpRef :: IORef (Maybe YouTubePlayer) <- liftIO (newIORef Nothing)
  let
    didMount el = void $ forkIO $ do
      ytp <- youTubeNew el YouTubeNew
        { ytnHeight = 390
        , ytnWidth = 640
        , ytnVideoId = textFromJSString (st^.ytsVideoId)
        }
      for_ (st^.ytsLastPosition) $ \t -> do
        youTubeSeekTo ytp t
        youTubePauseVideo ytp
      writeIORef mbYtpRef (Just ytp)
  let
    willRemove _el = do
      mbYtp <- readIORef mbYtpRef
      case mbYtp of
        Nothing -> return ()
        Just ytp -> do
          t <- youTubeGetCurrentTime ytp
          runDispatch dispatch (ytsLastPosition .= Just t)
  container <- DOM.liftJSM $ do
    doc <- DOM.currentDocumentUnchecked
    container <- DOM.unsafeCastTo DOM.Element =<< DOM.createElement doc ("div" :: JSString)
    simpleRenderComponent container () $
      bootstrapRow $ bootstrapCol $
        n$ text "YouTube player not ready"
    return container
  unsafeDidMount didMount . unsafeWillRemove willRemove <$> rawNode DOM.Element container

-- | Never rerender the node
youTubeComponent :: Component' YouTubeState
youTubeComponent = do
  n$ marked
    (\mbPrevSt st -> case mbPrevSt of
      Just prevSt -> if prevSt^.ytsToken == st^.ytsToken
        then UnsafeDontRerender
        else Rerender
      Nothing -> Rerender)
    (static youTubeNode)
  dispatch <- askDispatch
  bootstrapRow $ bootstrapCol $ zoomL ytsVideoId $ simpleTextInput "video id"
    (dispatch (\st' -> youTubeInit (st'^.ytsVideoId)))
    "Choose video"

