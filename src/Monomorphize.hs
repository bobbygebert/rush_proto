{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecursiveDo #-}
{-# LANGUAGE TupleSections #-}

module Monomorphize where

import Control.Monad.Except
import Control.Monad.Reader hiding (local)
import qualified Control.Monad.Reader as Reader
import Control.Monad.State
import Control.Monad.Writer
import Data.Bifunctor
import Data.Function hiding (const)
import qualified Data.Function as Functor
import Data.Functor
import Data.List hiding (init, lookup)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text hiding (concatMap, filter, foldr, head, init, partition, reverse, tail, unlines, zip)
import qualified Data.Text.Internal.Fusion.Size as Map
import Debug.Trace
import qualified Eval as Rush
import qualified Expression as Rush
import IR
import Infer
import Span
import qualified Type as Rush
import Prelude hiding (const, init, lookup)

ir :: [Rush.Named Rush.Type] -> [IR.Named Type]
ir =
  (\a -> trace ("generated: \n" ++ unlines (show <$> a)) a)
    . generate
    . (\a -> trace ("built: \n" ++ unlines (show <$> a)) a)
    . solve
    . runBuild
    . (unpack <=< closeOver)
  where
    unpack = Functor.const $ gets $ reverse . definitions
    closeOver [] = return ()
    closeOver (c@(Rush.Named n e) : cs) = do
      ty <- closeOverConstant c
      withGlobal [(n, ty)] $ closeOver cs

type Build = InferT (State BuildState) Type (Definitions Type)

data BuildState = BuildState {definitions :: [IR.Named Type], names :: [Text], constraints :: [Constraint Type]}

instance TypeVarStream (State BuildState) Type where
  freshTypeVar span = do
    state <- get
    let n : ns = names state
    put $ state {names = ns}
    return $ TVar n

runBuild :: Build a -> (a, [Constraint Type])
runBuild =
  either (error . show) id
    . flip evalState (BuildState [] freshNames [])
    . flip runReaderT (Definitions (Context Map.empty) (Context Map.empty))
    . runExceptT
    . runWriterT

type Generate = InferT (State GenerateState) Type (Definitions Type)

data GenerateState = GenerateState
  { generated :: Map.Map (Text, Type) (IR.Constant Type),
    templates :: Context (IR.Constant Type),
    numbers :: [Text]
  }
  deriving (Show)

instance TypeVarStream (State GenerateState) Type where
  freshTypeVar span = do
    state <- get
    let n : ns = numbers state
    put $ state {numbers = ns}
    return $ TVar n

runGenerate :: Context Type -> Context (IR.Constant Type) -> Generate [IR.Named Type] -> [IR.Named Type]
runGenerate types templates =
  solve
    . either (error . show) id
    . flip evalState (GenerateState Map.empty templates (pack . show <$> [0 ..]))
    . flip runReaderT Definitions {local = Context Map.empty, global = types}
    . runExceptT
    . runWriterT
    . unpack
  where
    unpack as = do
      as' <- as
      gs <- gets $ Map.toList . generated
      let gs' = (\((name, ty), c) -> IR.Named name c) <$> gs
      return $ gs' ++ as'

generate :: [IR.Named Type] -> [IR.Named Type]
generate cs =
  runGenerate
    (Context types)
    (Context templates)
    (mapM generate' targets)
  where
    generate' (IR.Named name c) =
      IR.Named name <$> case c of
        IR.CNum {} -> pure c
        IR.CData {} -> pure c
        IR.CFn tc (x, tx) b -> IR.CFn tc (x, tx) <$> monomorphize (Set.fromList [name, x]) b
        IR.CType n s cs -> pure $ IR.CType n s cs
    noLocals = Set.empty
    types = Map.fromList $ (\(IR.Named n c) -> (n, typeOf $ unConst c)) <$> cs
    (templates, targets) =
      first
        (Map.fromList . fmap (\(IR.Named n c) -> (n, c)))
        (templatesAndTargets cs)
    templatesAndTargets =
      partition
        ( (/= 0) . Set.size
            . foldr (Set.union . freeTypeVars) Set.empty
            . (\(IR.Named _ c) -> unConst c)
        )

monomorphize :: Set.Set Text -> Expr Type -> Generate (Expr Type)
monomorphize locals e = case e of
  Num {} -> pure e
  Unit -> pure e
  Tup xs -> Tup <$> mapM (monomorphize locals) xs
  List ty xs -> List ty <$> mapM (monomorphize locals) xs
  Cons h t -> Cons <$> monomorphize locals h <*> monomorphize locals t
  Var v ty -> extract v ty locals e
  Add a b -> monomorphizeBinOp locals Add a b
  Sub a b -> monomorphizeBinOp locals Sub a b
  Mul a b -> monomorphizeBinOp locals Mul a b
  Div a b -> monomorphizeBinOp locals Div a b
  Mod a b -> monomorphizeBinOp locals Mod a b
  Match xs as -> Match <$> mapM (monomorphize locals) xs <*> mapM match as
    where
      match (ps, b) =
        let bs = foldr (Set.union . bindings) Set.empty ps
         in (ps,) <$> monomorphize (locals `Set.union` bs) b
  Fn tc (x, tx) b -> Fn tc (x, tx) <$> monomorphize (Set.insert x locals) b
  Closure name cs f -> Closure name cs <$> extract name (typeOf f) locals f
  App ty f x -> App ty <$> monomorphize locals f <*> monomorphize locals x
  Data c ty xs -> Data c ty <$> mapM (monomorphize locals) xs
  EType n -> pure $ EType n

monomorphizeBinOp locals op a b = op <$> monomorphize locals a <*> monomorphize locals b

-- TODO: Figure out why union closure type isn't being inferred.
extract :: Text -> Type -> Set.Set Text -> Expr Type -> Generate (Expr Type)
extract name ty locals defaultExpr
  | name `Set.member` locals = pure defaultExpr
  | otherwise = do
    generic <- mapM instantiate =<< template name
    case generic of
      Nothing -> pure defaultExpr
      Just c -> do
        state <- get
        c' <- monomorphize Set.empty (unConst c)
        let ty' = typeOf $ unConst c
        let mangled = "_" <> pack (show ty') <> "_" <> name
        ensure $ ty' :~ ty
        put
          state
            { generated = Map.insert (mangled, ty) c (generated state),
              numbers = tail (numbers state)
            }
        pure $ Var mangled ty

solve :: (Unify t, Refine a t, Refine t t, Show t, Eq t, Show a) => (a, [Constraint t]) -> a
solve (items, constraints) =
  (`apply` items) $
    either (error . show) id $
      solveConstraints constraints

template :: Text -> Generate (Maybe (IR.Constant Type))
template v = do
  Context templates <- gets templates
  return $ Map.lookup v templates

-- TODO: merge spans?
init :: Rush.Type -> Build Type
init = \case
  Rush.TInt s -> pure TInt
  Rush.TTup tys -> TTup <$> mapM init tys
  Rush.TList tx -> TList <$> init tx
  Rush.TVar v s -> pure $ TVar v
  Rush.TData c s ts ->
    TData c . fmap (second $ Map.fromList . zip fnames) <$> ts'
    where
      ts' = mapM (\(c', _, ts') -> (c',) <$> mapM init ts') ts
      fnames = (pack . show <$> [0 ..])
  Rush.TRef n s -> pure $ TRef n
  a Rush.:-> b -> do
    ta <- init a
    tb <- init b
    tc <- freshVar
    TFn tc <$> init a <*> init b
  Rush.Kind s -> pure Kind

closeOverConstant :: Rush.Named Rush.Type -> Build Type
closeOverConstant (Rush.Named name c) = ty'
  where
    ty' = (typeOf <$>) . define name =<< c'
    c' = case c of
      Rush.CNum n ty -> IR.CNum n <$> init ty
      Rush.CData c ty xs -> IR.CData c <$> init ty <*> mapM ((const <$>) . closeOverExpr c . Rush.unConst) xs
      Rush.CLambda (x, tx) b -> do
        tf <- TFn TUnit <$> init tx <*> init (Rush.typeOf b)
        let tx = tf & (\case TFn _ tx' _ -> tx'; _ -> error "unreachable")
        b' <- with [(name, tf), (x, tx)] $ closeOverExpr name b
        return $ IR.CFn TUnit (x, tx) b'
      Rush.CType (n, kind) cs ->
        CType n
          <$> init kind
          <*> forM cs (\(c, t, ts) -> (c,) <$> mapM init ts)

closeOverExpr :: Text -> Rush.Expr Rush.Type -> Build (Expr Type)
closeOverExpr parent e = case e of
  Rush.Num n ty -> Num n <$> init ty
  Rush.Var x ty -> Var x <$> lookup x
  Rush.Add a b -> Add <$> closeOverExpr parent a <*> closeOverExpr parent b
  Rush.Sub a b -> Sub <$> closeOverExpr parent a <*> closeOverExpr parent b
  Rush.Mul a b -> Mul <$> closeOverExpr parent a <*> closeOverExpr parent b
  Rush.Div a b -> Div <$> closeOverExpr parent a <*> closeOverExpr parent b
  Rush.Mod a b -> Mod <$> closeOverExpr parent a <*> closeOverExpr parent b
  Rush.Tup xs -> Tup <$> mapM (closeOverExpr parent) xs
  Rush.List ty xs -> do
    xs' <- mapM (closeOverExpr parent) xs
    case ty of
      _ Rush.:-> _ -> do
        cname <- (<> ("_" <> parent)) <$> freshName
        let cs = closureTypes xs'
        let ty' = TData cname cs
        pure $ List ty' (toData ty' xs')
      _ -> do
        ty' <- init ty
        mapM_ (ensure . (ty' :~) . typeOf) xs'
        pure $ List ty' xs'
    where
      closureTypes xs' = discriminatedType <$> xs'
      discriminatedType x = case typeOf x of
        tc@(TClosure f _ _) -> (f, Map.singleton "0" tc)
        _ -> error "unreachable"
      discriminatedVal tc x = case typeOf x of
        TClosure f _ _ -> Data f tc [x]
        _ -> error "unreachable"
      toData tc xs' = discriminatedVal tc <$> xs'
  Rush.Cons h t -> Cons <$> closeOverExpr parent h <*> closeOverExpr parent t
  Rush.Match xs as -> do
    xs' <- mapM (closeOverExpr parent) xs
    as' <- mapM match as
    let tas = fmap typeOf . fst <$> as'
    let txs = typeOf <$> xs'
    mapM_ (mapM_ (ensure . uncurry (:~))) (zip txs <$> tas)
    return $ Match xs' as'
    where
      match (ps, b) = do
        ps' <- mapM closeOverPattern ps
        b' <- with (typedBindings =<< ps') (closeOverExpr parent b)
        return (ps', b')
      closeOverPattern = \case
        Rush.Var b ty -> Var b <$> init ty
        Rush.Num n ty -> Num n <$> init ty
        Rush.Tup xs -> Tup <$> mapM closeOverPattern xs
        Rush.List ty xs -> do
          xs' <- mapM closeOverPattern xs
          ty' <- init ty
          mapM_ (ensure . (ty' :~) . typeOf) xs'
          pure $ List ty' xs'
        Rush.Cons h t -> Cons <$> closeOverPattern h <*> closeOverPattern t
        Rush.Data n ty xs -> Data n <$> init ty <*> mapM closeOverPattern xs
        _ -> error "unreachable"
  Rush.Lambda (x, tx) b -> mdo
    let fname = "_cls_" <> parent
    let cname = "_storage_" <> fname
    tx' <- init tx
    cs <- captures (Set.singleton x) b
    tc <-
      return $
        if Map.size cs == 0
          then TUnit
          else TData cname [(fname, Map.map typeOf cs)]
    f <- define fname $ IR.CFn tc (x, tx') b'
    b' <- with ((x, tx') : Map.toList (Map.map typeOf cs)) $ closeOverExpr fname b
    tp <- TFn <$> freshVar <*> freshVar <*> pure (TFn tc tx' (typeOf b'))
    lookup parent >>= ensure . (:~ tp)
    ensure $ typeOf f :~ TFn tc tx' (typeOf b')
    return $ case tc of
      TUnit -> f
      _ -> Closure fname cs f
  Rush.App ty f x -> do
    f' <- closeOverExpr parent f
    x' <- closeOverExpr parent x
    let (tx', ty') = case typeOf f' of
          TClosure _ _ (TFn _ tx tb) -> (tx, tb)
          TFn _ tx tb -> (tx, tb)
          ty' -> error $ show (ty, ty')
    ensure $ typeOf x' :~ tx'
    ensure . (ty' :~) =<< init ty
    return $ App ty' f' x'
  Rush.Data c ty xs -> Data c <$> init ty <*> mapM (closeOverExpr parent) xs

captures :: Set.Set Text -> Rush.Expr Rush.Type -> Build (Map.Map Text (Expr Type))
captures bound =
  let unionMany = foldr Map.union Map.empty
   in \case
        Rush.Num {} -> return Map.empty
        -- XXX: This is wrong.
        Rush.Var x (_ Rush.:-> _) -> return Map.empty
        Rush.Var x tx -> do
          if x `Set.member` bound
            then return Map.empty
            else Map.singleton x . Var x <$> init tx
        Rush.Add a b -> Map.union <$> captures bound a <*> captures bound b
        Rush.Sub a b -> Map.union <$> captures bound a <*> captures bound b
        Rush.Mul a b -> Map.union <$> captures bound a <*> captures bound b
        Rush.Div a b -> Map.union <$> captures bound a <*> captures bound b
        Rush.Mod a b -> Map.union <$> captures bound a <*> captures bound b
        Rush.Lambda (x, tx) b ->
          Map.filterWithKey (curry $ (/= x) . fst) <$> captures (Set.singleton x) b
        Rush.App _ f x -> Map.union <$> captures bound f <*> captures bound x
        Rush.Tup xs -> unionMany <$> mapM (captures bound) xs
        Rush.List _ xs -> unionMany <$> mapM (captures bound) xs
        Rush.Cons h t -> Map.union <$> captures bound h <*> captures bound t
        Rush.Data _ _ xs -> unionMany <$> mapM (captures bound) xs
        Rush.Match xs ps -> Map.union <$> bxs <*> bps
          where
            bxs = unionMany <$> mapM (captures bound) xs
            bps = unionMany <$> mapM (\(ps, es) -> excludeBindings ps <$> captures bound es) ps
            excludeBindings ps =
              Map.filterWithKey
                (curry $ not . (`Set.member` foldr (Set.union . bindings) Set.empty ps) . fst)
            bindings = Set.fromList . (fst <$>) . Rush.bindings

bindings :: Expr b -> Set.Set Text
bindings = Set.fromList . (fst <$>) . typedBindings

typedBindings :: Expr b -> [(Text, b)]
typedBindings = \case
  Var x tx -> [(x, tx)]
  Num _ _ -> []
  Tup ps -> typedBindings =<< ps
  List _ ps -> typedBindings =<< ps
  Cons h t -> typedBindings h ++ typedBindings t
  Data _ _ ps -> typedBindings =<< ps
  _ -> error "unreachable"

freshName :: Build Text
freshName = do
  state <- get
  put state {names = tail $ names state}
  return $ head $ names state

freshVar :: Build Type
freshVar = TVar <$> freshName

define :: Text -> IR.Constant Type -> Build (Expr Type)
define name val = do
  state <- get
  put state {definitions = IR.Named name val : definitions state}
  return $ Var name (typeOf $ unConst val)

freshNames :: [Text]
freshNames = pack . ('#' :) <$> ([1 ..] >>= flip replicateM ['a' .. 'z'])
