{-# LANGUAGE OverloadedStrings #-}

-- |
-- SPDX-License-Identifier: BSD-3-Clause
--
-- Parser for terms of the Swarm language.
module Swarm.Language.Parser.Term where

import Control.Lens (view, (^.))
import Control.Monad (guard)
import Control.Monad.Combinators.Expr
import Control.Monad.Reader (ask)
import Data.Foldable (asum)
import Data.List (foldl')
import Data.Map (Map)
import Data.Map qualified as M
import Data.Maybe (mapMaybe)
import Data.Set qualified as S
import Data.Set.Lens (setOf)
import Swarm.Language.Parser.Core
import Swarm.Language.Parser.Lex
import Swarm.Language.Parser.Record (parseRecord)
import Swarm.Language.Parser.Type
import Swarm.Language.Syntax
import Swarm.Language.Types
import Text.Megaparsec hiding (runParser)
import Text.Megaparsec.Char

-- Imports for doctests (cabal-docspec needs this)

-- $setup
-- >>> import qualified Data.Map.Strict as M

--------------------------------------------------
-- Parser

parseDirection :: Parser Direction
parseDirection = asum (map alternative allDirs) <?> "direction constant"
 where
  alternative d = d <$ (reserved . directionSyntax) d

-- | Parse Const as reserved words (e.g. @Fail <$ reserved "fail"@)
parseConst :: Parser Const
parseConst = asum (map alternative consts) <?> "built-in user function"
 where
  consts = filter isUserFunc allConst
  alternative c = c <$ reserved (syntax $ constInfo c)

-- | Parse an atomic term, optionally trailed by record projections like @t.x.y.z@.
--   Record projection binds more tightly than function application.
parseTermAtom :: Parser Syntax
parseTermAtom = do
  s1 <- parseTermAtom2
  ps <- many (symbol "." *> parseLocG tmVar)
  return $ foldl' (\(Syntax l1 t) (l2, x) -> Syntax (l1 <> l2) (TProj t x)) s1 ps

-- | Parse an atomic term.
parseTermAtom2 :: Parser Syntax
parseTermAtom2 =
  parseLoc
    ( TUnit <$ symbol "()"
        <|> TConst <$> parseConst
        <|> TVar <$> tmVar
        <|> TDir <$> parseDirection
        <|> TInt <$> integer
        <|> TText <$> textLiteral
        <|> TBool <$> ((True <$ reserved "true") <|> (False <$ reserved "false"))
        <|> reserved "require"
          *> ( ( TRequireDevice
                  <$> (textLiteral <?> "device name in double quotes")
               )
                <|> ( (TRequire . fromIntegral <$> integer)
                        <*> (textLiteral <?> "entity name in double quotes")
                    )
             )
        <|> uncurry SRequirements <$> (reserved "requirements" *> match parseTerm)
        <|> SLam
          <$> (symbol "\\" *> locTmVar)
          <*> optional (symbol ":" *> parseType)
          <*> (symbol "." *> parseTerm)
        <|> sLet
          <$> (reserved "let" *> locTmVar)
          <*> optional (symbol ":" *> parsePolytype)
          <*> (symbol "=" *> parseTerm)
          <*> (reserved "in" *> parseTerm)
        <|> sDef
          <$> (reserved "def" *> locTmVar)
          <*> optional (symbol ":" *> parsePolytype)
          <*> (symbol "=" *> parseTerm <* reserved "end")
        <|> SRcd <$> brackets (parseRecord (optional (symbol "=" *> parseTerm)))
        <|> parens (view sTerm . mkTuple <$> (parseTerm `sepBy` symbol ","))
    )
    -- Potential syntax for explicitly requesting memoized delay.
    -- Perhaps we will not need this in the end; see the discussion at
    -- https://github.com/swarm-game/swarm/issues/150 .
    -- <|> parseLoc (TDelay SimpleDelay (TConst Noop) <$ try (symbol "{{" *> symbol "}}"))
    -- <|> parseLoc (SDelay MemoizedDelay <$> dbraces parseTerm)

    <|> parseLoc (TDelay SimpleDelay (TConst Noop) <$ try (symbol "{" *> symbol "}"))
    <|> parseLoc (SDelay SimpleDelay <$> braces parseTerm)
    <|> parseLoc (ask >>= (guard . (== AllowAntiquoting)) >> parseAntiquotation)

-- | Construct an 'SLet', automatically filling in the Boolean field
--   indicating whether it is recursive.
sLet :: LocVar -> Maybe Polytype -> Syntax -> Syntax -> Term
sLet x ty t1 = SLet (lvVar x `S.member` setOf freeVarsV t1) x ty t1

-- | Construct an 'SDef', automatically filling in the Boolean field
--   indicating whether it is recursive.
sDef :: LocVar -> Maybe Polytype -> Syntax -> Term
sDef x ty t = SDef (lvVar x `S.member` setOf freeVarsV t) x ty t

parseAntiquotation :: Parser Term
parseAntiquotation =
  TAntiText <$> (lexeme . try) (symbol "$str:" *> tmVar)
    <|> TAntiInt <$> (lexeme . try) (symbol "$int:" *> tmVar)

-- | Parse a Swarm language term.
parseTerm :: Parser Syntax
parseTerm = sepEndBy1 parseStmt (symbol ";") >>= mkBindChain

mkBindChain :: [Stmt] -> Parser Syntax
mkBindChain stmts = case last stmts of
  Binder x _ -> return $ foldr mkBind (STerm (TApp (TConst Return) (TVar (lvVar x)))) stmts
  BareTerm t -> return $ foldr mkBind t (init stmts)
 where
  mkBind (BareTerm t1) t2 = loc Nothing t1 t2 $ SBind Nothing t1 t2
  mkBind (Binder x t1) t2 = loc (Just x) t1 t2 $ SBind (Just x) t1 t2
  loc mx a b = Syntax $ maybe NoLoc lvSrcLoc mx <> (a ^. sLoc) <> (b ^. sLoc)

data Stmt
  = BareTerm Syntax
  | Binder LocVar Syntax
  deriving (Show)

parseStmt :: Parser Stmt
parseStmt =
  mkStmt <$> optional (try (locTmVar <* symbol "<-")) <*> parseExpr

mkStmt :: Maybe LocVar -> Syntax -> Stmt
mkStmt Nothing = BareTerm
mkStmt (Just x) = Binder x

-- | When semicolons are missing between definitions, for example:
--     def a = 1 end def b = 2 end def c = 3 end
--   The makeExprParser produces:
--     App (App (TDef a) (TDef b)) (TDef x)
--   This function fix that by converting the Apps into Binds, so that it results in:
--     Bind a (Bind b (Bind c))
fixDefMissingSemis :: Syntax -> Syntax
fixDefMissingSemis term =
  case nestedDefs term [] of
    [] -> term
    defs -> foldr1 mkBind defs
 where
  mkBind t1 t2 = Syntax ((t1 ^. sLoc) <> (t2 ^. sLoc)) $ SBind Nothing t1 t2
  nestedDefs term' acc = case term' of
    def@(Syntax _ SDef {}) -> def : acc
    (Syntax _ (SApp nestedTerm def@(Syntax _ SDef {}))) -> nestedDefs nestedTerm (def : acc)
    -- Otherwise returns an empty list to keep the term unchanged
    _ -> []

parseExpr :: Parser Syntax
parseExpr =
  parseLoc $ ascribe <$> parseExpr' <*> optional (symbol ":" *> parsePolytype)
 where
  ascribe :: Syntax -> Maybe Polytype -> Term
  ascribe s Nothing = s ^. sTerm
  ascribe s (Just ty) = SAnnotate s ty

parseExpr' :: Parser Syntax
parseExpr' = fixDefMissingSemis <$> makeExprParser parseTermAtom table
 where
  table = snd <$> M.toDescList tableMap
  tableMap =
    M.unionsWith
      (++)
      [ M.singleton 9 [InfixL (exprLoc2 $ SApp <$ string "")]
      , binOps
      , unOps
      ]

  -- add location for ExprParser by combining all
  exprLoc2 :: Parser (Syntax -> Syntax -> Term) -> Parser (Syntax -> Syntax -> Syntax)
  exprLoc2 p = do
    (l, f) <- parseLocG p
    pure $ \s1 s2 -> Syntax (l <> (s1 ^. sLoc) <> (s2 ^. sLoc)) $ f s1 s2

-- | Precedences and parsers of binary operators.
--
-- >>> M.map length binOps
-- fromList [(0,1),(2,1),(3,1),(4,6),(6,3),(7,2),(8,1)]
binOps :: Map Int [Operator Parser Syntax]
binOps = M.unionsWith (++) $ mapMaybe binOpToTuple allConst
 where
  binOpToTuple c = do
    let ci = constInfo c
    ConstMBinOp assoc <- pure (constMeta ci)
    let assI = case assoc of
          L -> InfixL
          N -> InfixN
          R -> InfixR
    pure $
      M.singleton
        (fixity ci)
        [assI (mkOp c <$ operator (syntax ci))]

-- | Precedences and parsers of unary operators (currently only 'Neg').
--
-- >>> M.map length unOps
-- fromList [(7,1)]
unOps :: Map Int [Operator Parser Syntax]
unOps = M.unionsWith (++) $ mapMaybe unOpToTuple allConst
 where
  unOpToTuple c = do
    let ci = constInfo c
    ConstMUnOp assoc <- pure (constMeta ci)
    let assI = case assoc of
          P -> Prefix
          S -> Postfix
    pure $
      M.singleton
        (fixity ci)
        [assI (exprLoc1 $ SApp (noLoc $ TConst c) <$ operator (syntax ci))]

  -- combine location for ExprParser
  exprLoc1 :: Parser (Syntax -> Term) -> Parser (Syntax -> Syntax)
  exprLoc1 p = do
    (l, f) <- parseLocG p
    pure $ \s -> Syntax (l <> s ^. sLoc) $ f s