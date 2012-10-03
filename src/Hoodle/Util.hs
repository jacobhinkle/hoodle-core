-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Util 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Util where

import Data.Maybe
import Data.Hoodle.Simple

-- import Data.Time.Clock 
-- import Data.Time.Format
-- import System.Locale

-- for test
-- import Blaze.ByteString.Builder
-- import Text.Hoodle.Builder 

{-
testPage :: Page Edit -> IO () 
testPage page = do
    let pagesimple = toPage bkgFromBkgPDF . tpageBBoxMapPDFFromTPageBBoxMapPDFBuf $ page 
    L.putStrLn . toLazyByteString . Text.Hoodle.Builder.fromPage $ pagesimple 
-}

             
{-
testHoodle :: HoodleState -> IO () 
testHoodle hdlstate = do
  let hdlsimple :: Hoodle = case hdlstate of
                               ViewAppendState hdl -> xournalFromTHoodleSimple (gcast hdl :: THoodleSimple)
                               SelectState thdl -> xournalFromTHoodleSimple (gcast thdl :: THoodleSimple)
  L.putStrLn (builder hdlsimple)
-}

maybeFlip :: Maybe a -> b -> (a->b) -> b  
maybeFlip m n j = maybe n j m   

uncurry4 :: (a->b->c->d->e)->(a,b,c,d)->e 
uncurry4 f (x,y,z,w) = f x y z w 

maybeRead :: Read a => String -> Maybe a 
maybeRead = fmap fst . listToMaybe . reads 

maybeError :: String -> Maybe a -> a
maybeError str = maybe (error str) id 

getLargestWidth :: Hoodle -> Double 
getLargestWidth hdl = 
  let ws = map (dim_width . page_dim) (hoodle_pages hdl)  
  in  maximum ws 

getLargestHeight :: Hoodle -> Double 
getLargestHeight hdl = 
  let hs = map (dim_height . page_dim) (hoodle_pages hdl)  
  in  maximum hs 

waitUntil :: (Monad m) => (a -> Bool) -> m a -> m ()
waitUntil p act = do 
  a <- act
  if p a
    then return ()
    else waitUntil p act  

-- | for debugging
{-
timeShow :: String -> IO () 
timeShow msg = 
  putStrLn . (msg ++) . (formatTime defaultTimeLocale "%Q") 
    =<< getCurrentTime 
-}