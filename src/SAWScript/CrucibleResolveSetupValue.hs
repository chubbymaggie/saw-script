{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE GADTs #-}

module SAWScript.CrucibleResolveSetupValue
  ( LLVMVal
  , resolveSetupVal
  , typeOfLLVMVal
  , typeOfSetupValue
  , resolveTypedTerm
  , resolveSAWPred
  , equalValsPred
  , packPointer
  ) where

import Control.Lens
import Control.Monad (zipWithM, foldM)
import Data.Foldable (toList)
import Data.Maybe (fromJust)
import Data.IORef
import Data.Word (Word64)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Vector as V

import qualified Text.LLVM.AST as L

import qualified Cryptol.Eval.Type as Cryptol (TValue(..), tValTy, evalValType)
import qualified Cryptol.TypeCheck.AST as Cryptol (Schema(..))

import qualified Lang.Crucible.BaseTypes as Crucible
import qualified Lang.Crucible.CFG.Core as Crucible (Some(..))
import qualified Lang.Crucible.Solver.Interface as Crucible hiding (mkStruct)
import qualified Lang.Crucible.Solver.SimpleBuilder as Crucible
import qualified Lang.Crucible.Utils.Arithmetic as Crucible

import qualified Lang.Crucible.LLVM.DataLayout as Crucible
import qualified Lang.Crucible.LLVM.MemType as Crucible
import qualified Lang.Crucible.LLVM.LLVMContext as TyCtx
import qualified Lang.Crucible.LLVM.Translation as Crucible
import qualified Lang.Crucible.LLVM.MemModel as Crucible
import qualified Lang.Crucible.LLVM.MemModel.Common as Crucible
import qualified Lang.Crucible.Simulator.RegMap as Crucible
import qualified Lang.Crucible.Solver.Interface as Crucible (bvLit, bvAdd, Pred)
import qualified Lang.Crucible.Solver.SAWCoreBackend as Crucible
-- import           Lang.Crucible.Utils.MonadST
import qualified Data.Parameterized.NatRepr as NatRepr

import Verifier.SAW.Rewriter
import Verifier.SAW.SharedTerm
import Verifier.SAW.Cryptol (importType, emptyEnv)

import qualified Verifier.SAW.Simulator.SBV as SBV (sbvSolveBasic, toWord)
import qualified Data.SBV.Dynamic as SBV (svAsInteger)

import SAWScript.Builtins
import SAWScript.TypedTerm
import SAWScript.Utils

import SAWScript.CrucibleMethodSpecIR

--import qualified SAWScript.LLVMBuiltins as LB

type LLVMVal = Crucible.LLVMVal Sym Crucible.PtrWidth

typeOfSetupValue ::
  Monad m =>
  CrucibleContext ->
  Map AllocIndex Crucible.MemType ->
  SetupValue ->
  m Crucible.MemType
typeOfSetupValue cc env val =
  case val of
    SetupVar i ->
      case Map.lookup i env of
        Nothing -> fail ("typeOfSetupValue: Unresolved prestate variable:" ++ show i)
        Just memTy -> return (Crucible.PtrType (Crucible.MemType memTy))
    SetupTerm tt ->
      case ttSchema tt of
        Cryptol.Forall [] [] ty ->
          case toLLVMType dl (Cryptol.evalValType Map.empty ty) of
            Nothing -> fail "typeOfSetupValue: non-representable type"
            Just memTy -> return memTy
        _ -> fail "typeOfSetupValue: expected monomorphic term"
    SetupStruct vs ->
      do memTys <- traverse (typeOfSetupValue cc env) vs
         let si = Crucible.mkStructInfo dl False memTys
         return (Crucible.StructType si)
    SetupArray [] -> fail "typeOfSetupValue: invalid empty crucible_array"
    SetupArray (v : vs) ->
      do memTy <- typeOfSetupValue cc env v
         _memTys <- traverse (typeOfSetupValue cc env) vs
         -- TODO: check that all memTys are compatible with memTy
         return (Crucible.ArrayType (length (v:vs)) memTy)
    SetupElem v i ->
      do memTy <- typeOfSetupValue cc env v
         let msg = "typeOfSetupValue: crucible_elem requires pointer to struct or array"
         case memTy of
           Crucible.PtrType symTy ->
             case let ?lc = lc in TyCtx.asMemType symTy of
               Just memTy' ->
                 case memTy' of
                   Crucible.ArrayType n memTy''
                     | i < n -> return (Crucible.PtrType (Crucible.MemType memTy''))
                     | otherwise -> fail $ "typeOfSetupValue: array type index out of bounds: " ++ show (i, n)
                   Crucible.StructType si ->
                     case Crucible.siFieldInfo si i of
                       Just fi -> return (Crucible.PtrType (Crucible.MemType (Crucible.fiType fi)))
                       Nothing -> fail $ "typeOfSetupValue: struct type index out of bounds: " ++ show i
                   _ -> fail msg
               Nothing -> fail msg
           _ -> fail msg
    SetupNull ->
      -- We arbitrarily set the type of NULL to void*, because a) it
      -- is memory-compatible with any type that NULL can be used at,
      -- and b) it prevents us from doing a type-safe dereference
      -- operation.
      return (Crucible.PtrType Crucible.VoidType)
    SetupGlobal name ->
      do let m = ccLLVMModule cc
             tys = [ (L.globalSym g, L.globalType g) | g <- L.modGlobals m ] ++
                   [ (L.decName d, L.decFunType d) | d <- L.modDeclares m ] ++
                   [ (L.defName d, L.defFunType d) | d <- L.modDefines m ]
         case lookup (L.Symbol name) tys of
           Nothing -> fail $ "typeOfSetupValue: unknown global " ++ show name
           Just ty ->
             case let ?lc = lc in TyCtx.liftType ty of
               Nothing -> fail $ "typeOfSetupValue: invalid type " ++ show ty
               Just symTy -> return (Crucible.PtrType symTy)
  where
    lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
    dl = TyCtx.llvmDataLayout lc

resolveSetupVal ::
  CrucibleContext        ->
  Map AllocIndex LLVMVal ->
  Map AllocIndex Crucible.MemType ->
  SetupValue             ->
  IO LLVMVal
resolveSetupVal cc env tyenv val =
  case val of
    SetupVar i
      | Just val' <- Map.lookup i env -> return val'
      | otherwise -> fail ("resolveSetupVal: Unresolved prestate variable:" ++ show i)
    SetupTerm tm -> resolveTypedTerm cc tm
    SetupStruct vs -> do
      vals <- mapM (resolveSetupVal cc env tyenv) vs
      let tps = map (typeOfLLVMVal dl) vals
      let flds = case Crucible.typeF (Crucible.mkStruct (V.fromList (mkFields dl 0 0 tps))) of
            Crucible.Struct v -> v
            _ -> error "impossible"
      return $ Crucible.LLVMValStruct (V.zip flds (V.fromList vals))
    SetupArray [] -> fail "resolveSetupVal: invalid empty array"
    SetupArray vs -> do
      vals <- V.mapM (resolveSetupVal cc env tyenv) (V.fromList vs)
      let tp = typeOfLLVMVal dl (V.head vals)
      return $ Crucible.LLVMValArray tp vals
    SetupElem v i ->
      do memTy <- typeOfSetupValue cc tyenv v
         let msg = "resolveSetupVal: crucible_elem requires pointer to struct or array"
         delta <- case memTy of
           Crucible.PtrType symTy ->
             case let ?lc = lc in TyCtx.asMemType symTy of
               Just memTy' ->
                 case memTy' of
                   Crucible.ArrayType n memTy''
                     | i < n -> return (fromIntegral i * Crucible.memTypeSize dl memTy'')
                   Crucible.StructType si ->
                     case Crucible.siFieldOffset si i of
                       Just d -> return d
                       Nothing -> fail $ "resolveSetupVal: struct type index out of bounds: " ++ show (i, memTy')
                   _ -> fail msg
               Nothing -> fail msg
           _ -> fail msg
         ptr <- resolveSetupVal cc env tyenv v
         case ptr of
           Crucible.LLVMValPtr blk end off ->
             do delta' <- Crucible.bvLit sym Crucible.knownNat (toInteger delta)
                off' <- Crucible.bvAdd sym off delta'
                return (Crucible.LLVMValPtr blk end off')
           _ -> fail "resolveSetupVal: crucible_elem requires pointer value"
    SetupNull ->
      packPointer <$> Crucible.mkNullPointer sym
    SetupGlobal name ->
      do let mem = ccEmptyMemImpl cc
         ptr <- Crucible.doResolveGlobal sym mem (L.Symbol name)
         return (packPointer ptr)
  where
    sym = ccBackend cc
    lc = Crucible.llvmTypeCtx (ccLLVMContext cc)
    dl = TyCtx.llvmDataLayout lc

resolveTypedTerm ::
  CrucibleContext ->
  TypedTerm       ->
  IO LLVMVal
resolveTypedTerm cc tm =
  case ttSchema tm of
    Cryptol.Forall [] [] ty ->
      resolveSAWTerm cc (Cryptol.evalValType Map.empty ty) (ttTerm tm)
    _ -> fail "resolveSetupVal: expected monomorphic term"

resolveSAWPred ::
  CrucibleContext ->
  Term ->
  IO (Crucible.Pred Sym)
resolveSAWPred cc tm =
  Crucible.bindSAWTerm (ccBackend cc) Crucible.BaseBoolRepr tm

resolveSAWTerm ::
  CrucibleContext ->
  Cryptol.TValue ->
  Term ->
  IO LLVMVal
resolveSAWTerm cc tp tm =
    case tp of
      Cryptol.TVBit ->
        fail "resolveSAWTerm: unimplemented type Bit (FIXME)"
      Cryptol.TVSeq sz Cryptol.TVBit ->
        case Crucible.someNat sz of
          Just (Crucible.Some w)
            | Just Crucible.LeqProof <- Crucible.isPosNat w ->
              do sc <- Crucible.saw_ctx <$> readIORef (Crucible.sbStateManager sym)
                 ss <- basic_ss sc
                 tm' <- rewriteSharedTerm sc ss tm
                 mx <- case getAllExts tm' of
                         [] -> do
                           -- Evaluate in SBV to test whether 'tm' is a concrete value
                           sbv <- SBV.toWord =<< SBV.sbvSolveBasic (scModule sc) Map.empty [] tm'
                           return (SBV.svAsInteger sbv)
                         _ -> return Nothing
                 case mx of
                   Just x -> do
                     loc <- Crucible.curProgramLoc sym
                     let v = Crucible.BVElt w x loc
                     return (Crucible.LLVMValInt w v)
                   Nothing -> do
                     v <- Crucible.bindSAWTerm sym (Crucible.BaseBVRepr w) tm'
                     return (Crucible.LLVMValInt w v)
          _ -> fail ("Invalid bitvector width: " ++ show sz)
      Cryptol.TVSeq sz tp' ->
        do sc    <- Crucible.saw_ctx <$> (readIORef (Crucible.sbStateManager sym))
           sz_tm <- scNat sc (fromIntegral sz)
           tp_tm <- importType sc emptyEnv (Cryptol.tValTy tp')
           let f i = do i_tm <- scNat sc (fromIntegral i)
                        tm' <- scAt sc sz_tm tp_tm tm i_tm
                        resolveSAWTerm cc tp' tm'
           case toLLVMType dl tp' of
             Nothing -> fail "resolveSAWTerm: invalid type"
             Just mt -> do
               gt <- Crucible.toStorableType mt
               Crucible.LLVMValArray gt . V.fromList <$> mapM f [ 0 .. (sz-1) ]
      Cryptol.TVStream _tp' ->
        fail "resolveSAWTerm: invalid infinite stream type"
      Cryptol.TVTuple tps ->
        do sc <- Crucible.saw_ctx <$> (readIORef (Crucible.sbStateManager sym))
           tms <- mapM (scTupleSelector sc tm) [1 .. length tps]
           vals <- zipWithM (resolveSAWTerm cc) tps tms
           storTy <-
             case toLLVMType dl tp of
               Just memTy -> Crucible.toStorableType memTy
               _ -> fail "resolveSAWTerm: invalid tuple type"
           fields <-
             case Crucible.typeF storTy of
               Crucible.Struct fields -> return fields
               _ -> fail "resolveSAWTerm: impossible: expected struct"
           return (Crucible.LLVMValStruct (V.zip fields (V.fromList vals)))
      Cryptol.TVRec _flds ->
        fail "resolveSAWTerm: unimplemented record type (FIXME)"
      Cryptol.TVFun _ _ ->
        fail "resolveSAWTerm: invalid function type"
  where
    sym = ccBackend cc
    dl = TyCtx.llvmDataLayout (Crucible.llvmTypeCtx (ccLLVMContext cc))

packPointer ::
  Crucible.RegValue Sym Crucible.LLVMPointerType ->
  Crucible.LLVMVal Sym Crucible.PtrWidth
packPointer (Crucible.RolledType xs) = Crucible.LLVMValPtr blk end off
  where
    Crucible.RV blk = xs^._1
    Crucible.RV end = xs^._2
    Crucible.RV off = xs^._3

toLLVMType :: Crucible.DataLayout -> Cryptol.TValue -> Maybe Crucible.MemType
toLLVMType dl tp =
    case tp of
      Cryptol.TVBit -> Nothing -- FIXME
      Cryptol.TVSeq n Cryptol.TVBit
        | n > 0 -> Just (Crucible.IntType (fromInteger n))
        | otherwise -> Nothing
      Cryptol.TVSeq n t -> do
        t' <- toLLVMType dl t
        let n' = fromIntegral n
        Just (Crucible.ArrayType n' t')
      Cryptol.TVStream _tp' -> Nothing
      Cryptol.TVTuple tps -> do
        tps' <- mapM (toLLVMType dl) tps
        let si = Crucible.mkStructInfo dl False tps'
        return (Crucible.StructType si)
      Cryptol.TVRec _flds -> Nothing -- FIXME
      Cryptol.TVFun _ _ -> Nothing

mkFields ::
  Crucible.DataLayout ->
  Crucible.Alignment ->
  Word64 ->
  [Crucible.Type] ->
  [(Crucible.Type, Word64)]
mkFields _ _ _ [] = []
mkFields dl a off (ty : tys) = (ty, pad) : mkFields dl a' off' tys
    where
      end = off + Crucible.typeSize ty
      off' = Crucible.nextPow2Multiple end (fromIntegral nextAlign)
      pad = off' - end
      a' = max a (typeAlignment dl ty)
      nextAlign = case tys of
        [] -> a'
        (ty' : _) -> typeAlignment dl ty'



typeAlignment :: Crucible.DataLayout -> Crucible.Type -> Crucible.Alignment
typeAlignment dl ty =
  case Crucible.typeF ty of
    Crucible.Bitvector bytes -> Crucible.integerAlignment dl (fromIntegral (bytes*8))
    Crucible.Float           -> fromJust (Crucible.floatAlignment dl 32)
    Crucible.Double          -> fromJust (Crucible.floatAlignment dl 64)
    Crucible.Array _sz ty'   -> typeAlignment dl ty'
    Crucible.Struct flds     -> V.foldl max 0 (fmap (typeAlignment dl . (^. Crucible.fieldVal)) flds)

typeOfLLVMVal :: Crucible.DataLayout -> LLVMVal -> Crucible.Type
typeOfLLVMVal dl val =
  case val of
    Crucible.LLVMValPtr {}      -> ptrType
    Crucible.LLVMValInt w _bv   -> Crucible.bitvectorType (Crucible.intWidthSize (fromIntegral (NatRepr.natValue w)))
    Crucible.LLVMValReal _      -> error "FIXME: typeOfLLVMVal LLVMValReal"
    Crucible.LLVMValStruct flds -> Crucible.mkStruct (fmap fieldType flds)
    Crucible.LLVMValArray tp vs -> Crucible.arrayType (fromIntegral (V.length vs)) tp
  where
    ptrType = Crucible.bitvectorType (dl^.Crucible.ptrSize)
    fieldType (f, _) = (f ^. Crucible.fieldVal, Crucible.fieldPad f)

equalValsPred ::
  CrucibleContext ->
  LLVMVal ->
  LLVMVal ->
  IO (Crucible.Pred Sym)
equalValsPred cc v1 v2 = go (v1, v2)
  where
  go :: (LLVMVal, LLVMVal) -> IO (Crucible.Pred Sym)

  go (Crucible.LLVMValPtr blk1 _end1 off1, Crucible.LLVMValPtr blk2 _end2 off2)
       = do blk_eq <- Crucible.natEq sym blk1 blk2
            off_eq <- Crucible.bvEq sym off1 off2
            Crucible.andPred sym blk_eq off_eq
  go (Crucible.LLVMValInt wx x, Crucible.LLVMValInt wy y)
       | Just Crucible.Refl <- Crucible.testEquality wx wy
       = Crucible.bvEq sym x y
  go (Crucible.LLVMValReal x, Crucible.LLVMValReal y)
       = Crucible.realEq sym x y
  go (Crucible.LLVMValStruct xs, Crucible.LLVMValStruct ys)
       | V.length xs == V.length ys
       = do cs <- mapM go (zip (map snd (toList xs)) (map snd (toList ys)))
            foldM (Crucible.andPred sym) (Crucible.truePred sym) cs
  go (Crucible.LLVMValArray _tpx xs, Crucible.LLVMValArray _tpy ys)
       | V.length xs == V.length ys
       = do cs <- mapM go (zip (toList xs) (toList ys))
            foldM (Crucible.andPred sym) (Crucible.truePred sym) cs

  go _ = return (Crucible.falsePred sym)

  sym = ccBackend cc
