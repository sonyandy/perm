{-# LANGUAGE
    CPP
  , FlexibleInstances
  , GADTs
  , MultiParamTypeClasses
  , Rank2Types
  , UndecidableInstances #-}
{- |
Copyright: Andy Sonnenburg (c) 2012
License: BSD-style (see the file LICENSE)
Maintainer: Andy Sonnenburg <andy22286@gmail.com>
Stability: experimental
Portability: non-portable
-}
module Control.Monad.Perm.Internal
       ( Perm
       , runPerm
       , sum1
       , sum1M
       , liftPerm
       , hoistPerm
       ) where

import Control.Applicative
import Control.Monad
#if LANGUAGE_DefaultSignatures
import Control.Monad.Catch.Class (MonadThrow)
#else
import Control.Monad.Catch.Class (MonadThrow (throw))
#endif
import Control.Monad.IO.Class (MonadIO (liftIO))
#if MIN_VERSION_mtl(2, 1, 0)
import Control.Monad.Reader.Class (MonadReader (ask, local, reader))
import Control.Monad.State.Class (MonadState (get, put, state))
#else
import Control.Monad.Reader.Class (MonadReader (ask, local))
import Control.Monad.State.Class (MonadState (get, put))
#endif
import Control.Monad.Trans.Class (MonadTrans (lift))

import Data.Function (fix)

import Prelude (($), (.), const, flip, id, snd)

-- | The permutation applicative
data Perm m a
  = Branch (Branch m a)
  | Plus (PlusDict m) (Perm m a) (Perm m a)

data Branch m a where
  Ap :: Dict m -> Perm m (a -> b) -> m a -> Branch m b
  Bind :: Monad m => (a -> Perm m b) -> m a -> Branch m b
  Lift :: m a -> Branch m a

data Dict m where
  Applicative :: Applicative m => Dict m
  Monad :: Monad m => Dict m

data PlusDict m where
  Alternative :: Alternative m => PlusDict m
  MonadPlus :: MonadPlus m => PlusDict m
  Unit :: PlusDict m

-- | Unwrap a 'Perm', combining actions using the 'Alternative' for @f@.
sum1 :: Alternative m => Perm m a -> m a
sum1 m = runPerm m (<|>)

-- | Unwrap a 'Perm', combining actions using the 'MonadPlus' for @f@.
sum1M :: MonadPlus m => Perm m a -> m a
sum1M m = runPerm m mplus

runPerm :: Perm m b -> (forall a . m a -> m a -> m a) -> m b
runPerm (Branch m) plus = runBranch m plus
runPerm (Plus Alternative m n) plus = runPerm m plus <|> runPerm n plus
runPerm (Plus MonadPlus m n) plus = runPerm m plus `mplus` runPerm n plus
runPerm (Plus Unit m n) plus = runPerm m plus `plus` runPerm n plus

runBranch :: Branch m b -> (forall a . m a -> m a -> m a) -> m b
runBranch (Ap Applicative perm m) plus = m <**> runPerm perm plus
runBranch (Ap Monad perm m) plus = flip ($) `liftM` m `ap` runPerm perm plus
runBranch (Bind k m) plus = m >>= \ a -> runPerm (k a) plus
runBranch (Lift m) _ = m

-- | A version of 'lift' that can be used without a 'Monad' for @m@.
liftPerm :: m a -> Perm m a
liftPerm = Branch . Lift

{- |
Lift a monad homomorphism from @m@ to @n@ into a monad homomorphism from
@'Perm' m@ to @'Perm' n@.
-}
hoistPerm :: Monad n => (forall a . m a -> n a) -> Perm m b -> Perm n b
hoistPerm f (Branch m) = Branch (hoistBranch f m)
hoistPerm f (Plus _ m n) = Plus Unit (hoistPerm f m) (hoistPerm f n)

hoistBranch :: Monad n => (forall a . m a -> n a) -> Branch m b -> Branch n b
hoistBranch f (Ap _ perm m) = Ap Monad (hoistPerm f perm) (f m)
hoistBranch f (Bind k m) = Bind (hoistPerm f . k) (f m)
hoistBranch f (Lift m) = Lift (f m)

instance Functor m => Functor (Perm m) where
  fmap f (Branch m) = Branch (fmap f m)
  fmap f (Plus dict m n) = Plus dict (fmap f m) (fmap f n)

instance Functor m => Functor (Branch m) where
  fmap f (Ap dict perm m) = Ap dict (fmap (f .) perm) m
  fmap f (Bind k m) = Bind (fmap f . k) m
  fmap f (Lift m) = Lift (fmap f m)

instance Applicative m => Applicative (Perm m) where
  pure = liftPerm . pure
  f <*> a = mapB (`apB` a) f <> mapB (f `apP`) a

apB :: Applicative m => Branch m (a -> b) -> Perm m a -> Branch m b
Ap _ perm m `apB` a = Ap Applicative (flipA2 perm a) m
Bind k m `apB` a = Bind ((<*> a) . k) m
Lift f `apB` a = Ap Applicative (flip ($) <$> a) f

apP :: Applicative m => Perm m (a -> b) -> Branch m a -> Branch m b
f `apP` Ap _ perm m = Ap Applicative (f .@ perm) m
f `apP` Bind k m = Bind ((f <*>) . k) m
f `apP` Lift a = Ap Applicative f a

flipA2 :: Applicative f => f (a -> b -> c) -> f b -> f (a -> c)
flipA2 = liftA2 flip

(.@) :: Applicative f => f (b -> c) -> f (a -> b) -> f (a -> c)
(.@) = liftA2 (.)

instance Alternative m => Alternative (Perm m) where
  empty = liftPerm empty
  (<|>) = Plus Alternative

instance Monad m => Monad (Perm m) where
  return = lift . return
  m >>= k = mapB (`bindB` k) m <> mfix' (mapB (m `thenP`) . k)
  fail = lift . fail

bindB :: Monad m => Branch m a -> (a -> Perm m b) -> Branch m b
Ap _ perm m `bindB` k = Bind (\ a -> k . ($ a) =<< perm) m
Bind f m `bindB` g = Bind (g <=< f) m
Lift m `bindB` k = Bind k m

mfix' :: (a -> m b) -> m b
mfix' f = snd $ fix $ \ ~(a, _) -> (a, f a)

thenP :: Monad m => Perm m a -> Branch m b -> Branch m b
m `thenP` Ap _ perm n = Ap Monad (m >> perm) n
m `thenP` Bind k n = Bind ((m >>) . k) n
m `thenP` Lift n = Ap Monad (flip const `liftP` m) n

liftP :: Monad m => (a -> b) -> Perm m a -> Perm m b
liftP f (Branch m) = Branch (liftB f m)
liftP f (Plus dict m n) = Plus dict (liftP f m) (liftP f n)

liftB :: Monad m => (a -> b) -> Branch m a -> Branch m b
liftB f (Ap dict perm m) = Ap dict (liftP (f .) perm) m
liftB f (Bind k m) = Bind (liftP f . k) m
liftB f (Lift m) = Lift (liftM f m)

instance MonadPlus m => MonadPlus (Perm m) where
  mzero = lift mzero
  mplus = Plus MonadPlus

instance MonadTrans Perm where
  lift = Branch . Lift

instance MonadIO m => MonadIO (Perm m) where
  liftIO = lift . liftIO

instance MonadReader r m => MonadReader r (Perm m) where
  ask = lift ask
  local f = mapB (localBranch f)
#if MIN_VERSION_mtl(2, 1, 0)
  reader = lift . reader
#endif

localBranch :: MonadReader r m => (r -> r) -> Branch m a -> Branch m a
localBranch f (Ap dict perm m) = Ap dict (local f perm) (local f m)
localBranch f (Bind k m) = Bind (local f . k) (local f m)
localBranch f (Lift m) = Lift (local f m)

instance MonadState s m => MonadState s (Perm m) where
  get = lift get
  put = lift . put
#if MIN_VERSION_mtl(2, 1, 0)
  state = lift . state
#endif

#ifdef LANGUAGE_DefaultSignatures
instance MonadThrow e m => MonadThrow e (Perm m)
#else
instance MonadThrow e m => MonadThrow e (Perm m) where
  throw = lift . throw
#endif

infixr 6 <>
(<>) :: Perm m a -> Perm m a -> Perm m a
(<>) = Plus Unit

mapB :: (Branch m a -> Branch m b) -> Perm m a -> Perm m b
mapB f (Plus dict m n) = Plus dict (mapB f m) (mapB f n)
mapB f (Branch m) = Branch (f m)
