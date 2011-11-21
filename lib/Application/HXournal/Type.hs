module Application.HXournal.Type where

import Application.HXournal.Device
import Control.Monad.Coroutine 
import Control.Monad.Coroutine.SuspensionFunctors
import Data.Functor.Identity (Identity(..))
import Control.Monad.State
import Data.Sequence

import Data.IORef

import Text.Xournal.Type

import Graphics.UI.Gtk

type Trampoline m x = Coroutine Identity m x 
type Generator a m x = Coroutine (Yield a) m x
type Iteratee a m x = Coroutine (Await a) m x

type XournalStateIO = StateT XournalState IO 

data PenDrawing = PenDrawing { penDrawingPoints :: Seq (Double,Double)
                             } 
                  
data PageMode = Continous | OnePage
              deriving (Show,Eq) 

data ZoomMode = Original | FitWidth | Zoom Double 
              deriving (Show,Eq)

data ViewMode = ViewMode { vm_pgmode :: PageMode 
                         , vm_zmmode :: ZoomMode } 
              deriving (Show,Eq)

data XournalState = 
  XournalState 
  { xoj :: Xournal 
  , darea :: DrawingArea
  , currpage :: Int 
  , currpendrawing :: PenDrawing 
  , callback :: MyEvent -> IO ()
  , device :: DeviceList 
  , viewMode :: ViewMode
  } 
                      

data MyEvent = ButtonLeft 
             | ButtonRight 
             | ButtonRefresh 
             | ButtonQuit 
             | UpdateCanvas
             | MenuSave
             | MenuNormalSize
             | MenuPageWidth
             | PenDown PointerCoord
             | PenMove PointerCoord
             | PenUp   PointerCoord 
             deriving (Show,Eq,Ord)


emptyXournalState :: XournalState
emptyXournalState = 
  XournalState 
  { xoj = emptyXournal
  , darea = undefined
  , currpage = 0 
  , currpendrawing = PenDrawing empty 
  , callback = undefined 
  , device = undefined
  , viewMode = ViewMode OnePage Original
  } 
  
  