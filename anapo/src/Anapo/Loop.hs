{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
module Anapo.Loop
  ( installNodeBody
  , installNode
  , InstallMode(..)
  ) where

import Control.Concurrent.Chan (Chan, writeChan, readChan, newChan)
import Control.Monad.IO.Class (liftIO)
import Control.Monad (void, when)
import Data.Foldable (traverse_, for_)
import Data.Time.Clock (getCurrentTime, diffUTCTime, NominalDiffTime)
import Data.Monoid ((<>))
import Control.Exception.Safe (throwIO, tryAsync, SomeException(..), bracket, finally, Exception, Typeable)
import Control.Exception (BlockedIndefinitelyOnMVar)
import Control.Concurrent (MVar, newEmptyMVar, tryPutMVar, readMVar)
import Data.IORef (IORef, readIORef, atomicModifyIORef', newIORef, writeIORef)
import qualified Control.Concurrent.Async as Async
import Data.HashSet (HashSet)
import qualified Data.HashSet as HS
import Control.Concurrent (ThreadId, killThread, myThreadId)
import Control.Monad.State (runStateT, put, get, lift)
import qualified Data.HashMap.Strict as HMS
import GHC.Stack (CallStack, SrcLoc(..), getCallStack)
import Control.Exception.Safe (try)
import Data.List (foldl')

import qualified GHCJS.DOM as DOM
import qualified GHCJS.DOM.Types as DOM
import qualified GHCJS.DOM.Node as DOM.Node
import qualified GHCJS.DOM.Document as DOM.Document

import qualified Anapo.VDOM as V
import Anapo.Component.Internal
import Anapo.Text (Text, pack, unpack)
import Anapo.Logging

#if defined(ghcjs_HOST_OS)
import GHCJS.Concurrent (synchronously)
#else
synchronously :: DOM.JSM a -> DOM.JSM a
synchronously = id
#endif

timeIt :: DOM.JSM a -> DOM.JSM (a, NominalDiffTime)
timeIt m = do
  t0 <- liftIO getCurrentTime
  x <- m
  t1 <- liftIO getCurrentTime
  return (x, diffUTCTime t1 t0)

data DispatchMsg stateRoot = forall props context state. DispatchMsg
  { _dispatchMsgTraverseComp :: AffineTraversal' (Component () () stateRoot) (Component props context state)
  , _dispatchMsgModify :: context -> state -> DOM.JSM (state, Rerender)
  , _dispatchCallStack :: CallStack
  }

newtype AnapoException = AnapoException Text
  deriving (Eq, Show, Typeable)
instance Exception AnapoException

data InstallMode =
    IMAppend -- ^ append the node inside the the provided container
  | IMEraseAndAppend -- ^ clear everything in the container and append

{-# INLINABLE nodeLoop #-}
nodeLoop :: forall st.
     (forall a. (st -> DOM.JSM a) -> Action () st a)
  -> Node () st
  -- ^ how to render the state
  -> (SomeException -> Node () ())
  -- ^ how to render exceptions
  -> InstallMode
  -- ^ how to place the node
  -> DOM.Node
  -- ^ where to place the node
  -> DOM.JSM V.RenderedNode
  -- ^ returns the rendered node, when there is nothing left to
  -- do. might never terminate
nodeLoop withState node excComp injectMode root = do
  -- dispatch channel
  dispatchChan :: Chan (DispatchMsg st) <- liftIO newChan
  let
    getMsg = do
      mbF :: Either BlockedIndefinitelyOnMVar (DispatchMsg st) <- tryAsync (readChan dispatchChan)
      case mbF of
        Left{} -> do
          logInfo "got undefinitedly blocked on mvar on dispatch channel, will stop"
          return Nothing
        Right f -> return (Just f)
  -- exception mvar
  excVar :: MVar SomeException <- liftIO newEmptyMVar
  let handler err = void (tryPutMVar excVar err)
  -- set of threads
  tidsRef :: IORef (HashSet ThreadId) <- liftIO (newIORef mempty)
  let
    register m = do
      tid <- myThreadId
      bracket
        (atomicModifyIORef' tidsRef (\tids -> (HS.insert tid tids, ())))
        (\_ -> atomicModifyIORef' tidsRef (\tids -> (HS.delete tid tids, ())))
        (\_ -> m)
  let
    actionEnv :: ActionEnv (Component () () st)
    actionEnv = ActionEnv
      { aeRegisterThread = register
      , aeHandleException = handler
      , aeDispatch = Dispatch (\stack travComp modify -> writeChan dispatchChan (DispatchMsg travComp modify stack))
      }
  let
    actionTrav ::
         AffineTraversal' (Component () () st) (Component props ctx' st')
      -> ActionTraverse (Component () () st) props ctx' st' ctx' st'
    actionTrav travComp = ActionTraverse
      { atToComp = travComp
      , atToState = id
      , atToContext = id
      }
  -- helper to run the component
  let
    runComp ::
         V.Path
      -> AffineTraversal' (Component () () st) (Component props ctx' st')
      -> Component props ctx' st'
      -> props
      -> DOM.JSM V.Node
    runComp path travComp comp props = do
      mbCtx <- liftIO (readIORef (_componentContext comp))
      ctx <- case mbCtx of
        Nothing -> error ("Couldn't get context for component " <> unpack (_componentName comp) <> ", you probably forgot to initialize it.")
        Just ctx -> return ctx
      (vdom, vdomDt) <- timeIt $ unDomM
        (do
          node0 <- _componentNode comp props
          patches <- registerComponent (_componentName comp) (_componentPositions comp) props
          return (foldl' V.addNodeCallback node0 patches))
        actionEnv
        (actionTrav travComp)
        DomEnv
          { domEnvReversePath = reverse path
          , domEnvDirtyPath = False
          }
        ctx
        (_componentState comp)
        ()
      DOM.syncPoint
      logDebug ("Vdom generated (" <> pack (show vdomDt) <> ")")
      -- keep in sync with similar code in Anapo.Component.Internal.component
      return $ case _componentFingerprint comp of
        Nothing -> vdom
        Just fprint -> V.setNodeMark vdom (Just fprint)
  -- compute state
  unAction
    (withState $ \st0 -> do
      -- what to do in case of exceptions
      let
        onErr :: V.RenderedNode -> SomeException -> DOM.JSM a
        onErr rendered err = do
          -- if we got an exception, render one last time and shut down
          logError ("Got exception, will render it and rethrow: " <> pack (show err))
          vdom <- simpleNode () (excComp err)
          void (V.reconciliate rendered [] vdom)
          logError ("Just got exception and rendered, will rethrow: " <> pack (show err))
          liftIO (throwIO err)
      -- main loop
      let
        go ::
             Component () () st
          -- ^ the previous state
          -> V.RenderedNode
          -- ^ the rendered node
          -> DOM.JSM ()
        go compRoot !rendered = do
          -- get the next update or the next exception. we are biased
          -- towards exceptions since we want to exit immediately when
          -- there is a failure.
          fOrErr :: Either SomeException (Maybe (DispatchMsg st)) <- liftIO (Async.race (readMVar excVar) getMsg)
          case fOrErr of
            Left err -> onErr rendered err
            Right Nothing -> do
              logInfo "No state update received, terminating component loop"
              return ()
            Right (Just (DispatchMsg travComp modif stack)) -> do
              logDebug (addCallStack stack "About to update state")
              -- traverse to the component using StateT, failing
              -- if we reach anything twice (it'd mean it's not an
              -- AffineTraversal)
              ((compRoot', mbComp), updateDt) <- timeIt $ runStateT
                (travComp
                  (\comp -> do
                      logDebug ("Visiting component " <> _componentName comp)
                      mbComp <- get
                      case mbComp of
                        Just{} -> do
                          -- fail if we already visited
                          lift $ onErr rendered $ SomeException $ AnapoException
                            "nodeLoop: visited multiple elements in the affine traversal for component! check if your AffineTraversal are really affine"
                        Nothing -> do
                          mbCtx <- liftIO (readIORef (_componentContext comp))
                          ctx <- case mbCtx of
                            Nothing -> do
                              lift $ onErr rendered $ SomeException $ AnapoException $
                                "nodeLoop: failed to get component context for component " <> _componentName comp <> "!"
                            Just ctx -> return ctx
                          -- run the state update synchronously: both
                          -- because we want it to be done asap, and
                          -- because we want to crash it if there are
                          -- blocking calls
                          mbSt <- DOM.liftJSM (try (synchronously (modif ctx (_componentState comp))))
                          case mbSt of
                            Left err -> DOM.liftJSM (onErr rendered err)
                            Right (st, rerender) -> do
                              let comp' = comp{ _componentState = st }
                              put (Just (comp', rerender))
                              return comp')
                  compRoot)
                Nothing
              logDebug ("State updated (" <> pack (show updateDt) <> "), might re render")
              case mbComp of
                Nothing -> do
                  logInfo "The component was not found, not rerendering"
                  go compRoot' rendered
                Just (comp, rerender) -> do
                  case rerender of
                    UnsafeDontRerender -> do
                      logDebug ("Not rerendering component " <> _componentName comp <> " since the update function returned UnsafeDontRerender")
                      return ()
                    Rerender -> do
                      positions <- liftIO (readIORef (_componentPositions comp))
                      logDebug ("Rendering component " <> _componentName comp <> " at " <> pack (show (HMS.size positions)) <> " positions")
                      -- do not leave half-done DOM in place, run
                      -- everything synchronously
                      synchronously $ for_ (HMS.toList positions) $ \(pos, props) -> do
                        vdom <- runComp pos travComp comp props
                        V.reconciliate rendered pos vdom
                  go compRoot' rendered
      tid <- liftIO myThreadId
      finally
        (do
          -- run for the first time
          comp <- newNamedComponent "root" st0 (\() -> node)
          liftIO (writeIORef (_componentContext comp) (Just ()))
          vdom <- runComp [] id comp ()
          -- do this synchronously, too
          rendered0 <- synchronously $ do
            V.render vdom $ \rendered -> do
              case injectMode of
                IMAppend -> return ()
                IMEraseAndAppend -> removeAllChildren root
              DOM.Node.appendChild_ root =<< V.renderedNodeDom rendered
          -- now loop
          go comp rendered0
          return rendered0)
        (liftIO (readIORef tidsRef >>= traverse_ (\tid' -> when (tid /= tid') (killThread tid')))))
    actionEnv
    (actionTrav id)

removeAllChildren :: DOM.Node -> DOM.JSM ()
removeAllChildren node = go
  where
    go = do
      mbChild <- DOM.Node.getFirstChild node
      case mbChild of
        Nothing -> return ()
        Just child -> do
          DOM.Node.removeChild_ node child
          go

{-# INLINABLE installNodeBody #-}
installNodeBody ::
     (forall a. (st -> DOM.JSM a) -> Action () st a)
  -> Node () st
  -> (SomeException -> Node () ())
  -> InstallMode
  -> DOM.JSM ()
installNodeBody getSt vdom0 excVdom injectMode = do
  doc <- DOM.currentDocumentUnchecked
  body <- DOM.Document.getBodyUnchecked doc
  void (nodeLoop getSt vdom0 excVdom injectMode (DOM.toNode body))

{-# INLINABLE installNode #-}
installNode ::
     (DOM.IsNode el)
  => (forall a. (st -> DOM.JSM a) -> Action () st a)
  -> Node () st
  -> (SomeException -> Node () ())
  -> InstallMode
  -> el
  -> DOM.JSM ()
installNode getSt vdom0 excVdom injectMode container = do
  void (nodeLoop getSt vdom0 excVdom injectMode (DOM.toNode container))

addCallStack :: CallStack -> Text -> Text
addCallStack stack = case getCallStack stack of
  [] -> id
  (_, SrcLoc{..}) : _ -> \txt -> "[" <> pack srcLocModule <> ":" <> pack (show srcLocStartLine) <> ":" <> pack (show srcLocStartCol) <> "] " <> txt
