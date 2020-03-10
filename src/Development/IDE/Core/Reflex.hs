{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE NoMonoLocalBinds #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE DeriveFunctor #-}
module Development.IDE.Core.Reflex(module Development.IDE.Core.Reflex, HostFrame) where


import qualified Data.List.NonEmpty as NL
--import {-# SOURCE #-} Language.Haskell.Core.FileStore (getModificationTime)
import Language.Haskell.LSP.VFS
import Language.Haskell.LSP.Diagnostics
import qualified Data.SortedList as SL
import qualified Data.Text as T
import Data.List
import qualified Data.HashMap.Strict as HMap
import Control.Monad.Fix
import Data.Functor
import Data.Functor.Barbie
import Data.Functor.Product
import Language.Haskell.LSP.Core
import Data.Kind
import Reflex.Host.Class
import qualified Data.ByteString.Char8 as BS
import Development.IDE.Core.RuleTypes
import Control.Monad.Extra
import Control.Monad.Reader
import Data.GADT.Show
import Data.GADT.Compare.TH
import Data.GADT.Show.TH
import Control.Error.Util
import qualified Data.Dependent.Map as D
import Data.Dependent.Map (DMap, DSum(..))
import Data.These(These(..))
import Reflex.Time
import Reflex.Network
import System.Directory
import Reflex
import GHC hiding (parseModule, mkModule, typecheckModule, getSession)
import qualified GHC
import Reflex.PerformEvent.Class
import Development.IDE.Core.Compile
import Data.Default
import Control.Monad.IO.Class
import Development.IDE.Types.Location
import StringBuffer
import Development.IDE.Types.Options
import Data.Dependent.Map (GCompare)
import Data.GADT.Compare
import qualified Data.Map as M
import Unsafe.Coerce
import Reflex.Host.Basic
import Development.IDE.Import.FindImports
import Control.Monad
import HscTypes
import Data.Either
import Control.Monad.Trans.Maybe
import Control.Monad.Trans
import Module hiding (mkModule)
import qualified Data.Set as Set
import Data.Maybe
import Control.Monad.State.Strict
import Development.IDE.Types.Diagnostics
import Development.IDE.Import.DependencyInformation
import qualified Data.IntMap as IntMap
import qualified Data.IntSet as IntSet
import Data.Coerce
import Data.Traversable
import qualified GHC.LanguageExtensions as LangExt
import DynFlags
import Development.IDE.Spans.Type
import Development.IDE.Spans.Calculate
--import HIE.Bios
--import HIE.Bios.Environment
import System.Environment
import System.IO
import Linker
--import qualified GHC.Paths
import Control.Concurrent
import Reflex.Profiled
import Debug.Trace
import Control.Monad.Ref
import Reflex.Host.Class

import qualified Language.Haskell.LSP.Messages as LSP
import qualified Language.Haskell.LSP.Types as LSP
import qualified Language.Haskell.LSP.Types.Capabilities as LSP
import Development.IDE.Types.Logger
import Development.IDE.Core.Debouncer

data IdeState = IdeState

data Priority = Priority Int
setPriority a = return a

type IdeResult v = ([FileDiagnostic], Maybe v)
data HoverMap = HoverMap
type Diagnostics = String
type RMap t a = M.Map NormalizedFilePath (Dynamic t a)

-- Early cut off
data Early a = Early (Maybe BS.ByteString) a

unearly :: Early a -> a
unearly (Early _ a) = a

early :: _ => Dynamic t (Maybe BS.ByteString, a) -> m (Dynamic t (Early a))
early d = scanDynMaybe (\(h, v) -> Early h v) upd d
  where
    -- Nothing means there's no hash, so always update
    upd (Nothing, a) v = Just (Early Nothing a)
    -- If there's already a hash, and we get a new hash then update
    upd (Just h, new_a) (Early (Just h') _) = if h == h'
                                                  then Nothing
                                                  else (Just (Early (Just h) new_a))
    -- No stored, hash, just update
    upd (h, new_a) (Early Nothing _)   = Just (Early h new_a)


-- Like a Maybe, but has to be activated the first time we try to access it
data Thunk a = Value a | Awaiting | Seed (IO ()) deriving Functor

joinThunk :: Thunk (Maybe a) -> Thunk a
joinThunk (Value m) = maybe Awaiting Value m
joinThunk Awaiting = Awaiting
joinThunk (Seed trig) = (Seed trig)

splitThunk :: a -> Thunk (a, b)  -> (a, Thunk b)
splitThunk _ (Value (l, a)) = (l, Value a)
splitThunk a (Awaiting)  = (a, Awaiting)
splitThunk a (Seed trig) = (a, Seed trig)

thunk :: _ => Event t (Maybe a) -> m (Dynamic t (Thunk a), Event t ())
thunk e  = do
  (start, grow) <- newTriggerEvent
  -- Without this batching the program never terminates, and I don't know
  -- why. The artificial delay seems to allow the events to propagate
  -- correctly.
  start' <- batchOccurrences 0.01 start
  let trig = grow Awaiting
  d <- holdDyn (Seed trig) (leftmost [maybe Awaiting Value <$> e
                                                , Awaiting <$ start' ])
  -- Only allow the thunk to improve
  d' <- improvingResetableThunk d
  return (d', () <$ start')

forceThunk :: _ => Dynamic t (Thunk a) -> m ()
forceThunk d = do
  t <- sample (current d)
  case t of
    Seed start -> liftIO start
    _ -> return ()

sampleThunk :: _ => Dynamic t (Early (Thunk a)) -> m (Maybe a)
sampleThunk d = do
  t <- sample (current (unearly <$> d))
  case t of
    Seed start -> liftIO start >> return Nothing
    Awaiting   -> return Nothing
    Value a    -> return (Just a)


-- Like improvingMaybe, but for the Thunk type
improvingResetableThunk  :: _ => Dynamic t (Thunk a) -> m (Dynamic t (Thunk a))
improvingResetableThunk = scanDynMaybe id upd
  where
    -- ok, if you insist, write the new value
    upd (Value a) _ = Just (Value a)
    -- Wait, once the trigger is pressed
    upd Awaiting  (Seed {}) = Just Awaiting
    -- Allows the thunk to be reset to GC
--    upd s@(Seed {}) _ = Just s
    -- NOPE
    upd _ _ = Nothing

newtype MDynamic t a = MDynamic { getMD :: Dynamic t (Early (Thunk a)) }

-- All the stuff in here is state which depends on the specific module
data ModuleState t = ModuleState
      { rules :: DMap RuleType (MDynamic t)
      , diags :: Event t (NL.NonEmpty DiagsInfo) }

type DiagsInfo = (Maybe Int, NormalizedFilePath, Key, [FileDiagnostic])

data GlobalVar t a = GlobalVar { dyn :: Dynamic t a
                               , updGlobal :: (a -> a) -> IO ()
                               -- A function which can be used
                               -- to update the dynamic
                               }


data GlobalEnv t = GlobalEnv { globalEnv :: D.DMap GlobalType (GlobalVar t)
                             -- The global state of the application, stuff
                             -- which doesn't depend on the current file.
                             , handlers  :: GlobalHandlers t
                             -- These events fire when the server recieves a message
                             , init_e    :: Event t InitParams
                             -- This event fires when the server is
                             -- initialised
                             }


type ModuleMap t = (Dynamic t (M.Map NormalizedFilePath (ModuleState t)))

data ModuleMapWithUpdater t =
  MMU {
    getMap :: ModuleMap t
    , updateMap :: [(D.Some RuleType, NormalizedFilePath)] -> IO ()
    }

currentMap = current . getMap
updatedMap = updated . getMap


mkModuleMap :: forall t m . (Adjustable t m
                            , Reflex t
                            , PerformEvent t m
                            , Monad m
                            , TriggerEvent t m
                            , MonadIO m
                            , MonadFix m
                            , MonadIO (Performable m)
                            , MonadHold t m
                            ) => GlobalEnv t
                 -> [ShakeDefinition (Performable m) t]
                 -> Event t (D.Some RuleType, NormalizedFilePath)
                 -> m (ModuleMapWithUpdater t)
mkModuleMap genv rules_raw input = mdo

  -- An event which is triggered to update the incremental
  (map_update, update_trigger) <- newTriggerEvent
  map_update' <- fmap concat <$> batchOccurrences 0.01 map_update
  let mk_patch (fp, v) = v
      mkM (sel, fp) = (fp, Just (mkModule genv rules_raw mmu sel fp))
      mk_module fp act _ = mk_patch <$> act
      sing fp = [fp]
      inp = M.fromList . map mkM <$> mergeWith (++) [sing <$> input, map_update']
--  let input_event = (fmap mk_patch . mkModule o e mod_map <$> input)

  mod_map <- listWithKeyShallowDiff M.empty inp mk_module  --(mergeWith (<>) [input_event, map_update])
  let mmu = (MMU mod_map update_trigger)
  return mmu

type Action t m a = NormalizedFilePath -> ActionM t m (IdeResult a)

type EarlyAction t m a = NormalizedFilePath
                       -> ActionM t m ((Maybe BS.ByteString, IdeResult a))

type CAction t m a = NormalizedFilePath -> ActionM t m (Maybe BS.ByteString, IdeResult a)

type ActionM t m a = (ReaderT (REnv t) (MaybeT (EventWriterT t () m)) a)

type DynamicM t m a = (ReaderT (REnv t) m (Dynamic t a))

type BasicM t m a = (ReaderT (REnv t) m a)

liftActionM :: Monad m => m a -> ActionM t m a
liftActionM = lift . lift . lift

lr1 :: Monad m => ActionM t m (Maybe a) -> ActionM t m a
lr1 ac = do
  r <- ac
  lift $ MaybeT (return r)



data REnv t = REnv { global :: GlobalEnv t
                   , module_map :: ModuleMapWithUpdater t
                   }

data ForallAction a where
  ForallAction :: (forall t . C t => ActionM t (HostFrame t) a) -> ForallAction a

data ForallDynamic a where
  ForallDynamic :: (forall t . C t => DynamicM t (BasicGuestWrapper t) a) -> ForallDynamic a

data ForallBasic a where
  ForallBasic :: (forall t . C t => BasicM t (BasicGuestWrapper t) a) -> ForallBasic a

newtype WrappedAction m t a =
          WrappedAction { getAction :: Action t m a }

newtype WrappedEarlyAction m t a =
         WrappedEarlyAction { getEarlyAction :: EarlyAction t m a }

newtype WrappedActionM m t a =
          WrappedActionM { getActionM :: ActionM t m a }

newtype WrappedDynamicM m t a =
          WrappedDynamicM { getDynamicM :: DynamicM t m a }

type Definition rt f t  = D.DSum rt (f t)

newtype BasicGuestWrapper t a =
          BasicGuestWrapper { unwrapBG :: (forall m . BasicGuestConstraints t m => BasicGuest t m a) }

instance Monad (BasicGuestWrapper t) where
  return x = BasicGuestWrapper (return x)
  (BasicGuestWrapper a) >>= f = BasicGuestWrapper (a >>= unwrapBG . f)

instance Applicative (BasicGuestWrapper t) where
  pure x = BasicGuestWrapper (pure x)
  (BasicGuestWrapper a) <*> (BasicGuestWrapper b) = BasicGuestWrapper (a <*> b)

instance Functor (BasicGuestWrapper t) where
  fmap f (BasicGuestWrapper a) = BasicGuestWrapper (fmap f a)

instance MonadHold t (BasicGuestWrapper t) where
  buildDynamic a e = BasicGuestWrapper (buildDynamic a e)
  headE e = BasicGuestWrapper (headE e)
  hold a e = BasicGuestWrapper (hold a e)
  holdDyn a e = BasicGuestWrapper (holdDyn a e)
  holdIncremental a e = BasicGuestWrapper (holdIncremental a e)

instance MonadSample t (BasicGuestWrapper t) where
  sample b = BasicGuestWrapper (sample b)

instance MonadFix (BasicGuestWrapper t) where
  mfix f = BasicGuestWrapper (mfix (unwrapBG . f))

instance MonadIO (BasicGuestWrapper t) where
  liftIO m = BasicGuestWrapper (liftIO m)



-- Per module rules are only allowed to sample dynamics, so can be
-- triggered by external events but the external events also trigger
-- some global state to be updated.
type ShakeDefinition m t = Definition RuleType (WrappedEarlyAction m) t

-- Global definitions build dynamics directly as they need to populate
-- the global state
type GlobalDefinition m t = Definition GlobalType (WrappedDynamicM m) t

data Rule t = ModRule (ShakeDefinition (HostFrame t) t) | GlobalRule (GlobalDefinition (BasicGuestWrapper t) t)

type C t = (Monad (HostFrame t), MonadIO (HostFrame t), Ref (HostFrame t) ~ Ref IO
           , MonadRef (HostFrame t), Reflex t, MonadSample t (HostFrame t))

data WRule where
  WRule :: (forall t . C t => Rule t) -> WRule

type Rules = [WRule]

partitionRules :: C t => Rules -> ([ShakeDefinition (HostFrame t) t], [GlobalDefinition (BasicGuestWrapper t) t])
partitionRules [] = ([], [])
partitionRules (WRule (ModRule r) : xs) = let (rs, gs) = partitionRules xs in  (r:rs, gs)
partitionRules (WRule (GlobalRule g) : xs) = let (rs, gs) = partitionRules xs in  (rs, g:gs)

define :: RuleType a -> (forall t . C t => Action t (HostFrame t) a) -> WRule
define rn a = WRule (ModRule (rn :=> WrappedEarlyAction (fmap (fmap (Nothing,)) a)))

-- TODO: Doesn't implement early cutoff, need to generalise ModRule
defineEarlyCutoff :: RuleType a -> (forall t . C t => CAction t (HostFrame t) a) -> WRule
defineEarlyCutoff rn a = WRule (ModRule (rn :=> WrappedEarlyAction a))

-- Like define but doesn't depend on the filepath, usually depends on the
-- global input events somehow
addIdeGlobal :: GlobalType a -> (forall t . C t => DynamicM t (BasicGuestWrapper t) a) -> WRule
addIdeGlobal gn a = WRule (GlobalRule (gn :=> WrappedDynamicM a))

mkModule :: forall t m . (MonadIO m, PerformEvent t m, TriggerEvent t m, Monad m, Reflex t, MonadFix m, _) =>
                 GlobalEnv t
              -> [ShakeDefinition (Performable m) t]
              -> ModuleMapWithUpdater t
              -> D.Some RuleType
              -> NormalizedFilePath
              -> m (NormalizedFilePath, ModuleState t)
mkModule genv rules_raw mm (D.Some sel) f = do
  -- List of all rules in the application

  (rule_dyns, diags_e) <- unzip <$> mapM rule rules_raw
  let rule_dyns_map = D.fromList rule_dyns
  -- Run all the rules once to get them going
  case D.lookup sel rule_dyns_map of
    Just (MDynamic d) -> forceThunk (unearly <$> d)
    Nothing -> return ()
  let diags_with_mod = mergeList diags_e
--  let diags_with_mod = (Nothing,) <$> updated diags_e
  let m = ModuleState { rules = D.fromList rule_dyns
                      , diags = diags_with_mod }
  return (f, m)

  where
    rule :: _ => ShakeDefinition (Performable m) t
         -> m (DSum RuleType (MDynamic t), Event t DiagsInfo)
    rule (name :=> (WrappedEarlyAction act)) = mdo
        act_trig <- switchHoldPromptly trigger (fmap (\e -> leftmost [trigger, e]) deps)
        pm <- performEvent (traceAction ident (runEventWriterT (runMaybeT (flip runReaderT renv (act f)))) <$! act_trig)
        let (act_res, deps) = splitE pm
        (act_des_d, trigger) <- thunk act_res
        let swap_tup ((a, (b, c))) = (b, (a, c))
        let d = swap_tup . fmap (splitThunk []) . splitThunk Nothing <$> act_des_d
        let (pm_diags, res) = splitDynPure d
        early_res <- early (fmap joinThunk <$> res)
        diags_with_mod <- performEvent (get_mod <$> attach vfs_b (updated pm_diags))
--        tellDyn pm_diags
        let ident = show f ++ ": " ++ gshow name
        return (name :=> (MDynamic $ traceDynE ("D:" ++ ident) early_res), diags_with_mod)
--        return (name :=> MDynamic res')
--
      where
        get_mod (vfs, ds) = do
          mbVirtual <- liftIO $ getVirtualFile vfs $ filePathToUri' f
          return (virtualFileVersion <$> mbVirtual, f, D.Some name, ds)
    vfs_b = (current . dyn $ D.findWithDefault (error "error") GetVFSHandle (globalEnv genv))




    renv = REnv genv mm


traceAction ident a = a
traceAction ident a = do
  liftIO $ traceEventIO ("START:" ++ ident)
  r <- a
  liftIO $ traceEventIO ("END:" ++ ident)
  return r

traceDynE p d = traceDynWith (const $ Debug.Trace.traceEvent p p) d

{-
--test :: Dynamic t IdeOptions -> Dynamic t HscEnv -> [NormalizedFilePath] -> Event t NormalizedFilePath -> BasicGuest t m (ModuleMap t, Dynamic t [FileDiagnostic])
--test o e m i = _ $ mkModuleMap o e m i
--
-- Set the GHC libdir to the nix libdir if it's present.
getLibdir :: IO FilePath
getLibdir = fromMaybe GHC.Paths.libdir <$> lookupEnv "NIX_GHC_LIBDIR"


cradleToSession :: Cradle -> IO HscEnv
cradleToSession cradle = do
    cradleRes <- getCompilerOptions "" cradle
    ComponentOptions opts _deps <- case cradleRes of
        CradleSuccess r -> pure r
        CradleFail err -> error (show err)
        -- TODO Rather than failing here, we should ignore any files that use this cradle.
        -- That will require some more changes.
        CradleNone -> fail "'none' cradle is not yet supported"
    libdir <- getLibdir
    env <- runGhc (Just libdir) $ do
        dflags <- getSessionDynFlags
        -- Perhaps need to enable -fignore-interface-pragmas to not
        -- recompie due to changes to unfoldings and so on
        (dflags', _targets) <- addCmdOpts opts dflags
        _ <- setSessionDynFlags dflags'
        GHC.getSession

    initDynLinker env
    return env


loadSession :: FilePath -> FilePath -> IO HscEnv
loadSession dir v = do
    cradleLoc <- findCradle v
    c <- loadCradle v
    cradleToSession c
    -}

instance TraversableB HandlersG where
instance ApplicativeB HandlersG where
instance FunctorB HandlersG where

type GlobalHandlers t = HandlersG (Event t)

-- Make the handlers and events which fire when a handler fires
mkHandlers :: forall m t . _ => m (Handlers, GlobalHandlers t)
mkHandlers = do
  res <- btraverse go h
  return $ bunzip res
  where
    h :: Handlers
    h = def

    go :: f a -> m ((MHandler `Product` (Event t)) a)
    go _ = do
      (input, trig) <- newTriggerEvent
      return (Pair (MJust trig) (input))

reflexOpen :: Logger
           -> Debouncer LSP.NormalizedUri
           -> IdeOptions
           -> (Handlers ->
                ((VFSHandle, LSP.ClientCapabilities, IO LSP.LspId, (LSP.FromServerMessage -> IO ())) -> IO ())
              -> ((D.Some RuleType, NormalizedFilePath) -> IO ())
              -> ForallBasic ())
           -> Rules
           -> IO ()
reflexOpen logger debouncer opts startServer init_rules = do
--  session <- loadSession "/home/matt/reflex-ghc/ghcide/" "/home/matt/reflex-ghc/ghcide/hie.yaml"
--  setCurrentDirectory "/home/matt/reflex-ghc/ghcide"


  basicHostWithQuit $ mdo
    let (mod_rules, global_rules) = partitionRules init_rules
    pb <- getPostBuild
    (input, input_trigger) <- newTriggerEvent
--    (sample, sample_trigger) <- newTriggerEvent

    -- TODO: Deduplicate, global rules need to be MDynamic as well?
    -- Doesn't typecheck if you have the signature (haha)
    let --rule :: Event t () -> GlobalDefinition (Performable m) t -> m (DSum GlobalType (Dynamic t))
        rule trigger (name :=> (WrappedDynamicM act)) = mdo
          {-
          act_trig <- switchHoldPromptly trigger (fmap (\e -> leftmost [trigger, e]) deps)
          pm <- performEvent (traceAction ident (runEventWriterT (runMaybeT (flip runReaderT renv act))) <$! act_trig)
          -}
          (upd_e, upd) <- newTriggerEvent
          d <- unwrapBG (flip runReaderT renv act)
          d' <- dynApplyEvent upd_e d
--          cur <- sample (current d)
--          let go (This a) = Just (a cur)
              -- This is wrong, triggers are broken
--              go (That b) = Just b
--              go (These a b) = Just (a b)
--          d' <- holdDyn cur (alignEventWithMaybe go  upd_e  (updated d))
          --let (act_res, deps) = splitE pm
          --d <- holdDyn Nothing act_res
          --d' <- improvingMaybe d
          --let ident = gshow name
--        return (traceDynE ("D:" ++ ident) res')
          return (name :=> GlobalVar d' upd)

    let renv = REnv genv mmap

    genv_rules <- mapM (rule pb) global_rules

    let genv = GlobalEnv (D.fromList genv_rules) hs_es init

    all_diags <- switchHoldPromptly never (collectDiags <$> updated (getMap mmap))

    mmap <- mkModuleMap genv mod_rules input

    performEvent_ $ liftIO . print <$> input


--    reportDiags all_diags
--    performEvent_ $ liftIO . print <$> all_diags

    (init, init_trigger) <- newTriggerEvent
    (hs, hs_es) <- mkHandlers

    let ForallBasic start = startServer hs init_trigger input_trigger
    unwrapBG $ flip runReaderT renv start

    (output_diags, _) <- updateFileDiagnostics all_diags
    reportDiags renv (fmap snd output_diags)

    let typecheck fp = input_trigger  (D.Some GetTypecheckedModule, fp)

    liftIO $ forkIO $ do
      typecheck (toNormalizedFilePath "src/Development/IDE/Core/Rules.hs")
      threadDelay 1000000
--      input_trigger (toNormalizedFilePath "B.hs")
      threadDelay 1000000
      showProfilingData
      threadDelay 1000000000

    --performEvent_ $ liftIO . print <$> (updated diags2)
    return never

-- This use of (++) could be really inefficient, probably a better way to
-- do it
collectDiags :: _ => (M.Map NormalizedFilePath (ModuleState t)) -> Event t (NL.NonEmpty DiagsInfo)
collectDiags m = mergeWith (<>) $ map diags (M.elems m)

--  eventer $
-- | Output the diagnostics, with a 0.1s debouncer
reportDiags :: _ => _ -> Event t _ -> m ()
reportDiags renv e = do
  e' <- debounce 0.1 e
  performEvent_ (mapM_ (flip runReaderT renv . putEvent . render) <$> e')
  where
    render (uri, newDiags)
      = publishDiagnosticsNotification (fromNormalizedUri uri) newDiags

    putEvent e = do
      eventer <- askEventer
      liftIO $ eventer e

sampleMaybe :: (Monad m
               , Reflex t
               , MonadIO m
               , MonadSample t m)
                 => RuleType a
                 -> NormalizedFilePath
                 -> ActionM t m a
sampleMaybe sel fp = do
  lr1 (use sel fp)

use_ = sampleMaybe

uses_ :: _ => RuleType a
              -> [NormalizedFilePath]
              -> ActionM t m [a]
uses_ sel fps = mapM (sampleMaybe sel) fps

uses :: _ => RuleType a
             -> [NormalizedFilePath]
             -> ActionM t m [Maybe a]
uses sel fps = mapM (use sel) fps

useWithStale = use

use :: (Monad m
       , Reflex t
       , MonadIO m
       , MonadSample t m)
         => RuleType a
         -> NormalizedFilePath
         -> ActionM t m (Maybe a)
use sel fp = do
  m <- askModuleMap
  mm <- liftActionM $ sample (currentMap m)
  case M.lookup fp mm of
    Just ms -> do
      d <- lift $ hoistMaybe (getMD <$> D.lookup sel (rules ms))
      lift $ lift $ tellEvent (() <$! updated d)
      liftActionM $ sampleThunk d
    Nothing -> do
      liftIO $ traceEventIO "FAILED TO FIND"
      lift $ lift $ tellEvent (() <$! updatedMap m)
      liftIO $ updateMap m [(D.Some sel, fp)]
      return Nothing

useNoTrack :: _ =>  RuleType a -> NormalizedFilePath -> BasicM t m (Maybe a)
useNoTrack sel fp = noTrack (use_ sel fp)


noTrack :: _ => ActionM t m a -> BasicM t m (Maybe a)
noTrack act = ReaderT $ (\renv -> do
                      let x = fst <$> runEventWriterT (runMaybeT (runReaderT act renv))
                      x)

useNoFile_ :: _ => GlobalType a
           -> ActionM t m a
useNoFile_ sel = useNoFile sel

useNoFile :: _ => GlobalType a
          -> ActionM t m a

useNoFile sel = do
  m <- globalEnv <$> askGlobal
  liftActionM $ sample (current $ dyn $ D.findWithDefault (error $ "MISSING RULE:" ++ gshow sel) sel m)

useNoFileBasic :: _ => GlobalType a
          -> BasicM t m a

useNoFileBasic sel = do
  m <- globalEnv <$> askGlobal
  lift $ sample (current $ dyn $ D.findWithDefault (error $ "MISSING RULE:" ++ gshow sel) sel m)

getHandlerEvent sel = do
  sel . handlers <$> askGlobal

getInitEvent = do
  init_e <$> askGlobal


withNotification :: _ => Event t (LSP.NotificationMessage m a) -> Event t a
withNotification = fmap (\(LSP.NotificationMessage _ _ a) -> a)

whenUriFile :: Uri -> r -> (NormalizedFilePath -> r) ->  r
whenUriFile uri def act = maybe def (act . toNormalizedFilePath) (LSP.uriToFilePath uri)



(<$!) v fa = fmap (\a -> a `seq` v) fa


getIdeOptions = useNoFile_ GetIdeOptions
getSession = useNoFile_ GetEnv

askModuleMap = asks (module_map)
askGlobal = asks global

askEventer = do
  (_, _, _, eventer) <- useNoFileBasic GetInitFuncs
  return eventer

{-
getLocatedImportsRule :: _ => ShakeDefinition m t
getLocatedImportsRule = define GetLocatedImports $ \file -> do
            pm <- use_  GetParsedModule file
            env <- getSession
            opt <- getIdeOptions
            let ms = pm_mod_summary pm
            let imports = [(False, imp) | imp <- ms_textual_imps ms] ++ [(True, imp) | imp <- ms_srcimps ms]
            let dflags = addRelativeImport file pm $ hsc_dflags env
            (diags, imports') <- lift $ fmap unzip $ forM imports $ \(isSource, (mbPkgName, modName)) -> do
                diagOrImp <- locateModule dflags (optExtensions opt) doesExist modName mbPkgName isSource
                case diagOrImp of
                    Left diags -> pure (diags, Left (modName, Nothing))
                    Right (FileImport path) -> pure ([], Left (modName, Just $ path))
                    Right (PackageImport pkgId) -> liftIO $ do
                        diagsOrPkgDeps <- computePackageDeps env pkgId
                        case diagsOrPkgDeps of
                          Left diags -> pure (diags, Right Nothing)
                          Right pkgIds -> pure ([], Right $ Just $ pkgId : pkgIds)
            let (moduleImports, pkgImports) = partitionEithers imports'
            case sequence pkgImports of
                Nothing -> pure (concat diags, Nothing)
                Just pkgImports -> pure (concat diags, Just (moduleImports, Set.fromList $ concat pkgImports))
                -}

doesExist nfp = let fp = fromNormalizedFilePath nfp in liftIO $ doesFileExist fp

-- When a new FilePath arrives we need to
-- 1. Parse the module
-- 2. Get the dependenices of the module
-- 3. Compile the dependendencies
-- 4. Compile the module
-- 5. Construct the hover map from the module
--
-- During these steps, the network should be constructed so that if
-- a new file modification event comes in, it only triggers recompilation
-- to the part of the network which may have changed.
{-
getParsedModuleRule :: _ => ShakeDefinition m t
getParsedModuleRule = define GetParsedModule $ \fp -> do
    contents <- liftIO $ stringToStringBuffer <$> (readFile (fromNormalizedFilePath fp))
    packageState <- getSession
    opt <- getIdeOptions
    (diag, res) <- liftIO $ parseModule opt packageState (fromNormalizedFilePath fp) (Just contents)
    case res of
        Nothing -> pure (diag, Nothing)
        Just (contents, modu) -> do
            pure (diag, Just modu)
            -}

dynApplyEvent
  :: (Adjustable t m, MonadHold t m, MonadFix m)
  => Event t (a -> a)
  -> Dynamic t a
  -> m (Dynamic t a)
dynApplyEvent e d = do
  (a, b) <- runWithReplace (pure d) (updated d <&> \i -> foldDyn id i e)
  dd <- holdDyn a b
  pure (join dd)

{- Diagnostics -}

type Key = D.Some RuleType

updateFileDiagnostics ::
  _ => Event t (NL.NonEmpty DiagsInfo)
  -> m (Event t _, Dynamic t _)
updateFileDiagnostics diags = do
--    modTime <- join . fmap currentValue <$> getValues state GetModificationTime fp
    let split :: NL.NonEmpty DiagsInfo -> ([_], [_])
        split es = unzip (map split_one (NL.toList es))
        split_one (mt, fp, k, es) =
            let es' = map (\(_, b, c) -> (b, c)) es
                (currentShown, currentHidden) =
                  partition (\(b, c) -> b == ShowDiag) es'
            in ((mt, fp, k, currentShown), (mt, fp, k, currentHidden))
    let (shown_e, hidden_e) = splitE (split <$> diags)
    newDiags <- foldDynMaybe (\a b -> checkNew (foldr updNewDiags (fst b, []) a) b)
                  (HMap.empty, []) shown_e
    hiddenDiags <- foldDyn (\a b -> foldr updHiddenDiags b a) HMap.empty hidden_e
    return (updated newDiags, hiddenDiags)


    where
      checkNew (newDiagsStore, newDiags) (old, old_newDiags)
        = if old_newDiags == newDiags
            then Nothing
            else Just (newDiagsStore, newDiags)
      updNewDiags (ver, fp, k, currentShown) (c, cds) =
            let newDiagsStore = setStageDiagnostics fp ver
                                  (T.pack $ show k) (map snd currentShown) c
                newDiags = getFileDiagnostics fp newDiagsStore
                uri = filePathToUri' fp
            in (newDiagsStore, (uri, newDiags) : cds)

      updHiddenDiags (ver, fp, k, currentHidden) old =
            let newDiagsStore = setStageDiagnostics fp ver
                                  (T.pack $ show k) (map snd currentHidden) old
                newDiags = getFileDiagnostics fp newDiagsStore
            in newDiagsStore


{-
                     -}

--publish

publishDiagnosticsNotification :: Uri -> [Diagnostic] -> LSP.FromServerMessage
publishDiagnosticsNotification uri diags =
    LSP.NotPublishDiagnostics $
    LSP.NotificationMessage "2.0" LSP.TextDocumentPublishDiagnostics $
    LSP.PublishDiagnosticsParams uri (List diags)



-- | Sets the diagnostics for a file and compilation step
--   if you want to clear the diagnostics call this with an empty list
setStageDiagnostics
    :: NormalizedFilePath
    -> LSP.TextDocumentVersion -- ^ the time that the file these diagnostics originate from was last edited
    -> T.Text
    -> [LSP.Diagnostic]
    -> DiagnosticStore
    -> DiagnosticStore
setStageDiagnostics fp timeM stage diags ds  =
    updateDiagnostics ds uri timeM diagsBySource
    where
        diagsBySource = M.singleton (Just stage) (SL.toSortedList diags)
        uri = filePathToUri' fp

getAllDiagnostics ::
    DiagnosticStore ->
    [FileDiagnostic]
getAllDiagnostics =
    concatMap (\(k,v) -> map (fromUri k,ShowDiag,) $ getDiagnosticsFromStore v) . HMap.toList

getFileDiagnostics ::
    NormalizedFilePath ->
    DiagnosticStore ->
    [LSP.Diagnostic]
getFileDiagnostics fp ds =
    maybe [] getDiagnosticsFromStore $
    HMap.lookup (filePathToUri' fp) ds

filterDiagnostics ::
    (NormalizedFilePath -> Bool) ->
    DiagnosticStore ->
    DiagnosticStore
filterDiagnostics keep =
    HMap.filterWithKey (\uri _ -> maybe True (keep . toNormalizedFilePath) $ uriToFilePath' $ fromNormalizedUri uri)

filterVersionMap
    :: HMap.HashMap NormalizedUri (Set.Set LSP.TextDocumentVersion)
    -> HMap.HashMap NormalizedUri (M.Map LSP.TextDocumentVersion a)
    -> HMap.HashMap NormalizedUri (M.Map LSP.TextDocumentVersion a)
filterVersionMap =
    HMap.intersectionWith $ \versionsToKeep versionMap -> M.restrictKeys versionMap versionsToKeep

getDiagnosticsFromStore :: StoreItem -> [Diagnostic]
getDiagnosticsFromStore (StoreItem _ diags) = concatMap SL.fromSortedList $ M.elems diags