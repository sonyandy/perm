{- |
Copyright: Andy Sonnenburg (c) 2012
License: BSD-style (see the file LICENSE)
Maintainer: Andy Sonnenburg <andy22286@gmail.com>
Stability: experimental
Portability: non-portable
-}
module Control.Applicative.Perm
       ( Perm
       , runPerm
       , liftPerm
       , hoistPerm
       ) where

import Control.Monad.Perm.Base (Perm,
                                runPerm,
                                liftPerm,
                                hoistPerm)
