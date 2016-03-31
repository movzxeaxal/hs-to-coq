{-# LANGUAGE TupleSections, LambdaCase, RecordWildCards, PatternSynonyms,
             OverloadedLists, OverloadedStrings,
             ConstraintKinds, FlexibleContexts #-}

module HsToCoq.ConvertHaskell (
  -- * Conversion
  -- ** Types
  ConversionMonad, Renaming, HsNamespace(..), evalConversion,
  -- *** Variable renaming
  rename, var, freeVar,
  -- *** Utility
  tryEscapeReservedName, escapeReservedNames,
  -- ** Local bindings
  convertLocalBinds,
  -- ** Declarations
  convertTyClDecls, convertValDecls,
  convertTyClDecl, convertDataDecl, convertSynDecl,
  -- ** General bindings
  convertTypedBindings, convertTypedBinding,
  ConvertedDefinition(..), uncurryConvertedDefinition,
  -- ** Terms
  convertType, convertLType,
  convertExpr, convertLExpr,
  convertPat,  convertLPat,
  convertLHsTyVarBndrs,
  -- ** Case/match bodies
  convertMatchGroup, convertMatch,
  convertGRHSs, convertGRHS,
  ConvertedGuard(..), convertGuards, convertGuard,
  -- ** Functions
  convertFunction,
  -- ** Literals
  convertInteger, convertString, convertFastString,
  -- ** Declaration groups
  DeclarationGroup(..), addDeclaration,
  groupConvDecls, groupTyClDecls, convertDeclarationGroup,
  -- ** Backing types
  SynBody(..), ConvertedDeclaration(..),
  -- ** Internal
  convertDataDefn, convertConDecl,
  -- * Coq construction
  pattern Var, pattern App1, pattern App2, appList,
  pattern CoqVarPat
  ) where

import Prelude hiding (Num)

import Data.Semigroup ((<>))
import Data.Monoid hiding ((<>))
import Data.Bifunctor
import Data.Foldable
import Data.Traversable
import Data.Maybe
import Data.Either
import Data.Char
import Data.List.NonEmpty (NonEmpty(..), (<|), nonEmpty)
import qualified Data.List.NonEmpty as NEL
import qualified Data.Text as T

import Control.Arrow ((&&&))
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.State

import           Data.Map.Strict (Map)
import qualified Data.Set        as S
import qualified Data.Map.Strict as M

import GHC hiding (Name)
import Bag
import HsToCoq.Util.GHC.FastString
import Outputable (OutputableBndr)
import Panic
import HsToCoq.Util.GHC.Exception

import HsToCoq.Util.Functor
import HsToCoq.Util.List
import HsToCoq.Util.Containers
import HsToCoq.Util.Patterns
import HsToCoq.Util.GHC
import HsToCoq.Coq.Gallina
import qualified HsToCoq.Coq.Gallina as Coq
import HsToCoq.Coq.FreeVars

import Data.Generics

data HsNamespace = ExprNS | TypeNS
                 deriving (Eq, Ord, Show, Read, Enum, Bounded)

type Renaming = Map HsNamespace Ident

type ConversionMonad m = (GhcMonad m, MonadState (Map Ident Renaming) m)

evalConversion :: GhcMonad m => StateT (Map Ident Renaming) m a -> m a
evalConversion = flip evalStateT $ build
                   [ typ "Int" ~> "Z"

                   , typ "Bool"  ~> "bool"
                   , val "True"  ~> "true"
                   , val "False" ~> "false"

                   , typ "String" ~> "string"

                   , typ "Maybe"   ~> "option"
                   , val "Just"    ~> "Some"
                   , val "Nothing" ~> "None" ]
  where
    val hs = (hs,) . M.singleton ExprNS
    typ hs = (hs,) . M.singleton TypeNS
    (~>)   = ($)

    build = M.fromListWith M.union

rename :: ConversionMonad m => HsNamespace -> Ident -> Ident -> m ()
rename ns x x' = modify' . flip M.alter x $ Just . \case
                   Just m  -> M.insert    ns x' m
                   Nothing -> M.singleton ns x'

tryEscapeReservedName :: Ident -> Ident -> Maybe Ident
tryEscapeReservedName reserved name = do
  suffix <- T.stripPrefix reserved name
  guard $ T.all (== '_') suffix
  pure $ name <> "_"

escapeReservedNames :: Ident -> Ident
escapeReservedNames x = fromMaybe x . getFirst
                      . foldMap (First . flip tryEscapeReservedName x)
                      $ T.words "Set Type Prop fun fix forall"

freeVar :: (GhcMonad m, OutputableBndr name) => name -> m Ident
freeVar = fmap escapeReservedNames . ghcPpr
                                        
var :: (ConversionMonad m, OutputableBndr name) => HsNamespace -> name -> m Ident
var ns x = do
  x' <- ghcPpr x -- TODO Check module part?
  gets $ fromMaybe (escapeReservedNames x') . (M.lookup ns <=< M.lookup x')

-- Module-local
conv_unsupported :: MonadIO m => String -> m a
conv_unsupported what = liftIO . throwGhcExceptionIO . ProgramError $ what ++ " unsupported"

pattern Var  x       = Qualid (Bare x)
pattern App1 f x     = App f (PosArg x :| Nil)
pattern App2 f x1 x2 = App f (PosArg x1 :| PosArg x2 : Nil)

appList :: Term -> [Arg] -> Term
appList f xs = case nonEmpty xs of
                 Nothing  -> f
                 Just xs' -> App f xs'

pattern CoqVarPat x = QualidPat (Bare x)

-- Module-local
is_noSyntaxExpr :: HsExpr id -> Bool
is_noSyntaxExpr (HsLit (HsString "" str)) = str == fsLit "noSyntaxExpr"
is_noSyntaxExpr _                         = False

convertInteger :: MonadIO f => String -> Integer -> f Num
convertInteger what int | int >= 0  = pure $ fromInteger int
                        | otherwise = conv_unsupported $ "negative " ++ what

convertFastString :: FastString -> Term
convertFastString = String . T.pack . unpackFS

convertString :: String -> Term
convertString = String . T.pack

convertExpr :: ConversionMonad m => HsExpr RdrName -> m Term
convertExpr (HsVar x) =
  Var <$> var ExprNS x

convertExpr (HsIPVar _) =
  conv_unsupported "implicit parameters"

-- FIXME actually handle overloading
convertExpr (HsOverLit OverLit{..}) =
  case ol_val of
    HsIntegral   _src int -> Num <$> convertInteger "integer literals" int
    HsFractional _        -> conv_unsupported "fractional literals"
    HsIsString   _src str -> pure . String $ fsToText str

convertExpr (HsLit lit) =
  case lit of
    HsChar       _ _       -> conv_unsupported "`Char' literals"
    HsCharPrim   _ _       -> conv_unsupported "`Char#' literals"
    HsString     _ fs      -> pure . String $ fsToText fs
    HsStringPrim _ _       -> conv_unsupported "`Addr#' literals"
    HsInt        _ _       -> conv_unsupported "`Int' literals"
    HsIntPrim    _ _       -> conv_unsupported "`Int#' literals"
    HsWordPrim   _ _       -> conv_unsupported "`Word#' literals"
    HsInt64Prim  _ _       -> conv_unsupported "`Int64#' literals"
    HsWord64Prim _ _       -> conv_unsupported "`Word64#' literals"
    HsInteger    _ int _ty -> Num <$> convertInteger "`Integer' literals" int
    HsRat        _ _       -> conv_unsupported "`Rational' literals"
    HsFloatPrim  _         -> conv_unsupported "`Float#' literals"
    HsDoublePrim _         -> conv_unsupported "`Double#' literals"

convertExpr (HsLam mg) =
  uncurry Fun <$> convertFunction mg

convertExpr (HsLamCase PlaceHolder mg) =
  uncurry Fun <$> convertFunction mg

convertExpr (HsApp e1 e2) =
  App1 <$> convertLExpr e1 <*> convertLExpr e2

convertExpr (OpApp _ _ _ _) =
  conv_unsupported "binary operators"

convertExpr (NegApp _ _) =
  conv_unsupported "negation"

convertExpr (HsPar e) =
  Parens <$> convertLExpr e

convertExpr (SectionL _ _) =
  conv_unsupported "(left) operator sections"

convertExpr (SectionR _ _) =
  conv_unsupported "(right) operator sections"

convertExpr (ExplicitTuple _ _) =
  conv_unsupported "tuples"

convertExpr (HsCase e mg) =
  Coq.Match <$> (fmap pure $ MatchItem <$> convertLExpr e <*> pure Nothing <*> pure Nothing)
            <*> pure Nothing
            <*> convertMatchGroup mg

convertExpr (HsIf overloaded c t f) =
  if maybe True is_noSyntaxExpr overloaded
  then If <$> convertLExpr c <*> pure Nothing <*> convertLExpr t <*> convertLExpr f
  else conv_unsupported "overloaded if-then-else"

convertExpr (HsMultiIf _ _) =
  conv_unsupported "multi-way if"

convertExpr (HsLet binds body) =
  convertLocalBinds binds =<< convertLExpr body

convertExpr (HsDo _ _ _) =
  conv_unsupported "`do' expressions"

convertExpr (ExplicitList _ _ _) =
  conv_unsupported "explicit lists"

convertExpr (ExplicitPArr _ _) =
  conv_unsupported "explicit parallel arrays"

convertExpr (RecordCon _ _ _) =
  conv_unsupported "record constructors"

convertExpr (RecordUpd _ _ _ _ _) =
  conv_unsupported "record updates"

convertExpr (ExprWithTySig e ty PlaceHolder) =
  HasType <$> convertLExpr e <*> convertLType ty

convertExpr (ExprWithTySigOut _ _) =
  conv_unsupported "`ExprWithTySigOut' constructor"

convertExpr (ArithSeq _ _ _) =
  conv_unsupported "arithmetic sequences"

convertExpr (PArrSeq _ _) =
  conv_unsupported "parallel array arithmetic sequences"

convertExpr (HsSCC _ _ e) =
  convertLExpr e

convertExpr (HsCoreAnn _ _ e) =
  convertLExpr e

convertExpr (HsBracket _) =
  conv_unsupported "Template Haskell brackets"

convertExpr (HsRnBracketOut _ _) =
  conv_unsupported "`HsRnBracketOut' constructor"

convertExpr (HsTcBracketOut _ _) =
  conv_unsupported "`HsTcBracketOut' constructor"

convertExpr (HsSpliceE _ _) =
  conv_unsupported "Template Haskell expression splices"

convertExpr (HsQuasiQuoteE _) =
  conv_unsupported "expression quasiquoters"

convertExpr (HsProc _ _) =
  conv_unsupported "`proc' expressions"

convertExpr (HsStatic _) =
  conv_unsupported "static pointers"

convertExpr (HsArrApp _ _ _ _ _) =
  conv_unsupported "arrow application command"

convertExpr (HsArrForm _ _ _) =
  conv_unsupported "arrow command formation"

convertExpr (HsTick _ e) =
  convertLExpr e

convertExpr (HsBinTick _ _ e) =
  convertLExpr e

convertExpr (HsTickPragma _ _ e) =
  convertLExpr e

convertExpr EWildPat =
  conv_unsupported "wildcard pattern in expression"

convertExpr (EAsPat _ _) =
  conv_unsupported "as-pattern in expression"

convertExpr (EViewPat _ _) =
  conv_unsupported "view-pattern in expression"

convertExpr (ELazyPat _) =
  conv_unsupported "lazy pattern in expression"

convertExpr (HsType ty) =
  convertLType ty

convertExpr (HsWrap _ _) =
  conv_unsupported "`HsWrap' constructor"

convertExpr (HsUnboundVar x) =
  Var <$> freeVar x

convertLExpr :: ConversionMonad m => LHsExpr RdrName -> m Term
convertLExpr = convertExpr . unLoc

convertPat :: ConversionMonad m => Pat RdrName -> m Pattern
convertPat (WildPat PlaceHolder) =
  pure UnderscorePat

convertPat (GHC.VarPat x) =
  CoqVarPat <$> freeVar x

convertPat (LazyPat p) =
  convertLPat p

convertPat (GHC.AsPat x p) =
  Coq.AsPat <$> convertLPat p <*> freeVar (unLoc x)

convertPat (ParPat p) =
  convertLPat p

convertPat (BangPat p) =
  convertLPat p

convertPat (ListPat _ _ _) =
  conv_unsupported "list patterns"

convertPat (TuplePat _ _ _) =
  conv_unsupported "tuple patterns"

convertPat (PArrPat _ _) =
  conv_unsupported "parallel array patterns"

convertPat (ConPatIn con conVariety) =
  case conVariety of
    PrefixCon args' -> do
      conVar <- Bare <$> var ExprNS (unLoc con)
      case nonEmpty args' of
        Just args -> ArgsPat conVar <$> traverse convertLPat args
        Nothing   -> pure $ QualidPat conVar
    RecCon    _    ->
      conv_unsupported "record constructor patterns"
    InfixCon  _ _  ->
      conv_unsupported "infix constructor patterns"

convertPat (ConPatOut{}) =
  conv_unsupported "[internal?] `ConPatOut' constructor"

convertPat (ViewPat _ _ _) =
  conv_unsupported "view patterns"

convertPat (SplicePat _) =
  conv_unsupported "pattern splices"

convertPat (QuasiQuotePat _) =
  conv_unsupported "pattern quasiquoters"

convertPat (LitPat lit) =
  case lit of
    HsChar       _ _       -> conv_unsupported "`Char' literal patterns"
    HsCharPrim   _ _       -> conv_unsupported "`Char#' literal patterns"
    HsString     _ fs      -> pure . StringPat $ fsToText fs
    HsStringPrim _ _       -> conv_unsupported "`Addr#' literal patterns"
    HsInt        _ _       -> conv_unsupported "`Int' literal patterns"
    HsIntPrim    _ _       -> conv_unsupported "`Int#' literal patterns"
    HsWordPrim   _ _       -> conv_unsupported "`Word#' literal patterns"
    HsInt64Prim  _ _       -> conv_unsupported "`Int64#' literal patterns"
    HsWord64Prim _ _       -> conv_unsupported "`Word64#' literal patterns"
    HsInteger    _ int _ty -> NumPat <$> convertInteger "`Integer' literal patterns" int
    HsRat        _ _       -> conv_unsupported "`Rational' literal patterns"
    HsFloatPrim  _         -> conv_unsupported "`Float#' literal patterns"
    HsDoublePrim _         -> conv_unsupported "`Double#' literal patterns"

convertPat (NPat (L _ OverLit{..}) _negate _eq) = -- And strings
  case ol_val of
    HsIntegral   _src int -> NumPat <$> convertInteger "integer literal patterns" int
    HsFractional _        -> conv_unsupported "fractional literal patterns"
    HsIsString   _src str -> pure . StringPat $ fsToText str

convertPat (NPlusKPat _ _ _ _) =
  conv_unsupported "n+k-patterns"

convertPat (SigPatIn _ _) =
  conv_unsupported "`SigPatIn' constructor"

convertPat (SigPatOut _ _) =
  conv_unsupported "`SigPatOut' constructor"

convertPat (CoPat _ _ _) =
  conv_unsupported "coercion patterns"

convertLPat :: ConversionMonad m => LPat RdrName -> m Pattern
convertLPat = convertPat . unLoc

data ConvertedDefinition = ConvertedDefinition { convDefName :: !Ident
                                               , convDefArgs :: ![Binder]
                                               , convDefType :: !(Maybe Term)
                                               , convDefBody :: !Term }
                         deriving (Eq, Ord, Read, Show)

uncurryConvertedDefinition :: (Ident -> [Binder] -> Maybe Term -> Term -> a) -> (ConvertedDefinition -> a)
uncurryConvertedDefinition f ConvertedDefinition{..} = f convDefName convDefArgs convDefType convDefBody

convertLocalBinds :: ConversionMonad m => HsLocalBinds RdrName -> Term -> m Term
convertLocalBinds (HsValBinds (ValBindsIn binds sigs)) body =
  foldr (uncurryConvertedDefinition Let) body
    <$> convertTypedBindings (map unLoc . bagToList $ binds) (map unLoc sigs) pure Nothing
convertLocalBinds (HsValBinds (ValBindsOut _ _)) _ =
  conv_unsupported "post-renaming `ValBindsOut' bindings"
convertLocalBinds (HsIPBinds _) _ =
  conv_unsupported "local implicit parameter bindings"
convertLocalBinds EmptyLocalBinds body =
  pure body

-- TODO mutual recursion :-(
convertTypedBindings :: ConversionMonad m
                     => [HsBind RdrName] -> [Sig RdrName]
                     -> (ConvertedDefinition -> m a)
                     -> Maybe (HsBind RdrName -> GhcException -> m a)
                     -> m [a]
convertTypedBindings defns allSigs build mhandler =
  let sigs = M.fromList $ [(name,ty) | TypeSig lnames (L _ ty) PlaceHolder <- allSigs
                                     , L _ name <- lnames ]
      
      getType FunBind{..} = M.lookup (unLoc fun_id) sigs
      getType _           = Nothing

      processed defn = maybe id (ghandle . ($ defn)) mhandler . (build =<<)
      
  in traverse (processed <*> (convertTypedBinding =<< getType)) defns

convertTypedBinding :: ConversionMonad m => Maybe (HsType RdrName) -> HsBind RdrName -> m ConvertedDefinition
convertTypedBinding _hsTy PatBind{}    = conv_unsupported "pattern bindings"
convertTypedBinding _hsTy VarBind{}    = conv_unsupported "[internal] `VarBind'"
convertTypedBinding _hsTy AbsBinds{}   = conv_unsupported "[internal?] `AbsBinds'"
convertTypedBinding _hsTy PatSynBind{} = conv_unsupported "pattern synonym bindings"
convertTypedBinding  hsTy FunBind{..}  = do
  name <- freeVar $ unLoc fun_id
  
  (tvs, coqTy) <-
    -- The @forall@ed arguments need to be brought into scope
    let peelForall (Forall tvs body) = first (NEL.toList tvs ++) $ peelForall body
        peelForall ty                = ([], ty)
    in maybe ([], Nothing) (second Just . peelForall) <$> traverse convertType hsTy
  
  defn <-
    if all (null . m_pats . unLoc) $ mg_alts fun_matches
    then case mg_alts fun_matches of
           [L _ (GHC.Match _ [] mty grhss)] ->
             maybe (pure id) (fmap (flip HasType) . convertLType) mty <*> convertGRHSs grhss
           _ ->
             conv_unsupported "malformed multi-match variable definitions"
    else do
      (argBinders, match) <- convertFunction fun_matches
      pure $ if name `S.member` getFreeVars match
             then Fix . FixOne $ FixBody name argBinders Nothing Nothing match
             else Fun argBinders match
             
  pure $ ConvertedDefinition name tvs coqTy defn

convertMatchGroup :: ConversionMonad m => MatchGroup RdrName (LHsExpr RdrName) -> m [Equation]
convertMatchGroup (MG alts _ _ _) = traverse (convertMatch . unLoc) alts

convertMatch :: ConversionMonad m => Match RdrName (LHsExpr RdrName) -> m Equation
convertMatch GHC.Match{..} = do
  pats <- maybe (conv_unsupported "no-pattern case arms") pure . nonEmpty
            =<< traverse convertLPat m_pats
  oty  <- traverse convertLType m_type
  rhs  <- convertGRHSs m_grhss
  pure . Equation [MultPattern pats] $ maybe id (flip HasType) oty rhs

convertFunction :: ConversionMonad m => MatchGroup RdrName (LHsExpr RdrName) -> m (Binders, Term)
convertFunction mg = do
  eqns <- convertMatchGroup mg
  let argCount   = case eqns of
                     Equation (MultPattern args :| _) _ : _ -> length args
                     _                                      -> 0
      args       = NEL.fromList ["__arg_" <> T.pack (show n) <> "__" | n <- [1..argCount]]
      argBinders = (Inferred Coq.Explicit . Ident) <$> args
      match      = Coq.Match (args <&> \arg -> MatchItem (Var arg) Nothing Nothing) Nothing eqns
  pure (argBinders, match)

convertGRHSs :: ConversionMonad m => GRHSs RdrName (LHsExpr RdrName) -> m Term
convertGRHSs GRHSs{..} =
  convertLocalBinds grhssLocalBinds
    =<< convertGuards =<< traverse (convertGRHS . unLoc) grhssGRHSs

data ConvertedGuard = NoGuard
                    | BoolGuard Term
                    deriving (Eq, Ord, Show, Read)

convertGuards :: ConversionMonad m => [(ConvertedGuard,Term)] -> m Term
convertGuards []            = conv_unsupported "empty lists of guarded statements"
convertGuards [(NoGuard,t)] = pure t
convertGuards gts           = case traverse (\case (BoolGuard g,t) -> Just (g,t) ; _ -> Nothing) gts of
  Just bts -> case assertUnsnoc bts of
                (bts', (Var "true", lastTerm)) ->
                  pure $ foldr (\(c,t) f -> If c Nothing t f) lastTerm bts'
                _ ->
                  conv_unsupported "possibly-incomplete guards"
  Nothing  -> conv_unsupported "malformed guards"

convertGuard :: ConversionMonad m => [GuardLStmt RdrName] -> m ConvertedGuard
convertGuard [] = pure NoGuard
convertGuard gs = BoolGuard . foldr1 (App2 $ Var "andb") <$> traverse toCond gs where
  toCond (L _ (BodyStmt e _bind _guard _PlaceHolder)) =
    is_True_expr e >>= \case
      True  -> pure $ Var "true"
      False -> convertLExpr e
  toCond (L _ (LetStmt _)) =
    conv_unsupported "`let' statements in guards"
  toCond (L _ (BindStmt _ _ _ _)) =
    conv_unsupported "pattern guards"
  toCond _ =
    conv_unsupported "impossibly fancy guards"

convertGRHS :: ConversionMonad m => GRHS RdrName (LHsExpr RdrName) -> m (ConvertedGuard,Term)
convertGRHS (GRHS gs rhs) = (,) <$> convertGuard gs <*> convertLExpr rhs

-- Module-local
-- Based on `DsGRHSs.isTrueLHsExpr'
is_True_expr :: GhcMonad m => LHsExpr RdrName -> m Bool
is_True_expr (L _ (HsVar x))         = ((||) <$> (== "otherwise") <*> (== "True")) <$> ghcPpr x
is_True_expr (L _ (HsTick _ e))      = is_True_expr e
is_True_expr (L _ (HsBinTick _ _ e)) = is_True_expr e
is_True_expr (L _ (HsPar e))         = is_True_expr e
is_True_expr _                       = pure False

convertType :: ConversionMonad m => HsType RdrName -> m Term
convertType (HsForAllTy explicitness _ tvs ctx ty) =
  case unLoc ctx of
    [] -> do explicitTVs <- convertLHsTyVarBndrs Coq.Implicit tvs
             tyBody      <- convertLType ty
             implicitTVs <- case explicitness of
               GHC.Implicit -> do
                 -- We need to find all the unquantified type variables.  Since
                 -- Haskell never introduces a type variable name beginning with
                 -- an upper-case letter, we look for those; however, if we've
                 -- renamed a Coq value into one, we need to exclude that too.
                 -- (Also, we only keep "nonuppercase-first" names, not
                 -- "lowercase-first" names, as names beginning with @_@ are
                 -- also variables.)
                 bindings <- gets $ S.fromList . foldMap toList . toList
                 let fvs = S.filter (maybe False (not . isUpper . fst) . T.uncons) $
                             getFreeVars tyBody S.\\ bindings
                 pure . map (Inferred Coq.Implicit . Ident) $ S.toList fvs
               _ ->
                 pure []
             pure . maybe tyBody (flip Forall tyBody)
                  . nonEmpty $ explicitTVs ++ implicitTVs
    _ -> conv_unsupported "type class contexts"

convertType (HsTyVar tv) =
  Var <$> var TypeNS tv

convertType (HsAppTy ty1 ty2) =
  App1 <$> convertLType ty1 <*> convertLType ty2

convertType (HsFunTy ty1 ty2) =
  Arrow <$> convertLType ty1 <*> convertLType ty2

convertType (HsListTy ty) =
  App1 (Var "list") <$> convertLType ty

convertType (HsPArrTy _ty) =
  conv_unsupported "parallel arrays (`[:a:]')"

convertType (HsTupleTy tupTy tys) = do
  case tupTy of
    HsUnboxedTuple           -> conv_unsupported "unboxed tuples"
    HsBoxedTuple             -> pure ()
    HsConstraintTuple        -> conv_unsupported "constraint tuples"
    HsBoxedOrConstraintTuple -> pure () -- Sure, it's boxed, why not
  case tys of
    []   -> pure $ Var "unit"
    [ty] -> convertLType ty
    _    -> foldl1 (App2 $ Var "prod") <$> traverse convertLType tys

convertType (HsOpTy _ty1 _op _ty2) =
  conv_unsupported "binary operators" -- FIXME

convertType (HsParTy ty) =
  Parens <$> convertLType ty

convertType (HsIParamTy _ _) =
  conv_unsupported "implicit parameters"
                   
convertType (HsEqTy _ty1 _ty2) =
  conv_unsupported "type equality" -- FIXME

convertType (HsKindSig ty k) =
  HasType <$> convertLType ty <*> convertLType k

convertType (HsQuasiQuoteTy _) =
  conv_unsupported "type quasiquoters"

convertType (HsSpliceTy _ _) =
  conv_unsupported "Template Haskell type splices"

convertType (HsDocTy ty _doc) =
  convertLType ty

convertType (HsBangTy _bang ty) =
  convertLType ty -- Strictness annotations are ignored

convertType (HsRecTy _fields) =
  conv_unsupported "record types" -- FIXME

convertType (HsCoreTy _) =
  conv_unsupported "[internal] embedded core types"

convertType (HsExplicitListTy PlaceHolder tys) =
  foldr (App2 $ Var "cons") (Var "nil") <$> traverse convertLType tys

convertType (HsExplicitTupleTy _PlaceHolders tys) =
  case tys of
    []   -> pure $ Var "tt"
    [ty] -> convertLType ty
    _    -> foldl1 (App2 $ Var "pair") <$> traverse convertLType tys

convertType (HsTyLit lit) =
  case lit of
    HsNumTy _src int -> Num <$> convertInteger "type-level integers" int
    HsStrTy _src str -> pure $ convertFastString str

convertType (HsWrapTy _ _) =
  conv_unsupported "[internal] wrapped types" 

convertType HsWildcardTy =
  pure Underscore

convertType (HsNamedWildcardTy _) =
  conv_unsupported "named wildcards"

convertLType :: ConversionMonad m => LHsType RdrName -> m Term
convertLType = convertType . unLoc

type Constructor = (Ident, [Binder], Maybe Term)

convertLHsTyVarBndrs :: ConversionMonad m => Explicitness -> LHsTyVarBndrs RdrName -> m [Binder]
convertLHsTyVarBndrs ex (HsQTvs kvs tvs) = do
  kinds <- traverse (fmap (Inferred ex . Ident) . freeVar) kvs
  types <- for (map unLoc tvs) $ \case
             UserTyVar   tv   -> Inferred ex . Ident <$> freeVar tv
             KindedTyVar tv k -> Typed ex <$> (pure . Ident <$> freeVar (unLoc tv)) <*> convertLType k
  pure $ kinds ++ types

convertConDecl :: ConversionMonad m
               => Term -> ConDecl RdrName -> m [Constructor]
convertConDecl curType (ConDecl lnames _explicit lqvs lcxt ldetails lres _doc _old) = do
  unless (null $ unLoc lcxt) $ conv_unsupported "constructor contexts"
  names   <- for lnames $ \lname -> do
               name <- ghcPpr $ unLoc lname -- We use 'ghcPpr' because we munge the name here ourselves
               let name' = "Mk_" <> name
               name' <$ rename ExprNS name name'
  params  <- convertLHsTyVarBndrs Coq.Implicit lqvs
  resTy   <- case lres of
               ResTyH98       -> pure curType
               ResTyGADT _ ty -> convertLType ty
  args    <- traverse convertLType $ hsConDeclArgTys ldetails
  pure $ map (, params, Just $ foldr Arrow resTy args) names
  
convertDataDefn :: ConversionMonad m
                => Term -> HsDataDefn RdrName
                -> m (Term, [Constructor])
convertDataDefn curType (HsDataDefn _nd lcxt _ctype ksig cons _derivs) = do
  unless (null $ unLoc lcxt) $ conv_unsupported "data type contexts"
  (,) <$> maybe (pure $ Sort Type) convertLType ksig
      <*> (concat <$> traverse (convertConDecl curType . unLoc) cons)


convertDataDecl :: ConversionMonad m
                => Located RdrName -> LHsTyVarBndrs RdrName -> HsDataDefn RdrName
                -> m IndBody
convertDataDecl name tvs defn = do
  coqName <- freeVar $ unLoc name
  params  <- convertLHsTyVarBndrs Coq.Explicit tvs
  let nameArgs = map $ PosArg . \case
                   Ident x        -> Var x
                   UnderscoreName -> Underscore
      curType  = appList (Var coqName) . nameArgs $ foldMap binderNames params
  (resTy, cons) <- convertDataDefn curType defn
  pure $ IndBody coqName params resTy cons

data SynBody = SynBody Ident [Binder] (Maybe Term) Term
             deriving (Eq, Ord, Read, Show)

convertSynDecl :: ConversionMonad m
               => Located RdrName -> LHsTyVarBndrs RdrName -> LHsType RdrName
               -> m SynBody
convertSynDecl name args def  = SynBody <$> freeVar (unLoc name)
                                        <*> convertLHsTyVarBndrs Coq.Explicit args
                                        <*> pure Nothing
                                        <*> convertLType def

instance FreeVars SynBody where
  freeVars (SynBody _name args oty def) = binding' args $ freeVars oty *> freeVars def
       
data ConvertedDeclaration = ConvData IndBody
                          | ConvSyn  SynBody
                          deriving (Eq, Ord, Show, Read)

instance FreeVars ConvertedDeclaration where
  freeVars (ConvData ind) = freeVars ind
  freeVars (ConvSyn  syn) = freeVars syn

convDeclName :: ConvertedDeclaration -> Ident
convDeclName (ConvData (IndBody tyName  _ _ _)) = tyName
convDeclName (ConvSyn  (SynBody synName _ _ _)) = synName

convertTyClDecl :: ConversionMonad m => TyClDecl RdrName -> m ConvertedDeclaration
convertTyClDecl FamDecl{}    = conv_unsupported "type/data families"
convertTyClDecl SynDecl{..}  = ConvSyn  <$> convertSynDecl  tcdLName tcdTyVars tcdRhs
convertTyClDecl DataDecl{..} = ConvData <$> convertDataDecl tcdLName tcdTyVars tcdDataDefn
convertTyClDecl ClassDecl{}  = conv_unsupported "type classes"

data DeclarationGroup = Inductives (NonEmpty IndBody)
                      | Synonym    SynBody
                      | Synonyms   SynBody (NonEmpty SynBody)
                      | Mixed      (NonEmpty IndBody) (NonEmpty SynBody)
                      deriving (Eq, Ord, Show, Read)

addDeclaration :: ConvertedDeclaration -> DeclarationGroup -> DeclarationGroup
---------------------------------------------------------------------------------------------
addDeclaration (ConvData ind) (Inductives inds)      = Inductives (ind <| inds)
addDeclaration (ConvData ind) (Synonym    syn)       = Mixed      (ind :| [])   (syn :| [])
addDeclaration (ConvData ind) (Synonyms   syn syns)  = Mixed      (ind :| [])   (syn <| syns)
addDeclaration (ConvData ind) (Mixed      inds syns) = Mixed      (ind <| inds) syns
---------------------------------------------------------------------------------------------
addDeclaration (ConvSyn  syn) (Inductives inds)      = Mixed      inds          (syn :| [])
addDeclaration (ConvSyn  syn) (Synonym    syn')      = Synonyms                 syn (syn' :| [])
addDeclaration (ConvSyn  syn) (Synonyms   syn' syns) = Synonyms                 syn (syn' <| syns)
addDeclaration (ConvSyn  syn) (Mixed      inds syns) = Mixed      inds          (syn <| syns)

groupConvDecls :: NonEmpty ConvertedDeclaration -> DeclarationGroup
groupConvDecls (cd :| cds) = flip (foldr addDeclaration) cds $ case cd of
                               ConvData ind -> Inductives (ind :| [])
                               ConvSyn  syn -> Synonym    syn

groupTyClDecls :: ConversionMonad m => [TyClDecl RdrName] -> m [DeclarationGroup]
groupTyClDecls decls = do
  bodies <- traverse convertTyClDecl decls <&>
              M.fromList . map (convDeclName &&& id)
  -- The order is correct – later declarationss refer only to previous ones –
  -- since 'stronglyConnComp'' returns its outputs in topologically sorted
  -- order.
  let mutuals = stronglyConnComp' . M.toList $ (S.toList . getFreeVars) <$> bodies
  pure $ map (groupConvDecls . fmap (bodies M.!)) mutuals

convertDeclarationGroup :: DeclarationGroup -> Either String [Sentence]
convertDeclarationGroup = \case
  Inductives ind ->
    Right [InductiveSentence $ Inductive ind []]
  
  Synonym (SynBody name args oty def) ->
    Right [DefinitionSentence $ DefinitionDef Global name args oty def]
  
  Synonyms _ _ ->
    Left "mutually-recursive type synonyms"
  
  Mixed inds syns ->
    Right $  foldMap recSynType syns
          ++ [InductiveSentence $ Inductive inds (map (recSynDef $ foldMap indParams inds) $ toList syns)]
  
  where
    synName = (<> "__raw")
    
    recSynType :: SynBody -> [Sentence] -- Otherwise GHC infers a type containing @~@.
    recSynType (SynBody name _ _ _) =
      [ InductiveSentence $ Inductive [IndBody (synName name) [] (Sort Type) []] []
      , NotationSentence $ ReservedNotationIdent name ]
    
    indParams (IndBody _ params _ _) = S.fromList $ foldMap binderIdents params

    avoidParams params = until (`S.notMember` params) (<> "_")
    
    recSynDef params (SynBody name args oty def) =
      let mkFun    = maybe id Fun . nonEmpty
          withType = maybe id (flip HasType)
      in NotationIdentBinding name . App (Var "Synonym")
                                   $ fmap PosArg [ Var (synName name)
                                                 , everywhere (mkT $ avoidParams params) . -- FIXME use real substitution
                                                     mkFun args $ withType oty def ]

convertTyClDecls :: ConversionMonad m => [TyClDecl RdrName] -> m [Sentence]
convertTyClDecls =   either conv_unsupported (pure . fold)
                 .   traverse convertDeclarationGroup
                 <=< groupTyClDecls

convertValDecls :: ConversionMonad m => [HsDecl RdrName] -> m [Sentence]
convertValDecls args =
  let (defns, sigs) = partitionEithers . flip mapMaybe args $ \case
                        ValD def ->
                          Just $ Left def
                        SigD sig@(TypeSig _ _ _) ->
                          Just $ Right sig
                        _ ->
                          Nothing
      
      axiomatize :: GhcMonad m => HsBind RdrName -> GhcException -> m [Sentence]
      axiomatize FunBind{..} exn = do
        name <- freeVar $ unLoc fun_id
        pure [ CommentSentence . Comment
                 $ "Translating `" <> name <> "' failed: " <> T.pack (show exn)
             , AssumptionSentence . Assumption Axiom . UnparenthesizedAssums [name]
                 $ Forall [Typed Coq.Implicit [Ident "A"] $ Sort Type] (Var "A") ]
      axiomatize _ exn =
        liftIO $ throwGhcExceptionIO exn
  in fold <$> convertTypedBindings defns sigs
                                   (pure . pure . DefinitionSentence . uncurryConvertedDefinition (DefinitionDef Global))
                                   (Just axiomatize)

{-

`where' clauses         : 32
plain variable bindings : 29
record constructors     : 27
binary operators        : 23
guards                  : 15
tuple patterns          : 6
explicit lists          : 4
`do' expressions        : 4
lambdas                 : 4
tuples                  : 4
literals                : 3
`let' expressions       : 2
overloaded literals     : 2
infix constructors      : 2
record updates          : 1
numeric patterns        : 1
type class contexts     : 1

`where' clauses         : tickishScopesLike, chooseOrphanAnchor, mkTyApps, collectBinders, collectTyAndValBinders, collectArgs, collectArgsTicks, collectAnnArgs, collectAnnArgsTicks, collectAnnBndrs, ppr_role, ppr_fun_co, coVarRole, mkAppCo, mkTransAppCo, mkHomoForAllCos_NoRefl, mkCoVarCo, mkAxInstCo, mkAxInstRHS, mkAxInstLHS, mkNthCoRole, mkHomoPhantomCo, toPhantomCo, promoteCoercion, instCoercion, instCoercions, mkCoCast, topNormaliseTypeX_maybe, ty_co_subst, liftCoSubstVarBndr, liftEnvSubst, coercionKind
plain variable bindings : emptyRuleEnv, ruleName, ruleIdName, isLocalRule, needSaturated, unSaturatedOk, boringCxtOk, boringCxtNotOk, noUnfolding, evaldUnfolding, mkOtherCon, isRuntimeVar, isRuntimeArg, valBndrCount, valArgCount, coVarName, setCoVarUnique, setCoVarName, pprCoAxBranch, isReflexiveCo, mkRepReflCo, mkNomReflCo, mkCoVarCos, mkAxiomRuleCo, eqCoercion, swapLiftCoEnv, liftEnvSubstLeft, coercionKindRole, coercionRole
record constructors     : tickishCounts, tickishScoped, tickishCanSplit, tickishIsCode, tickishPlace, notOrphan, isBuiltinRule, isAutoRule, ruleArity, ruleActivation, isValueUnfolding, isEvaldUnfolding, isConLikeUnfolding, isCheapUnfolding, isStableUnfolding, isClosedUnfolding, canUnfold, isTyCoArg, isTypeArg, pprCoAxiom, ppr_co_ax_branch, isReflCo, mkSymCo, mkTransCo, mkCoherenceCo, mkProofIrrelCo, composeSteppers
binary operators        : tickishFloatable, ltAlt, cmpAltCon, mkConApp2, bindersOfBinds, coercionSize, ppr_co, ppr_axiom_rule_co, trans_co_list, ppr_forall_co, pprCoBndr, coVarKind, mkAxiomInstCo, mkSubCo, nthRole, castCoercionKind, eqCoercionX, liftCoSubstWith, mkLiftingContext, extendLiftingContext, isMappedByLC, seqCo, coercionKinds
guards                  : mkNoCount, mkNoScope, varToCoreExpr, coVarTypes, coVarKindsTypesRole, mkTyConAppCo, mkForAllCo, mkUnivCo, mkKindCo, setNominalRole_maybe, mkPiCo, instNewTyCon_maybe, unwrapNewTypeStepper, liftCoSubst, liftCoSubstTyVar
tuple patterns          : cmpAlt, deTagAlt, deAnnotate, deAnnotate', deAnnAlt, coercionType
explicit lists          : bindersOf, rhssOfBind, mkFunCo, mkInstCo
`do' expressions        : deTagBind, rhssOfAlts, decomposeCo, splitTyConAppCo_maybe
lambdas                 : mkCoApps, mkVarApps, mkCoercionType, applyRoles
tuples                  : splitAppCo_maybe, splitForAllCo_maybe, isReflCo_maybe, isReflexiveCo_maybe
literals                : exprToType, mkHeteroCoercionType, downgradeRole
`let' expressions       : mkForAllCos, liftCoSubstWithEx
overloaded literals     : provSize, mkUnbranchedAxInstCo
infix constructors      : flattenBinds, seqCos
record updates          : setRuleIdName
numeric patterns        : mkNthCo
type class contexts     : tickishContains

-}
