-- | Utilities to pretty print 'Expr' and 'EditExpr'
module Test.StateMachine.TreeDiff.Pretty (
    -- * Explicit dictionary
    Pretty (..),
    ppExpr,
    ppEditExpr,
    ppEditExprCompact,
    -- * pretty
    prettyPretty,
    prettyExpr,
    prettyEditExpr,
    prettyEditExprCompact,
    -- * ansi-wl-pprint
    ansiWlPretty,
    ansiWlExpr,
    ansiWlEditExpr,
    ansiWlEditExprCompact,
    -- ** background
    ansiWlBgPretty,
    ansiWlBgExpr,
    ansiWlBgEditExpr,
    ansiWlBgEditExprCompact,
    -- * Utilities
    escapeName,
    ) where

import           Data.Char
                   (isAlphaNum, isPunctuation, isSymbol, ord)
import           Data.Either
                   (partitionEithers)
import           Numeric
                   (showHex)
import           Prettyprinter.Render.Terminal (Color (..))
import           Test.StateMachine.TreeDiff.Expr
import           Text.Read
                   (readMaybe)


import qualified Data.Map                        as Map
import qualified Text.PrettyPrint                as HJ
import qualified Prettyprinter                   as WL
import qualified Prettyprinter.Render.Terminal   as PRT

-- | Because we don't want to commit to single pretty printing library,
-- we use explicit dictionary.
data Pretty doc = Pretty
    { ppCon    :: ConstructorName -> doc
    , ppRec    :: [(FieldName, doc)] -> doc
    , ppLst    :: [doc] -> doc
    , ppCpy    :: doc -> doc
    , ppIns    :: doc -> doc
    , ppDel    :: doc -> doc
    , ppSep    :: [doc] -> doc
    , ppParens :: doc -> doc
    , ppHang   :: doc -> doc -> doc
    }

-- | Escape field or constructor name
--
-- >>> putStrLn $ escapeName "Foo"
-- Foo
--
-- >>> putStrLn $ escapeName "_×_"
-- _×_
--
-- >>> putStrLn $ escapeName "-3"
-- `-3`
--
-- >>> putStrLn $ escapeName "kebab-case"
-- kebab-case
--
-- >>> putStrLn $ escapeName "inner space"
-- `inner space`
--
-- >>> putStrLn $ escapeName $ show "looks like a string"
-- "looks like a string"
--
-- >>> putStrLn $ escapeName $ show "tricky" ++ "   "
-- `"tricky"   `
--
-- >>> putStrLn $ escapeName "[]"
-- `[]`
--
-- >>> putStrLn $ escapeName "_,_"
-- `_,_`
--
escapeName :: String -> String
escapeName n
    | null n                      = "``"
    | isValidString n             = n
    | all valid' n && headNotMP n = n
    | otherwise                   = "`" ++ concatMap e n ++ "`"
  where
    e '`'               = "\\`"
    e '\\'              = "\\\\"
    e ' '               = " "
    e c | not (valid c) = "\\x" ++ showHex (ord c) ";"
    e c                 = [c]

    valid c = isAlphaNum c || isSymbol c || isPunctuation c
    valid' c = valid c && c `notElem` "[](){}`\","

    headNotMP ('-' : _) = False
    headNotMP ('+' : _) = False
    headNotMP _         = True

    isValidString s
        | length s >= 2 && head s == '"' && last s == '"' =
            case readMaybe s :: Maybe String of
                Just _  -> True
                Nothing -> False
    isValidString _         = False

-- | Pretty print an 'Expr' using explicit pretty-printing dictionary.
ppExpr :: Pretty doc -> Expr -> doc
ppExpr p = ppExpr' p False

ppExpr' :: Pretty doc -> Bool -> Expr -> doc
ppExpr' p = impl where
    impl _ (App x []) = ppCon p (escapeName x)
    impl b (App x xs) = ppParens' b $ ppHang p (ppCon p (escapeName x)) $
        ppSep p $ map (impl True) xs
    impl _ (Rec x xs) = ppHang p (ppCon p (escapeName x)) $ ppRec p $
        map ppField' $ Map.toList xs
    impl _ (Lst xs)   = ppLst p (map (impl False) xs)

    ppField' (n, e) = (escapeName n, impl False e)

    ppParens' True  = ppParens p
    ppParens' False = id

-- | Pretty print an @'Edit' 'EditExpr'@ using explicit pretty-printing dictionary.
ppEditExpr :: Pretty doc -> Edit EditExpr -> doc
ppEditExpr = ppEditExpr' False

-- | Like 'ppEditExpr' but print unchanged parts only shallowly
ppEditExprCompact :: Pretty doc -> Edit EditExpr -> doc
ppEditExprCompact = ppEditExpr' True

ppEditExpr' :: Bool -> Pretty doc -> Edit EditExpr -> doc
ppEditExpr' compact p = ppSep p . ppEdit False
  where
    ppEdit b (Cpy (EditExp expr)) = [ ppCpy p $ ppExpr' p b expr ]
    ppEdit b (Cpy expr) = [ ppEExpr b expr ]
    ppEdit b (Ins expr) = [ ppIns p (ppEExpr b expr) ]
    ppEdit b (Del expr) = [ ppDel p (ppEExpr b expr) ]
    ppEdit b (Swp x y) =
        [ ppDel p (ppEExpr b x)
        , ppIns p (ppEExpr b y)
        ]

    ppEExpr _ (EditApp x []) = ppCon p (escapeName x)
    ppEExpr b (EditApp x xs) = ppParens' b $ ppHang p (ppCon p (escapeName x)) $
        ppSep p $ concatMap (ppEdit True) xs
    ppEExpr _ (EditRec x xs) = ppHang p (ppCon p (escapeName x)) $ ppRec p $
        justs ++ [ (n, ppCon p "...") | n <- take 1 nothings ]
      where
        xs' = map ppField' $ Map.toList xs
        (nothings, justs) = partitionEithers xs'

    ppEExpr _ (EditLst xs)   = ppLst p (concatMap (ppEdit False) xs)
    ppEExpr b (EditExp x)    = ppExpr' p b x

    ppField' (n, Cpy (EditExp e)) | compact, not (isScalar e) = Left n
    ppField' (n, e) = Right (escapeName n, ppSep p $ ppEdit False e)

    ppParens' True  = ppParens p
    ppParens' False = id

    isScalar (App _ []) = True
    isScalar _          = False

-------------------------------------------------------------------------------
-- pretty
-------------------------------------------------------------------------------

-- | 'Pretty' via @pretty@ library.
prettyPretty :: Pretty HJ.Doc
prettyPretty = Pretty
    { ppCon    = HJ.text
    , ppRec    = HJ.braces . HJ.sep . HJ.punctuate HJ.comma
               . map (\(fn, d) -> HJ.text fn HJ.<+> HJ.equals HJ.<+> d)
    , ppLst    = HJ.brackets . HJ.sep . HJ.punctuate HJ.comma
    , ppCpy    = id
    , ppIns    = \d -> HJ.char '+' HJ.<> d
    , ppDel    = \d -> HJ.char '-' HJ.<> d
    , ppSep    = HJ.sep
    , ppParens = HJ.parens
    , ppHang   = \d1 d2 -> HJ.hang d1 2 d2
    }

-- | Pretty print 'Expr' using @pretty@.
--
-- >>> prettyExpr $ Rec "ex" (Map.fromList [("[]", App "bar" [])])
-- ex {`[]` = bar}
prettyExpr :: Expr -> HJ.Doc
prettyExpr = ppExpr prettyPretty

-- | Pretty print @'Edit' 'EditExpr'@ using @pretty@.
prettyEditExpr :: Edit EditExpr -> HJ.Doc
prettyEditExpr = ppEditExpr prettyPretty

-- | Compact 'prettyEditExpr'.
prettyEditExprCompact :: Edit EditExpr -> HJ.Doc
prettyEditExprCompact = ppEditExprCompact prettyPretty

-------------------------------------------------------------------------------
-- ansi-wl-pprint
-------------------------------------------------------------------------------

-- | 'Pretty' via @ansi-wl-pprint@ library (with colors).
ansiWlPretty :: Pretty (WL.Doc PRT.AnsiStyle)
ansiWlPretty = Pretty
    { ppCon    = WL.pretty
    , ppRec    = WL.encloseSep WL.lbrace WL.rbrace WL.comma
               . map (\(fn, d) -> WL.text fn WL.<+> WL.equals WL.</> d)
    , ppLst    = WL.list
    , ppCpy    = WL.annotate (PRT.colorDull White)
    , ppIns    = \d -> WL.annotate (PRT.bgColorDull Green) $ WL.unAnnotate $ WL.pretty '+' <> d
    , ppDel    = \d -> WL.annotate (PRT.bgColorDull Red)   $ WL.unAnnotate $ WL.pretty '-' <> d
    , ppSep    = WL.sep
    , ppParens = WL.parens
    , ppHang   = \d1 d2 -> WL.hang 2 (d1 WL.fillSep d2)
    }

-- | Pretty print 'Expr' using @ansi-wl-pprint@.
ansiWlExpr :: Expr -> WL.Doc PRT.AnsiStyle
ansiWlExpr = ppExpr ansiWlPretty

-- | Pretty print @'Edit' 'EditExpr'@ using @ansi-wl-pprint@.
ansiWlEditExpr :: Edit EditExpr -> WL.Doc PRT.AnsiStyle
ansiWlEditExpr = ppEditExpr ansiWlPretty

-- | Compact 'ansiWlEditExpr'
ansiWlEditExprCompact :: Edit EditExpr -> WL.Doc PRT.AnsiStyle
ansiWlEditExprCompact = ppEditExprCompact ansiWlPretty

-------------------------------------------------------------------------------
-- Background
-------------------------------------------------------------------------------

-- | Like 'ansiWlPretty' but color the background.
ansiWlBgPretty :: Pretty (WL.Doc PRT.AnsiStyle)
ansiWlBgPretty = ansiWlPretty
    { ppIns    = \d -> WL.annotate (PRT.bgColorDull Green) $ WL.space $ WL.unAnnotate $ WL.pretty '+' <> d
    , ppDel    = \d -> WL.annotate (PRT.bgColorDull Red)   $ WL.space $ WL.unAnnotate $ WL.pretty '-' <> d
    }

-- | Pretty print 'Expr' using @ansi-wl-pprint@.
ansiWlBgExpr :: Expr -> WL.Doc PRT.AnsiStyle
ansiWlBgExpr = ppExpr ansiWlBgPretty

-- | Pretty print @'Edit' 'EditExpr'@ using @ansi-wl-pprint@.
ansiWlBgEditExpr :: Edit EditExpr -> WL.Doc PRT.AnsiStyle
ansiWlBgEditExpr = ppEditExpr ansiWlBgPretty

-- | Compact 'ansiWlBgEditExpr'.
ansiWlBgEditExprCompact :: Edit EditExpr -> WL.Doc PRT.AnsiStyle
ansiWlBgEditExprCompact = ppEditExprCompact ansiWlBgPretty
