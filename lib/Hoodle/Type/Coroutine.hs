-----------------------------------------------------------------------------
-- |
-- Module      : Hoodle.Type.Coroutine 
-- Copyright   : (c) 2011, 2012 Ian-Woo Kim
--
-- License     : BSD3
-- Maintainer  : Ian-Woo Kim <ianwookim@gmail.com>
-- Stability   : experimental
-- Portability : GHC
--
-----------------------------------------------------------------------------

module Hoodle.Type.Coroutine where

-- from other packages 
import Control.Concurrent 
import Control.Monad.State
import Control.Monad.Trans.Free
import Data.IORef 
-- from hoodle-platform
import Control.Monad.Trans.Crtn 
-- from this package
import Hoodle.Type.Event
import Hoodle.Type.XournalState 
-- 

-- | 
type MainCoroutine a = CnsmT MyEvent XournalStateIO a 
-- type MainCoroutine a = SrvT MyEvent () XournalStateIO a 

-- |
type Driver a = CnsmT MyEvent IO a 
-- type Driver a = SrvT MyEvent () a 

{- 
-- | 
mapDown1 :: HoodleState -> MainCoroutine a -> Driver a 
mapDown1 st m = 
    FreeT $ do x <- flip runStateT st $ runFreeT m 
               case x of 
                 (Pure r,_) -> return (Pure r) 
                 (Free (Awt next),st') -> 
                   return . Free . Awt $ \ev -> mapDown st' (next ev)
-}                      

{-                   
                   
                   Awt $ \ev -> mapStateDown st' (fmap ev 
                                                                  
                                                                  
                                                                  f x next ev)
-}
  
  
type TRef = IORef (Maybe (MyEvent -> Driver ()))

type EventVar = MVar (Maybe (MyEvent -> Driver ()))

