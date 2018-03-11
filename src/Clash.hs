{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances, MultiWayIf #-}
module Clash where
--import qualified Prelude as P
import Program
import Utility
import CSR
import Data.Int
import Data.Word
import Data.Bits
import Data.Char
import Data.Maybe
import qualified Data.List as L
import Control.Applicative
import Control.Monad
import Control.Monad.State
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import System.IO.Error
import qualified Data.Map as S
import ExecuteClash
import qualified Decode as D
import Clash.Prelude


data MMIOClash = MMIOClash { registers :: Vec 31 Int32, pc :: Int32, nextPC :: Int32 , store:: Maybe (Int32,Int32,(Bool,Bool,Bool,Bool)), load :: Int32, loadAddress :: Maybe (Int32,(Bool,Bool,Bool,Bool)), exception :: Bool }
              deriving (Show)

type MState = State MMIOClash
type MMState = MaybeT MState

extract :: Integral a => (Bool,Bool,Bool,Bool) -> Int32 -> a
extract byteen load | -- quot get rid of the bits on the right fromIntegral, those on the left.
	byteen == (_,_,_,True) = fromIntegral load
	byteen == (_,_,True,_) = fromIntegral (load `quot` 256)
	byteen == (_,True,_,_) = fromIntegral (load `quot` 65536)
	byteen == (True,_,_,_) = fromIntegral (load `quot` 16777216)

 
instance RiscvProgram MState Int32 where
  getRegister reg = state $ \comp -> (if reg == 0 then 0 else (registers comp) !! (fromIntegral reg-1), comp)
  setRegister reg val = state $ \comp ->((), if reg == 0 then comp else comp { registers = replace (fromIntegral reg-1) (fromIntegral val) (registers comp) })
-- Fake load and stores
  loadByte ina = state $ \comp -> let a = (ina `quot` 4) * 4 
                                      offset = mod ina 4 
                                      byteen | offset == 3 = (True,False,False,False)
                                             | offset == 2 = (False,True,False,False)
                                             | offset == 1 = (False,False,True,False)
                                             | offset == 0 = (False,False,False,True) in
                         (extract byteen (load comp), comp{loadAddress = Just $ (fromIntegral a, byteen)})
  loadHalf ina =state $ \comp -> let a = (ina `quot` 4) * 4 -- zeroed the bottom two bits probably ot the smartest way Clash-wise
                                     offset = mod ina 4 
                                     byteen | offset == 2 = (True,True,False,False)
                                            | offset == 0 = (False,False,True,True)
                                            | otherwise = (False,False,False,False) -- Should not happen
                         in
                         (extract byteen (load comp), comp{loadAddress = Just $ (fromIntegral a, byteen)})
  loadWord a = state $ \comp -> (load comp, comp{loadAddress = Just $ (fromIntegral a,(True,True,True,True))})
  loadDouble a = state $ \comp -> (0, comp)
  storeByte ina v = state $ \comp -> let a = (ina `quot` 4) * 4 -- zeroed the bottom two bits probably ot the smartest way Clash-wise
                                         offset = mod ina 4 
                                         byteen | offset == 3 = (True,False,False,False)
                                                | offset == 2 = (False,True,False,False)
                                                | offset == 1 = (False,False,True,False)
                                                | offset == 0 = (False,False,False,True)
                         in ((), comp{store=Just (fromIntegral a, fromIntegral v, byteen)})
  storeHalf ina v = state $ \comp ->let a = (ina `quot` 4) * 4 -- zeroed the bottom two bits probably ot the smartest way Clash-wise
                                        offset = mod ina 4 
                                        byteen | offset == 2 = (True,True,False,False)
                                               | offset == 0 = (False,False,True,True)
                                               | otherwise = (False,False,False,False) -- Should not happen
                         in
                         ((), comp{store=Just (fromIntegral a, fromIntegral v, byteen)})
  storeWord  a v = state $ \comp -> ((), comp{store=Just (fromIntegral a, fromIntegral v,(True,True,True,True))})
  storeDouble  a v = state $ \comp -> ((), comp)
-- fake CSR
  getCSRField field = state $ \comp -> (0, comp)
  setCSRField field val = state $ \comp -> ((), comp)
  getPC = state $ \comp -> (pc comp, comp)
  setPC val = state $ \comp -> ((), comp { nextPC = fromIntegral val })
  step = state $ \comp -> ((), comp { pc = nextPC comp })





oneStep :: Int32 -> MState ()
oneStep i = do 
  result <- runMaybeT $ do
    pc <- getPC
    setPC (pc + 4)
    execute (D.decode 32 $ fromIntegral i)
    step
  case result of
    Nothing -> step >> (state $ \comp -> ((), comp{exception = True})) -- early return
    Just r -> return r

wrap :: Int32 -> MMIOClash-> MMIOClash
wrap i s = snd $ runState (oneStep i) s


{-# ANN topEntity 
 (defTop {t_name="rvspec",
          t_inputs=[PortField ""
                      [ PortName "clk"
                      , PortName "arst"
                      ]
                   ,PortField "" 
                      [ PortName "in_registers", PortName "in_instr",
                        PortName "in_pc", PortName "in_loadData"]],
          t_output=PortField "" [PortName "out_registers",
                                PortName "out_nextPC",
                                PortName "out_storeAddress", PortName "out_storeData",
                                PortName "out_storeEnable",
                                PortName "out_loadAddress",
				PortName "out_loadEn",
                                PortName "out_exception"]})#-}
topEntity :: SystemClockReset
  => Signal System (Vec 31 Int32,Int32, Int32, Int32)
  -> Signal System (Vec 31 Int32, Int32, Int32, Int32, (Bool,Bool,Bool,Bool), Int32, (Bool,Bool,Bool,Bool), Bool)
topEntity = fmap (\(
                    iregister, i, ipc, 
                    loadData) ->
                     let newstate = wrap i MMIOClash{registers = iregister,
                                                     pc = ipc,
                                                     nextPC= ipc,
                                                     store = Nothing,
                                                     load = loadData,
                                                     loadAddress = Nothing,
                                                     exception = False
                                                    }
                     in
                       let storeNext = store newstate
                           loadNext = loadAddress newstate
                       in
                         (registers newstate,pc newstate,
                          (\(x,y,z)->x) $ fromMaybe (0,0,(False,False,False,False)) storeNext,
                          (\(x,y,z)->y) $ fromMaybe (0,0,(False,False,False,False)) storeNext,
                          (\(x,y,z)->z) $ fromMaybe (0,0,(False,False,False,False)) storeNext,
                          (\(x,y)-> x) $ fromMaybe (0,(False,False,False,False)) loadNext,
                          (\(x,y)-> y) $ fromMaybe (0,(False,False,False,False)) loadNext,
                          exception newstate))

