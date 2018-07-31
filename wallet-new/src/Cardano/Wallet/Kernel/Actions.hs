{-# LANGUAGE LambdaCase #-}
module Cardano.Wallet.Kernel.Actions
    ( WalletAction(..)
    , WalletActionInterp(..)
    , withWalletWorker
    , interp
    , interpList
    , WalletWorkerState
    , isInitialState
    , hasPendingFork
    , isValidState
    ) where

import           Control.Concurrent (forkFinally)
import qualified Control.Concurrent.STM as STM
import qualified Control.Exception.Safe as Ex
import           Control.Monad.Morph (MFunctor(hoist))
import           Control.Lens (makeLenses, (%=), (+=), (-=), (.=))
import           Formatting (bprint, build, shown, (%))
import qualified Formatting.Buildable
import           Universum

import           Pos.Core.Chrono

{-------------------------------------------------------------------------------
  Workers and helpers for performing wallet state updates
-------------------------------------------------------------------------------}

-- | Actions that can be invoked on a wallet, via a worker.
--   Workers may not respond directly to each action; for example,
--   a `RollbackBlocks` followed by several `ApplyBlocks` may be
--   batched into a single operation on the actual wallet.
data WalletAction b
    = ApplyBlocks    (OldestFirst NE b)
    | RollbackBlocks (NewestFirst NE b)
    | LogMessage Text
    | Shutdown

-- | Interface abstraction for the wallet worker.
--   The caller provides these primitive wallet operations;
--   the worker uses these to invoke changes to the
--   underlying wallet.
data WalletActionInterp m b = WalletActionInterp
    { applyBlocks  :: OldestFirst NE b -> m ()
    , switchToFork :: Int -> OldestFirst [] b -> m ()
    , emit         :: Text -> m ()
    }

-- | Internal state of the wallet worker.
data WalletWorkerState b = WalletWorkerState
    { _pendingRollbacks    :: !Int
    , _pendingBlocks       :: !(NewestFirst [] b)
    , _lengthPendingBlocks :: !Int
    }
  deriving Eq

makeLenses ''WalletWorkerState

instance MFunctor WalletActionInterp where
  hoist nat i = WalletActionInterp
    { applyBlocks = fmap nat (applyBlocks i)
    , switchToFork = fmap (fmap nat) (switchToFork i)
    , emit = fmap nat (emit i) }

-- | `interp` is the main interpreter for converting a wallet action to a concrete
--   transition on the wallet worker's state, perhaps combined with some effects on
--   the concrete wallet.
interp :: Monad m => WalletActionInterp m b -> WalletAction b -> StateT (WalletWorkerState b) m ()
interp walletInterp action = do

    numPendingRollbacks <- use pendingRollbacks
    numPendingBlocks    <- use lengthPendingBlocks

    -- Respond to the incoming action
    case action of

      -- If we are not in the midst of a rollback, just apply the blocks.
      ApplyBlocks bs | numPendingRollbacks == 0 -> do
                         emit "applying some blocks (non-rollback)"
                         applyBlocks bs

      -- Otherwise, add the blocks to the pending list. If the resulting
      -- list of pending blocks is longer than the number of pending rollbacks,
      -- then perform a `switchToFork` operation on the wallet.
      ApplyBlocks bs -> do

        -- Add the blocks
        let bsList = toNewestFirst (OldestFirst (toList (getOldestFirst bs)))
        pendingBlocks %= prependNewestFirst bsList
        lengthPendingBlocks += length bs

        -- If we have seen more blocks than rollbacks, switch to the new fork.
        when (numPendingBlocks + length bs > numPendingRollbacks) $ do

          pb <- toOldestFirst <$> use pendingBlocks
          switchToFork numPendingRollbacks pb

          -- Reset state to "no fork in progress"
          pendingRollbacks    .= 0
          lengthPendingBlocks .= 0
          pendingBlocks       .= NewestFirst []

      -- If we are in the midst of a fork and have seen some new blocks,
      -- roll back some of those blocks. If there are more rollbacks requested
      -- than the number of new blocks, see the next case below.
      RollbackBlocks bs | length bs <= numPendingBlocks -> do
                            lengthPendingBlocks -= length bs
                            pendingBlocks %= NewestFirst . drop (length bs) . getNewestFirst

      -- If we are in the midst of a fork and are asked to rollback more than
      -- the number of new blocks seen so far, clear out the list of new
      -- blocks and add any excess to the number of pending rollback operations.
      RollbackBlocks bs -> do
        pendingRollbacks    += length bs - numPendingBlocks
        lengthPendingBlocks .= 0
        pendingBlocks       .= NewestFirst []

      LogMessage txt -> emit txt

      Shutdown -> error "walletWorker: unreacheable dead code, reached!"

  where
    WalletActionInterp{..} = hoist lift walletInterp
    prependNewestFirst bs = \nf -> NewestFirst (getNewestFirst bs <> getNewestFirst nf)

-- | Connect a wallet action interpreter to a source actions. This function
-- returns as soon as the given action returns 'Shutdown'.
walletWorker
  :: Ex.MonadMask m
  => WalletActionInterp m b
  -> m (WalletAction b)
  -> m ()
walletWorker wai getWA = Ex.bracket_
  (emit wai "Starting wallet worker.")
  (evalStateT
     (fix $ \next -> lift getWA >>= \case
        Shutdown -> pure ()
        wa -> interp wai wa >> next)
     initialWorkerState)
  (emit wai "Stoping wallet worker.")

-- | Connect a wallet action interpreter to a stream of actions.
interpList :: Monad m => WalletActionInterp m b -> [WalletAction b] -> m (WalletWorkerState b)
interpList ops actions = execStateT (forM_ actions $ interp ops) initialWorkerState

initialWorkerState :: WalletWorkerState b
initialWorkerState = WalletWorkerState
    { _pendingRollbacks    = 0
    , _pendingBlocks       = NewestFirst []
    , _lengthPendingBlocks = 0
    }


-- | Start a wallet worker in backround who will react to input provided via the
-- 'STM' function, in FIFO order.
--
-- After the given continuation returns (successfully or due to some exception),
-- the worker will continue processing any pending input before returning,
-- re-throwing the continuation's exception if any.
--
-- Usage of the obtained 'STM' action after the given continuation has returned
-- will fail with an exception.
withWalletWorker
  :: (MonadIO m, Ex.MonadMask m)
  => WalletActionInterp IO a
  -> ((WalletAction a -> STM ()) -> m b)
  -> m b
withWalletWorker wai k = do
  -- 'mDone' is full if the worker finished.
  mDone :: MVar (Either Ex.SomeException ()) <- liftIO newEmptyMVar
  -- 'tqWA' keeps items to be processed by the worker.
  tqWA :: STM.TQueue (WalletAction a) <- liftIO STM.newTQueueIO
  -- 'tvOpen' is 'True' as long as 'tqWA' can receive new input.
  tvOpen :: STM.TVar Bool <- liftIO (STM.newTVarIO True)
  -- 'getWA' returns the next action to be processed. This function blocks
  -- unless 'tvOpen' is 'False', in which case 'Shutdown' is returned.
  let getWA :: STM (WalletAction a)
      getWA = STM.tryReadTQueue tqWA >>= \case
         Just wa -> pure wa
         Nothing -> STM.readTVar tvOpen >>= \case
            False -> pure Shutdown
            True  -> STM.retry
  -- 'pushWA' adds an action to be executed by the worker, in FIFO order. It
  -- will throw 'BlockedIndefinitelyOnSTM' if used after `k` returns.
  let pushWA :: WalletAction a -> STM ()
      pushWA = \wa -> do STM.check =<< STM.readTVar tvOpen
                         STM.writeTQueue tqWA wa
  Ex.mask $ \restore -> do
     restore $ liftIO $ void $ forkFinally
        (walletWorker wai (STM.atomically getWA))
        (putMVar mDone)
     Ex.finally
        (restore (k pushWA))
        (liftIO $ do
            -- Prevent new input.
            STM.atomically (STM.writeTVar tvOpen False)
            -- Wait for the worker to finish.
            either Ex.throwM pure =<< takeMVar mDone)

-- | Check if this is the initial worker state.
isInitialState :: Eq b => WalletWorkerState b -> Bool
isInitialState = (== initialWorkerState)

-- | Check that the state invariants all hold.
isValidState :: WalletWorkerState b -> Bool
isValidState WalletWorkerState{..} =
    _pendingRollbacks >= 0 &&
    length (_pendingBlocks) == _lengthPendingBlocks &&
    _lengthPendingBlocks <= _pendingRollbacks

-- | Check if this state represents a pending fork.
hasPendingFork :: WalletWorkerState b -> Bool
hasPendingFork WalletWorkerState{..} = _pendingRollbacks /= 0

instance Show b => Buildable (WalletWorkerState b) where
    build WalletWorkerState{..} = bprint
      ( "WalletWorkerState "
      % "{ _pendingRollbacks:    " % shown
      % ", _pendingBlocks:       " % shown
      % ", _lengthPendingBlocks: " % shown
      % " }"
      )
      _pendingRollbacks
      _pendingBlocks
      _lengthPendingBlocks

instance Show b => Buildable (WalletAction b) where
    build wa = case wa of
      ApplyBlocks bs    -> bprint ("ApplyBlocks " % shown) bs
      RollbackBlocks bs -> bprint ("RollbackBlocks " % shown) bs
      LogMessage bs     -> bprint ("LogMessage " % shown) bs
      Shutdown          -> bprint "Shutdown"

instance Show b => Buildable [WalletAction b] where
    build was = case was of
      []     -> bprint "[]"
      (x:xs) -> bprint (build % ":" % build) x xs
