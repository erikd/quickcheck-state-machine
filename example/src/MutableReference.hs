{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE ExplicitNamespaces    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeInType            #-}
{-# LANGUAGE TypeOperators         #-}

module MutableReference
  ( MemStep(..)
  , Problem(..)
  , gens
  , shrink1
  , prop_sequential
  , prop_parallel
  ) where

import           Control.Concurrent      (threadDelay)
import           Control.Monad.IO.Class  (MonadIO, liftIO)
import           Data.Constraint         ((\\))
import           Data.IORef              (IORef, atomicModifyIORef', newIORef,
                                          readIORef, writeIORef)
import           Data.Map                (Map)
import qualified Data.Map                as M
import           Data.Singletons.Prelude (type (@@), ConstSym1, Proxy (..),
                                          Sing (STuple0))
import           System.Random           (randomRIO)
import           Test.QuickCheck         (Gen, Property, arbitrary, ioProperty,
                                          property, shrink)

import           Test.StateMachine
import           Test.StateMachine.Types

------------------------------------------------------------------------

data MemStep :: Signature () where
  New   ::                       MemStep refs ('Reference '())
  Read  :: refs @@ '() ->        MemStep refs ('Response Int)
  Write :: refs @@ '() -> Int -> MemStep refs ('Response   ())
  Inc   :: refs @@ '() ->        MemStep refs ('Response   ())
  Copy  :: refs @@ '() ->        MemStep refs ('Reference '())

------------------------------------------------------------------------

newtype Model refs = Model (Map (refs @@ '()) Int)

initModel :: Model ref
initModel = Model M.empty

preconditions :: forall refs resp. IxForallF Ord refs => Model refs -> MemStep refs resp -> Bool
preconditions (Model m) cmd = (case cmd of
  New         -> True
  Read  ref   -> M.member ref m
  Write ref _ -> M.member ref m
  Inc   ref   -> M.member ref m
  Copy  ref   -> M.member ref m) \\ (iinstF @'() Proxy :: Ords refs)

transitions :: forall refs resp. IxForallF Ord refs => Model refs -> MemStep refs resp
  -> Response_ refs resp -> Model refs
transitions (Model m) cmd resp = (case cmd of
  New         -> Model (M.insert resp 0 m)
  Read  _     -> Model m
  Write ref i -> Model (M.insert ref i m)
  Inc   ref   -> Model (M.insert ref (m M.! ref + 1) m)
  Copy  ref   -> Model (M.insert resp (m M.! ref) m)) \\ (iinstF @'() Proxy :: Ords refs)

postconditions :: forall refs resp. IxForallF Ord refs => Model refs -> MemStep refs resp
  -> Response_ refs resp -> Property
postconditions (Model m) cmd resp = (case cmd of
  New         -> property True
  Read  ref   -> property $ m  M.! ref == resp
  Write ref i -> property $ m' M.! ref == i
  Inc   ref   -> property $ m' M.! ref == m M.! ref + 1
  Copy  ref   -> property $ m' M.! resp == m M.! ref) \\ (iinstF @'() Proxy :: Ords refs)
  where
  Model m' = transitions (Model m) cmd resp

------------------------------------------------------------------------

data Problem = None | Bug | RaceCondition
  deriving Eq

semStep
  :: MonadIO m
  => Problem -> MemStep (ConstSym1 (IORef Int)) resp
  -> m (Response_ (ConstSym1 (IORef Int)) resp)
semStep _   New           = liftIO (newIORef 0)
semStep _   (Read  ref)   = liftIO (readIORef  ref)
semStep prb (Write ref i) = liftIO (writeIORef ref i')
  where
  -- Introduce bug:
  i' | i `elem` [5..10] = if prb == Bug then i + 1 else i
     | otherwise        = i
semStep prb (Inc ref)     = liftIO $

  -- Possible race condition:
  if prb == RaceCondition
  then do
    i <- readIORef ref
    threadDelay =<< randomRIO (0, 5000)
    writeIORef ref (i + 1)
  else
    atomicModifyIORef' ref (\i -> (i + 1, ()))
semStep _   (Copy ref)    = do
  old <- liftIO (readIORef ref)
  liftIO (newIORef old)

------------------------------------------------------------------------

gens :: [(Int, Gen (Untyped MemStep (RefPlaceholder ())))]
gens =
  [ (1, return . Untyped $ New)
  , (5, return . Untyped $ Read STuple0)
  , (5, Untyped . Write STuple0 <$> arbitrary)
  , (5, return . Untyped $ Inc STuple0)
  -- , (5, return . Untyped $ Copy STuple0)
  ]

instance HasResponse MemStep where
  response New   {} = SReference STuple0
  response Read  {} = SResponse
  response Write {} = SResponse
  response Inc   {} = SResponse
  response Copy  {} = SReference STuple0

------------------------------------------------------------------------

shrink1 :: MemStep refs resp -> [MemStep refs resp]
shrink1 (Write ref i) = [ Write ref i' | i' <- shrink i ]
shrink1 _             = []

------------------------------------------------------------------------

instance IxFunctor MemStep where
  ifmap _ New           = New
  ifmap f (Read  ref)   = Read  (f STuple0 ref)
  ifmap f (Write ref i) = Write (f STuple0 ref) i
  ifmap f (Inc   ref)   = Inc   (f STuple0 ref)
  ifmap f (Copy  ref)   = Copy  (f STuple0 ref)

instance IxFoldable MemStep where
  ifoldMap _ New           = mempty
  ifoldMap f (Read  ref)   = f STuple0 ref
  ifoldMap f (Write ref _) = f STuple0 ref
  ifoldMap f (Inc   ref)   = f STuple0 ref
  ifoldMap f (Copy  ref)   = f STuple0 ref

instance IxTraversable MemStep where
  ifor _ New             _ = pure New
  ifor _ (Read  ref)     f = Read  <$> f STuple0 ref
  ifor _ (Write ref val) f = Write <$> f STuple0 ref <*> pure val
  ifor _ (Inc   ref)     f = Inc   <$> f STuple0 ref
  ifor _ (Copy  ref)     f = Copy  <$> f STuple0 ref

------------------------------------------------------------------------

instance ShowCmd MemStep where
  showCmd New           = "New"
  showCmd (Read  ref)   = "Read ("  ++ show ref ++ ")"
  showCmd (Write ref i) = "Write (" ++ show ref ++ ") " ++ show i
  showCmd (Inc   ref)   = "Inc ("   ++ show ref ++ ")"
  showCmd (Copy  ref)   = "Copy ("   ++ show ref ++ ")"

------------------------------------------------------------------------

smm :: StateMachineModel Model MemStep
smm = StateMachineModel preconditions postconditions transitions initModel

prop_sequential :: Problem -> Property
prop_sequential prb = sequentialProperty
  smm
  gens
  shrink1
  (semStep prb)
  ioProperty

prop_parallel :: Problem -> Property
prop_parallel prb = parallelProperty
  smm
  gens
  shrink1
  (semStep prb)
