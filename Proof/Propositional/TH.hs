{-# LANGUAGE ExplicitNamespaces, MultiWayIf, PatternGuards      #-}
{-# LANGUAGE TemplateHaskell, TupleSections                     #-}
module Proof.Propositional.TH where
import Proof.Propositional.Empty
import Proof.Propositional.Inhabited

import           Control.Arrow               (Kleisli (..), second)
import           Control.Monad               (forM, zipWithM)
import           Data.Foldable               (asum)
import           Data.Map                    (Map)
import qualified Data.Map                    as M
import           Data.Maybe                  (fromJust)
import           Data.Type.Equality          ((:~:) (..))
import           Language.Haskell.TH         (DecsQ, Lit (CharL, IntegerL),
                                              Name, Q, TypeQ, isInstance,
                                              newName, ppr)
import           Language.Haskell.TH.Desugar (DClause (..), DCon (..),
                                              DConFields (..), DCxt, DDec (..),
                                              DExp (..), DInfo (..),
                                              DLetDec (DFunD),
                                              DPat (..), DPred,
                                              DTyVarBndr (..), DType (..),
                                              Overlap (Overlapping), desugar,
                                              dsReify, expandType, substTy,
                                              sweeten)

-- | Macro to automatically derive @'Empty'@ instance for
--   concrete (variable-free) types which may contain products.
refute :: TypeQ -> DecsQ
refute tps = do
  tp <- expandType =<< desugar =<< tps
  let Just (_, tyName, args) = splitType tp
      mkInst dxt cls = return $ sweeten
                       [DInstanceD (Just Overlapping) Nothing dxt
                        (DAppT (DConT ''Empty) (foldl DAppT (DConT tyName) args))
                        [DLetDec $ DFunD 'eliminate cls]
                         ]
  if tyName == ''(:~:)
    then do
      let [l, r] = args
      v    <- newName "_v"
      dist <- compareType l r
      case dist of
        NonEqual    -> mkInst [] [DClause [] $ DLamE [v] (DCaseE (DVarE v) []) ]
        Equal       -> fail $ "Equal: " ++ show (ppr $ sweeten l) ++ " ~ " ++ show (ppr $ sweeten r)
        Undecidable -> fail $ "No enough info to check non-equality: " ++
                         show (ppr $ sweeten l) ++ " ~ " ++ show (ppr $ sweeten r)
    else do
      (dxt, cons) <- resolveSubsts args . fromJust =<< dsReify tyName
      Just cls <- sequence <$> mapM buildRefuteClause cons
      mkInst dxt cls

-- | Macro to automatically derive @'Inhabited'@ instance for
--   concrete (variable-free) types which may contain sums.
prove :: TypeQ -> DecsQ
prove tps = do
  tp <- expandType =<< desugar =<< tps
  let Just (_, tyName, args) = splitType tp
      mkInst dxt cls = return $ sweeten
                       [DInstanceD (Just Overlapping) Nothing dxt
                        (DAppT (DConT ''Inhabited) (foldl DAppT (DConT tyName) args))
                        [DLetDec $ DFunD 'trivial cls]
                         ]
  isNum <- isInstance ''Num [sweeten tp]

  if | isNum -> mkInst [] [DClause [] $ DLitE $ IntegerL 0 ]
     | tyName == ''Char  -> mkInst [] [DClause [] $ DLitE $ CharL '\NUL']
     | tyName == ''(:~:) -> do
        let [l, r] = args
        dist <- compareType l r
        case dist of
          NonEqual    -> fail $ "Equal: " ++ show (ppr $ sweeten l) ++ " ~ " ++ show (ppr $ sweeten r)
          Equal       -> mkInst [] [DClause [] $ DConE 'Refl ]
          Undecidable -> fail $ "No enough info to check non-equality: " ++
                           show (ppr $ sweeten l) ++ " ~ " ++ show (ppr $ sweeten r)
     | otherwise -> do
        (dxt, cons) <- resolveSubsts args . fromJust =<< dsReify tyName
        Just cls <- asum <$> mapM buildProveClause cons
        mkInst dxt [cls]

buildClause :: Name -> (DType -> Q b) -> (DType -> b -> DExp)
            -> (Name -> [Maybe DExp] -> Maybe DExp) -> (Name -> [b] -> [DPat])
            -> DCon -> Q (Maybe DClause)
buildClause clsName genPlaceHolder buildFactor flattenExps toPats (DCon _ _ cName flds _) = do
  let tys = fieldsVars flds
  varDic <- mapM genPlaceHolder tys
  fmap (DClause $ toPats cName varDic) . flattenExps cName <$> zipWithM tryProc tys varDic
  where
    tryProc ty name = do
      isEmpty <- isInstance clsName . (:[]) $ sweeten ty
      return $ if isEmpty
        then Just $ buildFactor ty name
        else Nothing

buildRefuteClause :: DCon -> Q (Maybe DClause)
buildRefuteClause =
  buildClause
    ''Empty (const $ newName "_x")
    (const $ (DVarE 'eliminate `DAppE`) . DVarE) (const asum)
    (\cName ps -> [DConP cName $ map DVarP ps])

buildProveClause :: DCon -> Q (Maybe DClause)
buildProveClause  =
  buildClause
    ''Inhabited (const $ return ())
    (const $ const $ DVarE 'trivial)
    (\ con args -> foldl DAppE (DConE con) <$> sequence args )
    (const $ const [])

fieldsVars :: DConFields -> [DType]
fieldsVars (DNormalC _ fs)
  = map snd fs
fieldsVars (DRecC fs)    = map (\(_,_,c) -> c) fs

resolveSubsts :: [DType] -> DInfo -> Q (DCxt, [DCon])
resolveSubsts args info =
  case info of
    (DTyConI (DDataD _ cxt _ tvbs _ dcons _) _) -> do
      let dic = M.fromList $ zip (map dtvbToName tvbs) args
      (cxt , ) <$> mapM (substDCon dic) dcons
    -- (DTyConI (DOpenTypeFamilyD n) _) ->  return []
    -- (DTyConI (DClosedTypeFamilyD _ ddec2) minst) ->  return []
    -- (DTyConI (DDataFamilyD _ ddec2) minst) ->  return []
    -- (DTyConI (DDataInstD _ ddec2 ddec3 ddec4 ddec5 ddec6) minst) ->  return []
    (DTyConI _ _) -> fail "Not supported data ty"
    _ -> fail "Please pass data-type"

type SubstDic = Map Name DType

substDCon :: SubstDic -> DCon -> Q DCon
substDCon dic (DCon forall'd cxt conName fields mPhantom) =
  DCon forall'd cxt conName
    <$> substFields dic fields
    <*> substTy dic mPhantom

substFields :: SubstDic -> DConFields -> Q DConFields
substFields subst (DNormalC fixi fs)
  = DNormalC fixi <$>
  mapM (runKleisli $ second $ Kleisli $ substTy subst) fs
substFields subst (DRecC fs) =
  DRecC <$> forM fs (\(a,b,c) -> (a, b ,) <$> substTy subst c)

dtvbToName :: DTyVarBndr -> Name
dtvbToName (DPlainTV n)    = n
dtvbToName (DKindedTV n _) = n

splitType :: DType -> Maybe ([Name], Name, [DType])
splitType (DForallT vs _ t) = (\(a,b,c) -> (map dtvbToName vs ++ a, b, c)) <$> splitType t
splitType (DAppKindT t _) = splitType t
splitType (DAppT t1 t2) = (\(a,b,c) -> (a, b, c ++ [t2])) <$> splitType t1
splitType (DSigT t _) = splitType t
splitType (DVarT _) = Nothing
splitType (DConT n) = Just ([], n, [])
splitType DArrowT = Just ([], ''(->), [])
splitType (DLitT _) = Nothing
splitType DWildCardT = Nothing


data EqlJudge = NonEqual | Undecidable | Equal
              deriving (Read, Show, Eq, Ord)

instance Semigroup EqlJudge where
  NonEqual    <> _        = NonEqual
  Undecidable <> NonEqual = NonEqual
  Undecidable <> _        = Undecidable
  Equal       <> m        = m

instance Monoid EqlJudge where
  mappend = (<>)
  mempty = Equal

compareType :: DType -> DType -> Q EqlJudge
compareType t0 s0 = do
  t <- expandType t0
  s <- expandType s0
  compareType' t s

compareType' :: DType -> DType -> Q EqlJudge
compareType' (DSigT t1 t2) (DSigT s1 s2)
  = (<>) <$> compareType' t1 s1 <*> compareType' t2 s2
compareType' (DSigT t _) s
  = compareType' t s
compareType' t (DSigT s _)
  = compareType' t s
compareType' (DVarT t) (DVarT s)
  | t == s    = return Equal
  | otherwise = return Undecidable
compareType' (DVarT _) _ = return Undecidable
compareType' _ (DVarT _) = return Undecidable
compareType' DWildCardT _ = return Undecidable
compareType' _ DWildCardT = return Undecidable
compareType' (DForallT tTvBs tCxt t) (DForallT sTvBs sCxt s)
  | length tTvBs == length sTvBs = do
      let dic = M.fromList $ zip (map dtvbToName sTvBs) (map (DVarT . dtvbToName) tTvBs)
      s' <- substTy dic s
      pd <- compareCxt tCxt =<< mapM (substPred dic) sCxt
      bd <- compareType' t s'
      return (pd <> bd)
  | otherwise = return NonEqual
compareType' DForallT{} _   = return NonEqual
compareType' (DAppT t1 t2) (DAppT s1 s2)
  = (<>) <$> compareType' t1 s1 <*> compareType' t2 s2
compareType' (DConT t) (DConT s)
  | t == s    = return Equal
  | otherwise = return NonEqual
compareType' (DConT _) _ = return NonEqual
compareType' DArrowT DArrowT = return Equal
compareType' DArrowT _ = return NonEqual
compareType' (DLitT t) (DLitT s)
  | t == s    = return Equal
  | otherwise = return NonEqual
compareType' (DLitT _) _ = return NonEqual
compareType' (DAppKindT l t) (DAppKindT r s) =
  (<>) <$> compareType' t s <*> compareType l r
compareType' (DAppKindT l _) r = compareType l r
compareType' l (DAppKindT r _) = compareType l r
compareType' _ _ = return NonEqual

compareCxt :: DCxt -> DCxt -> Q EqlJudge
compareCxt l r = mconcat <$> zipWithM compareType l r

substPred :: SubstDic -> DPred -> Q DPred
substPred dic (DAppT p1 p2) = DAppT <$> substPred dic p1 <*> (expandType =<< substTy dic p2)
substPred dic (DSigT p knd) = DSigT <$> substPred dic p  <*> (expandType =<< substTy dic knd)
substPred dic prd@(DVarT p)
  | Just (DVarT t) <- M.lookup p dic = return $ DVarT t
  | Just (DConT t) <- M.lookup p dic = return $ DConT t
  | otherwise = return prd
substPred _ t = return t
