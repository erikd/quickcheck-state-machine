{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Test.StateMachine.Types.History
-- Copyright   :  (C) 2017, ATS Advanced Telematic Systems GmbH
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Stevan Andjelkovic <stevan@advancedtelematic.com>
-- Stability   :  provisional
-- Portability :  non-portable (GHC extensions)
--
-- This module contains the notion of a history of an execution of a
-- (parallel) program.
--
-----------------------------------------------------------------------------

module Test.StateMachine.Types.History
  ( History(..)
  , History'
  , ppHistory
  , ppHistory'
  , HistoryEvent(..)
  , getProcessIdEvent
  , UntypedConcrete(..)
  , Operation(..)
  , linearTree
  )
  where

import           Data.Dynamic
                   (Dynamic, fromDyn)
import           Data.Tree
                   (Tree(Node))
import           Data.Typeable
                   (Typeable)

import           Test.StateMachine.Internal.Types
import           Test.StateMachine.Internal.Types.Environment
import           Test.StateMachine.Types

------------------------------------------------------------------------

-- | A history is a trace of a program execution.
newtype History act err = History
  { unHistory :: History' act err }
  deriving Monoid

-- | A trace is a list of events.
type History' act err = [HistoryEvent (UntypedConcrete act) err]

-- | An event is either an invocation or a response.
data HistoryEvent act err
  = InvocationEvent act                  String Var Pid
  | ResponseEvent   (Result Dynamic err) String     Pid

-- | Untyped concrete actions.
data UntypedConcrete (act :: (* -> *) -> * -> *) where
  UntypedConcrete :: (Show resp, Typeable resp) =>
    act Concrete resp -> UntypedConcrete act

-- | Pretty print a history.
ppHistory :: History act err -> String
ppHistory = foldr go "" . unHistory
  where
  go :: HistoryEvent (UntypedConcrete act) err -> String -> String
  go (InvocationEvent _ str _ _) ih = " " ++ str ++ " ==> " ++ ih
  go (ResponseEvent   _ str   _) ih =        str ++ "\n"    ++ ih

ppHistory'
  :: forall model act err
  .  Show (model Concrete)
  => model Concrete -> Transition model act -> History act err -> String
ppHistory' model0 transition
  = showsPrec 10 model0
  . go model0
  . unHistory
  where
  go :: model Concrete -> History' act err -> String
  go _     [] = "\n"
  go model (InvocationEvent (UntypedConcrete act) astr var _pid : ResponseEvent res rstr _ : hist)
    = "\n\n    " ++ astr ++ " --> " ++ rstr ++ "\n\n" ++ show model' ++ go model' hist
    where
    model' :: model Concrete
    model' = case res of
      Fail err -> model
      Ok resp  -> transition model act (Concrete (fromDyn resp (error "ppHistory': fromDyn")))

-- | Get the process id of an event.
getProcessIdEvent :: HistoryEvent act err -> Pid
getProcessIdEvent (InvocationEvent _ _ _ pid) = pid
getProcessIdEvent (ResponseEvent   _ _ pid)   = pid

takeInvocations :: [HistoryEvent a b] -> [HistoryEvent a b]
takeInvocations = takeWhile $ \h -> case h of
  InvocationEvent {} -> True
  _                  -> False

findCorrespondingResp :: Pid -> History' act err -> [(Result Dynamic err, History' act err)]
findCorrespondingResp _   [] = []
findCorrespondingResp pid (ResponseEvent resp _ pid' : es) | pid == pid' = [(resp, es)]
findCorrespondingResp pid (e : es) =
  [ (resp, e : es') | (resp, es') <- findCorrespondingResp pid es ]

------------------------------------------------------------------------

-- | An operation packs up an invocation event with its corresponding
--   response event.
data Operation act err = forall resp. Typeable resp =>
  Operation (act Concrete resp) String (Result (Concrete resp) err) Pid

-- | Given a history, return all possible interleavings of invocations
--   and corresponding response events.
linearTree :: History' act err -> [Tree (Operation act err)]
linearTree [] = []
linearTree es =
  [ Node (Operation act str (dynResp resp) pid) (linearTree es')
  | InvocationEvent (UntypedConcrete act) str _ pid <- takeInvocations es
  , (resp, es')  <- findCorrespondingResp pid $ filter1 (not . matchInv pid) es
  ]
  where
  dynResp (Ok   resp) = Ok (either (error . show) id (reifyDynamic resp))
  dynResp (Fail err)  = Fail err

  filter1 :: (a -> Bool) -> [a] -> [a]
  filter1 _ []                   = []
  filter1 p (x : xs) | p x       = x : filter1 p xs
                     | otherwise = xs

  -- Hmm, is this enough?
  matchInv pid (InvocationEvent _ _ _ pid') = pid == pid'
  matchInv _   _                            = False
