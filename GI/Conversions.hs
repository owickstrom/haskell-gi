{-# LANGUAGE PatternGuards, DeriveFunctor, OverloadedStrings #-}

module GI.Conversions
    ( convert
    , genConversion
    , unpackCArray
    , computeArrayLength

    , marshallFType
    , convertFMarshall
    , convertHMarshall
    , hToF
    , fToH
    , haskellType
    , foreignType

    , apply
    , mapC
    , literal
    , Constructor(..)
    ) where

import Control.Applicative ((<$>))
import Control.Monad.Free (Free(..), liftF)
import Data.Typeable (TypeRep, tyConName, typeRepTyCon, typeOf)
import GHC.Exts (IsString(..))
import Data.Int
import Data.Word

import GI.API
import GI.Code
import GI.GObject
import GI.SymbolNaming
import GI.Type
import GI.Util

import GI.Internal.ArgInfo (Transfer(..))

toPtr con = "(\\(" ++ con ++ " x) -> x)"

-- String identifying a constructor in the generated code, which is
-- either (by default) a pure function (indicated by the P
-- constructor) or a function returning values on a monad (M
-- constructor). 'Id' denotes the identity function.
data Constructor = P String | M String | Id
                   deriving (Eq,Show)
instance IsString Constructor where
    fromString cs = P cs

data FExpr next = Apply Constructor next
                | MapC Constructor next
                | Literal Constructor next
                  deriving (Show, Functor)

type Converter = Free FExpr ()

apply f = liftF $ Apply f ()
mapC f = liftF $ MapC f ()
literal f = liftF $ Literal f ()

genConversion :: String -> Converter -> CodeGen String
genConversion l (Pure ()) = return l
genConversion l (Free k) = do
  let l' = prime l
  case k of
    Apply (P f) next ->
        do line $ "let " ++ l' ++ " = " ++ f ++ " " ++ l
           genConversion l' next
    Apply (M f) next ->
        do line $ l' ++ " <- " ++ f ++ " " ++ l
           genConversion l' next
    Apply Id next -> genConversion l next

    MapC (P f) next ->
        do line $ "let " ++ l' ++ " = map " ++ f ++ " " ++ l
           genConversion l' next
    MapC (M f) next ->
        do line $ l' ++ " <- mapM " ++ f ++ " " ++ l
           genConversion l' next
    MapC Id next -> genConversion l next

    Literal (P f) next ->
        do line $ "let " ++ l ++ " = " ++ f
           genConversion l next
    Literal (M f) next ->
        do line $ l ++ " <- " ++ f
           genConversion l next
    Literal Id next -> genConversion l next

-- Given an array, together with its type, return the code for reading
-- its length.
computeArrayLength :: String -> Type -> String
computeArrayLength array (TCArray _ _ _ t) =
    "fromIntegral $ " ++ reader ++ " " ++ array
    where reader = case t of
                     TBasicType TUInt8 -> "B.length"
                     TBasicType _ -> "length"
                     TInterface _ _ -> "length"
                     _ -> error $ "Don't know how to compute length of "
                          ++ show t
computeArrayLength _ t =
    error $ "computeArrayLength called on non-CArray type " ++ show t

convert :: String -> CodeGen Converter -> CodeGen String
convert l c = do
  c' <- c
  genConversion l c'

hObjectToF :: Type -> Transfer -> CodeGen Constructor
hObjectToF t transfer = do
  if transfer == TransferEverything
  then do
    isGO <- isGObject t
    if isGO
    then return $ M "refObject"
    else do
      line $ "-- XXX Transferring a non-GObject object!"
      return "unsafeManagedPtrGetPtr"
  else return "unsafeManagedPtrGetPtr"

hBoxedToF :: Bool -> Transfer -> CodeGen Constructor
hBoxedToF isBoxed transfer = do
  if transfer == TransferEverything
  then do
    if isBoxed
    then return $ M "copyBoxed"
    else do
      line $ "-- XXX Transferring a non-Boxed object!"
      return "unsafeManagedPtrGetPtr"
  else return "unsafeManagedPtrGetPtr"

-- Given the Haskell and Foreign types, returns the name of the
-- function marshalling between both.
hToF' :: Type -> Maybe API -> TypeRep -> TypeRep -> Transfer
            -> CodeGen Constructor
hToF' t a hType fType transfer
    | ( hType == fType ) = return Id
    | Just (APIEnum _) <- a = return "(fromIntegral . fromEnum)"
    | Just (APIFlags _) <- a = return "fromIntegral"
    | Just (APIObject _) <- a = hObjectToF t transfer
    | Just (APIInterface _) <- a = hObjectToF t transfer
    | Just (APIStruct s) <- a = hBoxedToF (structIsBoxed s) transfer
    | Just (APIUnion u) <- a = hBoxedToF (unionIsBoxed u) transfer
    | TError <- t = hBoxedToF True transfer
    | Just (APICallback _) <- a = do
        line $ "--- XXX Callback types are not properly supported yet"
        let con = tyConName $ typeRepTyCon hType
        return $ P $ toPtr con
    | TByteArray <- t = return $ M "packGByteArray"
    | TCArray True _ _ (TBasicType TUTF8) <- t =
        return $ M "packZeroTerminatedUTF8CArray"
    | TCArray True _ _ (TBasicType TFileName) <- t =
        return $ M "packZeroTerminatedFileNameArray"
    | TCArray True _ _ (TBasicType TVoid) <- t =
        return $ M "packZeroTerminatedPtrArray"
    | TCArray True _ _ (TBasicType TUInt8) <- t =
        return $ M "packZeroTerminatedByteString"
    | TCArray True _ _ (TBasicType TBoolean) <- t =
        return $ M "(packMapZeroTerminatedStorableArray (fromIntegral . fromEnum))"
    | TCArray True _ _ (TBasicType _) <- t =
        return $ M "packZeroTerminatedStorableArray"
    | TCArray False _ _ (TBasicType TUTF8) <- t =
        return $ M "packUTF8CArray"
    | TCArray False _ _ (TBasicType TFileName) <- t =
        return $ M "packFileNameArray"
    | TCArray False _ _ (TBasicType TVoid) <- t =
        return $ M "packPtrArray"
    | TCArray False _ _ (TBasicType TUInt8) <- t =
        return $ M "packByteString"
    | TCArray False _ _ (TBasicType TBoolean) <- t =
        return $ M "(packMapStorableArray (fromIntegral . fromEnum))"
    | TCArray False _ _ (TBasicType _) <- t =
        return $ M "packStorableArray"
    | TCArray _ _ _ _ <- t =
                         error $ "Don't know how to pack C array of type "
                                   ++ show t
    | TGHash _ _ <- t = do
        line $ "-- XXX Hash tables are not properly supported yet"
        let con = tyConName $ typeRepTyCon hType
        return $ P $ toPtr con
    | otherwise = return $ case (show hType, show fType) of
               ("[Char]", "CString") -> M "newCString"
               ("ByteString", "CString") -> M "byteStringToCString"
               ("Char", "CInt")      -> "(fromIntegral . ord)"
               ("Bool", "CInt")      -> "(fromIntegral . fromEnum)"
               _                     -> error $ "don't know how to convert "
                                        ++ show hType ++ " into "
                                        ++ show fType ++ ".\n"
                                        ++ "Internal type: "
                                        ++ show t

hToF_PackedType t packer transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  innerConstructor <- hToF' t a hType fType transfer
  return $ do
    mapC innerConstructor
    apply (M packer)

hToF :: Type -> Transfer -> CodeGen Converter
hToF (TGList t) transfer = hToF_PackedType t "packGList" transfer
hToF (TGSList t) transfer = hToF_PackedType t "packGSList" transfer
hToF (TGArray t) transfer = hToF_PackedType t "packGArray" transfer
hToF (TPtrArray t) transfer = hToF_PackedType t "packGPtrArray" transfer
hToF (TCArray zt _ _ t@(TInterface _ _)) transfer = do
  isScalar <- getIsScalar t
  let packer = if zt
               then "packZeroTerminated"
               else "pack"
  if isScalar
  then hToF_PackedType t (packer ++ "StorableArray") transfer
  else hToF_PackedType t (packer ++ "PtrArray") transfer

hToF t transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  constructor <- hToF' t a hType fType transfer
  return $ apply constructor

boxedForeignPtr :: TypeRep -> Bool -> Transfer -> CodeGen Constructor
boxedForeignPtr hType boxed transfer = do
  let constructor = tyConName $ typeRepTyCon hType
  case transfer of
    TransferEverything ->
        if boxed
        then return $ M $ parenthesize $ "wrapBoxed " ++ constructor
        else do
          line $ "-- XXX (Leak) Got a transfer of an unboxed object"
          return $ M $ parenthesize $
           "\\x -> " ++ constructor ++ " <$> newForeignPtr_ x"
    _ ->
        if boxed
        then return $ M $ parenthesize $ "newBoxed " ++ constructor
        else do
          line $ "-- XXX Wrapping an unboxed object with no copy..."
          return $ M $ parenthesize $
           "\\x -> " ++ constructor ++ " <$> newForeignPtr_ x"

fObjectToH :: Type -> TypeRep -> Transfer -> CodeGen Constructor
fObjectToH t hType transfer = do
  let constructor = tyConName $ typeRepTyCon hType
  isGO <- isGObject t
  case transfer of
    TransferEverything ->
        if isGO
        then return $ M $ parenthesize $ "wrapObject " ++ constructor
        else do
          line $ "-- XXX (Leak) Got a transfer of something not a GObject"
          return $ M $ parenthesize $
           "\\x -> " ++ constructor ++ " <$> newForeignPtr_ x"
    _ ->
        if isGO
        then return $ M $ parenthesize $ "newObject " ++ constructor
        else do
          line $ "-- XXX Wrapping not a GObject with no copy..."
          return $ M $ parenthesize $
           "\\x -> " ++ constructor ++ " <$> newForeignPtr_ x"

fToH' :: Type -> Maybe API -> TypeRep -> TypeRep -> Transfer
         -> CodeGen Constructor
fToH' t a hType fType transfer
    | ( hType == fType ) = return Id
    | Just (APIEnum _) <- a = return "(toEnum . fromIntegral)"
    | Just (APIFlags _) <- a = return "fromIntegral"
    | TError <- t = case transfer of
        TransferEverything -> return $ M "(wrapBoxed GI.GLib.Error)"
        _ -> return $ M "(newBoxed GI.GLib.Error)"
    | Just (APIStruct s) <- a = boxedForeignPtr hType (structIsBoxed s) transfer
    | Just (APIUnion u) <- a = boxedForeignPtr hType (unionIsBoxed u) transfer
    | Just (APIObject _) <- a = fObjectToH t hType transfer
    | Just (APIInterface _) <- a = fObjectToH t hType transfer
    | TCArray True _ _ (TBasicType TUTF8) <- t =
        return $ M "unpackZeroTerminatedUTF8CArray"
    | TCArray True _ _ (TBasicType TFileName) <- t =
        return $ M "unpackZeroTerminatedFileNameArray"
    | TCArray True _ _ (TBasicType TUInt8) <- t =
        return $ M "unpackZeroTerminatedByteString"
    | TCArray True _ _ (TBasicType TVoid) <- t =
        return $ M "unpackZeroTerminatedPtrArray"
    | TCArray True _ _ (TBasicType TBoolean) <- t =
        return $ M "(unpackMapZeroTerminatedStorableArray (/= 0))"
    | TCArray True _ _ (TBasicType _) <- t =
        return $ M "unpackZeroTerminatedStorableArray"
    | TCArray _ _ _ _ <- t =
                         error $
                           "fToH' : Don't know how to unpack C array of type "
                           ++ show t
    | TByteArray <- t = return $ M "unpackGByteArray"
    | otherwise = return $ case (show fType, show hType) of
               ("CString", "[Char]") -> M "peekCString"
               ("CString", "ByteString") -> M "B.packCString"
               ("CInt", "Char")      -> "(chr . fromIntegral)"
               ("CInt", "Bool")      -> "(/= 0)"
               _                     -> error $ "don't know how to convert "
                                        ++ show fType ++ " into "
                                        ++ show hType ++ ".\n"
                                        ++ "Internal type: "
                                        ++ show t

fToH_PackedType t unpacker transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  innerConstructor <- fToH' t a hType fType transfer
  return $ do
    apply (M unpacker)
    mapC innerConstructor

fToH :: Type -> Transfer -> CodeGen Converter

fToH (TGList t) transfer = fToH_PackedType t "unpackGList" transfer
fToH (TGSList t) transfer = fToH_PackedType t "unpackGSList" transfer
fToH (TGArray t) transfer = fToH_PackedType t "unpackGArray" transfer
fToH (TPtrArray t) transfer = fToH_PackedType t "unpackGPtrArray" transfer
fToH (TCArray True _ _ t@(TInterface _ _)) transfer = do
  isScalar <- getIsScalar t
  if isScalar
  then fToH_PackedType t "unpackZeroTerminatedStorableArray" transfer
  else fToH_PackedType t "unpackZeroTerminatedPtrArray" transfer

fToH t transfer = do
  a <- findAPI t
  hType <- haskellType t
  fType <- foreignType t
  constructor <- fToH' t a hType fType transfer
  return $ apply constructor

unpackCArray :: String -> Type -> Transfer -> CodeGen Converter
unpackCArray length (TCArray False _ _ t) transfer =
  case t of
    TBasicType TUTF8 -> return $ apply $ M $ parenthesize $
                        "unpackUTF8CArrayWithLength " ++ length
    TBasicType TFileName -> return $ apply $ M $ parenthesize $
                            "unpackFileNameArrayWithLength " ++ length
    TBasicType TUInt8 -> return $ apply $ M $ parenthesize $
                         "unpackByteStringWithLength " ++ length
    TBasicType TVoid -> return $ apply $ M $ parenthesize $
                         "unpackPtrArrayWithLength " ++ length
    TBasicType TBoolean -> return $ apply $ M $ parenthesize $
                         "unpackMapStorableArrayWithLength (/= 0) " ++ length
    TBasicType _ -> return $ apply $ M $ parenthesize $
                         "unpackStorableArrayWithLength " ++ length
    TInterface _ _ -> do
           a <- findAPI t
           isScalar <- getIsScalar t
           hType <- haskellType t
           fType <- foreignType t
           innerConstructor <- fToH' t a hType fType transfer
           let unpacker = if isScalar
                          then "unpackStorableArrayWithLength"
                          else "unpackPtrArrayWithLength"
           return $ do
             apply $ M $ parenthesize $ unpacker ++ " " ++ length
             mapC innerConstructor
    _ -> error $ "unpackCArray : Don't know how to unpack C Array of type "
                 ++ show t

unpackCArray _ _ _ = error $ "unpackCArray : unexpected array type."

-- The signal marshaller C code has some built in support for basic
-- types, so we only generate conversions for things that the
-- marshaller cannot do itself. (This list should be kept in sync with
-- hsgclosure.c)

-- Marshaller to haskell types.
-- There is no support in the marshaller for converting Haskell
-- strings into C strings directly.
marshallFType :: Type -> CodeGen TypeRep
marshallFType t@(TBasicType TUTF8) = foreignType t
marshallFType t@(TBasicType TFileName) = foreignType t
marshallFType t@(TBasicType _) = haskellType t
marshallFType a = foreignType a

convertFMarshall :: String -> Type -> Transfer -> CodeGen String
convertFMarshall name t@(TBasicType TUTF8) transfer =
    convert name $ fToH t transfer
convertFMarshall name t@(TBasicType TFileName) transfer =
    convert name $ fToH t transfer
convertFMarshall name (TBasicType _ ) _ = return name
convertFMarshall name t transfer = convert name $ fToH t transfer

convertHMarshall :: String -> Type -> Transfer -> CodeGen String
convertHMarshall name t@(TBasicType TUTF8) transfer =
    convert name $ hToF t transfer
convertHMarshall name t@(TBasicType TFileName) transfer =
    convert name $ hToF t transfer
convertHMarshall name (TBasicType _) _ = return name
convertHMarshall name t transfer =
    convert name $ hToF t transfer

haskellBasicType TVoid     = (ptr (typeOf ()))
haskellBasicType TBoolean  = typeOf True
haskellBasicType TInt8     = typeOf (0 :: Int8)
haskellBasicType TUInt8    = typeOf (0 :: Word8)
haskellBasicType TInt16    = typeOf (0 :: Int16)
haskellBasicType TUInt16   = typeOf (0 :: Word16)
haskellBasicType TInt32    = typeOf (0 :: Int32)
haskellBasicType TUInt32   = typeOf (0 :: Word32)
haskellBasicType TInt64    = typeOf (0 :: Int64)
haskellBasicType TUInt64   = typeOf (0 :: Word64)
haskellBasicType TGType    = "GType" `con` []
 -- XXX Text may be more appropriate
haskellBasicType TUTF8     = typeOf ("" :: String)
haskellBasicType TFloat    = typeOf (0 :: Float)
haskellBasicType TDouble   = typeOf (0 :: Double)
haskellBasicType TUniChar  = typeOf ('\0' :: Char)
haskellBasicType TFileName = "ByteString" `con` []

-- This translates GI types to the types used for generated Haskell code.
haskellType :: Type -> CodeGen TypeRep
haskellType (TBasicType bt) = return $ haskellBasicType bt
haskellType (TCArray _ _ _ (TBasicType TUInt8)) =
    return $ "ByteString" `con` []
haskellType (TCArray _ _ _ (TBasicType b)) =
    return $ "[]" `con` [haskellBasicType b]
haskellType (TCArray _ _ _ a@(TInterface _ _)) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TCArray _ _ _ a) =
    error $ "haskellType : Don't recognize CArray of type " ++ show a
haskellType (TGArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TPtrArray a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TByteArray) = return $ "ByteString" `con` []
haskellType (TGList a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGSList a) = do
  inner <- haskellType a
  return $ "[]" `con` [inner]
haskellType (TGHash a b) = do
  innerA <- haskellType a
  innerB <- haskellType b
  return $ "GHashTable" `con` [innerA, innerB]
haskellType TError = return $ "Error" `con` []
haskellType (TInterface ns n) = do
  prefix <- qualify ns
  return $ (prefix ++ n) `con` []

foreignBasicType TVoid     = ptr (typeOf ())
foreignBasicType TBoolean  = "CInt" `con` []
foreignBasicType TUTF8     = "CString" `con` []
foreignBasicType TFileName = "CString" `con` []
foreignBasicType TUniChar  = "CInt" `con` []
foreignBasicType t         = haskellBasicType t

-- This translates GI types to the types used in foreign function calls.
foreignType :: Type -> CodeGen TypeRep
foreignType (TBasicType t) = return $ foreignBasicType t
foreignType (TCArray _ _ _ t) = ptr <$> foreignType t
foreignType (TGArray a) = do
  inner <- foreignType a
  return $ ptr ("GArray" `con` [inner])
foreignType (TPtrArray a) = do
  inner <- foreignType a
  return $ ptr ("GPtrArray" `con` [inner])
foreignType (TByteArray) = return $ ptr ("GByteArray" `con` [])
foreignType (TGList a) = do
  inner <- foreignType a
  return $ ptr ("GList" `con` [inner])
foreignType (TGSList a) = do
  inner <- foreignType a
  return $ ptr ("GSList" `con` [inner])
foreignType t@(TGHash _ _) = ptr <$> haskellType t
foreignType t@TError = ptr <$> haskellType t
foreignType t@(TInterface ns n) = do
  isScalar <- getIsScalar t
  if isScalar
  then return $ "Word" `con` []
  else do
    prefix <- qualify ns
    return $ ptr $ (prefix ++ n) `con` []

getIsScalar :: Type -> CodeGen Bool
getIsScalar t = do
  a <- findAPI t
  case a of
    Nothing -> return False
    (Just (APIEnum _)) -> return True
    (Just (APIFlags _)) -> return True
    _ -> return False