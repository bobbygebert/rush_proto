{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}

module Ast (Ast (..)) where

import Data.Text
import Rush.Expression
import Rush.Type

data Ast c
  = Constant (Text, c) (Expr c)
  | Fn (Text, c) [([Expr c], Expr c)]
  | Type (Text, c) [(Text, c, [Type])]
  deriving (Show, Eq, Foldable, Functor)
