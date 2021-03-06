{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Coroutine.File 
-- Copyright   : (c) 2011-2013 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Coroutine.File where

-- from other packages
import           Control.Applicative ((<$>),(<*>))
import           Control.Concurrent
import           Control.Lens (view,set,over,(%~))
import           Control.Monad.Loops
import           Control.Monad.State hiding (mapM)
import           Control.Monad.Trans.Either
import           Data.ByteString (readFile)
import           Data.ByteString.Base64 
import           Data.ByteString.Char8 as B (pack,unpack)
import qualified Data.ByteString.Lazy as L
import           Data.Digest.Pure.MD5 (md5)
import           Data.Maybe
import qualified Data.IntMap as IM
import           Data.Time.Clock
import           Data.UUID.V4 
import           Filesystem.Path.CurrentOS (decodeString, encodeString)
import           Graphics.GD.ByteString 
import           Graphics.Rendering.Cairo
import           Graphics.UI.Gtk hiding (get,set)
import           System.Directory
import           System.Exit 
import           System.FilePath
import qualified System.FSNotify as FS
import           System.Process 
-- from hoodle-platform
import           Control.Monad.Trans.Crtn
import           Control.Monad.Trans.Crtn.Event
import           Control.Monad.Trans.Crtn.Queue 
import           Data.Hoodle.BBox
import           Data.Hoodle.Generic
import           Data.Hoodle.Simple
import           Data.Hoodle.Select
import           Graphics.Hoodle.Render.Generic
import           Graphics.Hoodle.Render.Item
import           Graphics.Hoodle.Render.Type
import           Graphics.Hoodle.Render.Type.HitTest 
import           Text.Hoodle.Builder 
-- from this package 
import           Hoodle.Accessor
import           Hoodle.Coroutine.Draw
import           Hoodle.Coroutine.Commit
import           Hoodle.Coroutine.Mode 
import           Hoodle.Coroutine.Scroll
import           Hoodle.Coroutine.TextInput
import           Hoodle.ModelAction.File
import           Hoodle.ModelAction.Layer 
import           Hoodle.ModelAction.Page
import           Hoodle.ModelAction.Select
import           Hoodle.ModelAction.Select.Transform
import           Hoodle.ModelAction.Window
import qualified Hoodle.Script.Coroutine as S
import           Hoodle.Script.Hook
-- import           Hoodle.Type.Alias
import           Hoodle.Type.Canvas
import           Hoodle.Type.Coroutine
import           Hoodle.Type.Enum
import           Hoodle.Type.Event hiding (TypSVG)
import           Hoodle.Type.HoodleState
import           Hoodle.Type.PageArrangement
import           Hoodle.View.Draw
--
import Prelude hiding (readFile,concat,mapM)



-- |
okMessageBox :: String -> MainCoroutine () 
okMessageBox msg = modify (tempQueue %~ enqueue action) 
                   >> waitSomeEvent (\x->case x of GotOk -> True ; _ -> False) 
                   >> return () 
  where 
    action = mkIOaction $ 
               \_evhandler -> do 
                 dialog <- messageDialogNew Nothing [DialogModal]
                   MessageQuestion ButtonsOk msg 
                 _res <- dialogRun dialog 
                 widgetDestroy dialog 
                 return (UsrEv GotOk)

-- | 
okCancelMessageBox :: String -> MainCoroutine Bool 
okCancelMessageBox msg = modify (tempQueue %~ enqueue action) 
                         >> waitSomeEvent p >>= return . q
  where 
    p (OkCancel _) = True 
    p _ = False 
    q (OkCancel b) = b 
    q _ = False 
    action = mkIOaction $ 
               \_evhandler -> do 
                 dialog <- messageDialogNew Nothing [DialogModal]
                   MessageQuestion ButtonsOkCancel msg 
                 res <- dialogRun dialog 
                 let b = case res of 
                           ResponseOk -> True
                           _ -> False
                 widgetDestroy dialog 
                 return (UsrEv (OkCancel b))

-- | 
fileChooser :: FileChooserAction -> Maybe String -> MainCoroutine (Maybe FilePath) 
fileChooser choosertyp mfname = do 
    mrecentfolder <- S.recentFolderHook 
    xst <- get 
    let rtrwin = view rootOfRootWindow xst 
    liftIO $ widgetQueueDraw rtrwin 
        
    modify (tempQueue %~ enqueue (action rtrwin mrecentfolder)) >> go 
  where 
    go = do r <- nextevent                   
            case r of 
              FileChosen b -> return b  
              UpdateCanvas cid -> -- this is temporary
                                  invalidateInBBox Nothing Efficient cid >> go  
              _ -> go 
    action win mrf = mkIOaction $ \_evhandler -> do 
      dialog <- fileChooserDialogNew Nothing (Just win) choosertyp 
                  [ ("OK", ResponseOk) 
                  , ("Cancel", ResponseCancel) ]
      case mrf of 
        Just rf -> fileChooserSetCurrentFolder dialog rf 
        Nothing -> getCurrentDirectory >>= fileChooserSetCurrentFolder dialog 
      maybe (return ()) (fileChooserSetCurrentName dialog) mfname 
      --   !!!!!! really hackish solution !!!!!!
      whileM_ (liftM (>0) eventsPending) (mainIterationDo False)
      
      res <- dialogRun dialog
      mr <- case res of 
              ResponseDeleteEvent -> return Nothing
              ResponseOk ->  fileChooserGetFilename dialog 
              ResponseCancel -> return Nothing 
              _ -> putStrLn "??? in fileOpen" >> return Nothing 
      widgetDestroy dialog
      return (UsrEv (FileChosen mr))

-- | 
askIfSave :: MainCoroutine () -> MainCoroutine () 
askIfSave action = do 
    xstate <- get 
    if not (view isSaved xstate)
      then do  
        b <- okCancelMessageBox "Current canvas is not saved yet. Will you proceed without save?" 
        case b of 
          True -> action 
          False -> return () 
      else action 

-- | 
askIfOverwrite :: FilePath -> MainCoroutine () -> MainCoroutine () 
askIfOverwrite fp action = do 
    b <- liftIO $ doesFileExist fp 
    if b 
      then do 
        r <- okCancelMessageBox ("Overwrite " ++ fp ++ "???") 
        if r then action else return () 
      else action 

-- | 
fileNew :: MainCoroutine () 
fileNew = do  
    xstate <- get
    xstate' <- liftIO $ getFileContent Nothing xstate 
    ncvsinfo <- liftIO $ setPage xstate' 0 (getCurrentCanvasId xstate')
    xstate'' <- return $ over currentCanvasInfo (const ncvsinfo) xstate'
    liftIO $ setTitleFromFileName xstate''
    commit xstate'' 
    invalidateAll 

-- | 
fileSave :: MainCoroutine ()
fileSave = do 
    xstate <- get 
    case view (hoodleFileControl.hoodleFileName) xstate of
      Nothing -> fileSaveAs 
      Just filename -> do     
        -- this is rather temporary not to make mistake 
        if takeExtension filename == ".hdl" 
          then do 
             put =<< (liftIO (saveHoodle xstate))
             (S.afterSaveHook filename . rHoodle2Hoodle . getHoodle) xstate
          else fileExtensionInvalid (".hdl","save") >> fileSaveAs 


-- | interleaving a monadic action between each pair of subsequent actions
sequence1_ :: (Monad m) => m () -> [m ()] -> m () 
sequence1_ _ []  = return () 
sequence1_ _ [a] = a 
sequence1_ i (a:as) = a >> i >> sequence1_ i as 

-- | 
renderjob :: RHoodle -> FilePath -> IO () 
renderjob h ofp = do 
  let p = maybe (error "renderjob") id $ IM.lookup 0 (view gpages h)  
  let Dim width height = view gdimension p  
  let rf x = cairoRenderOption (RBkgDrawPDF,DrawFull) x >> return () 
  withPDFSurface ofp width height $ \s -> renderWith s $  
    (sequence1_ showPage . map rf . IM.elems . view gpages ) h 

-- | 
fileExport :: MainCoroutine ()
fileExport = fileChooser FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename = 
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".pdf" 
      then fileExtensionInvalid (".pdf","export") >> fileExport 
      else do      
        xstate <- get 
        let hdl = getHoodle xstate 
        liftIO (renderjob hdl filename) 


-- | 
fileStartSync :: MainCoroutine ()
fileStartSync = do 
   
  xst <- get 
  let mf = (,) <$> view (hoodleFileControl.hoodleFileName) xst <*> view (hoodleFileControl.lastSavedTime) xst 
  -- liftIO $ print mf 
  maybe (return ()) (\(filename,lasttime) -> action filename lasttime) mf  
  --  fileChooser FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where  
    action filename lasttime  = do 
      let ioact = mkIOaction $ \evhandler ->do 
            forkIO $ do 
              FS.withManager $ \wm -> do 
                origfile <- canonicalizePath filename 
                let (filedir,_) = splitFileName origfile
                print filedir 
                FS.watchDir wm (decodeString filedir) (const True) $ \ev -> do 
                  let mchangedfile = case ev of 
                        FS.Added fp _ -> Just (encodeString fp)
                        FS.Modified fp _ -> Just (encodeString fp)
                        FS.Removed fp _ -> Nothing 
                  print mchangedfile 
                  case mchangedfile of 
                    Nothing -> return ()
                    Just changedfile -> do                       
                      let changedfilename = takeFileName changedfile 
                          changedfile' = (filedir </> changedfilename)
                      if changedfile' == origfile 
                        then do 
                          ctime <- getCurrentTime 
                          evhandler (UsrEv (Sync ctime))
                        else return () 

                let sec = 1000000
                forever (threadDelay (100 * sec))
            return (UsrEv ActionOrdered)
      modify (tempQueue %~ enqueue ioact) 

-- | need to be merged with ContextMenuEventSVG
exportCurrentPageAsSVG :: MainCoroutine ()
exportCurrentPageAsSVG = fileChooser FileChooserActionSave Nothing >>= maybe (return ()) action 
  where 
    action filename = 
      -- this is rather temporary not to make mistake 
      if takeExtension filename /= ".svg" 
      then fileExtensionInvalid (".svg","export") >> exportCurrentPageAsSVG 
      else do      
        cpg <- getCurrentPageCurr
        let Dim w h = view gdimension cpg 
        liftIO $ withSVGSurface filename w h $ \s -> renderWith s $ 
         cairoRenderOption (InBBoxOption Nothing) (InBBox cpg) >> return ()

-- | 
fileLoad :: FilePath -> MainCoroutine () 
fileLoad filename = do
    xstate <- get 
    xstate' <- liftIO $ getFileContent (Just filename) xstate
    ncvsinfo <- liftIO $ setPage xstate' 0 (getCurrentCanvasId xstate')
    xstateNew <- return $ over currentCanvasInfo (const ncvsinfo) xstate'
    put . set isSaved True $ xstateNew 
    let ui = view gtkUIManager xstate
    liftIO $ toggleSave ui False
    liftIO $ setTitleFromFileName xstateNew  
    clearUndoHistory 
    modeChange ToViewAppendMode 
    resetHoodleBuffers 
    invalidateAll 
    applyActionToAllCVS adjustScrollbarWithGeometryCvsId

-- | 
resetHoodleBuffers :: MainCoroutine () 
resetHoodleBuffers = do 
    liftIO $ putStrLn "resetHoodleBuffers called"
    xst <- get 
    nhdlst <- liftIO $ resetHoodleModeStateBuffers (view hoodleModeState xst)
    let nxst = set hoodleModeState nhdlst xst
    put nxst     

-- | main coroutine for open a file 
fileOpen :: MainCoroutine ()
fileOpen = do 
  mfilename <- fileChooser FileChooserActionOpen Nothing
  case mfilename of 
    Nothing -> return ()
    Just filename -> fileLoad filename 

-- | main coroutine for save as 
fileSaveAs :: MainCoroutine () 
fileSaveAs = do 
    xstate <- get 
    let hdl = (rHoodle2Hoodle . getHoodle) xstate
    maybe (defSaveAsAction xstate hdl) (\f -> liftIO (f hdl))
          (hookSaveAsAction xstate) 
  where 
    hookSaveAsAction xstate = do 
      hset <- view hookSet xstate
      saveAsHook hset
    defSaveAsAction xstate hdl = do 
        let msuggestedact = view hookSet xstate >>= fileNameSuggestionHook 
        (msuggested :: Maybe String) <- maybe (return Nothing) (liftM Just . liftIO) msuggestedact 
        mr <- fileChooser FileChooserActionSave msuggested 
        maybe (return ()) (action xstate hdl) mr 
      where action xst' hd filename = 
              if takeExtension filename /= ".hdl" 
              then fileExtensionInvalid (".hdl","save")
              else do 
                askIfOverwrite filename $ do 
                  let ntitle = B.pack . snd . splitFileName $ filename 
                      (hdlmodst',hdl') = case view hoodleModeState xst' of
                         ViewAppendState hdlmap -> 
                           if view gtitle hdlmap == "untitled"
                             then ( ViewAppendState . set gtitle ntitle
                                    $ hdlmap
                                  , (set title ntitle hd))
                             else (ViewAppendState hdlmap,hd)
                         SelectState thdl -> 
                           if view gselTitle thdl == "untitled"
                             then ( SelectState $ set gselTitle ntitle thdl 
                                  , set title ntitle hd)  
                             else (SelectState thdl,hd)
                      xstateNew = set (hoodleFileControl.hoodleFileName) (Just filename) 
                                . set hoodleModeState hdlmodst' $ xst'
                  liftIO . L.writeFile filename . builder $ hdl'
                  put . set isSaved True $ xstateNew    
                  let ui = view gtkUIManager xstateNew
                  liftIO $ toggleSave ui False
                  liftIO $ setTitleFromFileName xstateNew 
                  S.afterSaveHook filename hdl'
          

-- | main coroutine for open a file 
fileReload :: MainCoroutine ()
fileReload = do 
    xstate <- get
    case view (hoodleFileControl.hoodleFileName) xstate of 
      Nothing -> return () 
      Just filename -> do
        if not (view isSaved xstate) 
          then do
            b <- okCancelMessageBox "Discard changes and reload the file?" 
            case b of 
              True -> fileLoad filename 
              False -> return ()
          else fileLoad filename

-- | 
fileExtensionInvalid :: (String,String) -> MainCoroutine ()
fileExtensionInvalid (ext,a) = 
  okMessageBox $ "only " 
                 ++ ext 
                 ++ " extension is supported for " 
                 ++ a 
    
-- | 
fileAnnotatePDF :: MainCoroutine ()
fileAnnotatePDF = 
    fileChooser FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where 
    warning = do 
      okMessageBox "cannot load the pdf file. Check your hoodle compiled with poppler library" 
      invalidateAll 
    action filename = do  
      xstate <- get 
      let doesembed = view (settings.doesEmbedPDF) xstate
      mhdl <- liftIO $ makeNewHoodleWithPDF doesembed filename 
      flip (maybe warning) mhdl $ \hdl -> do 
        xstateNew <- return . set (hoodleFileControl.hoodleFileName) Nothing 
                     =<< (liftIO $ constructNewHoodleStateFromHoodle hdl xstate)
        commit xstateNew 
        liftIO $ setTitleFromFileName xstateNew             
        invalidateAll  
      

-- | 
fileLoadPNGorJPG :: MainCoroutine ()
fileLoadPNGorJPG = do 
    fileChooser FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where 
    action filename = do  
      xst <- get 
      let isembedded = view (settings.doesEmbedImage) xst 
      nitm <- liftIO (cnstrctRItem =<< makeNewItemImage isembedded filename) 
      insertItemAt Nothing nitm 


insertItemAt :: Maybe (PageNum,PageCoordinate) 
                -> RItem 
                -> MainCoroutine () 
insertItemAt mpcoord ritm = do 
    xst <- get   
    let hdl = getHoodle xst 
        (pgnum,mpos) = case mpcoord of 
          Just (PageNum n,pos) -> (n,Just pos)
          Nothing -> ((unboxGet currentPageNum.view currentCanvasInfo) xst,Nothing)
        (ulx,uly) = (bbox_upperleft.getBBox) ritm
        nitm = case mpos of 
                 Nothing -> ritm 
                 Just (PageCoord (nx,ny)) -> 
                   changeItemBy (\(x,y)->(x+nx-ulx,y+ny-uly)) ritm
          
    let pg = getPageFromGHoodleMap pgnum hdl
        lyr = getCurrentLayer pg 
        oitms = view gitems lyr  
        ntpg = makePageSelectMode pg (oitms :- (Hitted [nitm]) :- Empty)  
    modeChange ToSelectMode 
    nxst <- get 
    thdl <- case view hoodleModeState nxst of
      SelectState thdl' -> return thdl'
      _ -> (lift . EitherT . return . Left . Other) "insertItemAt"
    nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
    let nxst2 = set hoodleModeState (SelectState nthdl) nxst
    put nxst2
    invalidateAll  
        
-- | 
makeNewItemImage :: Bool  -- ^ isEmbedded?
                    -> FilePath 
                    -> IO Item
makeNewItemImage isembedded filename = 
    if isembedded 
      then let fileext = takeExtension filename 
               imgaction 
                 | fileext == ".PNG" || fileext == ".png" = loadpng 
                 | fileext == ".JPG" || fileext == ".jpg" = loadjpg 
                 | otherwise = loadsrc 
           in imgaction 
      else loadsrc 
  where loadsrc = (return . ItemImage) (Image (B.pack filename) (100,100) (Dim 300 300))
        loadpng = do 
          img <- loadPngFile filename
          (w,h) <- imageSize img 
          let dim | w >= h = Dim 300 (fromIntegral h*300/fromIntegral w)
                  | otherwise = Dim (fromIntegral w*300/fromIntegral h) 300 
          bstr <- savePngByteString img 
          let b64str = encode bstr 
              ebdsrc = "data:image/png;base64," <> b64str
          return . ItemImage $ Image ebdsrc (100,100) dim 
        loadjpg = do 
          img <- loadJpegFile filename
          (w,h) <- imageSize img 
          let dim | w >= h = Dim 300 (fromIntegral h*300/fromIntegral w)
                  | otherwise = Dim (fromIntegral w*300/fromIntegral h) 300 
          bstr <- savePngByteString img 
          let b64str = encode bstr 
              ebdsrc = "data:image/png;base64," <> b64str
          return . ItemImage $ Image ebdsrc (100,100) dim 
            
-- | 
fileLoadSVG :: MainCoroutine ()
fileLoadSVG = do 
    fileChooser FileChooserActionOpen Nothing >>= maybe (return ()) action 
  where 
    action filename = do 
      xstate <- get 
      liftIO $ putStrLn filename 
      bstr <- liftIO $ readFile filename 
      let pgnum = unboxGet currentPageNum . view currentCanvasInfo $ xstate
          hdl = getHoodle xstate 
          currpage = getPageFromGHoodleMap pgnum hdl
          currlayer = getCurrentLayer currpage
      newitem <- (liftIO . cnstrctRItem . ItemSVG) 
                   (SVG Nothing Nothing bstr (100,100) (Dim 300 300))
      let otheritems = view gitems currlayer  
      let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
      modeChange ToSelectMode 
      nxstate <- get 
      thdl <- case view hoodleModeState nxstate of
                SelectState thdl' -> return thdl'
                _ -> (lift . EitherT . return . Left . Other) "fileLoadSVG"
      nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
      let nxstate2 = set hoodleModeState (SelectState nthdl) nxstate
      put nxstate2
      invalidateAll 


fileLaTeX :: MainCoroutine () 
fileLaTeX = do modify (tempQueue %~ enqueue action) 
               minput <- go
               case minput of 
                 Nothing -> return () 
                 Just (latex,svg) -> afteraction (latex,svg) 
  where 
    go = do r <- nextevent
            case r of 
              LaTeXInput input -> return input 
              _ -> go 
    action = mkIOaction $ 
               \_evhandler -> do 
                 dialog <- messageDialogNew Nothing [DialogModal]
                   MessageQuestion ButtonsOkCancel "latex input"
                 vbox <- dialogGetUpper dialog
                 txtvw <- textViewNew
                 boxPackStart vbox txtvw PackGrow 0 
                 widgetShowAll dialog
                 res <- dialogRun dialog 
                 case res of 
                   ResponseOk -> do 
                     buf <- textViewGetBuffer txtvw 
                     istart <- textBufferGetStartIter buf
                     iend <- textBufferGetEndIter buf
                     l <- textBufferGetText buf istart iend True
                     widgetDestroy dialog
                     tdir <- getTemporaryDirectory
                     writeFile (tdir </> "latextest.tex") l 
                     let cmd = "lasem-render-0.6 " ++ (tdir </> "latextest.tex") ++ " -f svg -o " ++ (tdir </> "latextest.svg" )
                     print cmd 
                     excode <- system cmd 
                     case excode of 
                       ExitSuccess -> do 
                         svg <- readFile (tdir </> "latextest.svg")
                         return (UsrEv (LaTeXInput (Just (B.pack l,svg))))
                       _ -> return (UsrEv (LaTeXInput Nothing))

                   _ -> do 
                     widgetDestroy dialog
                     return (UsrEv (LaTeXInput Nothing))
    afteraction (latex,svg) = do 
      xstate <- get 
      let pgnum = unboxGet currentPageNum . view currentCanvasInfo $ xstate
          hdl = getHoodle xstate 
          currpage = getPageFromGHoodleMap pgnum hdl
          currlayer = getCurrentLayer currpage
      newitem <- (liftIO . cnstrctRItem . ItemSVG) 
          (SVG (Just latex) Nothing svg (100,100) (Dim 300 50))
      let otheritems = view gitems currlayer  
      let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
      modeChange ToSelectMode 
      nxstate <- get 
      thdl <- case view hoodleModeState nxstate of
                SelectState thdl' -> return thdl'
                _ -> (lift . EitherT . return . Left . Other) "fileLaTeX"
      nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
      let nxstate2 = set hoodleModeState (SelectState nthdl) nxstate
      put nxstate2
      invalidateAll 



-- |
askQuitProgram :: MainCoroutine () 
askQuitProgram = do 
    b <- okCancelMessageBox "Current canvas is not saved yet. Will you close hoodle?" 
    case b of 
      True -> liftIO mainQuit
      False -> return ()
  
-- | 
embedPredefinedImage :: MainCoroutine () 
embedPredefinedImage = do 
    liftIO $ putStrLn "embedPredefinedImage"
    mpredefined <- S.embedPredefinedImageHook 
    liftIO $ print mpredefined
    case mpredefined of 
      Nothing -> return () 
      Just filename -> do 
        xstate <- get 
        let pgnum = unboxGet currentPageNum . view currentCanvasInfo $ xstate
            hdl = getHoodle xstate 
            currpage = getPageFromGHoodleMap pgnum hdl
            currlayer = getCurrentLayer currpage
            isembedded = True
        newitem <- liftIO (cnstrctRItem =<< makeNewItemImage isembedded filename) 

        let otheritems = view gitems currlayer  
        let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
        modeChange ToSelectMode 
        nxstate <- get 
        thdl <- case view hoodleModeState nxstate of
                  SelectState thdl' -> return thdl'
                  _ -> (lift . EitherT . return . Left . Other) "embedPredefinedImage"
        nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
        let nxstate2 = set isOneTimeSelectMode YesAfterSelect 
                     . set hoodleModeState (SelectState nthdl) 
                     $ nxstate
        put nxstate2
        invalidateAll 
        
-- | this is temporary. I will remove it
embedPredefinedImage2 :: MainCoroutine () 
embedPredefinedImage2 = do 
    liftIO $ putStrLn "embedPredefinedImage2"
    mpredefined <- S.embedPredefinedImage2Hook 
    liftIO $ print mpredefined
    case mpredefined of 
      Nothing -> return () 
      Just filename -> do 
        xstate <- get 
        let pgnum = unboxGet currentPageNum . view currentCanvasInfo $ xstate
            hdl = getHoodle xstate 
            currpage = getPageFromGHoodleMap pgnum hdl
            currlayer = getCurrentLayer currpage
            isembedded = True
        newitem <- liftIO (cnstrctRItem =<< makeNewItemImage isembedded filename) 

        let otheritems = view gitems currlayer  
        let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
        modeChange ToSelectMode 
        nxstate <- get 
        thdl <- case view hoodleModeState nxstate of
                  SelectState thdl' -> return thdl'
                  _ -> (lift . EitherT . return . Left . Other) "embedPredefinedImage2"
        nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
        let nxstate2 = set isOneTimeSelectMode YesAfterSelect 
                     . set hoodleModeState (SelectState nthdl) 
                     $ nxstate
        put nxstate2
        invalidateAll         
        
-- | this is temporary. I will remove it
embedPredefinedImage3 :: MainCoroutine () 
embedPredefinedImage3 = do 
    liftIO $ putStrLn "embedPredefinedImage3"
    mpredefined <- S.embedPredefinedImage3Hook 
    liftIO $ print mpredefined
    case mpredefined of 
      Nothing -> return () 
      Just filename -> do 
        xstate <- get 
        let pgnum = unboxGet currentPageNum . view currentCanvasInfo $ xstate
            hdl = getHoodle xstate 
            currpage = getPageFromGHoodleMap pgnum hdl
            currlayer = getCurrentLayer currpage
            isembedded = True
        newitem <- liftIO (cnstrctRItem =<< makeNewItemImage isembedded filename) 

        let otheritems = view gitems currlayer  
        let ntpg = makePageSelectMode currpage (otheritems :- (Hitted [newitem]) :- Empty)  
        modeChange ToSelectMode 
        nxstate <- get 
        thdl <- case view hoodleModeState nxstate of
                  SelectState thdl' -> return thdl'
                  _ -> (lift . EitherT . return . Left . Other) "embedPredefinedImage3"
        nthdl <- liftIO $ updateTempHoodleSelectIO thdl ntpg pgnum 
        let nxstate2 = set isOneTimeSelectMode YesAfterSelect 
                     . set hoodleModeState (SelectState nthdl) 
                     $ nxstate
        put nxstate2
        invalidateAll         
        
-- | 
embedAllPDFBackground :: MainCoroutine () 
embedAllPDFBackground = do 
  xst <- get 
  let hdl = getHoodle xst
  nhdl <- liftIO . embedPDFInHoodle $ hdl
  modeChange ToViewAppendMode
  commit (set hoodleModeState (ViewAppendState nhdl) xst)
  invalidateAll   
  
-- | 
fileVersionSave :: MainCoroutine () 
fileVersionSave = do 
    hdl <- liftM (rHoodle2Hoodle . getHoodle ) get
    minput <- textInputDialog
    doIOaction $ \_evhandler -> do 
          putStrLn "version save"
          tdir <- getTemporaryDirectory 
          hdir <- getHomeDirectory
          uuid <- nextRandom
          let uuidstr = show uuid 
              tempfile = tdir </> uuidstr <.> "hdl"
              hdlbstr = builder hdl 
          L.writeFile tempfile hdlbstr
          ctime <- getCurrentTime 
          let idstr = B.unpack (view hoodleID hdl)
              md5str = show (md5 hdlbstr)
              nfilename = "UUID_"++idstr++"_MD5Digest_"++md5str++"_ModTime_"++ show ctime <.> "hdl"
              vcsdir = hdir </> ".hoodle.d" </> "vcs"
          b <- doesDirectoryExist vcsdir 
          unless b $ createDirectory vcsdir
          renameFile tempfile (vcsdir </> nfilename)  
          --
          let txtstr = maybe "" id minput       
          -- 
          return (UsrEv (GotRevision md5str txtstr))
    -- modify (tempQueue %~ enqueue action) 
    r <- waitSomeEvent (\x -> case x of GotRevision _ _ -> True ; _ -> False )
    let GotRevision md5str txtstr = r          
        nrev = Revision (B.pack md5str) (B.pack txtstr)
    modify (\xst -> let hdlmodst = view hoodleModeState xst 
                    in case hdlmodst of 
                         ViewAppendState rhdl -> 
                           let nrhdl = over grevisions (<> [nrev]) rhdl 
                           in set hoodleModeState (ViewAppendState nrhdl) xst 
                         SelectState thdl -> 
                           let nthdl = over gselRevisions (<> [nrev]) thdl
                           in set hoodleModeState (SelectState nthdl) xst)
    commit_ 

fileShowRevisions :: MainCoroutine ()
fileShowRevisions = do 
  hdl <- liftM getHoodle get  
  let revs = view grevisions hdl
      revstrs = unlines $ map (\rev -> B.unpack (view revmd5 rev) ++ ":" ++ B.unpack (view revtxt rev)) revs
  okMessageBox revstrs
  
fileShowUUID :: MainCoroutine ()
fileShowUUID = do 
  hdl <- liftM getHoodle get  
  let uuidstr = view ghoodleID hdl
  okMessageBox (B.unpack uuidstr)
  

  
  
  